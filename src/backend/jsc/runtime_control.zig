//! Runtime control — interrupt handling, GC, memory usage — for the JSC backend.
//!
//! JSC's public header doesn't declare JSContextGroupSetExecutionTimeLimit, but the symbol ships in the JavaScriptCore framework (same as JSSynchronousGarbageCollectForDebugging used elsewhere in this file). We declare it as an extern; linking against JavaScriptCore.framework resolves it.

const std = @import("std");
const io = @import("../../platform/io.zig");
const common = @import("common.zig");

const jsc = common.jsc;

const watchdog_period_seconds: f64 = 0.05;

/// Should-terminate callback signature (from <JavaScriptCore/JSContextRefPrivate.h>). Return `true` to terminate script execution on the next safe-point.
pub const JSShouldTerminateCallback = ?*const fn (
    ctx: jsc.JSContextRef,
    context: ?*anyopaque,
) callconv(.c) bool;

pub extern "c" fn JSContextGroupSetExecutionTimeLimit(
    group: jsc.JSContextGroupRef,
    limit: f64,
    callback: JSShouldTerminateCallback,
    context: ?*anyopaque,
) void;

pub extern "c" fn JSContextGroupClearExecutionTimeLimit(group: jsc.JSContextGroupRef) void;

/// Opaque per-instance state used by the JSC execution-time-limit callback. Layout compatible with runtime_control.InterruptState for the shared fields the callback reads (interrupt flag + deadline).
pub const JscInterruptState = extern struct {
    interrupt_requested: u8,
    _pad: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
    deadline_ms: u64,
    instance_id: i32 = -1,
};

/// Trampoline for the execution-time-limit watchdog. The system JavaScriptCore build exercised here needs an explicit re-arm after a false return, despite the upstream header documenting that it should invoke the callback again.
fn jscShouldTerminate(ctx: jsc.JSContextRef, context: ?*anyopaque) callconv(.c) bool {
    const state_ptr = context orelse return false;
    const state: *JscInterruptState = @ptrCast(@alignCast(state_ptr));

    const req_ptr: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    if (req_ptr.load(.monotonic) != 0) return true;

    const deadline_ptr: *std.atomic.Value(u64) = @ptrCast(&state.deadline_ms);
    const deadline = deadline_ptr.load(.monotonic);
    if (deadline != 0) {
        const now: u64 = @intCast(io.monotonicMilliseconds());
        if (now >= deadline) return true;
    }
    // Keep the same interval as installation so an interrupt requested after this check can still stop the running script on affected system builds.
    const group = jsc.JSContextGetGroup(ctx);
    JSContextGroupSetExecutionTimeLimit(group, watchdog_period_seconds, jscShouldTerminate, context);

    if (state.instance_id >= 0) {
        if (@import("../../inspector/sample_hook.zig").load()) |hook| hook(state.instance_id);
    }
    return false;
}

/// Install the JSC execution-time-limit callback at the fixed 50ms period.
pub fn jscInstallInterruptHandler(
    group: jsc.JSContextGroupRef,
    state: *JscInterruptState,
) void {
    JSContextGroupSetExecutionTimeLimit(group, watchdog_period_seconds, jscShouldTerminate, @ptrCast(state));
}

/// Remove the JSC execution-time-limit callback.  Call before freeing `state`.
pub fn jscUninstallInterruptHandler(group: jsc.JSContextGroupRef) void {
    JSContextGroupClearExecutionTimeLimit(group);
}

/// Force a GC pass on the given context. JSC's GC is per-VM (context group) but the public API exposes it via a context handle.
pub fn jscRunGc(ctx: jsc.JSGlobalContextRef) void {
    jsc.JSGarbageCollect(@ptrCast(ctx));
}
