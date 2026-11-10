//! state_tcas calendar: schedule / cancel / fireDue / ClockRewind / compact / advanceToNext.
//!
//! Also wires a Safety observe on fireDue (cancelled must never deliver), and a DES+DFS explore that undoes via Calendar.clone / resetTo. Proves the path dependency; does not exercise JS engine semantics.
//!
//! Run: `zig build test-state-tcas`

const std = @import("std");
const state_tcas = @import("state_tcas");

test "state_tcas calendar: schedule cancel fireDue ClockRewind" {
    const allocator = std.testing.allocator;

    var cal = state_tcas.calendar.Calendar.init(allocator, 0);
    defer cal.deinit();

    const timeout_id = try cal.schedule(1000, 42, 7);
    try std.testing.expect(cal.cancel(timeout_id));
    cal.compactCancelled();
    try cal.advanceTo(1000);

    const Sink = struct {
        saw: bool = false,
        fn on(self: *@This(), tag: u32, payload: u64) !void {
            _ = tag;
            _ = payload;
            self.saw = true;
        }
    };
    var sink: Sink = .{};
    const fired_cancelled = try cal.fireDue(&sink, Sink.on);
    try std.testing.expectEqual(@as(usize, 0), fired_cancelled);
    try std.testing.expect(!sink.saw);

    try std.testing.expectError(error.ClockRewind, cal.advanceTo(10));

    _ = try cal.schedule(2000, 1, 0);
    _ = try cal.schedule(2000, 2, 0);
    try cal.advanceTo(2000);
    const Order = struct {
        got: [2]u32 = undefined,
        n: usize = 0,
        fn on(self: *@This(), tag: u32, _: u64) !void {
            self.got[self.n] = tag;
            self.n += 1;
        }
    };
    var order: Order = .{};
    const n = try cal.fireDue(&order, Order.on);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 1), order.got[0]);
    try std.testing.expectEqual(@as(u32, 2), order.got[1]);
}

test "state_tcas calendar: advanceBy advanceToNext past-due compactCancelled" {
    const allocator = std.testing.allocator;
    var cal = state_tcas.calendar.Calendar.init(allocator, 0);
    defer cal.deinit();

    const a = try cal.schedule(500, 1, 0);
    _ = try cal.schedule(1500, 2, 0);
    try std.testing.expect(cal.cancel(a));
    try std.testing.expectEqual(@as(usize, 2), cal.slotCount());
    try std.testing.expectEqual(@as(usize, 1), cal.pendingCount());
    cal.compactCancelled();
    try std.testing.expectEqual(@as(usize, 1), cal.slotCount());

    try cal.advanceBy(100);
    try std.testing.expectEqual(@as(u64, 100), cal.now_us);
    try std.testing.expect(try cal.advanceToNext());
    try std.testing.expectEqual(@as(u64, 1500), cal.now_us);

    // tip b366a82: advanceBy is checked-add (no wrap-as-fake-rewind).
    try std.testing.expectError(error.Overflow, cal.advanceBy(std.math.maxInt(u64)));

    // Past-due relative to a later clock still pops.
    _ = try cal.schedule(1000, 9, 1);
    const e = cal.popDue().?;
    // dueIndex prefers earliest at_us among due; 1000 < 1500 and 1000 < now → due.
    // Actually now is 1500, so both 1500 tag2 and 1000 tag9 are due; earliest at_us is 1000.
    try std.testing.expectEqual(@as(u32, 9), e.tag);

    const e2 = cal.popDue().?;
    try std.testing.expectEqual(@as(u32, 2), e2.tag);
    try std.testing.expectEqual(@as(usize, 0), cal.pendingCount());
}

test "state_tcas calendar: Safety observe rejects delivery after cancel" {
    const allocator = std.testing.allocator;
    var cal = state_tcas.calendar.Calendar.init(allocator, 0);
    defer cal.deinit();

    const Box = struct {
        delivered: usize = 0,
        cancelled_ids_delivered: usize = 0,
        expect_id_cancelled: bool = false,

        fn safetyOk(ctx: *@This()) !void {
            if (ctx.cancelled_ids_delivered > 0) return error.SafetyViolation;
        }
    };
    var box: Box = .{};
    var saf = state_tcas.monitor.Safety(*Box){ .ctx = &box, .checkFn = Box.safetyOk };

    const id = try cal.schedule(100, 1, 0);
    try std.testing.expect(cal.cancel(id));
    try cal.advanceTo(100);

    const Sink = struct {
        box: *Box,
        fn on(self: *@This(), tag: u32, _: u64) !void {
            _ = tag;
            self.box.delivered += 1;
            // If we ever see a fire after cancel, mark it.
            self.box.cancelled_ids_delivered += 1;
        }
    };
    var sink: Sink = .{ .box = &box };
    const n = try cal.fireDue(&sink, Sink.on);
    try std.testing.expectEqual(@as(usize, 0), n);
    try saf.observe();
    try std.testing.expectEqual(@as(usize, 0), box.delivered);
}

test "state_tcas calendar: DFS arm/cancel vs advance/fire via clone+resetTo" {
    // Live Calendar refuses ClockRewind; DFS undo must snapshot with clone and
    // restore via resetTo (docs/harness.md#calendar-explore). Shared acts_buf is
    // fine — explore.dfs copies enabled() per frame.
    const allocator = std.testing.allocator;
    var cal = state_tcas.calendar.Calendar.init(allocator, 0);
    defer cal.deinit();

    const Act = enum { arm, cancel, advance, fire };
    const Phase = enum { idle, armed, due, done, cancelled };

    const Frame = struct {
        phase: Phase,
        fired: bool,
        cancelled: bool,
        event_id: ?state_tcas.calendar.EventId,
        snap: state_tcas.calendar.Calendar,
    };

    const Ctx = struct {
        cal: *state_tcas.calendar.Calendar,
        phase: Phase = .idle,
        fired: bool = false,
        cancelled: bool = false,
        event_id: ?state_tcas.calendar.EventId = null,
        delay_us: u64 = 1000,
        frames: [8]?Frame = @splat(null),
        sp: usize = 0,
        acts_buf: [4]Act = undefined,

        pub fn enabled(self: *@This()) []const Act {
            var n: usize = 0;
            switch (self.phase) {
                .idle => {
                    self.acts_buf[0] = .arm;
                    n = 1;
                },
                .armed => {
                    self.acts_buf[0] = .cancel;
                    self.acts_buf[1] = .advance;
                    n = 2;
                },
                .due => {
                    self.acts_buf[0] = .fire;
                    n = 1;
                },
                .done, .cancelled => {},
            }
            return self.acts_buf[0..n];
        }

        pub fn step(self: *@This(), act: Act) !void {
            var snap = try self.cal.clone();
            errdefer snap.deinit();
            self.frames[self.sp] = .{
                .phase = self.phase,
                .fired = self.fired,
                .cancelled = self.cancelled,
                .event_id = self.event_id,
                .snap = snap,
            };
            self.sp += 1;

            switch (act) {
                .arm => {
                    const id = try self.cal.schedule(self.cal.now_us + self.delay_us, 1, 0);
                    self.event_id = id;
                    self.phase = .armed;
                },
                .cancel => {
                    const id = self.event_id orelse return error.NoEvent;
                    if (!self.cal.cancel(id)) return error.CancelMiss;
                    self.cal.compactCancelled();
                    self.cancelled = true;
                    self.event_id = null;
                    self.phase = .cancelled;
                },
                .advance => {
                    try self.cal.advanceTo(self.cal.now_us + self.delay_us);
                    self.phase = .due;
                },
                .fire => {
                    const Sink = struct {
                        n: usize = 0,
                        fn on(s: *@This(), _: u32, _: u64) !void {
                            s.n += 1;
                        }
                    };
                    var sink: Sink = .{};
                    const n = try self.cal.fireDue(&sink, Sink.on);
                    if (n != 1) return error.FireCount;
                    self.fired = true;
                    self.event_id = null;
                    self.phase = .done;
                },
            }
        }

        pub fn undo(self: *@This(), act: Act) void {
            _ = act;
            self.sp -= 1;
            var frame = self.frames[self.sp].?;
            self.frames[self.sp] = null;
            self.cal.resetTo(&frame.snap) catch unreachable;
            frame.snap.deinit();
            self.phase = frame.phase;
            self.fired = frame.fired;
            self.cancelled = frame.cancelled;
            self.event_id = frame.event_id;
        }

        pub fn safetyOk(ctx: *@This()) !void {
            if (ctx.fired and ctx.cancelled) return error.SafetyViolation;
        }

        pub fn isEnabled(ctx: *@This()) bool {
            return ctx.phase != .idle;
        }

        pub fn isGoal(ctx: *@This()) bool {
            return ctx.fired or ctx.cancelled;
        }
    };

    var toy: Ctx = .{ .cal = &cal };
    var saf = state_tcas.monitor.Safety(*Ctx){ .ctx = &toy, .checkFn = Ctx.safetyOk };
    var liv = state_tcas.monitor.Liveness(*Ctx){
        .ctx = &toy,
        .enabledFn = Ctx.isEnabled,
        .goalFn = Ctx.isGoal,
    };
    const Wrapped = struct {
        inner: *Ctx,
        saf: *state_tcas.monitor.Safety(*Ctx),
        liv: *state_tcas.monitor.Liveness(*Ctx),
        pub fn enabled(self: *@This()) []const Act {
            return self.inner.enabled();
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
    var wrap: Wrapped = .{ .inner = &toy, .saf = &saf, .liv = &liv };
    var stats: state_tcas.explore.Stats = .{};
    try state_tcas.explore.dfs(Act, &wrap, 64, &stats);
    try liv.finish();
    try std.testing.expect(stats.expansions >= 3); // arm + (cancel | advance) + fire
    try std.testing.expectEqual(Phase.idle, toy.phase);
    try std.testing.expectEqual(@as(u64, 0), cal.now_us);
    try std.testing.expectEqual(@as(usize, 0), cal.pendingCount());
}
