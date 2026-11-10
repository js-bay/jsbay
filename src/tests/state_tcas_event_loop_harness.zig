//! Toy EventLoopModel duck for state_tcas explore (NOT the real js_event_loop).
//!
//! Contract (from src/tests/browser_event_loop_tests.zig / microtask_order_tests.zig):
//! - At most one queued JS task starts per turn.
//! - Its full microtask checkpoint drains before another queued task may start.
//! - Microtasks enqueued during a task (or during the checkpoint) run in that checkpoint; a timer scheduled inside a callback is a later macrotask.
//!
//! This does NOT drive `libs/js_event_loop` or the JS engine (vendors / ActiveEngine). For the real Scheduler under explore, see `state_tcas_js_event_loop_harness.zig`. Safety catches illegal task starts; Liveness requires that once work was offered, a drained-idle goal was observed during the run.
//!
//! Run: `zig build test-state-tcas`

const std = @import("std");
const state_tcas = @import("state_tcas");

const Act = enum {
    enqueue_macro,
    enqueue_micro,
    start_task,
    drain_micro,
};

const EventLoopModel = struct {
    macro_q: usize = 0,
    micro_q: usize = 0,
    in_checkpoint: bool = false,
    tasks_started: usize = 0,
    micros_drained: usize = 0,
    seq_buf: [32]u8 = undefined,
    seq_len: usize = 0,
    stack: [32]Snapshot = undefined,
    sp: usize = 0,
    enqueues_left: usize = 4,

    const Snapshot = struct {
        macro_q: usize,
        micro_q: usize,
        in_checkpoint: bool,
        tasks_started: usize,
        micros_drained: usize,
        seq_len: usize,
        enqueues_left: usize,
    };

    fn pushSeq(self: *@This(), c: u8) void {
        if (self.seq_len < self.seq_buf.len) {
            self.seq_buf[self.seq_len] = c;
            self.seq_len += 1;
        }
    }

    /// Fill `out` with the raw enabling set; returns count.
    /// Explore frames copy `enabled()` (`max_enabled`), so a shared acts_buf is safe.
    pub fn fillEnabledRaw(self: *const @This(), out: *[4]Act) usize {
        var n: usize = 0;
        if (self.enqueues_left > 0) {
            out[n] = .enqueue_macro;
            n += 1;
            out[n] = .enqueue_micro;
            n += 1;
        }
        if (self.macro_q > 0) {
            out[n] = .start_task;
            n += 1;
        }
        if (self.micro_q > 0) {
            out[n] = .drain_micro;
            n += 1;
        }
        return n;
    }

    pub fn step(self: *@This(), act: Act) !void {
        self.stack[self.sp] = .{
            .macro_q = self.macro_q,
            .micro_q = self.micro_q,
            .in_checkpoint = self.in_checkpoint,
            .tasks_started = self.tasks_started,
            .micros_drained = self.micros_drained,
            .seq_len = self.seq_len,
            .enqueues_left = self.enqueues_left,
        };
        self.sp += 1;

        switch (act) {
            .enqueue_macro => {
                self.macro_q += 1;
                self.enqueues_left -= 1;
            },
            .enqueue_micro => {
                self.micro_q += 1;
                self.enqueues_left -= 1;
            },
            .start_task => {
                if (self.macro_q == 0) return error.EmptyMacroQueue;
                self.macro_q -= 1;
                self.tasks_started += 1;
                self.in_checkpoint = true;
                self.pushSeq('T');
                // Odd-numbered tasks auto-queue one micro (task body side effect).
                if (self.enqueues_left > 0 and self.tasks_started % 2 == 1) {
                    self.micro_q += 1;
                    self.enqueues_left -= 1;
                }
                if (self.micro_q == 0) self.in_checkpoint = false;
            },
            .drain_micro => {
                if (self.micro_q == 0) return error.EmptyMicroQueue;
                self.micro_q -= 1;
                self.micros_drained += 1;
                self.pushSeq('m');
                if (self.micro_q == 0) self.in_checkpoint = false;
            },
        }
    }

    pub fn undo(self: *@This(), act: Act) void {
        _ = act;
        self.sp -= 1;
        const s = self.stack[self.sp];
        self.macro_q = s.macro_q;
        self.micro_q = s.micro_q;
        self.in_checkpoint = s.in_checkpoint;
        self.tasks_started = s.tasks_started;
        self.micros_drained = s.micros_drained;
        self.seq_len = s.seq_len;
        self.enqueues_left = s.enqueues_left;
    }

    /// jsbay: never start a macrotask while microtasks remain from prior work.
    pub fn safetyOk(ctx: *@This()) !void {
        if (ctx.sp == 0) return;
        const prev = ctx.stack[ctx.sp - 1];
        // Only when this step newly appended 'T' (enqueue_* leaves seq unchanged).
        if (ctx.seq_len == prev.seq_len + 1 and ctx.seq_buf[ctx.seq_len - 1] == 'T' and prev.micro_q > 0) {
            return error.SafetyViolation;
        }
    }

    pub fn isEnabled(ctx: *@This()) bool {
        return ctx.tasks_started > 0 or ctx.macro_q + ctx.micro_q > 0;
    }

    pub fn isGoal(ctx: *@This()) bool {
        return ctx.tasks_started > 0 and ctx.macro_q == 0 and ctx.micro_q == 0 and !ctx.in_checkpoint;
    }
};

test "state_tcas event-loop: DFS explores task/microtask interleavings with Safety" {
    var model: EventLoopModel = .{};
    model.macro_q = 1;
    model.enqueues_left = 3;

    var saf = state_tcas.monitor.Safety(*EventLoopModel){
        .ctx = &model,
        .checkFn = EventLoopModel.safetyOk,
    };
    var liv = state_tcas.monitor.Liveness(*EventLoopModel){
        .ctx = &model,
        .enabledFn = EventLoopModel.isEnabled,
        .goalFn = EventLoopModel.isGoal,
    };

    // Shared acts_buf is safe: explore.dfs copies enabled() per frame (max_enabled).
    const Legal = struct {
        inner: *EventLoopModel,
        saf: *state_tcas.monitor.Safety(*EventLoopModel),
        liv: *state_tcas.monitor.Liveness(*EventLoopModel),
        acts_buf: [4]Act = undefined,

        pub fn enabled(self: *@This()) []const Act {
            var raw_buf: [4]Act = undefined;
            const raw_n = self.inner.fillEnabledRaw(&raw_buf);
            var n: usize = 0;
            var i: usize = 0;
            while (i < raw_n) : (i += 1) {
                const a = raw_buf[i];
                if (a == .start_task and self.inner.micro_q > 0) continue;
                self.acts_buf[n] = a;
                n += 1;
            }
            return self.acts_buf[0..n];
        }
        pub fn step(self: *@This(), act: Act) !void {
            try self.inner.step(act);
            try self.saf.observe();
            self.liv.note();
        }
        pub fn undo(self: *@This(), act: Act) void {
            self.inner.undo(act);
        }
    };

    var legal: Legal = .{ .inner = &model, .saf = &saf, .liv = &liv };
    var stats: state_tcas.explore.Stats = .{};
    try state_tcas.explore.dfs(Act, &legal, 512, &stats);
    try liv.finish();
    try std.testing.expect(stats.visits > 1);
    try std.testing.expect(stats.expansions > 0);
    // Undo restored seed.
    try std.testing.expectEqual(@as(usize, 1), model.macro_q);
    try std.testing.expectEqual(@as(usize, 0), model.micro_q);
}

test "state_tcas event-loop: Safety fires when start_task races pending micros" {
    var model: EventLoopModel = .{};
    model.macro_q = 1;
    model.micro_q = 1;
    model.enqueues_left = 0;

    try model.step(.start_task);
    try std.testing.expectError(error.SafetyViolation, EventLoopModel.safetyOk(&model));
    model.undo(.start_task);

    try model.step(.drain_micro);
    try EventLoopModel.safetyOk(&model);
    try model.step(.start_task);
    try EventLoopModel.safetyOk(&model);
}

test "state_tcas event-loop: calendar timers + micro checkpoint order (AB)" {
    // Twin of microtask_order_tests: Promise/queueMicrotask before setTimeout(0).
    const allocator = std.testing.allocator;
    var cal = state_tcas.calendar.Calendar.init(allocator, 0);
    defer cal.deinit();

    var micro_q: std.ArrayList(u8) = .empty;
    defer micro_q.deinit(allocator);
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(allocator);

    try micro_q.append(allocator, 'A');
    _ = try cal.schedule(0, 1, 'B');

    while (micro_q.items.len > 0) {
        try seq.append(allocator, micro_q.orderedRemove(0));
    }
    try cal.advanceTo(0);
    const Sink = struct {
        seq: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        fn on(self: *@This(), tag: u32, payload: u64) !void {
            _ = tag;
            try self.seq.append(self.allocator, @intCast(payload));
        }
    };
    var sink: Sink = .{ .seq = &seq, .allocator = allocator };
    _ = try cal.fireDue(&sink, Sink.on);
    try std.testing.expectEqualStrings("AB", seq.items);
}

test "state_tcas event-loop: exhaust.play nested-timer story; orders+SkipOrder for illegal perms" {
    // Abstract of timer_order_tests "a1,m1,a2": sibling macrotask waits for the
    // first task's microcheckpoint. Constrained stories use exhaust.play;
    // orders + SkipOrder walks all unique perms without failing the run.
    const Act2 = enum { task_a1, micro_m1, task_a2 };
    const Phase2 = enum { start, after_a1, after_m1, done };
    const Ctx = struct {
        phase: Phase2 = .start,
        plays_ok: usize = 0,
        skipped: usize = 0,
        pub fn prepare(self: *@This()) !void {
            self.phase = .start;
        }
        pub fn release(_: *@This()) void {}
        pub fn step(self: *@This(), act: Act2, pic: ?*state_tcas.Picture) !void {
            _ = pic;
            switch (self.phase) {
                .start => {
                    if (act != .task_a1) return error.SkipOrder;
                    self.phase = .after_a1;
                },
                .after_a1 => {
                    if (act != .micro_m1) return error.SkipOrder;
                    self.phase = .after_m1;
                },
                .after_m1 => {
                    if (act != .task_a2) return error.SkipOrder;
                    self.phase = .done;
                },
                .done => return error.SkipOrder,
            }
        }
        pub fn finish(self: *@This(), _: []const Act2) !void {
            if (self.phase != .done) return error.SkipOrder;
            self.plays_ok += 1;
        }
    };

    var ctx_play: Ctx = .{};
    const story = [_]Act2{ .task_a1, .micro_m1, .task_a2 };
    try state_tcas.exhaust.play(Act2, &ctx_play, story[0..], null);
    try std.testing.expectEqual(Phase2.done, ctx_play.phase);
    try std.testing.expectEqual(@as(usize, 1), ctx_play.plays_ok);

    var ctx_orders: Ctx = .{};
    const seed = [_]Act2{ .task_a1, .micro_m1, .task_a2 };
    // 3! = 6 unique perms; only one legal. SkipOrder keeps the run green.
    const visits = try state_tcas.exhaust.orders(Act2, 3, seed, 64, &ctx_orders, null);
    try std.testing.expectEqual(@as(usize, 6), visits);
    try std.testing.expectEqual(@as(usize, 1), ctx_orders.plays_ok);
}
