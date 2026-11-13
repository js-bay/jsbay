//! TLA+ specification locking and Apalache ITF trace replay harness for JS event loop Scheduler.
//!
//! Verifies model declarations anti-drift, positive execution trace replay, negative counterexample rejection during sync wait, and dynamic action coverage.
//!
//! Run: `zig build test-state-tcas`
//!
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
    saved_state: SchedulerState,
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
    saved_state: SchedulerState = .idle,
    acts_buf: [8]SchedulerAct = undefined,
    allocator: std.mem.Allocator,

    pub fn prepare(self: *@This()) !void {
        self.release();
        self.sched = .{};
        self.macro_q = 0;
        self.micro_q = 0;
        self.after_task = false;
        self.sync_wait_depth = 0;
        self.saved_state = .idle;
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
        self.saved_state = .idle;
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
            .saved_state = self.saved_state,
            .macro_q = self.macro_q,
            .micro_q = self.micro_q,
            .sync_depth = self.sync_wait_depth,
        };
    }

    /// Infer a missing ITF action from adjacent projected states without cloning this context.
    ///
    /// Guard objects hold pointers back to `sched`, so a shallow copy is not a safe trial context.
    pub fn inferAction(self: *@This(), item: std.json.Value) !?SchedulerAct {
        const before = self.project();
        var found: ?SchedulerAct = null;
        for (self.enabled()) |act| {
            if (!projectedMatchesJson(projectedAfter(before, act), item)) continue;
            if (found != null) return null;
            found = act;
        }
        return found;
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
                if (!self.sched.beginBackendDrain()) return error.SchedulerRejected;
                defer self.sched.endBackendDrain();
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
                if (self.sync_wait_depth == 0) self.saved_state = self.project().state;
                self.sync_wait_stack[self.sync_wait_depth] = self.sched.beginSyncWait();
                self.sync_wait_depth += 1;
            },
            .end_sync_wait => {
                if (self.sync_wait_depth == 0) return error.SyncWaitUnderflow;
                self.sync_wait_depth -= 1;
                self.sync_wait_stack[self.sync_wait_depth].end();
                if (self.sync_wait_depth == 0) self.saved_state = .idle;
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

fn projectedAfter(before: ProjectedState, act: SchedulerAct) ProjectedState {
    var after = before;
    switch (act) {
        .enqueue_macro => after.macro_q += 1,
        .enqueue_micro => after.micro_q += 1,
        .begin_queued_task => {
            after.macro_q -= 1;
            after.state = .in_task;
        },
        .end_queued_task => after.state = if (after.micro_q > 0) .after_task else .idle,
        .begin_checkpoint => after.state = .in_checkpoint,
        .drain_micro => after.micro_q -= 1,
        .end_checkpoint => after.state = .idle,
        .begin_sync_wait => {
            if (after.sync_depth == 0) after.saved_state = after.state;
            after.sync_depth += 1;
            after.state = .in_sync_wait;
        },
        .end_sync_wait => {
            after.sync_depth -= 1;
            after.state = if (after.sync_depth == 0) after.saved_state else .in_sync_wait;
            if (after.sync_depth == 0) after.saved_state = .idle;
        },
    }
    return after;
}

fn jsonUsize(value: std.json.Value) ?usize {
    switch (value) {
        .integer => |n| {
            if (n < 0) return null;
            return std.math.cast(usize, n);
        },
        .object => |obj| {
            const raw = obj.get("#bigint") orelse return null;
            if (raw != .string) return null;
            return std.fmt.parseInt(usize, raw.string, 10) catch null;
        },
        else => return null,
    }
}

fn projectedMatchesJson(proj: ProjectedState, item: std.json.Value) bool {
    if (item != .object) return false;
    const obj = item.object;
    if (obj.get("state")) |v| {
        if (v != .string or !std.mem.eql(u8, v.string, @tagName(proj.state))) return false;
    }
    if (obj.get("saved_state")) |v| {
        if (v != .string or !std.mem.eql(u8, v.string, @tagName(proj.saved_state))) return false;
    }
    if (obj.get("macro_q")) |v| {
        if (jsonUsize(v) != proj.macro_q) return false;
    }
    if (obj.get("micro_q")) |v| {
        if (jsonUsize(v) != proj.micro_q) return false;
    }
    if (obj.get("sync_depth")) |v| {
        if (jsonUsize(v) != proj.sync_depth) return false;
    }
    return true;
}

test "state_tcas tla: lock Scheduler model declarations" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try state_tcas.tla.lock(
        io,
        allocator,
        "src/tests/tla/scheduler_model.tla",
        "scheduler_model",
        SchedulerAct,
        SchedulerState,
        SchedulerConfig,
    );
}

test "state_tcas tla: checkExtends and validateSpecSyntax confirm scheduler_spec integrity" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const spec_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/tests/tla/scheduler_spec.tla",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(spec_bytes);

    try std.testing.expect(state_tcas.tla.checkExtends(spec_bytes, "scheduler_model"));
    try state_tcas.tla.validateSpecSyntax(allocator, spec_bytes);
}

test "state_tcas tla: replay ITF trace for task then checkpoint drain" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const trace_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/tests/tla/scheduler_task_checkpoint_trace.json",
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
        "src/tests/tla/scheduler_sync_wait_rejection_trace.json",
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
        "src/tests/tla/scheduler_checkpoint_sync_wait_rejection_trace.json",
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
        \\  "vars": ["state", "saved_state", "macro_q", "micro_q", "sync_depth"],
        \\  "states": [
        \\    { "#meta": { "index": 0 }, "action": "init", "state": "idle", "saved_state": "idle", "macro_q": 99, "micro_q": 0, "sync_depth": 0 }
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
        "src/tests/tla/scheduler_task_checkpoint_trace.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(trace1_bytes);

    const trace2_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/tests/tla/scheduler_sync_wait_lifecycle_trace.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(trace2_bytes);

    var ctx: SchedulerTlaContext = .{ .allocator = allocator };

    var pic: state_tcas.Picture = .{};
    defer pic.deinit(allocator);

    const stats1 = try state_tcas.tla.replayJsonTrace(SchedulerAct, &ctx, allocator, trace1_bytes, &pic);
    const stats2 = try state_tcas.tla.replayJsonTrace(SchedulerAct, &ctx, allocator, trace2_bytes, &pic);

    // Verify dynamic coverage of all 9 actions directly via Picture and ReplayStats (state_tcas 0.3.1).
    try pic.verifyCoverage(SchedulerAct);
    try stats2.verifyCoverage(SchedulerAct, &pic);

    // Verify omission detection on partial Picture.
    var partial_pic: state_tcas.Picture = .{};
    defer partial_pic.deinit(allocator);
    _ = try state_tcas.tla.replayJsonTrace(SchedulerAct, &ctx, allocator, trace1_bytes, &partial_pic);
    try std.testing.expectError(
        error.ActUncovered,
        partial_pic.verifyCoverage(SchedulerAct),
    );
    _ = stats1;
}

test "state_tcas tla: render ADR-015 ITF JSON trace from replay exploration" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const trace_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/tests/tla/scheduler_task_checkpoint_trace.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(trace_bytes);

    var ctx: SchedulerTlaContext = .{ .allocator = allocator };
    var pic: state_tcas.Picture = .{};
    defer pic.deinit(allocator);

    _ = try state_tcas.tla.replayJsonTrace(
        SchedulerAct,
        &ctx,
        allocator,
        trace_bytes,
        &pic,
    );

    const itf_json = try pic.renderItfJson(allocator, .{});
    defer allocator.free(itf_json);

    try std.testing.expect(std.mem.indexOf(u8, itf_json, "\"#meta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, itf_json, "\"mbt::actionTaken\"") != null);
}

test "state_tcas tla: state-only ITF infers enqueue_macro without cloning the context" {
    const allocator = std.testing.allocator;
    var ctx: SchedulerTlaContext = .{ .allocator = allocator };
    defer ctx.release();
    const trace =
        \\{"vars":["state","saved_state","macro_q","micro_q","sync_depth"],"states":[
        \\{"state":"idle","saved_state":"idle","macro_q":0,"micro_q":0,"sync_depth":0},
        \\{"state":"idle","saved_state":"idle","macro_q":1,"micro_q":0,"sync_depth":0}]}
    ;
    const stats = try state_tcas.tla.replayJsonTrace(SchedulerAct, &ctx, allocator, trace, null);
    try std.testing.expectEqual(@as(usize, 1), stats.actions_replayed);
    try std.testing.expectEqual(@as(usize, 2), stats.states_verified);
    try std.testing.expectEqual(SchedulerState.idle, ctx.project().state);
    try std.testing.expectEqual(SchedulerState.idle, ctx.project().saved_state);
    try std.testing.expectEqual(@as(usize, 1), ctx.project().macro_q);
}

test "state_tcas tla: Init rejects saved_state that is not idle" {
    const allocator = std.testing.allocator;
    var ctx: SchedulerTlaContext = .{ .allocator = allocator };
    const trace =
        \\{"vars":["state","saved_state","macro_q","micro_q","sync_depth"],"states":[
        \\{"action":"init","state":"idle","saved_state":"in_task","macro_q":0,"micro_q":0,"sync_depth":0}]}
    ;
    try std.testing.expectError(
        error.TraceDiverged,
        state_tcas.tla.replayJsonTrace(SchedulerAct, &ctx, allocator, trace, null),
    );
}

fn expectResumeFrom(origin: SchedulerState) !void {
    var ctx: SchedulerTlaContext = .{ .allocator = std.testing.allocator };
    defer ctx.release();
    switch (origin) {
        .idle => {},
        .in_task => {
            try ctx.step(.enqueue_macro, null);
            try ctx.step(.begin_queued_task, null);
        },
        .after_task => {
            try ctx.step(.enqueue_macro, null);
            try ctx.step(.begin_queued_task, null);
            try ctx.step(.enqueue_micro, null);
            try ctx.step(.end_queued_task, null);
        },
        .in_checkpoint => {
            try ctx.step(.enqueue_micro, null);
            try ctx.step(.begin_checkpoint, null);
        },
        .in_sync_wait => unreachable,
    }
    try std.testing.expectEqual(origin, ctx.project().state);
    try std.testing.expectEqual(SchedulerState.idle, ctx.project().saved_state);

    try ctx.step(.begin_sync_wait, null);
    try std.testing.expectEqual(SchedulerState.in_sync_wait, ctx.project().state);
    try std.testing.expectEqual(origin, ctx.project().saved_state);
    try std.testing.expectEqual(@as(usize, 1), ctx.project().sync_depth);

    try ctx.step(.begin_sync_wait, null);
    try std.testing.expectEqual(SchedulerState.in_sync_wait, ctx.project().state);
    try std.testing.expectEqual(origin, ctx.project().saved_state);
    try std.testing.expectEqual(@as(usize, 2), ctx.project().sync_depth);

    try ctx.step(.end_sync_wait, null);
    try std.testing.expectEqual(SchedulerState.in_sync_wait, ctx.project().state);
    try std.testing.expectEqual(origin, ctx.project().saved_state);

    try ctx.step(.end_sync_wait, null);
    try std.testing.expectEqual(origin, ctx.project().state);
    try std.testing.expectEqual(SchedulerState.idle, ctx.project().saved_state);
    try std.testing.expectEqual(@as(usize, 0), ctx.project().sync_depth);
}

test "state_tcas tla: saved_state restores task, checkpoint, and after_task across nested sync wait" {
    try expectResumeFrom(.idle);
    try expectResumeFrom(.in_task);
    try expectResumeFrom(.after_task);
    try expectResumeFrom(.in_checkpoint);
}

test "state_tcas tla: wrong saved_state in a sync-wait trace is rejected" {
    const allocator = std.testing.allocator;
    var ctx: SchedulerTlaContext = .{ .allocator = allocator };
    const trace =
        \\{"vars":["state","saved_state","macro_q","micro_q","sync_depth"],"states":[
        \\{"action":"init","state":"idle","saved_state":"idle","macro_q":0,"micro_q":0,"sync_depth":0},
        \\{"action":"begin_sync_wait","state":"in_sync_wait","saved_state":"in_task","macro_q":0,"micro_q":0,"sync_depth":1}]}
    ;
    try std.testing.expectError(
        error.TraceDiverged,
        state_tcas.tla.replayJsonTrace(SchedulerAct, &ctx, allocator, trace, null),
    );
}
