//! JavaScriptCore host object. `hasProperty` is true for every name so `in` and `hasOwnProperty` succeed even when the name is not enumerated. `getPropertyNames` is the only source of `Object.keys` / `getOwnPropertyNames`. The finalizer does not call context APIs.

const std = @import("std");
const sync = @import("zev");
const host_value = @import("../../abi/host_value.zig");
const common = @import("common.zig");

const jsc = common.jsc;

pub const GetFn = *const fn (instance_id: i32, user_data: ?*anyopaque, name: []const u8, out: *host_value.HostValue) ?[*:0]const u8;
pub const SetFn = *const fn (instance_id: i32, user_data: ?*anyopaque, name: []const u8, value: host_value.HostValue) ?[*:0]const u8;
pub const NamesFn = *const fn (instance_id: i32, user_data: ?*anyopaque, out_names: *[]const []const u8) void;
pub const FinalizeFn = *const fn (user_data: ?*anyopaque) void;

extern "c" fn JSPropertyNameAccumulatorAddName(accumulator: jsc.JSPropertyNameAccumulatorRef, property_name: jsc.JSStringRef) void;

const Box = struct {
    instance_id: i32,
    user_data: ?*anyopaque,
    get_fn: ?GetFn,
    set_fn: ?SetFn,
    names_fn: ?NamesFn,
    finalize_fn: ?FinalizeFn,
    finalized: bool = false,
};

var class_ref: ?jsc.JSClassRef = null;
var class_mu: sync.Mutex = .{};

const class_name: [*:0]const u8 = "JsBayQjsHostObject";

fn boxOf(obj: jsc.JSObjectRef) ?*Box {
    const raw = jsc.JSObjectGetPrivate(obj) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn setException(exception: [*c]jsc.JSValueRef, value: jsc.JSValueRef) void {
    if (exception != null) exception.* = value;
}

fn makeError(ctx: jsc.JSContextRef, name: []const u8, msg: []const u8) jsc.JSValueRef {
    const msg_val = common.makeStringValue(ctx, msg) orelse return jsc.JSValueMakeUndefined(ctx);
    var args = [_]jsc.JSValueRef{msg_val};
    var inner: jsc.JSValueRef = null;
    const err_obj = jsc.JSObjectMakeError(ctx, 1, &args, &inner);
    if (err_obj == null) return msg_val;
    const name_val = common.makeStringValue(ctx, name) orelse return err_obj;
    common.setProperty(ctx, err_obj, "name", name_val);
    return err_obj;
}

fn nameFromJs(property_name: jsc.JSStringRef) ?[]u8 {
    return common.jsStringToOwnedAlloc(std.heap.c_allocator, property_name);
}

const HostConversion = union(enum) {
    value: jsc.JSValueRef,
    out_of_memory,
};

fn hostToJs(ctx: jsc.JSContextRef, hv: host_value.HostValue) HostConversion {
    switch (hv.tag) {
        host_value.tag_number => return .{ .value = jsc.JSValueMakeNumber(ctx, hv.number) },
        host_value.tag_string => {
            const ptr = hv.ptr orelse return .{ .value = jsc.JSValueMakeUndefined(ctx) };
            const slice: []const u8 = if (hv.len == 0) "" else ptr[0..hv.len];
            const js = common.jsStringFromSlice(slice) orelse return .out_of_memory;
            defer jsc.JSStringRelease(js);
            return .{ .value = jsc.JSValueMakeString(ctx, js) };
        },
        else => return .{ .value = jsc.JSValueMakeUndefined(ctx) },
    }
}

fn valueToHost(ctx: jsc.JSContextRef, value: jsc.JSValueRef, hv: *host_value.HostValue, str_buf: *?[]u8) bool {
    host_value.clear(hv);
    if (value == null or jsc.JSValueIsUndefined(ctx, value) or jsc.JSValueIsNull(ctx, value)) return true;
    if (jsc.JSValueIsNumber(ctx, value)) {
        var exc: jsc.JSValueRef = null;
        const n = jsc.JSValueToNumber(ctx, value, &exc);
        if (exc != null) return false;
        hv.tag = host_value.tag_number;
        hv.number = n;
        return true;
    }
    if (jsc.JSValueIsString(ctx, value)) {
        var exc: jsc.JSValueRef = null;
        const js = jsc.JSValueToStringCopy(ctx, value, &exc);
        if (exc != null or js == null) return false;
        defer jsc.JSStringRelease(js);
        const owned = nameFromJs(js) orelse return false;
        str_buf.* = owned;
        hv.tag = host_value.tag_string;
        hv.ptr = owned.ptr;
        hv.len = owned.len;
        return true;
    }
    return true;
}

fn jscHas(
    ctx: jsc.JSContextRef,
    object: jsc.JSObjectRef,
    property_name: jsc.JSStringRef,
) callconv(.c) bool {
    _ = ctx;
    _ = property_name;
    return boxOf(object) != null;
}

fn jscGet(
    ctx: jsc.JSContextRef,
    object: jsc.JSObjectRef,
    property_name: jsc.JSStringRef,
    exception: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const box = boxOf(object) orelse return null;
    const get_fn = box.get_fn orelse return jsc.JSValueMakeUndefined(ctx);
    const name_buf = nameFromJs(property_name) orelse {
        setException(exception, makeError(ctx, "Error", "host object name"));
        return null;
    };
    defer std.heap.c_allocator.free(name_buf);
    const name: []const u8 = name_buf;
    var out: host_value.HostValue = undefined;
    host_value.clear(&out);
    if (get_fn(box.instance_id, box.user_data, name, &out)) |msg| {
        setException(exception, makeError(ctx, "Error", std.mem.span(msg)));
        return null;
    }
    return switch (hostToJs(ctx, out)) {
        .value => |value| value,
        .out_of_memory => {
            setException(exception, makeError(ctx, "Error", "out of memory"));
            return null;
        },
    };
}

fn jscSet(
    ctx: jsc.JSContextRef,
    object: jsc.JSObjectRef,
    property_name: jsc.JSStringRef,
    value: jsc.JSValueRef,
    exception: [*c]jsc.JSValueRef,
) callconv(.c) bool {
    const box = boxOf(object) orelse return false;
    const set_fn = box.set_fn orelse {
        // Plain Error. The message carries the TypeError prefix; the name stays "Error".
        setException(exception, makeError(ctx, "Error", "TypeError: cannot set property"));
        return true;
    };
    const name_buf = nameFromJs(property_name) orelse {
        setException(exception, makeError(ctx, "Error", "host object name"));
        return true;
    };
    defer std.heap.c_allocator.free(name_buf);
    const name: []const u8 = name_buf;

    var hv: host_value.HostValue = undefined;
    var str_buf: ?[]u8 = null;
    defer if (str_buf) |b| std.heap.c_allocator.free(b);
    if (!valueToHost(ctx, value, &hv, &str_buf)) {
        setException(exception, makeError(ctx, "Error", "host object value"));
        return true;
    }
    if (set_fn(box.instance_id, box.user_data, name, hv)) |msg| {
        setException(exception, makeError(ctx, "Error", std.mem.span(msg)));
        return true;
    }
    return true;
}

/// Canonical array index: decimal form of an integer in `0 .. 2^32-2`.
fn canonicalArrayIndex(name: []const u8) ?u32 {
    if (name.len == 0 or name.len > 10) return null;
    if (name[0] == '0') return if (name.len == 1) 0 else null;
    var n: u64 = 0;
    for (name) |ch| {
        if (ch < '0' or ch > '9') return null;
        n = n * 10 + (ch - '0');
    }
    if (n >= 0xFFFF_FFFF) return null;
    return @intCast(n);
}

/// Integer indices ascending, then every other name in input order.
fn writeEnumerationOrder(names: []const []const u8, order: []usize) void {
    var n: usize = 0;
    for (names, 0..) |name, i| {
        if (canonicalArrayIndex(name) != null) {
            order[n] = i;
            n += 1;
        }
    }
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const key = order[i];
        const key_num = canonicalArrayIndex(names[key]).?;
        var j: usize = i;
        while (j > 0) {
            const prev = order[j - 1];
            const prev_num = canonicalArrayIndex(names[prev]).?;
            if (prev_num < key_num or (prev_num == key_num and prev < key)) break;
            order[j] = prev;
            j -= 1;
        }
        order[j] = key;
    }
    for (names, 0..) |name, idx| {
        if (canonicalArrayIndex(name) == null) {
            order[n] = idx;
            n += 1;
        }
    }
}

fn addName(property_names: jsc.JSPropertyNameAccumulatorRef, name: []const u8) bool {
    const tmp = std.heap.c_allocator.alloc(u8, name.len + 1) catch return false;
    defer std.heap.c_allocator.free(tmp);
    if (name.len > 0) @memcpy(tmp[0..name.len], name);
    tmp[name.len] = 0;
    const js = jsc.JSStringCreateWithUTF8CString(tmp[0..name.len :0].ptr);
    defer jsc.JSStringRelease(js);
    JSPropertyNameAccumulatorAddName(property_names, js);
    return true;
}

fn jscNames(
    ctx: jsc.JSContextRef,
    object: jsc.JSObjectRef,
    property_names: jsc.JSPropertyNameAccumulatorRef,
) callconv(.c) void {
    const box = boxOf(object) orelse return;
    var list: []const []const u8 = &.{};
    if (box.names_fn) |names_fn| names_fn(box.instance_id, box.user_data, &list);
    var order_stack: [64]usize = undefined;
    const order = if (list.len <= order_stack.len)
        order_stack[0..list.len]
    else
        std.heap.c_allocator.alloc(usize, list.len) catch {
            for (list) |name| {
                if (!addName(property_names, name)) return;
            }
            return;
        };
    defer if (list.len > order_stack.len) std.heap.c_allocator.free(order);
    if (list.len <= order_stack.len or order.len == list.len) {
        writeEnumerationOrder(list, order);
        for (order) |name_index| {
            if (!addName(property_names, list[name_index])) return;
        }
    }
    _ = ctx;
}

fn jscFinalize(object: jsc.JSObjectRef) callconv(.c) void {
    const raw = jsc.JSObjectGetPrivate(object) orelse return;
    // Clear private data before the user callback. A later sweep, including engine destroy, must not enter this finalizer again. No context API.
    _ = jsc.JSObjectSetPrivate(object, null);
    const box: *Box = @ptrCast(@alignCast(raw));
    if (box.finalized) return;
    box.finalized = true;
    const fin = box.finalize_fn;
    box.finalize_fn = null;
    if (fin) |f| f(box.user_data);
    std.heap.c_allocator.destroy(box);
}

fn ensureClass() jsc.JSClassRef {
    class_mu.lock();
    defer class_mu.unlock();
    if (class_ref) |existing| return existing;
    var def = jsc.kJSClassDefinitionEmpty;
    def.className = class_name;
    def.hasProperty = jscHas;
    def.getProperty = jscGet;
    def.setProperty = jscSet;
    def.getPropertyNames = jscNames;
    def.finalize = jscFinalize;
    class_ref = jsc.JSClassCreate(&def);
    return class_ref.?;
}

pub fn create(
    ctx: jsc.JSContextRef,
    instance_id: i32,
    user_data: ?*anyopaque,
    get_fn: ?GetFn,
    set_fn: ?SetFn,
    names_fn: ?NamesFn,
    finalize_fn: ?FinalizeFn,
) jsc.JSObjectRef {
    const cls = ensureClass();
    const box = std.heap.c_allocator.create(Box) catch return null;
    box.* = .{
        .instance_id = instance_id,
        .user_data = user_data,
        .get_fn = get_fn,
        .set_fn = set_fn,
        .names_fn = names_fn,
        .finalize_fn = finalize_fn,
    };
    const obj = jsc.JSObjectMake(ctx, cls, @ptrCast(box));
    if (obj == null) {
        std.heap.c_allocator.destroy(box);
        return null;
    }
    return obj;
}
