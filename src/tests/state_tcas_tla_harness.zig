//! TLA+ specification locking and Apalache ITF trace replay harness for JS event loop Scheduler.
//!
//! Verifies model declarations anti-drift, positive execution trace replay,
//! negative counterexample rejection during sync wait, and action coverage.
//!
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

pub const SchedulerTlaContext = struct {
    sched: Scheduler = .{},
    state: SchedulerState = .idle,
    macro_q: usize = 0,
    micro_q: usize = 0,
    sync_wait_guard: ?Scheduler.SyncWait = null,
    task_guard: ?Scheduler.Task = null,
    checkpoint_guard: ?Scheduler.Checkpoint = null,
    allocator: std.mem.Allocator,

    pub fn prepare(self: *@This()) !void {
        self.sched = .{};
        self.state = .idle;
        self.macro_q = 0;
        self.micro_q = 0;
        self.sync_wait_guard = null;
        self.task_guard = null;
        self.checkpoint_guard = null;
    }

    pub fn release(self: *@This()) void {
        if (self.task_guard) |*t| _ = t.end();
        if (self.checkpoint_guard) |*c| c.end();
        if (self.sync_wait_guard) |*s| s.end();
    }

    pub fn project(self: *const @This()) SchedulerState {
        return self.state;
    }

    pub fn enabled(self: *const @This()) []const SchedulerAct {
        return switch (self.state) {
            .idle => if (self.macro_q > 0)
                &.{ .enqueue_macro, .enqueue_micro, .begin_queued_task, .begin_sync_wait }
            else
                &.{ .enqueue_macro, .enqueue_micro, .begin_sync_wait },
            .in_task => &.{ .enqueue_micro, .end_queued_task },
            .after_task => &.{.begin_checkpoint},
            .in_checkpoint => if (self.micro_q > 0)
                &.{.drain_micro}
            else
                &.{.end_checkpoint},
            .in_sync_wait => &.{.end_sync_wait},
        };
    }

    pub fn step(self: *@This(), act: SchedulerAct, pic: ?*state_tcas.Picture) !void {
        const before = @tagName(self.state);
        switch (act) {
            .enqueue_macro => {
                self.macro_q += 1;
            },
            .enqueue_micro => {
                self.micro_q += 1;
            },
            .begin_queued_task => {
                if (self.task_guard != null) return error.TaskAlreadyRunning;
                const task = self.sched.beginQueuedTask() orelse return error.ActionNotEnabled;
                self.task_guard = task;
                self.macro_q -|= 1;
                self.state = .in_task;
            },
            .end_queued_task => {
                if (self.task_guard) |*t| {
                    const is_outer = t.end();
                    self.task_guard = null;
                    self.state = if (is_outer) .after_task else .in_task;
                } else return error.NoTaskToComplete;
            },
            .begin_checkpoint => {
                if (self.checkpoint_guard != null) return error.CheckpointAlreadyRunning;
                const cp = self.sched.beginCheckpoint() orelse return error.ActionNotEnabled;
                self.checkpoint_guard = cp;
                self.state = .in_checkpoint;
            },
            .drain_micro => {
                if (self.state != .in_checkpoint) return error.ActionNotEnabled;
                if (self.micro_q == 0) return error.ActionNotEnabled;
                self.micro_q -= 1;
            },
            .end_checkpoint => {
                if (self.checkpoint_guard) |*c| {
                    c.end();
                    self.checkpoint_guard = null;
                    self.state = .idle;
                } else return error.NoCheckpointToComplete;
            },
            .begin_sync_wait => {
                if (self.sync_wait_guard != null) return error.ActionNotEnabled;
                self.sync_wait_guard = self.sched.beginSyncWait();
                self.state = .in_sync_wait;
            },
            .end_sync_wait => {
                if (self.sync_wait_guard) |*s| {
                    s.end();
                    self.sync_wait_guard = null;
                    self.state = .idle;
                } else return error.NoSyncWaitToComplete;
            },
        }

        if (pic) |p| {
            try p.observe(self.allocator, .{
                .before = before,
                .after = @tagName(self.state),
                .label = @tagName(act),
                .rejected = false,
                .mutated = true,
                .note = @tagName(self.state),
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
    try std.testing.expectEqual(SchedulerState.idle, ctx.state);
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

    _ = try state_tcas.tla.replayJsonTraceWithOptions(
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

    try std.testing.expectEqual(SchedulerState.in_sync_wait, ctx.state);
}

test "state_tcas tla: verify action coverage across replay traces" {
    const covered_actions = [_]SchedulerAct{
        .enqueue_macro,
        .enqueue_micro,
        .begin_queued_task,
        .end_queued_task,
        .begin_checkpoint,
        .drain_micro,
        .end_checkpoint,
        .begin_sync_wait,
        .end_sync_wait,
    };

    try state_tcas.tla.verifyCoverage(SchedulerAct, &covered_actions);

    // Omission of actions detected by verifyCoverage
    try std.testing.expectError(
        error.ActUncovered,
        state_tcas.tla.verifyCoverage(SchedulerAct, covered_actions[0..7]),
    );
}
