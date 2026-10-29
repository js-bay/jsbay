//! QuickJS exotic host object. Property traps live on the class; the per-object box only stores the callbacks captured at creation.
//!
//! `finalize` runs from the class finalizer. It must not evaluate script. The opaque pointer is cleared before the user callback so a nested collection cannot enter the same finalizer again.

const std = @import("std");
const sync = @import("zev");
const host_value = @import("../../abi/host_value.zig");
const c = @import("c_api.zig");
const qjs = c.qjs;

pub const GetFn = *const fn (instance_id: i32, user_data: ?*anyopaque, name: []const u8, out: *host_value.HostValue) ?[*:0]const u8;
pub const SetFn = *const fn (instance_id: i32, user_data: ?*anyopaque, name: []const u8, value: host_value.HostValue) ?[*:0]const u8;
pub const NamesFn = *const fn (instance_id: i32, user_data: ?*anyopaque, out_names: *[]const []const u8) void;
pub const FinalizeFn = *const fn (user_data: ?*anyopaque) void;

const Box = struct {
    instance_id: i32,
    user_data: ?*anyopaque,
    get_fn: ?GetFn,
    set_fn: ?SetFn,
    names_fn: ?NamesFn,
    finalize_fn: ?FinalizeFn,
    finalized: bool = false,
};

var class_id: qjs.JSClassID = 0;
var class_mu: sync.Mutex = .{};

fn boxOf(obj: qjs.JSValue) ?*Box {
    if (class_id == 0) return null;
    const raw = qjs.JS_GetOpaque(obj, class_id) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn throwMsg(ctx: ?*qjs.JSContext, msg: [*:0]const u8) qjs.JSValue {
    return qjs.JS_ThrowTypeError(ctx, "%s", msg);
}

/// Plain Error, not a TypeError. `message` is the own message string, so callers that only scan text still see the "TypeError: " prefix.
fn throwPlainError(ctx: ?*qjs.JSContext, msg: [*:0]const u8) qjs.JSValue {
    const err = qjs.JS_NewError(ctx);
    if (c.jsIsException(err)) return err;
    const msg_val = c.jsbay_qjs_JS_NewString(ctx, msg);
    if (c.jsIsException(msg_val)) {
        c.jsbay_qjs_JS_FreeValue(ctx, err);
        return msg_val;
    }
    _ = qjs.JS_DefinePropertyValueStr(
        ctx,
        err,
        "message",
        msg_val,
        qjs.JS_PROP_WRITABLE | qjs.JS_PROP_CONFIGURABLE,
    );
    return qjs.JS_Throw(ctx, err);
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

/// Integer indices ascending, then every other name in input order. QuickJS keeps exotic own-keys in callback order, so the sort has to happen here.
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

fn hostToJs(ctx: ?*qjs.JSContext, hv: host_value.HostValue) qjs.JSValue {
    switch (hv.tag) {
        host_value.tag_number => return c.jsbay_qjs_JS_NewFloat64(ctx, hv.number),
        host_value.tag_string => {
            const ptr = hv.ptr orelse return c.JS_UNDEFINED;
            return qjs.JS_NewStringLen(ctx, ptr, hv.len);
        },
        else => return c.JS_UNDEFINED,
    }
}

fn readName(ctx: ?*qjs.JSContext, atom: qjs.JSAtom) ?[]const u8 {
    var len: usize = 0;
    const ptr = qjs.JS_AtomToCStringLen(ctx, &len, atom) orelse return null;
    return ptr[0..len];
}

fn freeName(ctx: ?*qjs.JSContext, name: []const u8) void {
    c.jsbay_qjs_JS_FreeCString(ctx, @ptrCast(name.ptr));
}

fn callGet(ctx: ?*qjs.JSContext, box: *Box, name: []const u8) qjs.JSValue {
    const get_fn = box.get_fn orelse return c.JS_UNDEFINED;
    var out: host_value.HostValue = undefined;
    host_value.clear(&out);
    if (get_fn(box.instance_id, box.user_data, name, &out)) |msg| {
        return throwMsg(ctx, msg);
    }
    return hostToJs(ctx, out);
}

fn qjsGetOwn(
    ctx: ?*qjs.JSContext,
    desc: [*c]qjs.JSPropertyDescriptor,
    obj: qjs.JSValue,
    prop: qjs.JSAtom,
) callconv(.c) c_int {
    const box = boxOf(obj) orelse return 0;
    const name = readName(ctx, prop) orelse return -1;
    defer freeName(ctx, name);
    // Every name is an own property, including names absent from the enumeration list. That is what `in` and hasOwnProperty observe.
    const value = callGet(ctx, box, name);
    if (c.jsIsException(value)) return -1;
    if (desc) |d| {
        d.* = .{
            .flags = qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_WRITABLE | qjs.JS_PROP_ENUMERABLE,
            .value = value,
            .getter = c.JS_UNDEFINED,
            .setter = c.JS_UNDEFINED,
        };
    } else {
        c.jsbay_qjs_JS_FreeValue(ctx, value);
    }
    return 1;
}

fn qjsOwnNames(
    ctx: ?*qjs.JSContext,
    ptab: [*c][*c]qjs.JSPropertyEnum,
    plen: [*c]u32,
    obj: qjs.JSValue,
) callconv(.c) c_int {
    ptab.* = null;
    plen.* = 0;
    const box = boxOf(obj) orelse return 0;
    var list: []const []const u8 = &.{};
    if (box.names_fn) |names_fn| names_fn(box.instance_id, box.user_data, &list);
    if (list.len == 0) return 0;
    if (list.len > std.math.maxInt(u32)) return -1;

    const raw = qjs.js_malloc(ctx, list.len * @sizeOf(qjs.JSPropertyEnum)) orelse return -1;
    const tab: [*]qjs.JSPropertyEnum = @ptrCast(@alignCast(raw));
    var order_stack: [64]usize = undefined;
    const order = if (list.len <= order_stack.len)
        order_stack[0..list.len]
    else
        std.heap.c_allocator.alloc(usize, list.len) catch {
            qjs.js_free(ctx, raw);
            return -1;
        };
    defer if (list.len > order_stack.len) std.heap.c_allocator.free(order);
    writeEnumerationOrder(list, order);
    var filled: usize = 0;
    for (order) |name_index| {
        const name = list[name_index];
        const atom = qjs.JS_NewAtomLen(ctx, name.ptr, name.len);
        if (atom == qjs.JS_ATOM_NULL) {
            var i: usize = 0;
            while (i < filled) : (i += 1) qjs.JS_FreeAtom(ctx, tab[i].atom);
            qjs.js_free(ctx, raw);
            return -1;
        }
        tab[filled] = .{ .is_enumerable = true, .atom = atom };
        filled += 1;
    }
    ptab.* = tab;
    plen.* = @intCast(list.len);
    return 0;
}

fn qjsHas(
    ctx: ?*qjs.JSContext,
    obj: qjs.JSValue,
    atom: qjs.JSAtom,
) callconv(.c) c_int {
    _ = ctx;
    _ = atom;
    if (boxOf(obj) == null) return 0;
    return 1;
}

fn qjsGet(
    ctx: ?*qjs.JSContext,
    obj: qjs.JSValue,
    atom: qjs.JSAtom,
    receiver: qjs.JSValue,
) callconv(.c) qjs.JSValue {
    _ = receiver;
    const box = boxOf(obj) orelse return c.JS_UNDEFINED;
    const name = readName(ctx, atom) orelse return c.JS_EXCEPTION;
    defer freeName(ctx, name);
    return callGet(ctx, box, name);
}

fn qjsSet(
    ctx: ?*qjs.JSContext,
    obj: qjs.JSValue,
    atom: qjs.JSAtom,
    value: qjs.JSValue,
    receiver: qjs.JSValue,
    flags: c_int,
) callconv(.c) c_int {
    _ = receiver;
    _ = flags;
    const box = boxOf(obj) orelse return 0;
    const set_fn = box.set_fn orelse {
        _ = throwPlainError(ctx, "TypeError: cannot set property");
        return -1;
    };
    const name = readName(ctx, atom) orelse return -1;
    defer freeName(ctx, name);

    var hv: host_value.HostValue = undefined;
    host_value.clear(&hv);
    var cstr: ?[*]const u8 = null;
    defer if (cstr) |ptr| qjs.JS_FreeCString(ctx, ptr);

    if (c.jsbay_qjs_JS_IsNumber(value) != 0) {
        var n: f64 = 0;
        if (qjs.JS_ToFloat64(ctx, &n, value) != 0) return -1;
        hv.tag = host_value.tag_number;
        hv.number = n;
    } else if (c.jsbay_qjs_JS_IsString(value) != 0) {
        var len: usize = 0;
        cstr = qjs.JS_ToCStringLen(ctx, &len, value) orelse return -1;
        hv.tag = host_value.tag_string;
        hv.ptr = cstr.?;
        hv.len = len;
    }

    if (set_fn(box.instance_id, box.user_data, name, hv)) |msg| {
        _ = throwMsg(ctx, msg);
        return -1;
    }
    return 1;
}

fn qjsHostFinalizer(rt: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const raw = qjs.JS_GetOpaque(val, class_id) orelse return;
    const box: *Box = @ptrCast(@alignCast(raw));
    if (box.finalized) return;
    box.finalized = true;
    // A nested sweep must not observe this object as still having a finalizer.
    _ = qjs.JS_SetOpaque(val, null);
    const fin = box.finalize_fn;
    box.finalize_fn = null;
    if (fin) |f| f(box.user_data);
    qjs.js_free_rt(rt, raw);
}

var exotic_methods = qjs.JSClassExoticMethods{
    .get_own_property = qjsGetOwn,
    .get_own_property_names = qjsOwnNames,
    .delete_property = null,
    .define_own_property = null,
    .has_property = qjsHas,
    .get_property = qjsGet,
    .set_property = qjsSet,
};

fn ensureClass(rt: ?*qjs.JSRuntime) void {
    class_mu.lock();
    defer class_mu.unlock();
    _ = c.JS_NewClassID(rt, &class_id);
    const def = qjs.JSClassDef{
        .class_name = "JsBayQjsHostObject",
        .finalizer = qjsHostFinalizer,
        .gc_mark = null,
        .call = null,
        .exotic = &exotic_methods,
    };
    _ = qjs.JS_NewClass(rt, class_id, &def);
}

pub fn create(
    ctx: ?*qjs.JSContext,
    instance_id: i32,
    user_data: ?*anyopaque,
    get_fn: ?GetFn,
    set_fn: ?SetFn,
    names_fn: ?NamesFn,
    finalize_fn: ?FinalizeFn,
) qjs.JSValue {
    const rt = qjs.JS_GetRuntime(ctx);
    ensureClass(rt);

    const obj = qjs.JS_NewObjectClass(ctx, @intCast(class_id));
    if (c.jsIsException(obj)) return obj;

    const raw = qjs.js_mallocz(ctx, @sizeOf(Box));
    if (raw == null) {
        c.jsbay_qjs_JS_FreeValue(ctx, obj);
        return qjs.JS_ThrowOutOfMemory(ctx);
    }
    const box: *Box = @ptrCast(@alignCast(raw.?));
    box.* = .{
        .instance_id = instance_id,
        .user_data = user_data,
        .get_fn = get_fn,
        .set_fn = set_fn,
        .names_fn = names_fn,
        .finalize_fn = finalize_fn,
    };
    _ = qjs.JS_SetOpaque(obj, raw);
    return obj;
}
