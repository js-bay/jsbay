//! Hermes Runtime/Context lifecycle and eval — native HermesPublic via C bridge.
const std = @import("std");
const types = @import("../../types.zig");
const c_api = @import("c_api.zig");

/// Match JSC: optional opaque pointers so `!= null` checks typecheck.
pub const Runtime = ?*c_api.Runtime;
pub const Context = ?*c_api.Context;

pub fn newRuntime() ?Runtime {
    return newRuntimeWithMaxHeap(0);
}

/// Create Hermes Runtime with optional create-time GCConfig.MaxHeapSize. `max_heap_bytes == 0` keeps Hermes default (3 GiB). Not a runtime setMemoryLimit.
pub fn newRuntimeWithMaxHeap(max_heap_bytes: u64) ?Runtime {
    return c_api.hermes_runtime_new(max_heap_bytes);
}

pub fn setMaxStackSize(_: Runtime, _: usize) void {}

pub fn newContext(rt: Runtime) ?Context {
    ensureDrainHook();
    return c_api.hermes_context_new(rt);
}

pub fn freeContext(ctx: Context) void {
    c_api.hermes_context_free(ctx);
}

pub fn freeRuntime(rt: Runtime) void {
    c_api.hermes_runtime_free(rt);
}

pub fn runGc(rt: Runtime) void {
    c_api.hermes_runtime_gc(rt);
}

fn shouldStopPendingJobDrain(instance_id: i32) bool {
    const runtime_control = @import("../../runtime/runtime_control.zig");
    if (runtime_control.isInterruptRequested(instance_id) or runtime_control.isStopRequested(instance_id)) return true;
    // Include the per-entry execution budget and shutdown grace, not only the absolute manual deadline; short Promise microtasks may finish without an opcode interrupt check, so without this an expired budget never ends the drain.
    return if (runtime_control.remainingEffectiveExecutionLimitMillis(instance_id)) |remaining| remaining == 0 else false;
}

fn shouldStopPendingJobDrainC(instance_id: c_int) callconv(.c) bool {
    return shouldStopPendingJobDrain(@intCast(instance_id));
}

var drain_hook_installed: bool = false;

fn ensureDrainHook() void {
    if (drain_hook_installed) return;
    c_api.hermes_set_should_stop_pending_job_drain(&shouldStopPendingJobDrainC);
    drain_hook_installed = true;
}

pub fn processPendingJobs(ctx: Context) void {
    // Match QuickJS/JSC: Deferred.settleWith can call this while an outer script/native callback is still on the stack; gate so Promise reactions wait for the outer checkpoint.
    if (ctx == null) return;
    if (!@import("../../runtime/scheduler_gate.zig").allows(@ptrCast(ctx))) return;
    defer @import("../../runtime/scheduler_gate.zig").finished(@ptrCast(ctx));
    ensureDrainHook();
    const opaque_ptr = c_api.hermes_context_get_opaque(ctx);
    const instance_id: i32 = if (opaque_ptr) |p| @bitCast(@as(u32, @truncate(@intFromPtr(p)))) else 0;
    if (instance_id != 0 and shouldStopPendingJobDrain(instance_id)) return;
    c_api.hermes_process_pending_jobs(ctx);
}

pub fn eval(ctx: Context, script: []const u8, filename: []const u8) types.EvalResult {
    const raw = c_api.hermes_eval(ctx, script.ptr, script.len, filename.ptr, filename.len);
    const result = if (raw.result) |p| blk: {
        const s = p[0..raw.result_len];
        const owned = std.heap.c_allocator.dupe(u8, s) catch {
            _ = std.c.free(p);
            if (raw.err) |e| _ = std.c.free(e);
            return .{ .result = null, .err = "Out of memory", .err_is_heap = false };
        };
        _ = std.c.free(p);
        break :blk owned;
    } else null;
    const err = if (raw.err) |p| blk: {
        const s = p[0..raw.err_len];
        const owned = std.heap.c_allocator.dupe(u8, s) catch {
            _ = std.c.free(p);
            if (result) |r| std.heap.c_allocator.free(r);
            return .{ .result = null, .err = "Out of memory", .err_is_heap = false };
        };
        _ = std.c.free(p);
        break :blk owned;
    } else null;
    return .{ .result = result, .err = err, .err_is_heap = err != null };
}
