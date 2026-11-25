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
    budget_millis: u64 = 0,
    budget_deadline_ms: u64 = 0,
    budget_depth: usize = 0,
    shutdown_deadline_ms: u64 = 0,
    shutdown_phase: c_int = 0,
    exec_epoch: u64 = 0,
    interrupt_target: u64 = 0,
};

/// Re-arm both outcomes: JSC consumes a fired timer even when a nested API boundary catches its termination.
fn jscShouldTerminate(ctx: jsc.JSContextRef, context: ?*anyopaque) callconv(.c) bool {
    const state_ptr = context orelse return false;
    const state: *JscInterruptState = @ptrCast(@alignCast(state_ptr));

    const shutdown_ptr: *std.atomic.Value(u64) = @ptrCast(&state.shutdown_deadline_ms);
    const now: u64 = @intCast(io.monotonicMilliseconds());
    const shutdown_deadline = shutdown_ptr.load(.monotonic);

    const req_ptr: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);

    const deadline_ptr: *std.atomic.Value(u64) = @ptrCast(&state.deadline_ms);
    const budget_ptr: *std.atomic.Value(u64) = @ptrCast(&state.budget_deadline_ms);
    const deadline = deadline_ptr.load(.monotonic);
    const budget_deadline = budget_ptr.load(.monotonic);
    const terminate = (shutdown_deadline != 0 and now >= shutdown_deadline) or
        req_ptr.load(.monotonic) != 0 or
        (deadline != 0 and now >= deadline) or
        (budget_deadline != 0 and now >= budget_deadline);

    // Dynamically adjust watchdog period if an active deadline is sooner than the default 50ms interval.
    var next_period: f64 = watchdog_period_seconds;
    var earliest: u64 = std.math.maxInt(u64);
    if (deadline != 0 and deadline < earliest) earliest = deadline;
    if (budget_deadline != 0 and budget_deadline < earliest) earliest = budget_deadline;
    if (shutdown_deadline != 0 and shutdown_deadline < earliest) earliest = shutdown_deadline;
    if (earliest != std.math.maxInt(u64)) {
        const remaining_sec = @as(f64, @floatFromInt(earliest -| now)) / 1000.0;
        if (remaining_sec < next_period) {
            next_period = @max(remaining_sec, 0.005);
        }
    }

    const group = jsc.JSContextGetGroup(ctx);
    JSContextGroupSetExecutionTimeLimit(group, next_period, jscShouldTerminate, context);

    if (!terminate and state.instance_id >= 0) {
        if (@import("../../inspector/sample_hook.zig").load()) |hook| hook(state.instance_id);
    }
    return terminate;
}

/// Install the JSC execution-time-limit callback at the fixed 50ms period.
pub fn jscInstallInterruptHandler(
    group: jsc.JSContextGroupRef,
    state: *JscInterruptState,
) void {
    JSContextGroupSetExecutionTimeLimit(group, watchdog_period_seconds, jscShouldTerminate, @ptrCast(state));
}

/// Re-arm the JSC watchdog timer with a custom period (in seconds), clamped to at least 5ms.
pub fn jscArmWatchdogPeriod(
    group: jsc.JSContextGroupRef,
    state: *JscInterruptState,
    period_seconds: f64,
) void {
    const clamped = @max(period_seconds, 0.005);
    JSContextGroupSetExecutionTimeLimit(group, clamped, jscShouldTerminate, @ptrCast(state));
}

/// Remove the JSC execution-time-limit callback.  Call before freeing `state`.
pub fn jscUninstallInterruptHandler(group: jsc.JSContextGroupRef) void {
    JSContextGroupClearExecutionTimeLimit(group);
}

/// Force a GC pass on the given context. JSC's GC is per-VM (context group) but the public API exposes it via a context handle.
pub fn jscRunGc(ctx: jsc.JSGlobalContextRef) void {
    jsc.JSGarbageCollect(@ptrCast(ctx));
}
