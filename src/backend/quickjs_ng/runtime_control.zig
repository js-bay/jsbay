//! Runtime control — interrupt handling, GC, memory usage.
//!
//! See src/runtime/runtime_control.zig for the public cross-backend surface; this module wires QuickJS-specific primitives.

const std = @import("std");
const io = @import("../../platform/io.zig");
const c = @import("c_api.zig");
const qjs = c.qjs;

/// Opaque per-instance state owned by runtime_control.zig; QJS-side uses it to read the interrupt flag and deadline from inside the interrupt trampoline. Layout MUST match runtime_control.InterruptState.
pub const QjsInterruptState = extern struct {
    /// Non-zero when an interrupt has been requested from another thread.
    interrupt_requested: u8,
    _pad: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
    /// Absolute deadline in milliseconds since engine start (monotonic); zero means "no limit". Read atomically.
    deadline_ms: u64,
    instance_id: i32 = -1,
};

/// C trampoline: called by QuickJS periodically during JS execution. Returns non-zero to trigger interrupt (QuickJS throws InternalError).
fn qjsInterruptTrampoline(_: ?*qjs.JSRuntime, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const state_ptr = opaque_ptr orelse return 0;
    const state: *QjsInterruptState = @ptrCast(@alignCast(state_ptr));

    // Atomic-load the flag (relaxed ordering is fine — we tolerate seeing a stale value for up to one interrupt check period).
    const req_ptr: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    if (req_ptr.load(.monotonic) != 0) return 1;

    const deadline_ptr: *std.atomic.Value(u64) = @ptrCast(&state.deadline_ms);
    const deadline = deadline_ptr.load(.monotonic);
    if (deadline != 0) {
        const now: u64 = @intCast(io.monotonicMilliseconds());
        if (now >= deadline) return 1;
    }
    if (state.instance_id >= 0) {
        if (@import("../../inspector/sample_hook.zig").load()) |hook| hook(state.instance_id);
    }
    return 0;
}

/// Install the interrupt handler onto `rt`, using `state` as the opaque carrier. `state` MUST outlive the runtime (the handler is called from the JS thread during eval).
pub fn qjsInstallInterruptHandler(rt: ?*qjs.JSRuntime, state: *QjsInterruptState) void {
    qjs.JS_SetInterruptHandler(rt, qjsInterruptTrampoline, @ptrCast(state));
}

/// Remove the interrupt handler (pass null fn).  Call before freeing `state`.
pub fn qjsUninstallInterruptHandler(rt: ?*qjs.JSRuntime) void {
    qjs.JS_SetInterruptHandler(rt, null, null);
}

/// Force a synchronous GC pass on the runtime.
pub fn qjsRunGc(rt: ?*qjs.JSRuntime) void {
    qjs.JS_RunGC(rt);
}

/// Set the maximum heap memory (bytes) QuickJS may allocate before GC is forced (0 = unlimited). Runtime-wide, so it must be called on the engine's owning thread before untrusted scripts run.
pub fn qjsSetMemoryLimit(rt: ?*qjs.JSRuntime, limit: usize) void {
    qjs.JS_SetMemoryLimit(rt, limit);
}

/// Snapshot runtime memory usage. Fields on the native JSMemoryUsage struct we don't carry through are dropped.
pub fn qjsMemoryUsage(rt: ?*qjs.JSRuntime) QjsMemoryUsageSnapshot {
    var raw: qjs.JSMemoryUsage = undefined;
    qjs.JS_ComputeMemoryUsage(rt, &raw);
    return .{
        .malloc_count = @intCast(@max(raw.malloc_count, 0)),
        .malloc_size = @intCast(@max(raw.malloc_size, 0)),
        .malloc_limit = @intCast(@max(raw.malloc_limit, 0)),
        .memory_used_count = @intCast(@max(raw.memory_used_count, 0)),
        .memory_used_size = @intCast(@max(raw.memory_used_size, 0)),
        .atom_count = @intCast(@max(raw.atom_count, 0)),
        .atom_size = @intCast(@max(raw.atom_size, 0)),
        .obj_count = @intCast(@max(raw.obj_count, 0)),
        .obj_size = @intCast(@max(raw.obj_size, 0)),
        .shape_count = @intCast(@max(raw.shape_count, 0)),
    };
}

pub const QjsMemoryUsageSnapshot = struct {
    malloc_count: u64,
    malloc_size: u64,
    malloc_limit: u64,
    memory_used_count: u64,
    memory_used_size: u64,
    atom_count: u64,
    atom_size: u64,
    obj_count: u64,
    obj_size: u64,
    shape_count: u64,
};
