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
};

fn methodBridge(
    ctx: ?*c_api.Context,
    this_val: Value,
    args: ?[*]const Value,
    argc: usize,
    user_data: ?*anyopaque,
) callconv(.c) Value {
    const box: *MethodBox = @ptrCast(@alignCast(user_data orelse return null));
    const slice: []const Value = if (args) |a| a[0..argc] else &.{};
    // Receiver is Function.prototype.bind's [[BoundThis]] (GC-visible); detached `const f = h.m; f()` still sees the handle.
    return box.method(ctx, this_val, slice);
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

fn methodBoxFree(ctx: ?*c_api.Context, user_data: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    const box: *MethodBox = @ptrCast(@alignCast(user_data orelse return));
    std.heap.c_allocator.destroy(box);
}

/// Bind `fn_obj` to `handle` so the method keeps a GC edge to the receiver (no permanent protect-map root).
fn bindMethodToHandle(ctx: Context, fn_obj: Value, handle: Value) Value {
    const global = c_api.hermes_get_global(ctx) orelse return null;
    defer c_api.hermes_free_value(ctx, global);
    const Function = c_api.hermes_get_property(ctx, global, "Function") orelse return null;
    defer c_api.hermes_free_value(ctx, Function);
    const proto = c_api.hermes_get_property(ctx, Function, "prototype") orelse return null;
    defer c_api.hermes_free_value(ctx, proto);
    const bind_fn = c_api.hermes_get_property(ctx, proto, "bind") orelse return null;
    defer c_api.hermes_free_value(ctx, bind_fn);
    var err: ?[*:0]u8 = null;
    const args = [_]Value{handle};
    const bound = c_api.hermes_call(ctx, bind_fn, fn_obj, &args, 1, &err);
    if (err) |e| _ = std.c.free(e);
    return bound;
}

pub fn setMethod(ctx: Context, obj: Value, name: [*:0]const u8, method: MethodFn) void {
    if (obj == null) return;
    const box = std.heap.c_allocator.create(MethodBox) catch return;
    box.* = .{ .method = method };
    // Host function + Function.prototype.bind(handle): bound function holds a GC edge to the receiver; handle↔method cycles stay collectible.
    const fn_obj = c_api.hermes_make_function_ex(ctx, name, &methodBridge, box, &methodBoxFree);
    if (fn_obj == null) {
        // make_function_ex frees user_data via methodBoxFree on failure.
        return;
    }
    const bound = bindMethodToHandle(ctx, fn_obj, obj);
    c_api.hermes_free_value(ctx, fn_obj);
    if (bound == null) return;
    _ = c_api.hermes_set_property(ctx, obj, name, bound);
    c_api.hermes_free_value(ctx, bound);
}

pub fn setStringProp(ctx: Context, obj: Value, name: [*:0]const u8, value: []const u8) void {
    if (obj == null) return;
    const s = c_api.hermes_new_string(ctx, value.ptr, value.len);
    defer c_api.hermes_free_value(ctx, s);
    _ = c_api.hermes_set_property(ctx, obj, name, s);
}

pub fn setIntProp(ctx: Context, obj: Value, name: [*:0]const u8, value: i32) void {
    if (obj == null) return;
    const n = c_api.hermes_new_int32(ctx, value);
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
