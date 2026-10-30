//! Hermes NativeHandle — opaque + optional call + finalize (NativeState + pending_finals).
//! Not full QJS class_id / CallbackStore parity; methods via make_function; finalize teardown-forced.
const std = @import("std");
const lifecycle = @import("lifecycle.zig");
const c_api = @import("c_api.zig");

pub const Context = lifecycle.Context;
pub const Value = c_api.Value;

pub const CallFn = *const fn (ctx: Context, this: Value, args: []const Value) Value;
pub const FinalizeFn = *const fn (ptr: ?*anyopaque) void;
pub const MethodFn = *const fn (ctx: Context, this: Value, args: []const Value) Value;

pub const HandleData = struct {
    ptr: ?*anyopaque = null,
    call_fn: ?CallFn = null,
    finalize_fn: ?FinalizeFn = null,
};

pub const MethodEntry = struct {
    name: [*:0]const u8,
    method: MethodFn,
};

const class_id_sentinel: usize = 0x4845_524E_4844; // 'HERNHD'

pub fn init() void {}
pub fn initWithRuntime(_: anytype) void {}

fn finalizeBridge(raw: ?*anyopaque) callconv(.c) void {
    const p = raw orelse return;
    const data: *HandleData = @ptrCast(@alignCast(p));
    if (data.finalize_fn) |fin| fin(data.ptr);
    std.heap.c_allocator.destroy(data);
}

fn callBridge(
    ctx: ?*c_api.Context,
    this_val: Value,
    args: ?[*]const Value,
    argc: usize,
    user_data: ?*anyopaque,
) callconv(.c) Value {
    const data: *HandleData = @ptrCast(@alignCast(user_data orelse return null));
    const cf = data.call_fn orelse return null;
    const slice: []const Value = if (args) |a| a[0..argc] else &.{};
    return cf(ctx, this_val, slice);
}

const MethodBox = struct {
    method: MethodFn,
    handle: Value, // own protect retain (dup); survives setPropertyStr consume of caller's Value
};

fn methodBridge(
    ctx: ?*c_api.Context,
    this_val: Value,
    args: ?[*]const Value,
    argc: usize,
    user_data: ?*anyopaque,
) callconv(.c) Value {
    _ = this_val;
    const box: *MethodBox = @ptrCast(@alignCast(user_data orelse return null));
    const slice: []const Value = if (args) |a| a[0..argc] else &.{};
    // Bound this: always the NativeHandle, so detached `const f = h.m; f()` still sees the handle.
    return box.method(ctx, box.handle, slice);
}

pub fn create(ctx: Context, config: HandleData) Value {
    const data = std.heap.c_allocator.create(HandleData) catch return null;
    data.* = config;
    const call_c: ?c_api.NativeFn = if (config.call_fn != null) &callBridge else null;
    const out = c_api.hermes_native_handle_create(ctx, data, call_c, &finalizeBridge);
    if (out == null) {
        std.heap.c_allocator.destroy(data);
        return null;
    }
    return out;
}

pub fn createWithMethods(ctx: Context, config: HandleData, methods: []const MethodEntry) Value {
    const obj = create(ctx, config);
    if (obj == null) return null;
    for (methods) |m| setMethod(ctx, obj, m.name, m.method);
    return obj;
}

pub fn setMethod(ctx: Context, obj: Value, name: [*:0]const u8, method: MethodFn) void {
    if (obj == null) return;
    const handle_dup = c_api.hermes_dup(ctx, obj);
    if (handle_dup == null) return;
    const box = std.heap.c_allocator.create(MethodBox) catch {
        c_api.hermes_free_value(ctx, handle_dup);
        return;
    };
    box.* = .{ .method = method, .handle = handle_dup };
    const fn_obj = c_api.hermes_make_function(ctx, name, &methodBridge, box);
    if (fn_obj == null) {
        c_api.hermes_free_value(ctx, handle_dup);
        std.heap.c_allocator.destroy(box);
        return;
    }
    _ = c_api.hermes_set_property(ctx, obj, name, fn_obj);
    c_api.hermes_free_value(ctx, fn_obj);
}

pub fn setStringProp(ctx: Context, obj: Value, name: [*:0]const u8, value: []const u8) void {
    if (obj == null) return;
    const s = c_api.hermes_new_string(ctx, value.ptr, value.len);
    defer c_api.hermes_free_value(ctx, s);
    _ = c_api.hermes_set_property(ctx, obj, name, s);
}

pub fn setIntProp(ctx: Context, obj: Value, name: [*:0]const u8, value: i32) void {
    if (obj == null) return;
    const n = c_api.hermes_new_int32(value);
    defer c_api.hermes_free_value(ctx, n);
    _ = c_api.hermes_set_property(ctx, obj, name, n);
}

pub fn getOpaque(ctx: Context, v: Value) ?*HandleData {
    const raw = c_api.hermes_native_handle_get(ctx, v) orelse return null;
    return @ptrCast(@alignCast(raw));
}

pub fn getClassId() usize {
    return class_id_sentinel;
}
