//! TLA+ specification locking and Apalache ITF trace replay harness for JS event loop Scheduler.
//! Verifies model declarations anti-drift, positive execution trace replay, negative counterexample rejection during sync wait, and dynamic action coverage.
//! Run: `zig build test-state-tcas`
//! Update golden: touch .state_tcas-update-tla && zig build test-state-tcas && rm -f .state_tcas-update-tla

const std = @import("std");
const state_tcas = @import("state_tcas");
const js_event_loop = @import("js_event_loop");

const Scheduler = js_event_loop.Scheduler;

pub const SchedulerAct = enum {
    enqueue_macro,
    enqueue_micro,
    begin_queued_task,
    end_queued_task,
    begin_checkpoint,
    drain_micro,
    end_checkpoint,
    begin_sync_wait,
    end_sync_wait,
};

pub const SchedulerState = enum {
    idle,
    in_task,
    after_task,
    in_checkpoint,
    in_sync_wait,
};

pub const SchedulerConfig = struct {
    pub const max_microtasks: usize = 1000;
    pub const max_queued_tasks: usize = 128;
    pub const max_sync_depth: usize = 8;
};

pub const ProjectedState = struct {
    state: SchedulerState,
    macro_q: usize,
    micro_q: usize,
    sync_depth: usize,
};

pub const SchedulerTlaContext = struct {
    sched: Scheduler = .{},
    macro_q: usize = 0,
    micro_q: usize = 0,
    after_task: bool = false,
    sync_wait_stack: [SchedulerConfig.max_sync_depth]Scheduler.SyncWait = undefined,
    sync_wait_depth: usize = 0,
    task_guard: ?Scheduler.Task = null,
    checkpoint_guard: ?Scheduler.Checkpoint = null,
    acts_buf: [8]SchedulerAct = undefined,
    allocator: std.mem.Allocator,

    pub fn prepare(self: *@This()) !void {
        self.release();
        self.sched = .{};
        self.macro_q = 0;
        self.micro_q = 0;
        self.after_task = false;
        self.sync_wait_depth = 0;
        self.task_guard = null;
        self.checkpoint_guard = null;
    }

    pub fn release(self: *@This()) void {
        if (self.task_guard) |*t| _ = t.end();
        self.task_guard = null;
        if (self.checkpoint_guard) |*c| c.end();
        self.checkpoint_guard = null;
        while (self.sync_wait_depth > 0) {
            self.sync_wait_depth -= 1;
            self.sync_wait_stack[self.sync_wait_depth].end();
        }
        self.after_task = false;
    }

    pub fn project(self: *const @This()) ProjectedState {
        // Dynamic state projection directly derived from Scheduler execution, sync wait counters, and host queues.
        const st: SchedulerState = if (self.sched.sync_wait_depth.load(.acquire) > 0)
            .in_sync_wait
        else if (self.sched.execution_depth > 0)
            .in_task
        else if (self.sched.checkpoint_active)
            .in_checkpoint
        else if (self.after_task)
            .after_task
        else
            .idle;

        return .{
            .state = st,
            .macro_q = self.macro_q,
            .micro_q = self.micro_q,
            .sync_depth = self.sync_wait_depth,
        };
    }

    pub fn enabled(self: *@This()) []const SchedulerAct {
        var n: usize = 0;
        // Enqueue operations bounded by SchedulerConfig constants.
        if (self.macro_q < SchedulerConfig.max_queued_tasks) {
            self.acts_buf[n] = .enqueue_macro;
            n += 1;
        }
        if (self.micro_q < SchedulerConfig.max_microtasks) {
            self.acts_buf[n] = .enqueue_micro;
            n += 1;
        }

        // Synchronous native wait entry and exit (supports nesting up to max_sync_depth).
        if (self.sync_wait_depth < SchedulerConfig.max_sync_depth) {
            self.acts_buf[n] = .begin_sync_wait;
            n += 1;
        }
        if (self.sync_wait_depth > 0) {
            self.acts_buf[n] = .end_sync_wait;
            n += 1;
        }

        // HTML5 Event Loop invariant & Scheduler contract: Queued tasks may start only if microtasks are drained.
        if (self.macro_q > 0 and self.sched.allowsQueuedWork() and self.micro_q == 0) {
            self.acts_buf[n] = .begin_queued_task;
            n += 1;
        }

        // Active task completion: can only complete when sync wait is not blocking the task stack.
        if (self.sched.execution_depth > 0 and self.sync_wait_depth == 0 and !self.sched.checkpoint_active) {
            self.acts_buf[n] = .end_queued_task;
            n += 1;
        }

        // Microtask checkpoint entry: required when leaving a task with microtasks, or when idle with pending microtasks.
        if (self.micro_q > 0 and self.sched.allowsQueuedWork() and !self.after_task and self.sched.execution_depth == 0) {
            self.acts_buf[n] = .begin_checkpoint;
            n += 1;
        }
        if (self.after_task and self.sched.allowsQueuedWork()) {
            self.acts_buf[n] = .begin_checkpoint;
            n += 1;
        }

        // Checkpoint execution and completion (strictly prohibited during synchronous wait).
        if (self.sched.checkpoint_active and self.sync_wait_depth == 0) {
            if (self.micro_q > 0) {
                self.acts_buf[n] = .drain_micro;
                n += 1;
            } else {
                self.acts_buf[n] = .end_checkpoint;
                n += 1;
            }
        }

        return self.acts_buf[0..n];
    }

    pub fn step(self: *@This(), act: SchedulerAct, pic: ?*state_tcas.Picture) !void {
        const before = @tagName(self.project().state);
        switch (act) {
            .enqueue_macro => {
                if (self.macro_q >= SchedulerConfig.max_queued_tasks) return error.QueueOverflow;
                self.macro_q += 1;
            },
            .enqueue_micro => {
                if (self.micro_q >= SchedulerConfig.max_microtasks) return error.QueueOverflow;
                self.micro_q += 1;
            },
            .begin_queued_task => {
                if (self.task_guard != null) return error.TaskAlreadyRunning;
                const task = self.sched.beginQueuedTask() orelse return error.SchedulerRejected;
                self.task_guard = task;
                self.macro_q -|= 1;
            },
            .end_queued_task => {
                if (self.task_guard) |*t| {
                    if (self.sched.isSynchronouslyWaiting()) return error.SchedulerRejected;
                    const is_outer = t.end();
                    self.task_guard = null;
                    if (is_outer) {
                        self.after_task = (self.micro_q > 0);
                    }
                } else return error.NoTaskToComplete;
            },
            .begin_checkpoint => {
                if (self.checkpoint_guard != null) return error.CheckpointAlreadyRunning;
                const cp = self.sched.beginCheckpoint() orelse return error.SchedulerRejected;
                self.checkpoint_guard = cp;
                self.after_task = false;
            },
            .drain_micro => {
                if (!self.sched.checkpoint_active or self.sched.isSynchronouslyWaiting()) return error.SchedulerRejected;
                if (self.micro_q == 0) return error.QueueUnderflow;
                self.micro_q -= 1;
            },
            .end_checkpoint => {
                if (self.checkpoint_guard) |*c| {
                    if (self.sched.isSynchronouslyWaiting()) return error.SchedulerRejected;
                    c.end();
                    self.checkpoint_guard = null;
                    self.after_task = false;
                } else return error.NoCheckpointToComplete;
            },
            .begin_sync_wait => {
                if (self.sync_wait_depth >= SchedulerConfig.max_sync_depth) return error.SyncWaitOverflow;
                self.sync_wait_stack[self.sync_wait_depth] = self.sched.beginSyncWait();
                self.sync_wait_depth += 1;
            },
            .end_sync_wait => {
                if (self.sync_wait_depth == 0) return error.SyncWaitUnderflow;
                self.sync_wait_depth -= 1;
                self.sync_wait_stack[self.sync_wait_depth].end();
            },
        }

        const after = @tagName(self.project().state);
        if (pic) |p| {
            try p.observe(self.allocator, .{
                .before = before,
                .after = after,
                .label = @tagName(act),
                .rejected = false,
                .mutated = true,
                .note = after,
                .from = "Host",
                .to = "Scheduler",
            });
        }
    }
};

test "state_tcas tla: lock Scheduler model declarations" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try state_tcas.tla.lock(
        io,
        allocator,
        "docs/tla/scheduler_model.tla",
        "scheduler_model",
        SchedulerAct,
        SchedulerState,
        SchedulerConfig,
    );
}

test "state_tcas tla: checkExtends confirms scheduler_spec extends scheduler_model" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const spec_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "docs/tla/scheduler_spec.tla",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(spec_bytes);

    try std.testing.expect(state_tcas.tla.checkExtends(spec_bytes, "scheduler_model"));
}

test "state_tcas tla: replay ITF trace for task then checkpoint drain" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const trace_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "docs/tla/scheduler_task_checkpoint_trace.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(trace_bytes);

    var ctx: SchedulerTlaContext = .{ .allocator = allocator };
    var pic: state_tcas.Picture = .{};
    defer pic.deinit(allocator);

    const stats = try state_tcas.tla.replayJsonTrace(
        SchedulerAct,
        &ctx,
        allocator,
        trace_bytes,
        &pic,
    );

    try std.testing.expectEqual(@as(usize, 7), stats.actions_replayed);
    try std.testing.expectEqual(@as(usize, 8), stats.states_verified);
    try std.testing.expectEqual(SchedulerState.idle, ctx.project().state);
    try std.testing.expectEqual(@as(usize, 0), ctx.project().macro_q);
    try std.testing.expectEqual(@as(usize, 0), ctx.project().micro_q);
    try std.testing.expectEqual(@as(usize, 0), ctx.project().sync_depth);
    try std.testing.expectEqual(@as(usize, 7), pic.steps.items.len);
}

test "state_tcas tla: replay counterexample trace expecting ActionNotEnabled during sync wait" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const trace_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "docs/tla/scheduler_sync_wait_rejection_trace.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(trace_bytes);

    var ctx: SchedulerTlaContext = .{ .allocator = allocator };

    const stats = try state_tcas.tla.replayJsonTraceWithOptions(
        SchedulerAct,
        &ctx,
        allocator,
        trace_bytes,
        null,
        .{
            .expect_rejection = .{
                .at_step = 2,
                .err = error.ActionNotEnabled,
            },
        },
    );

    try std.testing.expectEqual(@as(usize, 1), stats.actions_replayed);
    // Harness release() safely cleans up all guards upon trace completion returning state to idle.
    try std.testing.expectEqual(SchedulerState.idle, ctx.project().state);
}

test "state_tcas tla: replay counterexample expecting ActionNotEnabled when draining micro during sync wait" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const trace_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "docs/tla/scheduler_checkpoint_sync_wait_rejection_trace.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(trace_bytes);

    var ctx: SchedulerTlaContext = .{ .allocator = allocator };

    const stats = try state_tcas.tla.replayJsonTraceWithOptions(
        SchedulerAct,
        &ctx,
        allocator,
        trace_bytes,
        null,
        .{
            .expect_rejection = .{
                .at_step = 4,
                .err = error.ActionNotEnabled,
            },
        },
    );

    try std.testing.expectEqual(@as(usize, 3), stats.actions_replayed);
    try std.testing.expectEqual(SchedulerState.idle, ctx.project().state);
}

test "state_tcas tla: TraceDiverged triggered when queue counters diverge in ITF trace" {
    const allocator = std.testing.allocator;
    const divergent_trace =
        \\{
        \\  "vars": ["state", "macro_q", "micro_q", "sync_depth"],
        \\  "states": [
        \\    { "#meta": { "index": 0 }, "action": "init", "state": "idle", "macro_q": 99, "micro_q": 0, "sync_depth": 0 }
        \\  ]
        \\}
    ;
    var ctx: SchedulerTlaContext = .{ .allocator = allocator };
    try std.testing.expectError(
        error.TraceDiverged,
        state_tcas.tla.replayJsonTrace(SchedulerAct, &ctx, allocator, divergent_trace, null),
    );
}

test "state_tcas tla: begin_checkpoint is not enabled during sync wait after task with microtasks" {
    var ctx: SchedulerTlaContext = .{ .allocator = std.testing.allocator };
    try ctx.step(.enqueue_macro, null);
    try ctx.step(.begin_queued_task, null);
    try ctx.step(.enqueue_micro, null);
    try ctx.step(.end_queued_task, null);
    try std.testing.expectEqual(SchedulerState.after_task, ctx.project().state);

    // Enter synchronous wait after task.
    try ctx.step(.begin_sync_wait, null);
    try std.testing.expectEqual(SchedulerState.in_sync_wait, ctx.project().state);

    const en = ctx.enabled();
    for (en) |act| {
        try std.testing.expect(act != .begin_checkpoint);
    }
    try std.testing.expectError(error.SchedulerRejected, ctx.step(.begin_checkpoint, null));

    try ctx.step(.end_sync_wait, null);
    try std.testing.expectEqual(SchedulerState.after_task, ctx.project().state);
    try std.testing.expect(ctx.sched.allowsQueuedWork());

    // Checkpoint can now proceed.
    try ctx.step(.begin_checkpoint, null);
    try ctx.step(.drain_micro, null);
    try ctx.step(.end_checkpoint, null);
    try std.testing.expectEqual(SchedulerState.idle, ctx.project().state);
}

test "state_tcas tla: drain_micro and end_checkpoint reject operations during sync wait within checkpoint" {
    var ctx: SchedulerTlaContext = .{ .allocator = std.testing.allocator };
    try ctx.step(.enqueue_micro, null);
    try ctx.step(.begin_checkpoint, null);
    try std.testing.expectEqual(SchedulerState.in_checkpoint, ctx.project().state);

    // Enter synchronous wait from within checkpoint callback.
    try ctx.step(.begin_sync_wait, null);
    try std.testing.expectEqual(SchedulerState.in_sync_wait, ctx.project().state);

    const en = ctx.enabled();
    for (en) |act| {
        try std.testing.expect(act != .drain_micro);
        try std.testing.expect(act != .end_checkpoint);
    }
    try std.testing.expectError(error.SchedulerRejected, ctx.step(.drain_micro, null));
    try std.testing.expectError(error.SchedulerRejected, ctx.step(.end_checkpoint, null));

    try ctx.step(.end_sync_wait, null);
    try std.testing.expectEqual(SchedulerState.in_checkpoint, ctx.project().state);

    try ctx.step(.drain_micro, null);
    try ctx.step(.end_checkpoint, null);
    try std.testing.expectEqual(SchedulerState.idle, ctx.project().state);
}

test "state_tcas tla: Scheduler implementation rejects beginQueuedTask during sync wait" {
    var ctx: SchedulerTlaContext = .{ .allocator = std.testing.allocator };
    try ctx.step(.begin_sync_wait, null);

    // Directly verify that the live Scheduler's allowsQueuedWork() returns false and beginQueuedTask returns null.
    try std.testing.expect(!ctx.sched.allowsQueuedWork());
    try std.testing.expect(ctx.sched.beginQueuedTask() == null);
    try std.testing.expectError(error.SchedulerRejected, ctx.step(.begin_queued_task, null));

    try ctx.step(.end_sync_wait, null);
    try std.testing.expect(ctx.sched.allowsQueuedWork());
}

test "state_tcas tla: nested sync wait inside in_task preserves execution depth and resumes task" {
    var ctx: SchedulerTlaContext = .{ .allocator = std.testing.allocator };

    try ctx.step(.enqueue_macro, null);
    try ctx.step(.begin_queued_task, null);
    try std.testing.expectEqual(SchedulerState.in_task, ctx.project().state);

    // Enter first level sync wait from inside task.
    try ctx.step(.begin_sync_wait, null);
    try std.testing.expectEqual(SchedulerState.in_sync_wait, ctx.project().state);
    try std.testing.expectEqual(@as(usize, 1), ctx.project().sync_depth);

    // Enter second level nested sync wait.
    try ctx.step(.begin_sync_wait, null);
    try std.testing.expectEqual(SchedulerState.in_sync_wait, ctx.project().state);
    try std.testing.expectEqual(@as(usize, 2), ctx.project().sync_depth);

    // Exit nested level.
    try ctx.step(.end_sync_wait, null);
    try std.testing.expectEqual(@as(usize, 1), ctx.project().sync_depth);
    try std.testing.expectEqual(SchedulerState.in_sync_wait, ctx.project().state);

    // Exit outer sync wait -> state smoothly resumes to in_task.
    try ctx.step(.end_sync_wait, null);
    try std.testing.expectEqual(SchedulerState.in_task, ctx.project().state);
    try std.testing.expectEqual(@as(usize, 0), ctx.project().sync_depth);

    // Finish task.
    try ctx.step(.end_queued_task, null);
    try std.testing.expectEqual(SchedulerState.idle, ctx.project().state);
}

test "state_tcas tla: sync wait depth is bounded by SchedulerConfig.max_sync_depth" {
    var ctx: SchedulerTlaContext = .{ .allocator = std.testing.allocator };
    var i: usize = 0;
    while (i < SchedulerConfig.max_sync_depth) : (i += 1) {
        try ctx.step(.begin_sync_wait, null);
    }
    try std.testing.expectEqual(SchedulerConfig.max_sync_depth, ctx.project().sync_depth);
    try std.testing.expectError(error.SyncWaitOverflow, ctx.step(.begin_sync_wait, null));

    while (i > 0) : (i -= 1) {
        try ctx.step(.end_sync_wait, null);
    }
    try std.testing.expectEqual(@as(usize, 0), ctx.project().sync_depth);
}

test "state_tcas tla: dynamic action coverage across replay traces" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const trace1_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "docs/tla/scheduler_task_checkpoint_trace.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(trace1_bytes);

    const trace2_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "docs/tla/scheduler_sync_wait_lifecycle_trace.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(trace2_bytes);

    var ctx: SchedulerTlaContext = .{ .allocator = allocator };

    var pic1: state_tcas.Picture = .{};
    defer pic1.deinit(allocator);
    _ = try state_tcas.tla.replayJsonTrace(SchedulerAct, &ctx, allocator, trace1_bytes, &pic1);

    var pic2: state_tcas.Picture = .{};
    defer pic2.deinit(allocator);
    _ = try state_tcas.tla.replayJsonTrace(SchedulerAct, &ctx, allocator, trace2_bytes, &pic2);

    // Collect all executed actions dynamically from the replay observations.
    var executed: std.ArrayList(SchedulerAct) = .empty;
    defer executed.deinit(allocator);

    for (pic1.steps.items) |step| {
        if (std.meta.stringToEnum(SchedulerAct, step.label)) |act| {
            try executed.append(allocator, act);
        }
    }
    for (pic2.steps.items) |step| {
        if (std.meta.stringToEnum(SchedulerAct, step.label)) |act| {
            try executed.append(allocator, act);
        }
    }

    // Verify dynamic coverage of all 9 actions across the replay suite.
    try state_tcas.tla.verifyCoverage(SchedulerAct, executed.items);

    // Verify omission detection on partial set.
    try std.testing.expectError(
        error.ActUncovered,
        state_tcas.tla.verifyCoverage(SchedulerAct, executed.items[0..4]),
    );
}
