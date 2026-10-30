//! Zig-side "await" for a JS Promise — blocks the owning JS thread, pumping microtasks + timers + dispatch queues until settlement.
//!
//! Call on the engine's owning thread only. Pumps that thread's event loop, so no other work happens on it aside from what the loop drains.

const std = @import("std");
const io = @import("../platform/io.zig");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const dispatch = @import("dispatch.zig");
const engine_thread = @import("engine_thread.zig");
const instance_map = @import("instance_map.zig");
const runtime_control = @import("runtime_control.zig");

const ActiveEngine = backend.ActiveEngine;

pub const AwaitError = error{
    /// Value passed to `await` was not a thenable (no `.then` / not a Promise).
    NotAPromise,
    /// Promise rejected. The rejection value is in `out_reason` if provided.
    Rejected,
    /// Deadline exceeded before promise settled.
    TimedOut,
    /// A caller explicitly interrupted this instance while waiting.
    Interrupted,
    /// Engine instance not found (destroyed).
    InstanceGone,
    SyncNativeWait,
    ReentrantExecution,
};

pub const AwaitOptions = struct {
    /// Maximum wall-clock time to wait, in milliseconds. 0 = no timeout. When timed out, returns AwaitError.TimedOut; caller may still pump the loop later — this function does not cancel the promise.
    timeout_ms: u64 = 0,

    /// If rejected and this is non-null, the rejection reason (engine-owned Value) is written here. Caller frees via ActiveEngine.freeValue. On resolve/non-rejection outcomes, not written.
    out_reason: ?*ActiveEngine.Value = null,
};

/// Monotonically increasing sequence used to mint unique holder keys, so nested/reentrant awaits on the same engine don't collide.
var g_await_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Block the calling (owning) thread until `promise` settles, pumping the event loop and microtasks between polls.
///
/// On resolve: returns the resolved value (engine-owned; caller frees). On reject: returns AwaitError.Rejected; if opts.out_reason is provided, the reason Value is placed there (also caller-freed). If `promise` is not a thenable at all, returns AwaitError.NotAPromise without pumping.
pub fn awaitPromise(
    instance_id: i32,
    promise: ActiveEngine.Value,
    opts: AwaitOptions,
) AwaitError!ActiveEngine.Value {
    if (@import("js_scheduler.zig").isSynchronouslyWaiting(instance_id)) return error.SyncNativeWait;
    const lease = @import("engine_thread.zig").beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return error.InstanceGone;
    if (abortReason(instance_id, lease)) |err| return err;
    const ctx = engine.getContext(instance_id) orelse return error.InstanceGone;
    if (!@import("js_scheduler.zig").allowsQueuedWork(instance_id)) return error.ReentrantExecution;

    // Fast path: not a thenable — bail without installing anything.
    const thenable = isThenable(ctx, promise);
    if (abortReason(instance_id, lease)) |err| return err;
    if (!thenable) return error.NotAPromise;

    // Mint a unique holder key.
    const seq = g_await_seq.fetchAdd(1, .seq_cst);
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrintSentinel(&key_buf, "__jsbay_qjs_await_{d}", .{seq}, 0) catch
        return error.InstanceGone;

    // Stash the promise on globalThis under our unique key so the installer script below can reach it without needing to embed a Value literal.
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);

    const promise_dup = ActiveEngine.dupValue(ctx, promise);
    ActiveEngine.setPropertyStr(ctx, global, key.ptr, promise_dup);

    // Ensure we clean the stashed properties on all exit paths.
    defer cleanupHolder(ctx, global, key);

    // Install the holder + wire the then/catch callbacks via a JS shim. The promise reference we stashed is read back from globalThis so the callbacks form a closure over the shim's own locals (no string interpolation of Values needed).
    var install_buf: [512]u8 = undefined;
    const install_script = std.fmt.bufPrint(
        &install_buf,
        \\(function() {{
        \\  const key = "{s}";
        \\  const p = globalThis[key];
        \\  const holder = {{ state: 0, value: undefined }};
        \\  globalThis[key + "_h"] = holder;
        \\  Promise.resolve(p).then(
        \\    v => {{ holder.value = v; holder.state = 1; }},
        \\    r => {{ holder.value = r; holder.state = 2; }}
        \\  );
        \\}})();
    ,
        .{key},
    ) catch return error.InstanceGone;

    const install_result = engine.evalScript(instance_id, install_script, "<await-install>");
    defer freeEvalResult(install_result);
    if (abortReason(instance_id, lease)) |err| return err;
    if (install_result.err != null) {
        // If the installer raised (e.g. `.then` threw), treat as rejection-like from native's point of view; but the installer only fails on truly malformed thenables, which we gated above. Be defensive.
        return error.NotAPromise;
    }

    // Holder lookup key is "<base>_h".
    var holder_key_buf: [80]u8 = undefined;
    const holder_key = std.fmt.bufPrintSentinel(&holder_key_buf, "{s}_h", .{key}, 0) catch
        return error.InstanceGone;

    // Clamp to a year so huge timeouts don't overflow i64 arithmetic below.
    const max_timeout_ms: u64 = 365 * 24 * 60 * 60 * 1000;
    const clamped_timeout = @min(opts.timeout_ms, max_timeout_ms);
    const deadline: i64 = if (clamped_timeout > 0)
        io.milliTimestamp() + @as(i64, @intCast(clamped_timeout))
    else
        0;

    // Pump until the holder's state transitions. Promise jobs are deliberately not drained here without a task: `runEventLoopOnce` starts one real task and its scheduler checkpoint drains jobs at that task boundary.
    while (true) {
        if (abortReason(instance_id, lease)) |err| return err;

        // Read holder.state. We fetch the holder each iteration because the Value is cheap and avoids tracking retention across the loop.
        const state = readHolderState(ctx, global, holder_key);
        if (state != 0) {
            // Settled. Extract the settlement value and translate.
            const holder = ActiveEngine.getPropertyVal(ctx, global, holder_key.ptr) orelse
                return error.InstanceGone;
            defer ActiveEngine.freeValue(ctx, holder);
            const value = ActiveEngine.getPropertyVal(ctx, holder, "value") orelse
                ActiveEngine.newUndefinedVal(ctx);

            if (state == 1) {
                return value;
            } else {
                // Rejected. Hand the reason to the caller via out_reason or release it.
                if (opts.out_reason) |slot| {
                    slot.* = value;
                } else {
                    ActiveEngine.freeValue(ctx, value);
                }
                return error.Rejected;
            }
        }

        // Drive timers and native task dispatch so work that feeds back into JS can make progress.
        engine.runEventLoopOnce(instance_id);
        _ = dispatch.tickInstance(instance_id);

        if (abortReason(instance_id, lease)) |err| return err;

        if (deadline > 0 and io.milliTimestamp() >= deadline) {
            return error.TimedOut;
        }

        // Small yield to avoid burning a core when nothing is ready.
        io.sleepMs(1);
    }
}

/// Observe only native lifecycle state before touching the context again. The outer EvalLease keeps `ctx` alive until this function returns, but teardown must not wait for a pending Promise forever.
fn abortReason(instance_id: i32, lease: engine_thread.EvalLease) ?AwaitError {
    if (instance_map.isTeardownPending(instance_id) or engine_thread.deferredDestroyRequested(lease)) {
        return error.InstanceGone;
    }
    if (runtime_control.isStopRequested(instance_id)) return error.InstanceGone;
    if (runtime_control.remainingExecutionLimitMillis(instance_id)) |remaining| {
        if (remaining == 0) return error.TimedOut;
    }
    if (runtime_control.isInterruptRequested(instance_id)) return error.Interrupted;
    return null;
}

/// Read `holder.state` as an i32, returning 0 ("pending") on any access failure so the loop simply keeps pumping.
fn readHolderState(ctx: ActiveEngine.Context, global: ActiveEngine.Value, holder_key: [:0]const u8) i32 {
    const holder = ActiveEngine.getPropertyVal(ctx, global, holder_key.ptr) orelse return 0;
    defer ActiveEngine.freeValue(ctx, holder);
    const state_val = ActiveEngine.getPropertyVal(ctx, holder, "state") orelse return 0;
    defer ActiveEngine.freeValue(ctx, state_val);
    return ActiveEngine.toInt32(ctx, state_val) orelse 0;
}

/// Check whether `value` is a thenable — i.e. an object with a callable `.then` property. Mirrors the spec definition used by `await`.
fn isThenable(ctx: ActiveEngine.Context, value: ActiveEngine.Value) bool {
    if (!ActiveEngine.isObjectVal(ctx, value)) return false;
    const then_val = ActiveEngine.getPropertyVal(ctx, value, "then") orelse return false;
    defer ActiveEngine.freeValue(ctx, then_val);
    return ActiveEngine.isFunction(ctx, then_val);
}

/// Remove the promise + holder we stashed on globalThis so the next await doesn't see stale state and the values can be collected.
fn cleanupHolder(ctx: ActiveEngine.Context, global: ActiveEngine.Value, key: [:0]const u8) void {
    var holder_key_buf: [80]u8 = undefined;
    const holder_key = std.fmt.bufPrintSentinel(&holder_key_buf, "{s}_h", .{key}, 0) catch return;
    deleteGlobalProperty(ctx, global, key);
    deleteGlobalProperty(ctx, global, holder_key);
}

/// Delete the private holder without evaluating JavaScript. In particular, an aborted wait must not invoke a user-installed setter or create a fresh microtask checkpoint while teardown is trying to unwind this EvalLease.
fn deleteGlobalProperty(ctx: ActiveEngine.Context, global: ActiveEngine.Value, key: [:0]const u8) void {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const atom = qjs_mod.qjs.JS_NewAtom(ctx, key.ptr);
            defer qjs_mod.qjs.JS_FreeAtom(ctx, atom);
            _ = qjs_mod.qjs.JS_DeleteProperty(ctx, global, atom, 0);
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const property = jsc_mod.jsc.JSStringCreateWithUTF8CString(key.ptr);
            defer jsc_mod.jsc.JSStringRelease(property);
            var exception: jsc_mod.jsc.JSValueRef = null;
            _ = jsc_mod.jsc.JSObjectDeleteProperty(@ptrCast(ctx), @ptrCast(@constCast(global)), property, &exception);
        },
        .escargot, .hermes => {},
    }
}

fn freeEvalResult(res: @import("../types.zig").EvalResult) void {
    if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
    if (res.err_is_heap) {
        if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
    }
}
