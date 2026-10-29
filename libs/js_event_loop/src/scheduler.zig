const std = @import("std");

/// Owner-thread state for one JavaScript environment.
///
/// The scheduler intentionally stores no engine values. Hosts must call it on their JavaScript owner thread; foreign completion threads only use the native completion primitive and wake the owner directly.
pub const Scheduler = struct {
    /// Atomic so any-thread controlSnapshot can sample without racing owner begin/end SyncWait.
    sync_wait_depth: std.atomic.Value(usize) = .init(0),
    execution_depth: usize = 0,
    checkpoint_active: bool = false,
    backend_drain_permit: bool = false,
    backend_drain_running: bool = false,
    implicit_checkpoint: bool = false,
    turn_active: bool = false,
    task_admission_permit: bool = false,
    next_task_source: TaskSource = .host_script,
    debugger_control_active: bool = false,

    /// A synchronous JavaScript entry such as script evaluation. Nested calls are allowed, but a reentrant event-loop tick cannot pull a queued timer or host callback into the middle of this stack.
    pub const Execution = struct {
        scheduler: *Scheduler,
        active: bool = true,

        pub fn end(self: *Execution) void {
            if (!self.active) return;
            std.debug.assert(self.scheduler.execution_depth != 0);
            self.scheduler.execution_depth -= 1;
            self.active = false;
        }
    };

    pub const SyncWait = struct {
        scheduler: *Scheduler,
        active: bool = true,

        pub fn end(self: *SyncWait) void {
            if (!self.active) return;
            const prev = self.scheduler.sync_wait_depth.fetchSub(1, .acq_rel);
            std.debug.assert(prev != 0);
            self.active = false;
        }
    };

    pub const Task = struct {
        scheduler: *Scheduler,
        active: bool = true,

        /// Returns true only for the outer queued task. The caller must then attempt a microtask checkpoint after the task has fully returned.
        pub fn end(self: *Task) bool {
            if (!self.active) return false;
            std.debug.assert(self.scheduler.execution_depth != 0);
            self.scheduler.execution_depth -= 1;
            self.active = false;
            return self.scheduler.execution_depth == 0;
        }
    };

    pub const Checkpoint = struct {
        scheduler: *Scheduler,
        active: bool = true,

        pub fn end(self: *Checkpoint) void {
            if (!self.active) return;
            std.debug.assert(self.scheduler.checkpoint_active);
            self.scheduler.checkpoint_active = false;
            self.active = false;
        }
    };

    /// Explicit debugger commands may inspect a paused stack. They cannot pump application tasks or enter a synchronous native wait's callback queue, and their completion does not create a microtask checkpoint.
    pub const DebuggerControl = struct {
        scheduler: *Scheduler,
        active: bool = true,

        pub fn end(self: *DebuggerControl) void {
            if (!self.active) return;
            std.debug.assert(self.scheduler.debugger_control_active);
            self.scheduler.debugger_control_active = false;
            self.scheduler.execution_depth -= 1;
            self.active = false;
        }
    };

    pub fn beginDebuggerControl(self: *Scheduler) ?DebuggerControl {
        if (self.sync_wait_depth.load(.acquire) != 0 or self.debugger_control_active) return null;
        self.debugger_control_active = true;
        self.execution_depth += 1;
        return .{ .scheduler = self };
    }

    /// Enter the native section of a JavaScript-visible synchronous call. No queued JavaScript work may begin until this guard ends.
    pub fn beginSyncWait(self: *Scheduler) SyncWait {
        _ = self.sync_wait_depth.fetchAdd(1, .acq_rel);
        return .{ .scheduler = self };
    }

    pub fn beginExecution(self: *Scheduler) Execution {
        self.execution_depth += 1;
        return .{ .scheduler = self };
    }

    /// A queued timer, dispatch item, TSFN callback, or host task may start only when neither a synchronous wait nor another queued task/checkpoint is already executing.
    pub fn beginQueuedTask(self: *Scheduler) ?Task {
        if (!self.allowsQueuedWork()) return null;
        if (self.turn_active) {
            if (!self.task_admission_permit) return null;
            self.task_admission_permit = false;
        }
        self.execution_depth += 1;
        return .{ .scheduler = self };
    }

    pub fn allowsQueuedWork(self: *const Scheduler) bool {
        return self.sync_wait_depth.load(.acquire) == 0 and self.execution_depth == 0 and !self.checkpoint_active;
    }

    /// Bulk drain APIs must not consume more work from a currently selected host turn. Internal `run_one_task` adapters are already inside it.
    pub fn isTurnActive(self: *const Scheduler) bool {
        return self.turn_active;
    }

    /// Start a microtask checkpoint after an outer queued task. A host calls its backend's drain routine while this guard is alive. Reentrant ticks and recursive checkpoints observe the guard and do no queued work.
    pub fn beginCheckpoint(self: *Scheduler) ?Checkpoint {
        if (self.sync_wait_depth.load(.acquire) != 0 or self.execution_depth != 0 or self.checkpoint_active) return null;
        self.checkpoint_active = true;
        return .{ .scheduler = self };
    }

    pub fn isSynchronouslyWaiting(self: *const Scheduler) bool {
        return self.sync_wait_depth.load(.acquire) != 0;
    }

    pub fn allowsBackendDrain(self: *const Scheduler) bool {
        // A synchronous native wait always wins, including from a callback reached while a formerly legal checkpoint is still unwinding.
        if (self.sync_wait_depth.load(.acquire) != 0) return false;
        if (self.execution_depth != 0 or self.backend_drain_running) return false;
        return !self.checkpoint_active or self.backend_drain_permit;
    }

    pub fn beginBackendDrain(self: *Scheduler) bool {
        if (!self.checkpoint_active or self.backend_drain_permit or self.backend_drain_running) return false;
        self.backend_drain_permit = true;
        return true;
    }
    pub fn endBackendDrain(self: *Scheduler) void {
        // JSC has no explicit Promise-job runner, so its deferred-finalizer drain may not consume the QuickJS-facing permit.
        self.backend_drain_permit = false;
        self.backend_drain_running = false;
        if (self.implicit_checkpoint) {
            self.implicit_checkpoint = false;
            self.checkpoint_active = false;
        }
    }
    pub fn consumeBackendDrain(self: *Scheduler) bool {
        if (!self.allowsBackendDrain()) return false;
        if (!self.checkpoint_active) {
            self.checkpoint_active = true;
            self.implicit_checkpoint = true;
        }
        self.backend_drain_permit = false;
        self.backend_drain_running = true;
        return true;
    }

    /// Sources selected by one host event-loop turn. FIFO is preserved within each source; the cursor prevents a ready source from starving another.
    pub const TaskSource = enum { host_script, native_dispatch, tsfn, timer };

    /// One browser-style event-loop turn. Native readiness is collected before selection, then at most one JavaScript task runs before its checkpoint.
    pub const TurnHooks = struct {
        context: ?*anyopaque,
        prepare_native_events: *const fn (?*anyopaque) void,
        run_one_task: *const fn (?*anyopaque, TaskSource) bool,
        checkpoint: *const fn (?*anyopaque) void,
        finish_task: ?*const fn (?*anyopaque) void = null,
    };

    pub fn runTurn(self: *Scheduler, hooks: TurnHooks) bool {
        if (self.turn_active or !self.allowsQueuedWork()) return false;
        self.turn_active = true;
        defer {
            self.task_admission_permit = false;
            self.turn_active = false;
        }
        var ran = false;
        defer if (ran) if (hooks.finish_task) |finish| finish(hooks.context);

        hooks.prepare_native_events(hooks.context);
        if (!self.allowsQueuedWork()) return false;

        const sources = [_]TaskSource{ .host_script, .native_dispatch, .tsfn, .timer };
        const first = @backingInt(self.next_task_source);
        for (0..sources.len) |offset| {
            const index = (first + offset) % sources.len;
            self.task_admission_permit = true;
            const selected = hooks.run_one_task(hooks.context, sources[index]);
            self.task_admission_permit = false;
            if (selected) {
                self.next_task_source = sources[(index + 1) % sources.len];
                ran = true;
                break;
            }
            if (!self.allowsQueuedWork()) return false;
        }
        if (!ran) return false;
        if (self.allowsQueuedWork()) hooks.checkpoint(hooks.context);
        return ran;
    }
};
