//! Drives the real `js_event_loop.Scheduler` under `state_tcas` explore.
//!
//! Unlike `state_tcas_event_loop_harness.zig` (toy EventLoopModel duck), this
//! file mutates a live Scheduler through begin/end APIs. Toy macro/micro
//! counters sit beside it so Safety can express the host obligation "drain
//! the checkpoint before the next queued task"; the Scheduler itself does not
//! own those queues.
//!
//! ## Layering vs live Driver/Engine
//! - **This file**: Scheduler + host toy queues are **value-copyable** →
//!   `dfs` / `dfsKeyed` / **`explore.bfs`** are all honest here (`Snap` clone).
//! - **Live Driver / ActiveEngine**: opaque `zev.Loop` → act-log + DFS only
//!   (`*_driver_harness.zig`, `*_engine_harness.zig`). Do not claim those as BFS.
//! - L2 Ungated / Loop direct dispatch: gap file only; never explore acts here.
//!
//! Run: `zig build test-state-tcas`

const std = @import("std");
const state_tcas = @import("state_tcas");
const explore_adapters = @import("state_tcas_explore_adapters.zig");
const js_event_loop = @import("js_event_loop");

const Scheduler = js_event_loop.Scheduler;

const Act = enum {
    enqueue_macro,
    enqueue_micro,
    begin_sync_wait,
    end_sync_wait,
    begin_queued_task,
    end_queued_task,
    begin_checkpoint,
    end_checkpoint,
    drain_micro,
};

/// Snapshot of Scheduler + host toy queues for void undo / bfs clone keys.
const Snap = struct {
    sync_wait_depth: usize,
    execution_depth: usize,
    checkpoint_active: bool,
    backend_drain_permit: bool,
    backend_drain_running: bool,
    implicit_checkpoint: bool,
    turn_active: bool,
    task_admission_permit: bool,
    next_task_source: Scheduler.TaskSource,
    debugger_control_active: bool,
    macro_q: usize,
    micro_q: usize,
    enqueues_left: usize,
    tasks_started: usize,
    micros_drained: usize,
};

const Host = struct {
    sched: Scheduler = .{},
    macro_q: usize = 0,
    micro_q: usize = 0,
    enqueues_left: usize = 3,
    tasks_started: usize = 0,
    micros_drained: usize = 0,
    /// Set when a step records a queued-task start the Scheduler would reject.
    forced_illegal_task: bool = false,
    stack: [48]Snap = undefined,
    sp: usize = 0,
    acts_buf: [8]Act = undefined,

    fn capture(self: *const @This()) Snap {
        return .{
            .sync_wait_depth = self.sched.sync_wait_depth.load(.acquire),
            .execution_depth = self.sched.execution_depth,
            .checkpoint_active = self.sched.checkpoint_active,
            .backend_drain_permit = self.sched.backend_drain_permit,
            .backend_drain_running = self.sched.backend_drain_running,
            .implicit_checkpoint = self.sched.implicit_checkpoint,
            .turn_active = self.sched.turn_active,
            .task_admission_permit = self.sched.task_admission_permit,
            .next_task_source = self.sched.next_task_source,
            .debugger_control_active = self.sched.debugger_control_active,
            .macro_q = self.macro_q,
            .micro_q = self.micro_q,
            .enqueues_left = self.enqueues_left,
            .tasks_started = self.tasks_started,
            .micros_drained = self.micros_drained,
        };
    }

    fn restore(self: *@This(), s: Snap) void {
        self.sched.sync_wait_depth.store(s.sync_wait_depth, .release);
        self.sched.execution_depth = s.execution_depth;
        self.sched.checkpoint_active = s.checkpoint_active;
        self.sched.backend_drain_permit = s.backend_drain_permit;
        self.sched.backend_drain_running = s.backend_drain_running;
        self.sched.implicit_checkpoint = s.implicit_checkpoint;
        self.sched.turn_active = s.turn_active;
        self.sched.task_admission_permit = s.task_admission_permit;
        self.sched.next_task_source = s.next_task_source;
        self.sched.debugger_control_active = s.debugger_control_active;
        self.macro_q = s.macro_q;
        self.micro_q = s.micro_q;
        self.enqueues_left = s.enqueues_left;
        self.tasks_started = s.tasks_started;
        self.micros_drained = s.micros_drained;
        self.forced_illegal_task = false;
    }

    fn pushSnap(self: *@This()) void {
        self.stack[self.sp] = self.capture();
        self.sp += 1;
    }

    /// Pack Scheduler + queues into a u64 for dfsKeyed / bfs prune.
    pub fn key(self: *const @This()) u64 {
        var k: u64 = 0;
        k |= @as(u64, @intCast(self.sched.sync_wait_depth.load(.acquire) & 0xf));
        k |= @as(u64, @intCast(self.sched.execution_depth & 0xf)) << 4;
        k |= @as(u64, @intFromBool(self.sched.checkpoint_active)) << 8;
        k |= @as(u64, @intCast(self.macro_q & 0xf)) << 9;
        k |= @as(u64, @intCast(self.micro_q & 0xf)) << 13;
        k |= @as(u64, @intCast(self.enqueues_left & 0xf)) << 17;
        k |= @as(u64, @intCast(self.tasks_started & 0xf)) << 21;
        k |= @as(u64, @intCast(self.micros_drained & 0xf)) << 25;
        k |= @as(u64, @intFromBool(self.sched.turn_active)) << 29;
        return k;
    }

    pub fn enabled(self: *@This()) []const Act {
        // Sync-wait begin/end is covered by direct API + Safety tests; offering it
        // here would let plain DFS oscillate forever (begin↔end, same key).
        var n: usize = 0;
        if (self.enqueues_left > 0) {
            self.acts_buf[n] = .enqueue_macro;
            n += 1;
            // Micros are typically enqueued from task/checkpoint bodies.
            if (self.sched.execution_depth > 0 or self.sched.checkpoint_active) {
                self.acts_buf[n] = .enqueue_micro;
                n += 1;
            }
        }
        // Host obligation on top of Scheduler: finish pending micros first.
        if (self.macro_q > 0 and self.sched.allowsQueuedWork() and self.micro_q == 0) {
            self.acts_buf[n] = .begin_queued_task;
            n += 1;
        }
        if (self.sched.execution_depth > 0 and !self.sched.checkpoint_active) {
            self.acts_buf[n] = .end_queued_task;
            n += 1;
        }
        // Only open a checkpoint when there is something to drain (avoids empty begin↔end oscillation under unkeyed DFS).
        if (self.micro_q > 0 and
            self.sched.sync_wait_depth.load(.acquire) == 0 and
            self.sched.execution_depth == 0 and
            !self.sched.checkpoint_active)
        {
            self.acts_buf[n] = .begin_checkpoint;
            n += 1;
        }
        if (self.sched.checkpoint_active) {
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

    pub fn step(self: *@This(), act: Act) !void {
        self.pushSnap();
        switch (act) {
            .enqueue_macro => {
                self.macro_q += 1;
                self.enqueues_left -= 1;
            },
            .enqueue_micro => {
                self.micro_q += 1;
                self.enqueues_left -= 1;
            },
            .begin_sync_wait => {
                // Leave SyncWait open across explore steps (discard without end).
                _ = self.sched.beginSyncWait();
            },
            .end_sync_wait => {
                var wait: Scheduler.SyncWait = .{ .scheduler = &self.sched, .active = true };
                wait.end();
            },
            .begin_queued_task => {
                if (self.macro_q == 0) return error.EmptyMacroQueue;
                // Real Scheduler admission.
                const task = self.sched.beginQueuedTask() orelse return error.TaskRejected;
                // Keep task open: do not call task.end().
                _ = task;
                self.macro_q -= 1;
                self.tasks_started += 1;
                // Odd tasks auto-queue one micro (task-body side effect).
                if (self.enqueues_left > 0 and self.tasks_started % 2 == 1) {
                    self.micro_q += 1;
                    self.enqueues_left -= 1;
                }
            },
            .end_queued_task => {
                if (self.sched.execution_depth == 0) return error.NoOpenTask;
                var task: Scheduler.Task = .{ .scheduler = &self.sched, .active = true };
                _ = task.end();
            },
            .begin_checkpoint => {
                _ = self.sched.beginCheckpoint() orelse return error.CheckpointRejected;
            },
            .end_checkpoint => {
                if (!self.sched.checkpoint_active) return error.NoCheckpoint;
                var cp: Scheduler.Checkpoint = .{ .scheduler = &self.sched, .active = true };
                cp.end();
            },
            .drain_micro => {
                if (!self.sched.checkpoint_active) return error.NotInCheckpoint;
                if (self.micro_q == 0) return error.EmptyMicroQueue;
                self.micro_q -= 1;
                self.micros_drained += 1;
            },
        }
    }

    pub fn undo(self: *@This(), act: Act) void {
        _ = act;
        self.sp -= 1;
        self.restore(self.stack[self.sp]);
    }

    pub fn clone(self: *const @This()) !@This() {
        var c = self.*;
        // Fresh undo stack for bfs nodes; Scheduler value-copied (atomic load baked in).
        c.sp = 0;
        c.forced_illegal_task = false;
        c.sched = .{
            .sync_wait_depth = .init(self.sched.sync_wait_depth.load(.acquire)),
            .execution_depth = self.sched.execution_depth,
            .checkpoint_active = self.sched.checkpoint_active,
            .backend_drain_permit = self.sched.backend_drain_permit,
            .backend_drain_running = self.sched.backend_drain_running,
            .implicit_checkpoint = self.sched.implicit_checkpoint,
            .turn_active = self.sched.turn_active,
            .task_admission_permit = self.sched.task_admission_permit,
            .next_task_source = self.sched.next_task_source,
            .debugger_control_active = self.sched.debugger_control_active,
        };
        return c;
    }

    pub fn destroy(self: *@This()) void {
        _ = self;
    }

    /// Diff Safety: a newly started queued task is illegal if the prior Scheduler state disallowed queued work, or prior micros were still pending, or the step forced a start after beginQueuedTask returned null.
    pub fn safetyOk(ctx: *@This()) !void {
        if (ctx.forced_illegal_task) return error.SafetyViolation;
        if (ctx.sp == 0) return;
        const prev = ctx.stack[ctx.sp - 1];
        if (ctx.tasks_started == prev.tasks_started + 1) {
            const prev_allows = prev.sync_wait_depth == 0 and prev.execution_depth == 0 and !prev.checkpoint_active;
            if (!prev_allows or prev.micro_q > 0) return error.SafetyViolation;
        }
    }

    pub fn isEnabled(ctx: *@This()) bool {
        return ctx.tasks_started > 0 or ctx.macro_q + ctx.micro_q > 0 or
            ctx.sched.sync_wait_depth.load(.acquire) > 0 or
            ctx.sched.execution_depth > 0 or
            ctx.sched.checkpoint_active;
    }

    pub fn isGoal(ctx: *@This()) bool {
        return ctx.tasks_started > 0 and
            ctx.macro_q == 0 and
            ctx.micro_q == 0 and
            ctx.sched.allowsQueuedWork();
    }

    /// Buggy host: ignore Scheduler rejection and record a task start anyway.
    fn forceIllegalQueuedTask(self: *@This()) void {
        self.pushSnap();
        std.debug.assert(self.sched.beginQueuedTask() == null);
        self.forced_illegal_task = true;
        self.tasks_started += 1;
        if (self.macro_q > 0) self.macro_q -= 1;
    }
};

test "state_tcas js_event_loop: Scheduler rejects queued task during sync wait" {
    var sched: Scheduler = .{};
    var wait = sched.beginSyncWait();
    defer wait.end();
    try std.testing.expect(sched.isSynchronouslyWaiting());
    try std.testing.expect(sched.beginQueuedTask() == null);
    try std.testing.expect(sched.beginCheckpoint() == null);
}

test "state_tcas js_event_loop: DFS explores real Scheduler with Safety+Liveness" {
    var host: Host = .{};
    host.macro_q = 1;
    host.enqueues_left = 2;

    var saf = state_tcas.monitor.Safety(*Host){
        .ctx = &host,
        .checkFn = Host.safetyOk,
    };
    var liv = state_tcas.monitor.Liveness(*Host){
        .ctx = &host,
        .enabledFn = Host.isEnabled,
        .goalFn = Host.isGoal,
    };

    var legal: explore_adapters.Monitored(Act, Host) = .{ .inner = &host, .saf = &saf, .liv = &liv };
    var stats: state_tcas.explore.Stats = .{};
    try state_tcas.explore.dfs(Act, &legal, 2048, &stats);
    try liv.finish();
    try std.testing.expect(stats.visits > 1);
    try std.testing.expect(stats.expansions > 0);
    // Undo restored seed.
    try std.testing.expectEqual(@as(usize, 1), host.macro_q);
    try std.testing.expectEqual(@as(usize, 0), host.micro_q);
    try std.testing.expect(host.sched.allowsQueuedWork());
}

test "state_tcas js_event_loop: dfsKeyed prunes on Scheduler+queue key" {
    var host: Host = .{};
    host.macro_q = 1;
    host.enqueues_left = 2;

    var keyed: explore_adapters.KeyedOnly(Act, Host) = .{ .inner = &host };
    var stats: state_tcas.explore.Stats = .{};
    var visited = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer visited.deinit();
    try state_tcas.explore.dfsKeyed(Act, u64, &keyed, 2048, &stats, &visited);
    try std.testing.expect(stats.visits >= 2);
    // With keyed prune we should finish under budget and restore seed.
    try std.testing.expectEqual(@as(usize, 1), host.macro_q);
    try std.testing.expect(host.sched.allowsQueuedWork());
}

test "state_tcas js_event_loop: bfs clones Scheduler state by value" {
    const allocator = std.testing.allocator;
    var root: Host = .{};
    root.macro_q = 1;
    root.enqueues_left = 2;

    var stats: state_tcas.explore.Stats = .{};
    try state_tcas.explore.bfs(Act, u64, Host, root, allocator, 4096, &stats);
    try std.testing.expect(stats.visits >= 2);
    try std.testing.expect(stats.expansions > 0);
}

test "state_tcas js_event_loop: Safety fires when host ignores sync-wait rejection" {
    var host: Host = .{};
    host.macro_q = 1;
    _ = host.sched.beginSyncWait();
    try std.testing.expect(host.sched.beginQueuedTask() == null);

    host.forceIllegalQueuedTask();
    try std.testing.expectError(error.SafetyViolation, Host.safetyOk(&host));

    // Legal path after ending sync wait still uses the real API.
    host.undo(.begin_queued_task);
    var wait: Scheduler.SyncWait = .{ .scheduler = &host.sched, .active = true };
    wait.end();
    try host.step(.begin_queued_task);
    try Host.safetyOk(&host);
}

test "state_tcas js_event_loop: outer task then checkpoint matches Scheduler contract" {
    var host: Host = .{};
    host.macro_q = 1;
    host.enqueues_left = 1;

    try host.step(.begin_queued_task);
    try std.testing.expect(host.sched.beginQueuedTask() == null);
    try std.testing.expect(host.sched.beginCheckpoint() == null);
    try host.step(.end_queued_task);
    try host.step(.begin_checkpoint);
    try std.testing.expect(host.sched.beginQueuedTask() == null);
    // Drain auto-queued micro from odd task, then end checkpoint.
    if (host.micro_q > 0) try host.step(.drain_micro);
    try host.step(.end_checkpoint);
    try std.testing.expect(host.sched.allowsQueuedWork());
    try std.testing.expect(Host.isGoal(&host));
}

test "state_tcas js_event_loop: publish Scheduler task-checkpoint picture lock" {
    // Fixed story: outer queued task → checkpoint drain (Observation → Mermaid).
    const StoryAct = enum {
        begin_queued_task,
        end_queued_task,
        begin_checkpoint,
        drain_micro,
        end_checkpoint,
    };
    const Phase = enum { idle, in_task, after_task, in_checkpoint, drained, done };
    const Ctx = struct {
        host: Host = .{},
        phase: Phase = .idle,
        allocator: std.mem.Allocator,

        fn phaseName(self: *const @This()) []const u8 {
            return switch (self.phase) {
                .idle => "idle",
                .in_task => "in_task",
                .after_task => "after_task",
                .in_checkpoint => "in_checkpoint",
                .drained => "drained",
                .done => "done",
            };
        }

        pub fn prepare(self: *@This()) !void {
            self.host = .{};
            self.host.macro_q = 1;
            self.host.enqueues_left = 1;
            self.phase = .idle;
        }

        pub fn step(self: *@This(), act: StoryAct, pic: ?*state_tcas.Picture) !void {
            const before = self.phaseName();
            // Map story acts onto the live Host/Scheduler duck.
            const host_act: Act = switch (act) {
                .begin_queued_task => .begin_queued_task,
                .end_queued_task => .end_queued_task,
                .begin_checkpoint => .begin_checkpoint,
                .drain_micro => .drain_micro,
                .end_checkpoint => .end_checkpoint,
            };
            try self.host.step(host_act);
            self.phase = switch (act) {
                .begin_queued_task => .in_task,
                .end_queued_task => .after_task,
                .begin_checkpoint => .in_checkpoint,
                .drain_micro => .drained,
                .end_checkpoint => .done,
            };
            if (pic) |p| {
                try p.observe(self.allocator, .{
                    .before = before,
                    .after = self.phaseName(),
                    .label = @tagName(act),
                    .rejected = false,
                    .mutated = true,
                    .note = self.phaseName(),
                    .from = "Host",
                    .to = "Scheduler",
                });
            }
        }

        pub fn finish(self: *@This(), _: []const StoryAct) !void {
            try std.testing.expect(self.phase == .done);
            try std.testing.expect(Host.isGoal(&self.host));
        }

        pub fn release(_: *@This()) void {}
    };

    const allocator = std.testing.allocator;
    var ctx: Ctx = .{ .allocator = allocator };
    const story = [_]StoryAct{
        .begin_queued_task,
        .end_queued_task,
        .begin_checkpoint,
        .drain_micro,
        .end_checkpoint,
    };
    var pic: state_tcas.Picture = .{};
    defer pic.deinit(allocator);
    try state_tcas.exhaust.play(StoryAct, &ctx, story[0..], &pic);
    const text = try pic.render(
        allocator,
        "# Scheduler task then checkpoint (state_tcas Observation)\n\n",
        "Host",
        "Scheduler",
    );
    defer allocator.free(text);
    try explore_adapters.lockNormalized(
        std.testing.io,
        allocator,
        "docs/state-tcas-scheduler-task-checkpoint.md",
        text,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "sequenceDiagram") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "begin_queued_task") != null);
}

// - Live Driver + zev timers: `state_tcas_js_event_loop_driver_harness.zig` (act-log DFS).
// - L2 escape probes: `state_tcas_js_event_loop_driver_gap.zig` (not explore).
