//! Install a pointer + length host function on the QuickJS global object.
//!
//! Input strings are borrowed during the callback. Output strings use host-owned storage that remains valid after callback return, until copied into JS strings. The slot table is process-wide; each function carries its own instance id.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;
const sync = @import("zev");
const instance_map = @import("../../runtime/instance_map.zig");
const host_value = @import("../../abi/host_value.zig");

const Binding = struct {
    instance_id: i32,
    func: host_value.HostFn,
    user_data: ?*anyopaque,
    name: [:0]u8,
    alive: bool,
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
    const ctx = ptrs.ctx;

    const name_z = std.heap.c_allocator.allocSentinel(u8, name.len, 0) catch return false;
    @memcpy(name_z, name);

    const binding = std.heap.c_allocator.create(Binding) catch {
        std.heap.c_allocator.free(name_z);
        return false;
    };
    binding.* = .{
        .instance_id = instance_id,
        .func = func,
        .user_data = user_data,
        .name = name_z,
        .alive = true,
    };

    mutex.lock();
    const slot = slots.items.len;
    if (slot > std.math.maxInt(c_int)) {
        mutex.unlock();
        std.heap.c_allocator.free(name_z);
        std.heap.c_allocator.destroy(binding);
        return false;
    }
    slots.append(std.heap.c_allocator, binding) catch {
        mutex.unlock();
        std.heap.c_allocator.free(name_z);
        std.heap.c_allocator.destroy(binding);
        return false;
    };
    mutex.unlock();

    const global = qjs.JS_GetGlobalObject(ctx);
    const data = c.jsbay_qjs_JS_NewInt32(ctx, @intCast(slot));
    if (c.jsIsException(data)) {
        c.jsbay_qjs_JS_FreeValue(ctx, global);
        killSlot(@intCast(slot));
        return false;
    }
    const js_fn = c.jsbay_qjs_JS_NewCFunctionData(ctx, &trampoline, name_z.ptr, 0, data);
    c.jsbay_qjs_JS_FreeValue(ctx, data);
    if (c.jsIsException(js_fn)) {
        c.jsbay_qjs_JS_FreeValue(ctx, global);
        killSlot(@intCast(slot));
        return false;
    }
    // JS_SetPropertyStr consumes `js_fn`.
    const rc = qjs.JS_SetPropertyStr(ctx, global, name_z.ptr, js_fn);
    c.jsbay_qjs_JS_FreeValue(ctx, global);
    if (rc < 0) {
        killSlot(@intCast(slot));
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

fn killSlot(slot: usize) void {
    mutex.lock();
    defer mutex.unlock();
    if (slot >= slots.items.len) return;
    const binding = slots.items[slot] orelse return;
    binding.alive = false;
    std.heap.c_allocator.free(binding.name);
    std.heap.c_allocator.destroy(binding);
    slots.items[slot] = null;
}

const CopiedCall = struct {
    func: host_value.HostFn,
    user_data: ?*anyopaque,
    instance_id: i32,
};

fn lookup(slot: usize) ?CopiedCall {
    mutex.lock();
    defer mutex.unlock();
    if (slot >= slots.items.len) return null;
    const binding = slots.items[slot] orelse return null;
    if (!binding.alive) return null;
    return .{
        .func = binding.func,
        .user_data = binding.user_data,
        .instance_id = binding.instance_id,
    };
}

fn trampoline(
    ctx: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
    _: c_int,
    func_data: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    var slot_i64: i64 = 0;
    if (qjs.JS_ToInt64(ctx, &slot_i64, func_data[0]) < 0 or slot_i64 < 0) return c.JS_EXCEPTION;
    const call = lookup(@intCast(slot_i64)) orelse return c.JS_EXCEPTION;
    const n: usize = if (argc > 0) @intCast(argc) else 0;

    var small: [8]host_value.HostValue = undefined;
    var small_cstr: [8]?[*:0]const u8 = @splat(null);
    const args = if (n <= small.len) small[0..n] else std.heap.c_allocator.alloc(host_value.HostValue, n) catch {
        return qjs.JS_ThrowOutOfMemory(ctx);
    };
    const cstrs = if (n <= small_cstr.len) small_cstr[0..n] else std.heap.c_allocator.alloc(?[*:0]const u8, n) catch {
        if (n > small.len) std.heap.c_allocator.free(args);
        return qjs.JS_ThrowOutOfMemory(ctx);
    };
    defer if (n > small.len) std.heap.c_allocator.free(args);
    defer if (n > small_cstr.len) std.heap.c_allocator.free(cstrs);
    defer {
        for (cstrs) |ptr| {
            if (ptr) |p| qjs.JS_FreeCString(ctx, p);
        }
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        cstrs[i] = null;
        const val = argv[i];
        if (c.jsbay_qjs_JS_IsNumber(val) != 0) {
            var number: f64 = 0;
            if (qjs.JS_ToFloat64(ctx, &number, val) < 0) {
                const exc = qjs.JS_GetException(ctx);
                c.jsbay_qjs_JS_FreeValue(ctx, exc);
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
        } else if (c.jsbay_qjs_JS_IsString(val) != 0) {
            var len: usize = 0;
            if (qjs.JS_ToCStringLen(ctx, &len, val)) |ptr| {
                cstrs[i] = ptr;
                args[i] = .{
                    .tag = host_value.tag_string,
                    .reserved = 0,
                    .number = 0,
                    .ptr = @ptrCast(ptr),
                    .len = len,
                };
            } else {
                host_value.clear(&args[i]);
            }
        } else {
            host_value.clear(&args[i]);
        }
    }

    var out: host_value.HostValue = undefined;
    host_value.clear(&out);
    const argv_ptr: ?[*]const host_value.HostValue = if (n == 0) null else args.ptr;
    const rc = call.func(call.instance_id, call.user_data, @intCast(n), argv_ptr, &out);
    if (rc != 0) {
        return qjs.JS_ThrowTypeError(ctx, "host function failed");
    }

    return switch (out.tag) {
        host_value.tag_undefined => c.JS_UNDEFINED,
        host_value.tag_number => c.jsbay_qjs_JS_NewFloat64(ctx, out.number),
        host_value.tag_string => blk: {
            if (out.len == 0 or out.ptr == null) {
                break :blk qjs.JS_NewStringLen(ctx, "", 0);
            }
            break :blk qjs.JS_NewStringLen(ctx, out.ptr.?, out.len);
        },
        else => c.JS_UNDEFINED,
    };
}
