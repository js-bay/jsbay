//! Drives a real `js_event_loop.Driver` (+ Timer / Notifier) under `state_tcas`.
//!
//! ## Process (live Driver — no fake BFS)
//! 1. **Explore shape**: act-log rebuild + `dfs` / `dfsKeyed` only. `undo` = teardown +
//!    boot + replay `log[0..len]`. Never value-copy / half-clone `Driver`/`zev.Loop`.
//! 2. **L0/L1/L2 discipline**: explore/exhaust *dispatch* acts = L0 (`runOnce`/`advance`)
//!    only; pure clock acts may use L1 `setNow`; L2 escape hatch is gap-only
//!    (`state_tcas_js_event_loop_driver_gap.zig`). `ExploreAct` physically has no L2.
//! 3. **Rebuild invariant**: any prefix of the act-log, after boot+apply, matches the
//!    observations seen when exploration reached that prefix.
//! 4. **Key fields** (dfsKeyed): early/late armed+cancelled+fired, suspended, now_target,
//!    dual_timers / allow_suspend flags as encoded by `ExploreWorld.key`.
//! 5. **Out of explore (intentional)**: SyncWait begin↔end pairs, Notifier notify,
//!    and beginExecution stop-latch stay on **direct** contract tests above (and
//!    gap Ungated probes). Do not add oscillating begin/end to `ExploreAct`
//!    without a keyed depth-1 gate — cookbook forbids sync-wait oscillation in DFS.
//!
//! Checklist (direct, not DFS explore):
//! - sync_wait gates `runOnce`/`advance` (no native dispatch)
//! - Notifier delivers via `runOnce`; suspend blocks L0 turn path
//! - cancel-after-due; same-deadline FIFO; stop latch + beginExecution
//! - gap: `dispatchEventsUngated` still bypasses sync_wait / suspend / Notifier gate
//!
//! Scheduler-only `explore.bfs` lives in `state_tcas_js_event_loop_harness.zig` (value
//! Snap). Do not read "js_event_loop BFS" as covering this live Driver file.
//!
//! Run: `zig build test-state-tcas`

const std = @import("std");
const state_tcas = @import("state_tcas");
const explore_adapters = @import("state_tcas_explore_adapters.zig");
const js_event_loop = @import("js_event_loop");

const Driver = js_event_loop.Driver;
const Timer = js_event_loop.Timer;
const Notifier = js_event_loop.Notifier;
const Scheduler = js_event_loop.Scheduler;

const early_deadline: u64 = 10;
const late_deadline: u64 = 20;

fn emptyHooks(ctx: ?*anyopaque) Driver.Hooks {
    const H = struct {
        fn runTask(_: ?*anyopaque, _: Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
    };
    return .{
        .context = ctx,
        .run_one_task = H.runTask,
        .checkpoint = H.checkpoint,
        .next_task_deadline = H.nextDeadline,
    };
}

// ─── Adversarial / contract probes against the live Driver ───────────────────

test "state_tcas Driver: setNow ClockRewind; clampNow absorbs; same-tick OK" {
    // setNow aligns with Calendar (strict); clampNow keeps host-tick @max.
    const driver = try Driver.create(std.testing.allocator);
    defer driver.destroy();
    try Driver.testing.setNow(driver, 100);
    try std.testing.expectEqual(@as(u64, 100), driver.now());
    try std.testing.expectError(error.ClockRewind, Driver.testing.setNow(driver, 50));
    try std.testing.expectEqual(@as(u64, 100), driver.now());
    try Driver.testing.setNow(driver, 100); // same tick
    try std.testing.expectEqual(@as(u64, 100), driver.now());

    Driver.testing.clampNow(driver, 50);
    try std.testing.expectEqual(@as(u64, 100), driver.now());
    Driver.testing.clampNow(driver, 120);
    try std.testing.expectEqual(@as(u64, 120), driver.now());

    // Fresh driver: first install of 0 is not a rewind.
    const d2 = try Driver.create(std.testing.allocator);
    defer d2.destroy();
    try Driver.testing.setNow(d2, 0);
    try std.testing.expectEqual(@as(u64, 0), d2.now());
}

test "state_tcas Driver: runOnce/advance honor sync_wait (no native dispatch)" {
    const Probe = struct {
        fired: usize = 0,
        fn timer(context: ?*anyopaque, _: *Timer) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).fired += 1;
        }
    };
    var probe = Probe{};
    const driver = try Driver.create(std.testing.allocator);
    defer driver.destroy();
    try Driver.testing.setNow(driver, 0);
    var timer: Timer = undefined;
    timer.init(driver, &probe, Probe.timer);
    defer timer.close();
    try timer.startAt(early_deadline);

    var wait = driver.scheduler.beginSyncWait();
    defer wait.end();
    _ = Driver.testing.advance(driver, emptyHooks(&probe), early_deadline + 5);
    try std.testing.expectEqual(@as(usize, 0), probe.fired);
    try std.testing.expect(timer.isActive());
}

test "state_tcas Driver: cancel after due before runOnce never delivers" {
    const Probe = struct {
        fired: usize = 0,
        fn timer(context: ?*anyopaque, _: *Timer) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).fired += 1;
        }
    };
    var probe = Probe{};
    const driver = try Driver.create(std.testing.allocator);
    defer driver.destroy();
    try Driver.testing.setNow(driver, 0);
    var timer: Timer = undefined;
    timer.init(driver, &probe, Probe.timer);
    defer timer.close();
    try timer.startAt(early_deadline);
    try Driver.testing.setNow(driver, early_deadline + 1);
    try std.testing.expect(timer.isActive());
    try std.testing.expect(timer.cancel());
    _ = Driver.testing.runOnce(driver, emptyHooks(&probe));
    try std.testing.expectEqual(@as(usize, 0), probe.fired);
    try std.testing.expect(!timer.isActive());
}

test "state_tcas Driver: same-deadline timers fire FIFO by start order" {
    const Probe = struct {
        order: [2]u8 = .{ 0, 0 },
        n: usize = 0,
        fn onA(context: ?*anyopaque, _: *Timer) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.order[self.n] = 1;
            self.n += 1;
        }
        fn onB(context: ?*anyopaque, _: *Timer) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.order[self.n] = 2;
            self.n += 1;
        }
    };
    var probe = Probe{};
    const driver = try Driver.create(std.testing.allocator);
    defer driver.destroy();
    try Driver.testing.setNow(driver, 0);
    var a: Timer = undefined;
    var b: Timer = undefined;
    a.init(driver, &probe, Probe.onA);
    defer a.close();
    b.init(driver, &probe, Probe.onB);
    defer b.close();
    try a.startAt(early_deadline);
    try b.startAt(early_deadline);
    _ = Driver.testing.advance(driver, emptyHooks(&probe), early_deadline);
    try std.testing.expectEqual(@as(usize, 2), probe.n);
    try std.testing.expectEqual(@as(u8, 1), probe.order[0]);
    try std.testing.expectEqual(@as(u8, 2), probe.order[1]);
}

test "state_tcas Driver: Notifier delivers via runOnce; suspend blocks turn path" {
    const Probe = struct {
        notes: usize = 0,
        fn onNote(context: ?*anyopaque, _: *Notifier) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).notes += 1;
        }
    };
    var probe = Probe{};
    const driver = try Driver.create(std.testing.allocator);
    defer driver.destroy();
    try Driver.testing.setNow(driver, 0);
    var n: Notifier = undefined;
    n.init(driver, &probe, Probe.onNote);
    defer n.close();
    try std.testing.expect(n.notify());
    _ = Driver.testing.runOnce(driver, emptyHooks(&probe));
    try std.testing.expectEqual(@as(usize, 1), probe.notes);

    try std.testing.expect(n.notify());
    driver.suspendScheduling();
    defer driver.resumeScheduling();
    _ = Driver.testing.runOnce(driver, emptyHooks(&probe));
    // L0 turn path stays gated while suspended (L2 escape covered in *_gap.zig).
    try std.testing.expectEqual(@as(usize, 1), probe.notes);
}

test "state_tcas Driver: stop then idle runOnce ignores prior stop latch" {
    // Mirrors driver_tests: requestStop while idle is ignored by shouldStop
    // (mode == .idle). beginExecution makes runTurn refuse the turn so
    // finish_turn is skipped; after end(), a later idle runOnce still runs.
    const Probe = struct {
        finished: usize = 0,
        fn finish(context: ?*anyopaque) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).finished += 1;
        }
        fn runTask(_: ?*anyopaque, _: Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
    };
    var probe = Probe{};
    const driver = try Driver.create(std.testing.allocator);
    defer driver.destroy();
    driver.requestStop();
    var execution = driver.scheduler.beginExecution();
    _ = Driver.testing.runOnce(driver, .{
        .context = &probe,
        .run_one_task = Probe.runTask,
        .checkpoint = Probe.checkpoint,
        .finish_turn = Probe.finish,
        .next_task_deadline = Probe.nextDeadline,
    });
    execution.end();
    try std.testing.expectEqual(@as(usize, 0), probe.finished);
    _ = Driver.testing.runOnce(driver, .{
        .context = &probe,
        .run_one_task = Probe.runTask,
        .checkpoint = Probe.checkpoint,
        .finish_turn = Probe.finish,
        .next_task_deadline = Probe.nextDeadline,
    });
    try std.testing.expectEqual(@as(usize, 1), probe.finished);
}

test "state_tcas Driver: Safety rejects cancelled delivery (host contract)" {
    const Box = struct {
        cancelled_delivered: usize = 0,
        fn safetyOk(ctx: *@This()) !void {
            if (ctx.cancelled_delivered > 0) return error.SafetyViolation;
        }
    };
    var box: Box = .{};
    var saf = state_tcas.monitor.Safety(*Box){ .ctx = &box, .checkFn = Box.safetyOk };

    const Probe = struct {
        box: *Box,
        expect_cancelled: bool = false,
        fn timer(context: ?*anyopaque, _: *Timer) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.expect_cancelled) self.box.cancelled_delivered += 1;
        }
    };
    var probe = Probe{ .box = &box };
    const driver = try Driver.create(std.testing.allocator);
    defer driver.destroy();
    try Driver.testing.setNow(driver, 0);
    var timer: Timer = undefined;
    timer.init(driver, &probe, Probe.timer);
    defer timer.close();
    try timer.startAt(early_deadline);
    try std.testing.expect(timer.cancel());
    probe.expect_cancelled = true;
    _ = Driver.testing.advance(driver, emptyHooks(&probe), early_deadline + 1);
    try saf.observe();
    try std.testing.expectEqual(@as(usize, 0), box.cancelled_delivered);
}

test "state_tcas Driver: exhaust.play arm/cancel/advance/fire story" {
    // setNow is strict: each story needs a fresh Driver clock (no rewind-as-reset).
    const Act = enum { arm, cancel, advance_past, run_once };
    const Probe = struct {
        fired: usize = 0,
        fn timer(context: ?*anyopaque, _: *Timer) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).fired += 1;
        }
    };
    var probe = Probe{};

    const Ctx = struct {
        driver: *Driver,
        timer: *Timer,
        probe: *Probe,
        cancelled: bool = false,

        pub fn prepare(self: *@This()) !void {
            self.cancelled = false;
            self.probe.fired = 0;
            try Driver.testing.setNow(self.driver, 0);
        }
        pub fn step(self: *@This(), act: Act, _: ?*state_tcas.picture.Picture) !void {
            switch (act) {
                .arm => try self.timer.startAt(early_deadline),
                .cancel => {
                    try std.testing.expect(self.timer.cancel());
                    self.cancelled = true;
                },
                .advance_past => try Driver.testing.setNow(self.driver, early_deadline + 1),
                .run_once => _ = Driver.testing.runOnce(self.driver, emptyHooks(null)),
            }
        }
        pub fn finish(self: *@This(), _: []const Act) !void {
            if (self.cancelled) try std.testing.expectEqual(@as(usize, 0), self.probe.fired);
        }
        pub fn release(_: *@This()) void {}
    };

    const FirePhase = enum { idle, armed, fired };
    const FireCtx = struct {
        driver: *Driver,
        timer: *Timer,
        probe: *Probe,
        phase: FirePhase = .idle,
        allocator: std.mem.Allocator,

        fn phaseName(self: *const @This()) []const u8 {
            return switch (self.phase) {
                .idle => "idle",
                .armed => "armed",
                .fired => "fired",
            };
        }

        pub fn prepare(self: *@This()) !void {
            self.probe.fired = 0;
            self.phase = .idle;
            try Driver.testing.setNow(self.driver, 0);
        }
        pub fn step(self: *@This(), act: Act, pic: ?*state_tcas.Picture) !void {
            const before = self.phaseName();
            switch (act) {
                .arm => {
                    try self.timer.startAt(early_deadline);
                    self.phase = .armed;
                },
                .cancel => unreachable,
                .advance_past => {},
                .run_once => {
                    _ = Driver.testing.advance(self.driver, emptyHooks(null), early_deadline + 1);
                    if (self.probe.fired > 0) self.phase = .fired;
                },
            }
            if (pic) |p| {
                try p.observe(self.allocator, .{
                    .before = before,
                    .after = self.phaseName(),
                    .label = @tagName(act),
                    .rejected = false,
                    .mutated = !std.mem.eql(u8, before, self.phaseName()),
                    .note = self.phaseName(),
                    .from = "Host",
                    .to = "Driver",
                    .keep_unchanged = true,
                });
            }
        }
        pub fn finish(self: *@This(), _: []const Act) !void {
            try std.testing.expectEqual(@as(usize, 1), self.probe.fired);
            try std.testing.expect(self.phase == .fired);
        }
        pub fn release(_: *@This()) void {}
    };

    // Cancel before due.
    {
        const driver = try Driver.create(std.testing.allocator);
        defer driver.destroy();
        var timer: Timer = undefined;
        timer.init(driver, &probe, Probe.timer);
        defer timer.close();
        var ctx: Ctx = .{ .driver = driver, .timer = &timer, .probe = &probe };
        try state_tcas.exhaust.play(Act, &ctx, &[_]Act{ .arm, .cancel, .advance_past, .run_once }, null);
        try std.testing.expectEqual(@as(usize, 0), probe.fired);
    }

    // Cancel after due, before runOnce.
    {
        const driver = try Driver.create(std.testing.allocator);
        defer driver.destroy();
        var timer: Timer = undefined;
        timer.init(driver, &probe, Probe.timer);
        defer timer.close();
        var ctx: Ctx = .{ .driver = driver, .timer = &timer, .probe = &probe };
        try state_tcas.exhaust.play(Act, &ctx, &[_]Act{ .arm, .advance_past, .cancel, .run_once }, null);
        try std.testing.expectEqual(@as(usize, 0), probe.fired);
    }

    // Fire path (no picture — covered by dedicated lock test below).
    {
        const driver = try Driver.create(std.testing.allocator);
        defer driver.destroy();
        var timer: Timer = undefined;
        timer.init(driver, &probe, Probe.timer);
        defer timer.close();
        var fire_ctx: FireCtx = .{
            .driver = driver,
            .timer = &timer,
            .probe = &probe,
            .allocator = std.testing.allocator,
        };
        try state_tcas.exhaust.play(Act, &fire_ctx, &[_]Act{ .arm, .run_once }, null);
    }
}

test "state_tcas Driver: publish timer-fire picture lock" {
    // Sequence + state diagram from the arm→advance fire story (Observation → Mermaid).
    const Act = enum { arm, cancel, advance_past, run_once };
    const Probe = struct {
        fired: usize = 0,
        fn timer(context: ?*anyopaque, _: *Timer) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).fired += 1;
        }
    };
    var probe = Probe{};
    const FirePhase = enum { idle, armed, fired };
    const FireCtx = struct {
        driver: *Driver,
        timer: *Timer,
        probe: *Probe,
        phase: FirePhase = .idle,
        allocator: std.mem.Allocator,
        fn phaseName(self: *const @This()) []const u8 {
            return switch (self.phase) {
                .idle => "idle",
                .armed => "armed",
                .fired => "fired",
            };
        }
        pub fn prepare(self: *@This()) !void {
            self.probe.fired = 0;
            self.phase = .idle;
            try Driver.testing.setNow(self.driver, 0);
        }
        pub fn step(self: *@This(), act: Act, pic: ?*state_tcas.Picture) !void {
            const before = self.phaseName();
            switch (act) {
                .arm => {
                    try self.timer.startAt(early_deadline);
                    self.phase = .armed;
                },
                .cancel => unreachable,
                .advance_past => {},
                .run_once => {
                    _ = Driver.testing.advance(self.driver, emptyHooks(null), early_deadline + 1);
                    if (self.probe.fired > 0) self.phase = .fired;
                },
            }
            if (pic) |p| {
                try p.observe(self.allocator, .{
                    .before = before,
                    .after = self.phaseName(),
                    .label = @tagName(act),
                    .rejected = false,
                    .mutated = !std.mem.eql(u8, before, self.phaseName()),
                    .note = self.phaseName(),
                    .from = "Host",
                    .to = "Driver",
                    .keep_unchanged = true,
                });
            }
        }
        pub fn finish(self: *@This(), _: []const Act) !void {
            try std.testing.expectEqual(@as(usize, 1), self.probe.fired);
        }
        pub fn release(_: *@This()) void {}
    };

    const allocator = std.testing.allocator;
    const driver = try Driver.create(allocator);
    defer driver.destroy();
    var timer: Timer = undefined;
    timer.init(driver, &probe, Probe.timer);
    defer timer.close();
    var fire_ctx: FireCtx = .{
        .driver = driver,
        .timer = &timer,
        .probe = &probe,
        .allocator = allocator,
    };

    var pic: state_tcas.Picture = .{};
    defer pic.deinit(allocator);
    try state_tcas.exhaust.play(Act, &fire_ctx, &[_]Act{ .arm, .run_once }, &pic);
    const text = try pic.render(
        allocator,
        "# Driver timer fire (state_tcas Observation)\n\n",
        "Host",
        "Driver",
    );
    defer allocator.free(text);
    try explore_adapters.lockNormalized(
        std.testing.io,
        allocator,
        "docs/state-tcas-driver-timer-fire.md",
        text,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "sequenceDiagram") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Host->>Driver: arm") != null);
}

// ─── DFS with act-log rebuild (opaque Loop → no BFS clone) ───────────────────

/// Explore acts: L0 dispatch (`run_once`) + L1 clock (`set_now_*`) + arm/cancel/suspend. No L2 escape variant — gap probes live in `*_driver_gap.zig`.
const ExploreAct = enum {
    arm_early,
    arm_late,
    cancel_early,
    cancel_late,
    set_now_mid, // 15: early due, late not
    set_now_past, // 25: both due
    run_once,
    suspend_sched,
    resume_sched,
};

/// Live Driver + two timers. Undo rebuilds by destroying the Driver and replaying `log[0..len]`. Honest because zev.Loop cannot be value-copied.
const ExploreWorld = struct {
    allocator: std.mem.Allocator,
    driver: ?*Driver = null,
    early: Timer = .{},
    late: Timer = .{},
    early_inited: bool = false,
    late_inited: bool = false,

    early_armed: bool = false,
    late_armed: bool = false,
    early_cancelled: bool = false,
    late_cancelled: bool = false,
    early_fired: usize = 0,
    late_fired: usize = 0,
    suspended: bool = false,
    now_target: u64 = 0,
    /// Sticky across undo/rebuild: a timer was ever armed this run (Liveness). Not cleared by `boot`/`rebuild` — seed must not vacuum `liv.finish` (P1-2).
    ever_armed: bool = false,
    /// When false, enabled() omits suspend/resume (keeps unkeyed DFS small).
    allow_suspend: bool = true,
    /// When false, only the early timer is offered (unkeyed DFS smoke).
    dual_timers: bool = true,

    log: [48]ExploreAct = undefined,
    len: usize = 0,
    acts_buf: [8]ExploreAct = undefined,

    /// Safety: a fire counted while the matching timer was marked cancelled.
    bad_cancel_delivery: bool = false,
    /// Safety: fire observed through run_once while suspended (production path).
    bad_suspend_fire: bool = false,

    fn onEarly(context: ?*anyopaque, _: *Timer) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.early_fired += 1;
        self.early_armed = false;
        if (self.early_cancelled) self.bad_cancel_delivery = true;
        if (self.suspended) self.bad_suspend_fire = true;
    }
    fn onLate(context: ?*anyopaque, _: *Timer) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.late_fired += 1;
        self.late_armed = false;
        if (self.late_cancelled) self.bad_cancel_delivery = true;
        if (self.suspended) self.bad_suspend_fire = true;
    }

    fn teardown(self: *@This()) void {
        if (self.early_inited) {
            self.early.close();
            self.early_inited = false;
        }
        if (self.late_inited) {
            self.late.close();
            self.late_inited = false;
        }
        if (self.driver) |d| {
            d.destroy();
            self.driver = null;
        }
    }

    fn boot(self: *@This()) !void {
        const keep_ever = self.ever_armed;
        self.teardown();
        const d = try Driver.create(self.allocator);
        errdefer d.destroy();
        self.driver = d;
        self.early = .{};
        self.late = .{};
        self.early.init(d, self, onEarly);
        self.early_inited = true;
        self.late.init(d, self, onLate);
        self.late_inited = true;
        try Driver.testing.setNow(d, 0);
        self.early_armed = false;
        self.late_armed = false;
        self.early_cancelled = false;
        self.late_cancelled = false;
        self.early_fired = 0;
        self.late_fired = 0;
        self.suspended = false;
        self.now_target = 0;
        self.bad_cancel_delivery = false;
        self.bad_suspend_fire = false;
        self.ever_armed = keep_ever; // sticky across rebuild
    }

    fn apply(self: *@This(), act: ExploreAct) !void {
        const d = self.driver orelse return error.NoDriver;
        switch (act) {
            .arm_early => {
                if (self.early_armed) return error.AlreadyArmed;
                try self.early.startAt(early_deadline);
                self.early_armed = true;
                self.early_cancelled = false;
                self.ever_armed = true;
            },
            .arm_late => {
                if (self.late_armed) return error.AlreadyArmed;
                try self.late.startAt(late_deadline);
                self.late_armed = true;
                self.late_cancelled = false;
                self.ever_armed = true;
            },
            .cancel_early => {
                if (!self.early_armed) return error.NotArmed;
                if (!self.early.cancel()) return error.CancelMissed;
                self.early_armed = false;
                self.early_cancelled = true;
            },
            .cancel_late => {
                if (!self.late_armed) return error.NotArmed;
                if (!self.late.cancel()) return error.CancelMissed;
                self.late_armed = false;
                self.late_cancelled = true;
            },
            .set_now_mid => {
                if (self.now_target >= 15) return error.ClockNoop;
                try Driver.testing.setNow(d, 15);
                self.now_target = 15;
            },
            .set_now_past => {
                if (self.now_target >= 25) return error.ClockNoop;
                try Driver.testing.setNow(d, 25);
                self.now_target = 25;
            },
            .run_once => {
                const before_e = self.early_fired;
                const before_l = self.late_fired;
                _ = Driver.testing.runOnce(d, emptyHooks(self));
                if (self.suspended) {
                    if (self.early_fired != before_e or self.late_fired != before_l)
                        self.bad_suspend_fire = true;
                }
            },
            .suspend_sched => {
                if (self.suspended) return error.AlreadySuspended;
                d.suspendScheduling();
                self.suspended = true;
            },
            .resume_sched => {
                if (!self.suspended) return error.NotSuspended;
                d.resumeScheduling();
                self.suspended = false;
            },
        }
    }

    /// Replay saved act-log after boot. Log only contains enabled-legal acts
    /// (`step` appends after a successful `apply`); rebuild of those prefixes
    /// must stay infallible. Unexpected create/OOM → `undo`'s `catch unreachable`
    /// (package undo is void). Prefer pre-boot in the DFS test so create cannot
    /// surprise mid-search.
    fn rebuild(self: *@This()) !void {
        const saved = self.log;
        const n = self.len;
        try self.boot();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try self.apply(saved[i]);
        }
        // boot cleared log bookkeeping via fields; restore log cursor.
        self.log = saved;
        self.len = n;
    }

    pub fn enabled(self: *@This()) []const ExploreAct {
        // Depth cap: act-log rebuild is O(depth); avoid suspend/run_once livelock.
        if (self.len >= 8) return self.acts_buf[0..0];
        var n: usize = 0;
        if (!self.early_armed and self.early_fired == 0 and !self.early_cancelled) {
            self.acts_buf[n] = .arm_early;
            n += 1;
        }
        if (self.dual_timers and !self.late_armed and self.late_fired == 0 and !self.late_cancelled) {
            self.acts_buf[n] = .arm_late;
            n += 1;
        }
        if (self.early_armed) {
            self.acts_buf[n] = .cancel_early;
            n += 1;
        }
        if (self.dual_timers and self.late_armed) {
            self.acts_buf[n] = .cancel_late;
            n += 1;
        }
        if (self.now_target < 15) {
            self.acts_buf[n] = .set_now_mid;
            n += 1;
        }
        if (self.now_target < 25) {
            self.acts_buf[n] = .set_now_past;
            n += 1;
        }
        // Only run a turn while a timer is still armed (due or not). Prevents infinite run_once after both have fired/cancelled.
        if (self.early_armed or self.late_armed) {
            self.acts_buf[n] = .run_once;
            n += 1;
        }
        // Suspend/resume only while work is pending — cuts oscillation tails.
        if (self.allow_suspend) {
            if (self.early_armed or self.late_armed) {
                if (!self.suspended) {
                    self.acts_buf[n] = .suspend_sched;
                    n += 1;
                } else {
                    self.acts_buf[n] = .resume_sched;
                    n += 1;
                }
            } else if (self.suspended) {
                self.acts_buf[n] = .resume_sched;
                n += 1;
            }
        }
        return self.acts_buf[0..n];
    }

    pub fn step(self: *@This(), act: ExploreAct) !void {
        if (self.len >= self.log.len) return error.LogFull;
        self.log[self.len] = act;
        self.len += 1;
        try self.apply(act);
    }

    pub fn undo(self: *@This(), act: ExploreAct) void {
        _ = act;
        self.len -= 1;
        self.rebuild() catch unreachable;
    }

    pub fn key(self: *const @This()) u64 {
        // State-keyed (not path-keyed): omit act-log length so equivalent Driver snapshots prune.
        // Include the depth-cap bit because enabled() becomes empty at len >= 8; without it, a capped leaf can prune a shallower equivalent state that still expands.
        var k: u64 = 0;
        k |= @as(u64, @intFromBool(self.early_armed));
        k |= @as(u64, @intFromBool(self.late_armed)) << 1;
        k |= @as(u64, @intFromBool(self.early_cancelled)) << 2;
        k |= @as(u64, @intFromBool(self.late_cancelled)) << 3;
        k |= @as(u64, @intCast(self.early_fired & 0x3)) << 4;
        k |= @as(u64, @intCast(self.late_fired & 0x3)) << 6;
        k |= @as(u64, @intFromBool(self.suspended)) << 8;
        k |= @as(u64, @intCast(self.now_target & 0x3f)) << 9;
        k |= @as(u64, @intFromBool(self.len >= 8)) << 15;
        return k;
    }

    pub fn safetyOk(ctx: *@This()) !void {
        if (ctx.bad_cancel_delivery or ctx.bad_suspend_fire) return error.SafetyViolation;
    }

    pub fn isEnabled(ctx: *@This()) bool {
        // Sticky: seed after DFS undo is idle. Live armed/suspend alone makes finish-after-undo a no-op when no goal was noted (P1-2).
        return ctx.ever_armed;
    }

    pub fn isGoal(ctx: *@This()) bool {
        // Quiescent: nothing armed, not suspended, and every offered timer resolved.
        const early_done = ctx.early_fired > 0 or ctx.early_cancelled;
        const late_done = (!ctx.dual_timers) or (ctx.late_fired > 0 or ctx.late_cancelled);
        return !ctx.early_armed and !ctx.late_armed and !ctx.suspended and early_done and late_done;
    }
};

test "state_tcas Driver: DFS explore arm/cancel/clock/runOnce with Safety+Liveness" {
    var world: ExploreWorld = .{ .allocator = std.testing.allocator, .allow_suspend = false, .dual_timers = false };
    try world.boot();
    defer world.teardown();

    var saf = state_tcas.monitor.Safety(*ExploreWorld){
        .ctx = &world,
        .checkFn = ExploreWorld.safetyOk,
    };
    var liv = state_tcas.monitor.Liveness(*ExploreWorld){
        .ctx = &world,
        .enabledFn = ExploreWorld.isEnabled,
        .goalFn = ExploreWorld.isGoal,
    };

    var legal: explore_adapters.Monitored(ExploreAct, ExploreWorld) = .{ .inner = &world, .saf = &saf, .liv = &liv };
    var stats: state_tcas.explore.Stats = .{};
    // Depth budget: rebuild is expensive; keep the frontier modest.
    try state_tcas.explore.dfs(ExploreAct, &legal, 1024, &stats);
    try liv.finish();
    try std.testing.expect(liv.reached);
    try std.testing.expect(stats.visits > 1);
    try std.testing.expect(stats.expansions > 0);
    // Seed restored: empty log, clock 0, nothing armed.
    try std.testing.expectEqual(@as(usize, 0), world.len);
    try std.testing.expectEqual(@as(usize, 0), world.early_fired);
    try std.testing.expectEqual(@as(usize, 0), world.late_fired);
    try std.testing.expect(!world.suspended);
    try std.testing.expect(world.ever_armed); // sticky survived undo
}

test "state_tcas Driver: dfsKeyed prunes on logical Driver key" {
    var world: ExploreWorld = .{ .allocator = std.testing.allocator };
    try world.boot();
    defer world.teardown();

    var saf = state_tcas.monitor.Safety(*ExploreWorld){
        .ctx = &world,
        .checkFn = ExploreWorld.safetyOk,
    };
    var liv = state_tcas.monitor.Liveness(*ExploreWorld){
        .ctx = &world,
        .enabledFn = ExploreWorld.isEnabled,
        .goalFn = ExploreWorld.isGoal,
    };

    var keyed: explore_adapters.MonitoredKeyed(ExploreAct, ExploreWorld) = .{ .inner = &world, .saf = &saf, .liv = &liv };
    var stats: state_tcas.explore.Stats = .{};
    var visited = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer visited.deinit();
    try state_tcas.explore.dfsKeyed(ExploreAct, u64, &keyed, 4096, &stats, &visited);
    try liv.finish();
    try std.testing.expect(liv.reached);
    try std.testing.expect(stats.visits >= 2);
    try std.testing.expectEqual(@as(usize, 0), world.len);
}

test "state_tcas Driver: rebuild of every act-log prefix succeeds" {
    var world: ExploreWorld = .{ .allocator = std.testing.allocator, .allow_suspend = false, .dual_timers = false };
    try world.boot();
    defer world.teardown();
    const script = [_]ExploreAct{ .arm_early, .set_now_past, .run_once };
    for (script) |act| {
        try world.step(act);
    }
    const full = world.len;
    var prefix: usize = 0;
    while (prefix <= full) : (prefix += 1) {
        world.len = prefix;
        try world.rebuild();
        try std.testing.expectEqual(prefix, world.len);
    }
}

test "state_tcas Driver: BFS clone of live Driver intentionally unsupported" {
    // Honesty lock: zev.Loop / Timer heap / notifier queues are opaque and pointer-rich. ExploreWorld rebuilds via act-log for DFS/dfsKeyed only. Scheduler-value bfs stays in state_tcas_js_event_loop_harness.zig.
    try std.testing.expect(!@hasDecl(Driver, "clone"));
}

test "state_tcas Driver: dfsKeyed depth-cap bit keeps expandability distinct" {
    var world: ExploreWorld = .{ .allocator = std.testing.allocator, .allow_suspend = false, .dual_timers = false };
    try world.boot();
    defer world.teardown();
    try world.step(.arm_early);
    try world.step(.set_now_mid);
    try std.testing.expect(world.len < 8);
    try std.testing.expect(world.enabled().len > 0);
    const key_open = world.key();
    const saved_len = world.len;
    world.len = 8;
    try std.testing.expectEqual(@as(usize, 0), world.enabled().len);
    const key_capped = world.key();
    try std.testing.expect(key_open != key_capped);
    world.len = 3;
    try std.testing.expect(world.enabled().len > 0);
    try std.testing.expectEqual(key_open, world.key());
    world.len = saved_len;
}

test "state_tcas Driver: rebuild cost split boot vs replay" {
    var world: ExploreWorld = .{ .allocator = std.testing.allocator, .allow_suspend = false, .dual_timers = false };
    const rounds: usize = 16;
    try world.boot();
    defer world.teardown();
    // Keep the log cancellable (no fire): re-arm after fire is not enabled once early_fired > 0.
    try world.step(.arm_early);
    try world.step(.set_now_mid);
    try world.step(.set_now_past);
    try world.step(.cancel_early);
    const log_len = world.len;
    try std.testing.expect(log_len >= 4);
    try world.rebuild();

    var boot_ns: u64 = 0;
    var full_ns: u64 = 0;
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        var t0 = explore_adapters.monoNs();
        try world.boot();
        boot_ns += explore_adapters.monoNs() - t0;

        // boot() leaves log/len intact; rebuild replays that log after another boot.
        t0 = explore_adapters.monoNs();
        try world.rebuild();
        full_ns += explore_adapters.monoNs() - t0;
    }
    const avg_boot = boot_ns / rounds;
    const avg_full = full_ns / rounds;
    const replay_est: u64 = if (avg_full > avg_boot) avg_full - avg_boot else 0;
    std.debug.print(
        "state_tcas Driver rebuild cost: boot_ns_avg={d} full_rebuild_ns_avg={d} replay_est_ns_avg={d} rounds={d} log_len={d}\n",
        .{ avg_boot, avg_full, replay_est, rounds, log_len },
    );
    try std.testing.expect(avg_boot > 0);
    try std.testing.expect(avg_full > 0);
}
