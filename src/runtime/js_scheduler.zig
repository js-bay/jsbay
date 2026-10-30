//! Root adapter from engine ownership to the engine-independent scheduler.
const backend = @import("../backend.zig");
const instance_map = @import("instance_map.zig");
const js_event_loop = @import("js_event_loop");

const ActiveEngine = backend.ActiveEngine;

const engine_thread = @import("engine_thread.zig");

/// Admission for stable host helpers that accept either an engine-owned or a standalone context. Engine-owned contexts keep their runtime alive until all retained values and scheduler scopes have been released.
pub const ContextExecution = struct {
    ctx: ActiveEngine.Context,
    instance_id: ?i32 = null,
    admitted: bool = true,
    lease: ?engine_thread.EvalLease = null,
    execution: ?js_event_loop.Scheduler.Execution = null,

    pub fn isClosing(self: *const ContextExecution) bool {
        const id = self.instance_id orelse return false;
        return instance_map.isTeardownPending(id) or if (self.lease) |lease| engine_thread.deferredDestroyRequested(lease) else false;
    }

    fn endExecution(self: *ContextExecution) void {
        if (self.execution) |*guard| guard.end();
        self.execution = null;
    }

    pub fn checkpoint(self: *ContextExecution) void {
        self.endExecution();
        if (self.instance_id) |id| {
            @import("js_scheduler.zig").checkpoint(id, self.ctx);
        } else {
            ActiveEngine.processPendingJobs(self.ctx);
        }
    }

    pub fn end(self: *ContextExecution) void {
        self.endExecution();
        if (self.lease) |lease| @import("../engine.zig").finishEvalEntry(self.instance_id.?, lease);
        self.lease = null;
    }
};

pub fn beginContextExecution(ctx: ActiveEngine.Context) ContextExecution {
    const id = ActiveEngine.instanceIdFromCtx(ctx);
    const ptrs = instance_map.getPtrs(id) orelse return .{ .ctx = ctx };
    if (ptrs.ctx != ctx) return .{ .ctx = ctx };
    const lease = engine_thread.beginEval(id);
    if (!lease.allowed) return .{ .ctx = ctx, .admitted = false };
    const execution = beginExecution(id) orelse {
        @import("../engine.zig").finishEvalEntry(id, lease);
        return .{ .ctx = ctx, .admitted = false };
    };
    return .{ .ctx = ctx, .instance_id = id, .lease = lease, .execution = execution };
}

pub fn beginExecution(instance_id: i32) ?js_event_loop.Scheduler.Execution {
    if (engine_thread.ownerHasYielded(instance_id)) return null;
    const instance = instance_map.getInstance(instance_id) orelse return null;
    return instance.loop.scheduler.beginExecution();
}

pub fn beginSyncWait(instance_id: i32) ?js_event_loop.Scheduler.SyncWait {
    if (engine_thread.ownerHasYielded(instance_id)) return null;
    const instance = instance_map.getInstance(instance_id) orelse return null;
    return instance.loop.scheduler.beginSyncWait();
}

pub fn beginQueuedTask(instance_id: i32) ?js_event_loop.Scheduler.Task {
    if (engine_thread.ownerHasYielded(instance_id)) return null;
    const instance = instance_map.getInstance(instance_id) orelse return null;
    return instance.loop.scheduler.beginQueuedTask();
}

pub fn beginDebuggerControl(instance_id: i32) ?js_event_loop.Scheduler.DebuggerControl {
    if (engine_thread.ownerHasYielded(instance_id)) return null;
    const instance = instance_map.getInstance(instance_id) orelse return null;
    return instance.loop.scheduler.beginDebuggerControl();
}

pub fn allowsQueuedWork(instance_id: i32) bool {
    if (engine_thread.ownerHasYielded(instance_id)) return false;
    const instance = instance_map.getInstance(instance_id) orelse return false;
    return instance.loop.scheduler.allowsQueuedWork();
}

pub fn isTurnActive(instance_id: i32) bool {
    const instance = instance_map.getInstance(instance_id) orelse return false;
    return instance.loop.scheduler.isTurnActive();
}

pub fn isSynchronouslyWaiting(instance_id: i32) bool {
    if (engine_thread.ownerHasYielded(instance_id)) return false;
    const instance = instance_map.getInstance(instance_id) orelse return false;
    return instance.loop.scheduler.isSynchronouslyWaiting();
}

/// Run a backend microtask drain only at an admitted task boundary.
pub fn checkpoint(instance_id: i32, ctx: ActiveEngine.Context) void {
    if (engine_thread.ownerHasYielded(instance_id)) return;
    const instance = instance_map.getInstance(instance_id) orelse return;
    var guard = instance.loop.scheduler.beginCheckpoint() orelse return;
    defer guard.end();
    if (!instance.loop.scheduler.beginBackendDrain()) return;
    defer instance.loop.scheduler.endBackendDrain();
    if (!instance_map.isTeardownPending(instance_id)) ActiveEngine.processPendingJobs(ctx);
}

/// Drain microtasks for mono or packed-alt instances (packed-alt must not use ActiveEngine.Context).
pub fn checkpointInstance(instance_id: i32) void {
    const instance = instance_map.getInstance(instance_id) orelse return;
    switch (instance.engine_handles) {
        .mono => |m| checkpoint(instance_id, m.ctx),
        .packed_alt => |a| {
            if (engine_thread.ownerHasYielded(instance_id)) return;
            var guard = instance.loop.scheduler.beginCheckpoint() orelse return;
            defer guard.end();
            if (!instance.loop.scheduler.beginBackendDrain()) return;
            defer instance.loop.scheduler.endBackendDrain();
            if (!instance_map.isTeardownPending(instance_id)) {
                @import("../backend_dispatch.zig").processPendingJobsPacked(a.tag, .{
                    .runtime_addr = a.runtime_addr,
                    .ctx_addr = a.ctx_addr,
                });
            }
        },
    }
}

pub fn backendDrainAllowed(raw_ctx: ?*anyopaque) bool {
    const ctx: ActiveEngine.Context = @ptrCast(raw_ctx);
    const id = ActiveEngine.instanceIdFromCtx(ctx);
    const instance = instance_map.getInstance(id) orelse return true;
    if (instance.monoCtx()) |mc| { if (mc != ctx) return true; } else return true;
    if (engine_thread.ownerHasYielded(id)) return false;
    return instance.loop.scheduler.consumeBackendDrain();
}

pub fn backendDrainFinished(raw_ctx: ?*anyopaque) void {
    const ctx: ActiveEngine.Context = @ptrCast(raw_ctx);
    const id = ActiveEngine.instanceIdFromCtx(ctx);
    const instance = instance_map.getInstance(id) orelse return;
    if (instance.monoCtx()) |mc| { if (mc == ctx) instance.loop.scheduler.endBackendDrain(); }
}

pub fn runTurn(instance_id: i32, hooks: @import("js_event_loop").Scheduler.TurnHooks) bool {
    if (engine_thread.ownerHasYielded(instance_id)) return false;
    const instance = instance_map.getInstance(instance_id) orelse return false;
    return instance.loop.scheduler.runTurn(hooks);
}
