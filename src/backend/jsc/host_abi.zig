//! Install a pointer + length host function on the JavaScriptCore global object.
//!
//! Input strings live for the callback. Output strings use host-owned storage that remains valid after callback return, until copied into JS strings. The slot table is process-wide. JavaScriptCore function callbacks do not take a magic integer, and `JSObjectSetPrivate` is unreliable on callback functions, so each function object pointer maps back to its slot.

const std = @import("std");
const jsc = @import("jsc_c.zig");
const common = @import("common.zig");
const sync = @import("zev");
const instance_map = @import("../../runtime/instance_map.zig");
const host_value = @import("../../abi/host_value.zig");

const Binding = struct {
    instance_id: i32,
    func: host_value.HostFn,
    user_data: ?*anyopaque,
    name: [:0]u8,
    alive: bool,
    function_key: usize,
};

var mutex: sync.Mutex = .{};
var slots: std.ArrayList(?*Binding) = .empty;

pub fn install(
    instance_id: i32,
    name: []const u8,
    func: host_value.HostFn,
    user_data: ?*anyopaque,
) bool {
    const ptrs = instance_map.getPtrs(instance_id) orelse return false;
    const ctx: jsc.JSContextRef = ptrs.ctx;

    const name_z = std.heap.c_allocator.allocSentinel(u8, name.len, 0) catch return false;
    @memcpy(name_z, name);

    const binding = std.heap.c_allocator.create(Binding) catch {
        std.heap.c_allocator.free(name_z);
        return false;
    };

    const js_name = jsc.JSStringCreateWithUTF8CString(name_z.ptr);
    const function = jsc.JSObjectMakeFunctionWithCallback(ctx, js_name, &trampoline);
    jsc.JSStringRelease(js_name);
    const function_obj = function orelse {
        std.heap.c_allocator.free(name_z);
        std.heap.c_allocator.destroy(binding);
        return false;
    };

    binding.* = .{
        .instance_id = instance_id,
        .func = func,
        .user_data = user_data,
        .name = name_z,
        .alive = true,
        .function_key = @intFromPtr(function_obj),
    };

    mutex.lock();
    slots.append(std.heap.c_allocator, binding) catch {
        mutex.unlock();
        std.heap.c_allocator.free(name_z);
        std.heap.c_allocator.destroy(binding);
        return false;
    };
    mutex.unlock();

    const global = jsc.JSContextGetGlobalObject(ctx);
    const prop = jsc.JSStringCreateWithUTF8CString(name_z.ptr);
    defer jsc.JSStringRelease(prop);
    var exception: jsc.JSValueRef = null;
    jsc.JSObjectSetProperty(ctx, global, prop, function_obj, 0, &exception);
    if (exception != null) {
        killFunction(binding.function_key);
        return false;
    }
    return true;
}

pub fn releaseInstance(instance_id: i32) void {
    mutex.lock();
    defer mutex.unlock();
    for (slots.items) |*entry| {
        const binding = entry.* orelse continue;
        if (binding.instance_id != instance_id) continue;
        binding.alive = false;
        std.heap.c_allocator.free(binding.name);
        std.heap.c_allocator.destroy(binding);
        entry.* = null;
    }
}

fn killFunction(function_key: usize) void {
    mutex.lock();
    defer mutex.unlock();
    for (slots.items) |*entry| {
        const binding = entry.* orelse continue;
        if (binding.function_key != function_key) continue;
        binding.alive = false;
        std.heap.c_allocator.free(binding.name);
        std.heap.c_allocator.destroy(binding);
        entry.* = null;
    }
}

const CopiedCall = struct {
    func: host_value.HostFn,
    user_data: ?*anyopaque,
    instance_id: i32,
};

/// Temporary UTF-8 storage shared by all string arguments in one callback. JSC's string APIs require a trailing NUL in the destination, so callers reserve the maximum size reported by JSC and expose only the bytes before that terminator through HostValue.len.
const StringScratch = struct {
    allocator: std.mem.Allocator,
    storage: ?[]u8,
    offset: usize = 0,

    fn init(allocator: std.mem.Allocator, size: usize) !StringScratch {
        return .{
            .allocator = allocator,
            .storage = if (size == 0) null else try allocator.alloc(u8, size),
        };
    }

    fn deinit(self: *StringScratch) void {
        if (self.storage) |storage| self.allocator.free(storage);
        self.storage = null;
        self.offset = 0;
    }

    fn copy(self: *StringScratch, bytes: []const u8) []u8 {
        const storage = self.storage orelse return &.{};
        const end = self.offset + bytes.len;
        std.debug.assert(end <= storage.len);
        @memcpy(storage[self.offset..end], bytes);
        const result = storage[self.offset..end];
        self.offset = end;
        return result;
    }

    fn reserve(self: *StringScratch, size: usize) []u8 {
        const storage = self.storage orelse return &.{};
        const end = self.offset + size;
        std.debug.assert(end <= storage.len);
        const result = storage[self.offset..end];
        self.offset = end;
        return result;
    }
};

fn lookup(function: jsc.JSObjectRef) ?CopiedCall {
    const function_obj = function orelse return null;
    const key = @intFromPtr(function_obj);
    mutex.lock();
    defer mutex.unlock();
    for (slots.items) |entry| {
        const binding = entry orelse continue;
        if (binding.function_key != key or !binding.alive) continue;
        return .{
            .func = binding.func,
            .user_data = binding.user_data,
            .instance_id = binding.instance_id,
        };
    }
    return null;
}

fn trampoline(
    ctx: jsc.JSContextRef,
    function: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argument_count: usize,
    arguments: [*c]const jsc.JSValueRef,
    exception: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const call = lookup(function) orelse {
        return common.throwError(ctx, exception, "host function is gone");
    };

    var small: [8]host_value.HostValue = undefined;
    var small_refs: [8]jsc.JSStringRef = std.mem.zeroes([8]jsc.JSStringRef);
    const args = if (argument_count <= small.len)
        small[0..argument_count]
    else
        std.heap.c_allocator.alloc(host_value.HostValue, argument_count) catch {
            return common.throwError(ctx, exception, "out of memory");
        };
    const refs = if (argument_count <= small_refs.len)
        small_refs[0..argument_count]
    else
        std.heap.c_allocator.alloc(jsc.JSStringRef, argument_count) catch {
            if (argument_count > small.len) std.heap.c_allocator.free(args);
            return common.throwError(ctx, exception, "out of memory");
        };
    if (argument_count > small_refs.len) @memset(refs, null);
    defer if (argument_count > small.len) std.heap.c_allocator.free(args);
    defer if (argument_count > small_refs.len) std.heap.c_allocator.free(refs);
    defer for (refs) |ref| if (ref) |string| jsc.JSStringRelease(string);

    var total_string_bytes: usize = 0;
    var string_size_overflow = false;
    var i: usize = 0;
    while (i < argument_count) : (i += 1) {
        const val = arguments[i];
        if (jsc.JSValueIsNumber(ctx, val)) {
            var inner: jsc.JSValueRef = null;
            const number = jsc.JSValueToNumber(ctx, val, &inner);
            if (inner != null) {
                host_value.clear(&args[i]);
            } else {
                args[i] = .{
                    .tag = host_value.tag_number,
                    .reserved = 0,
                    .number = number,
                    .ptr = null,
                    .len = 0,
                };
            }
        } else if (jsc.JSValueIsString(ctx, val)) {
            var inner: jsc.JSValueRef = null;
            const js_string = jsc.JSValueToStringCopy(ctx, val, &inner);
            if (js_string == null or inner != null) {
                if (js_string) |string| jsc.JSStringRelease(string);
                host_value.clear(&args[i]);
            } else {
                refs[i] = js_string;
                const needed = jsc.JSStringGetMaximumUTF8CStringSize(js_string);
                total_string_bytes = std.math.add(usize, total_string_bytes, needed) catch {
                    string_size_overflow = true;
                    continue;
                };
            }
        } else {
            host_value.clear(&args[i]);
        }
    }

    var scratch: ?StringScratch = null;
    if (!string_size_overflow and total_string_bytes != 0) {
        scratch = StringScratch.init(std.heap.c_allocator, total_string_bytes) catch null;
    }
    defer if (scratch) |*storage| storage.deinit();

    if (scratch) |*storage| {
        i = 0;
        while (i < argument_count) : (i += 1) {
            const js_string = refs[i] orelse continue;
            const needed = jsc.JSStringGetMaximumUTF8CStringSize(js_string);
            if (needed == 0) {
                host_value.clear(&args[i]);
                continue;
            }
            const raw = storage.reserve(needed);
            const written = jsc.JSStringGetUTF8CString(js_string, raw.ptr, raw.len);
            if (written == 0) {
                host_value.clear(&args[i]);
                continue;
            }
            const len = written - 1;
            args[i] = .{
                .tag = host_value.tag_string,
                .reserved = 0,
                .number = 0,
                .ptr = if (len == 0) null else raw.ptr,
                .len = len,
            };
        }
    } else {
        // A failed bulk allocation has the same safe callback contract as an individual string allocation failure: those arguments become undefined, and all JSC string refs are still released below.
        for (refs, 0..) |ref, index| {
            if (ref != null) host_value.clear(&args[index]);
        }
    }

    var out: host_value.HostValue = undefined;
    host_value.clear(&out);
    const argv_ptr: ?[*]const host_value.HostValue = if (argument_count == 0) null else args.ptr;
    const rc = call.func(call.instance_id, call.user_data, @intCast(argument_count), argv_ptr, &out);
    if (rc != 0) {
        return common.throwError(ctx, exception, "host function failed");
    }

    return switch (out.tag) {
        host_value.tag_undefined => jsc.JSValueMakeUndefined(ctx),
        host_value.tag_number => jsc.JSValueMakeNumber(ctx, out.number),
        host_value.tag_string => blk: {
            const slice: []const u8 = if (out.ptr == null or out.len == 0) "" else out.ptr.?[0..out.len];
            const js_string = common.jsStringFromSlice(slice);
            if (js_string == null) break :blk common.throwError(ctx, exception, "out of memory");
            defer jsc.JSStringRelease(js_string);
            break :blk jsc.JSValueMakeString(ctx, js_string);
        },
        else => jsc.JSValueMakeUndefined(ctx),
    };
}

test "JSC host string scratch packs values and releases one allocation on OOM" {
    const testing = std.testing;

    var scratch = try StringScratch.init(testing.allocator, 7);
    defer scratch.deinit();
    try testing.expectEqualSlices(u8, "abc", scratch.copy("abc"));
    try testing.expectEqualSlices(u8, "", scratch.copy(""));
    try testing.expectEqualSlices(u8, "xy", scratch.copy("xy"));
    try testing.expectEqual(@as(usize, 5), scratch.offset);

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, StringScratch.init(failing.allocator(), 1));
    try testing.expectEqual(@as(usize, 0), failing.allocations);
    try testing.expectEqual(@as(usize, 0), failing.deallocations);
}
