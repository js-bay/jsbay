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
    execution: ?Execution = null,

    pub fn isClosing(self: *const ContextExecution) bool {
        const id = self.instance_id orelse return false;
        return instance_map.isTeardownPending(id) or if (self.lease) |lease| engine_thread.deferredDestroyRequested(lease) else false;
    }

    fn endExecution(self: *ContextExecution) void {
        if (self.execution) |*guard| guard.end();
        self.execution = null;
    }

    pub fn checkpoint(self: *ContextExecution) void {
        if (self.execution) |*execution| {
            checkpointAfterExecution(execution, self.ctx);
            self.execution = null;
        } else if (self.instance_id) |id| {
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

pub const Execution = struct {
    scheduler: js_event_loop.Scheduler.Execution,
    instance_id: i32,
    budget_armed: bool,
    scheduler_active: bool = true,
    budget_active: bool = true,

    pub fn endScheduler(self: *Execution) void {
        if (!self.scheduler_active) return;
        self.scheduler_active = false;
        self.scheduler.end();
    }

    pub fn endBudget(self: *Execution) void {
        if (!self.budget_active) return;
        self.budget_active = false;
        if (self.budget_armed) @import("runtime_control.zig").endExecutionBudget(self.instance_id);
    }

    pub fn end(self: *Execution) void {
        self.endScheduler();
        self.endBudget();
    }
};

/// Drain a checkpoint after leaving the scheduler execution scope while retaining its original runtime budget lease.
pub fn checkpointAfterExecution(execution: *Execution, ctx: ActiveEngine.Context) void {
    execution.endScheduler();
    checkpoint(execution.instance_id, ctx);
    execution.endBudget();
}

/// Packed variant of checkpointAfterExecution.
pub fn checkpointInstanceAfterExecution(execution: *Execution) void {
    execution.endScheduler();
    checkpointInstance(execution.instance_id);
    execution.endBudget();
}

pub const Task = struct {
    scheduler: js_event_loop.Scheduler.Task,
    instance_id: i32,
    budget_armed: bool,
    scheduler_active: bool = true,
    budget_active: bool = true,

    pub fn endScheduler(self: *Task) bool {
        if (!self.scheduler_active) return false;
        self.scheduler_active = false;
        return self.scheduler.end();
    }

    pub fn endBudget(self: *Task) void {
        if (!self.budget_active) return;
        self.budget_active = false;
        if (self.budget_armed) @import("runtime_control.zig").endExecutionBudget(self.instance_id);
    }

    pub fn end(self: *Task) bool {
        const outer = self.endScheduler();
        self.endBudget();
        return outer;
    }
};

pub fn beginExecution(instance_id: i32) ?Execution {
    if (engine_thread.ownerHasYielded(instance_id)) return null;
    if (!@import("runtime_control.zig").canEnterExecution(instance_id)) return null;
    const instance = instance_map.getInstance(instance_id) orelse return null;
    return .{ .scheduler = instance.loop.scheduler.beginExecution(), .instance_id = instance_id, .budget_armed = @import("runtime_control.zig").beginExecutionBudget(instance_id) };
}

pub fn beginSyncWait(instance_id: i32) ?js_event_loop.Scheduler.SyncWait {
    if (engine_thread.ownerHasYielded(instance_id)) return null;
    const instance = instance_map.getInstance(instance_id) orelse return null;
    return instance.loop.scheduler.beginSyncWait();
}

pub fn beginQueuedTask(instance_id: i32) ?Task {
    if (engine_thread.ownerHasYielded(instance_id)) return null;
    const instance = instance_map.getInstance(instance_id) orelse return null;
    const task = instance.loop.scheduler.beginQueuedTask() orelse return null;
    return .{ .scheduler = task, .instance_id = instance_id, .budget_armed = @import("runtime_control.zig").beginExecutionBudget(instance_id) };
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
    if (!instance_map.isTeardownPending(instance_id)) {
        if (!@import("runtime_control.zig").beginExecutionBudget(instance_id)) return;
        defer @import("runtime_control.zig").endExecutionBudget(instance_id);
        ActiveEngine.processPendingJobs(ctx);
    }
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
                if (!@import("runtime_control.zig").beginExecutionBudget(instance_id)) return;
                defer @import("runtime_control.zig").endExecutionBudget(instance_id);
                @import("../backend_dispatch.zig").processPendingJobsPacked(a.tag, .{
                    .runtime_addr = a.runtime_addr,
                    .ctx_addr = a.ctx_addr,
                });
            }
        },
    }
}

pub fn backendDrainAllowed(raw_ctx: ?*anyopaque) bool {
    // Resolve by stored context address so packed-alt (non-primary) contexts are not passed through the primary ActiveEngine.instanceIdFromCtx.
    const id = instance_map.findByContextAddr(@intFromPtr(raw_ctx orelse return true)) orelse return true;
    const instance = instance_map.getInstance(id) orelse return true;
    if (engine_thread.ownerHasYielded(id)) return false;
    return instance.loop.scheduler.consumeBackendDrain();
}

pub fn backendDrainFinished(raw_ctx: ?*anyopaque) void {
    const id = instance_map.findByContextAddr(@intFromPtr(raw_ctx orelse return)) orelse return;
    const instance = instance_map.getInstance(id) orelse return;
    instance.loop.scheduler.endBackendDrain();
}

pub fn runTurn(instance_id: i32, hooks: @import("js_event_loop").Scheduler.TurnHooks) bool {
    if (engine_thread.ownerHasYielded(instance_id)) return false;
    const instance = instance_map.getInstance(instance_id) orelse return false;
    return instance.loop.scheduler.runTurn(hooks);
}
