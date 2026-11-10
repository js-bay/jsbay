//! Safety + Liveness monitors over a jsbay-like timer arm/fire/cancel FSM.
//! Pattern mirrors state_tcas/examples/toy_fsm.zig; calendar backs delays.
//! Run: `zig build test-state-tcas`

const std = @import("std");
const state_tcas = @import("state_tcas");

const Act = enum { arm, cancel, advance, fire };

const Phase = enum { idle, armed, due, done, cancelled };

test "state_tcas monitor: Safety+Liveness on arm/cancel DFS (toy_fsm pattern)" {
    const Pure = struct {
        phase: Phase = .idle,
        fired: bool = false,
        cancelled: bool = false,
        stack: [8]Phase = undefined,
        sp: usize = 0,

        pub fn enabled(self: *@This()) []const Act {
            return switch (self.phase) {
                .idle => &[_]Act{.arm},
                .armed => &[_]Act{.cancel},
                else => &[_]Act{},
            };
        }
        pub fn step(self: *@This(), act: Act) !void {
            self.stack[self.sp] = self.phase;
            self.sp += 1;
            switch (act) {
                .arm => self.phase = .armed,
                .cancel => {
                    self.phase = .cancelled;
                    self.cancelled = true;
                },
                else => return error.BadAct,
            }
        }
        pub fn undo(self: *@This(), act: Act) void {
            _ = act;
            self.sp -= 1;
            self.phase = self.stack[self.sp];
            if (self.phase != .cancelled) self.cancelled = false;
        }
        pub fn safetyOk(ctx: *@This()) !void {
            if (ctx.fired and ctx.cancelled) return error.SafetyViolation;
        }
        pub fn isEnabled(ctx: *@This()) bool {
            return ctx.phase != .idle;
        }
        pub fn isGoal(ctx: *@This()) bool {
            return ctx.cancelled or ctx.fired;
        }
    };

    var toy: Pure = .{};
    var saf = state_tcas.monitor.Safety(*Pure){ .ctx = &toy, .checkFn = Pure.safetyOk };
    var liv = state_tcas.monitor.Liveness(*Pure){
        .ctx = &toy,
        .enabledFn = Pure.isEnabled,
        .goalFn = Pure.isGoal,
    };
    const Wrapped = struct {
        inner: *Pure,
        saf: *state_tcas.monitor.Safety(*Pure),
        liv: *state_tcas.monitor.Liveness(*Pure),
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
    try state_tcas.explore.dfs(Act, &wrap, 32, &stats);
    try liv.finish();
    try std.testing.expect(stats.expansions >= 2);
    try std.testing.expect(saf.observations >= 2);
}

test "state_tcas monitor: calendar arm/advance/fire with Bundle + ClockRewind" {
    const allocator = std.testing.allocator;
    var cal = state_tcas.calendar.Calendar.init(allocator, 0);
    defer cal.deinit();

    const TimerFsm = struct {
        phase: Phase = .idle,
        fired: bool = false,
        cancelled: bool = false,
        delay_us: u64 = 1000,
        cal: *state_tcas.calendar.Calendar,
        event_id: ?state_tcas.calendar.EventId = null,

        fn arm(self: *@This()) !void {
            const id = try self.cal.schedule(self.cal.now_us + self.delay_us, 1, 0);
            self.event_id = id;
            self.phase = .armed;
        }
        fn advance(self: *@This()) !void {
            try self.cal.advanceTo(self.cal.now_us + self.delay_us);
            self.phase = .due;
        }
        fn fire(self: *@This()) !void {
            const Sink = struct {
                n: usize = 0,
                fn on(s: *@This(), tag: u32, _: u64) !void {
                    _ = tag;
                    s.n += 1;
                }
            };
            var sink: Sink = .{};
            const n = try self.cal.fireDue(&sink, Sink.on);
            if (n != 1) return error.FireCount;
            self.fired = true;
            self.event_id = null;
            self.phase = .done;
        }
        fn safetyOk(ctx: *@This()) !void {
            if (ctx.fired and ctx.cancelled) return error.SafetyViolation;
            if (ctx.phase == .done and !ctx.fired) return error.SafetyViolation;
        }
        fn isEnabled(ctx: *@This()) bool {
            return ctx.phase != .idle;
        }
        fn isGoal(ctx: *@This()) bool {
            return ctx.fired or ctx.cancelled;
        }
    };

    var fsm: TimerFsm = .{ .cal = &cal };
    var bun = state_tcas.monitor.Bundle(*TimerFsm){
        .safety = .{ .ctx = &fsm, .checkFn = TimerFsm.safetyOk },
        .liveness = .{
            .ctx = &fsm,
            .enabledFn = TimerFsm.isEnabled,
            .goalFn = TimerFsm.isGoal,
        },
    };

    try fsm.arm();
    try bun.afterStep();
    try fsm.advance();
    try bun.afterStep();
    try fsm.fire();
    try bun.afterStep();
    try bun.finish();

    try std.testing.expect(fsm.fired);
    try std.testing.expectEqual(Phase.done, fsm.phase);
    try std.testing.expectError(error.ClockRewind, cal.advanceTo(0));
}

test "state_tcas monitor: cancel-before-fire is live; fire+cancel together is unsafe" {
    const allocator = std.testing.allocator;
    var cal = state_tcas.calendar.Calendar.init(allocator, 0);
    defer cal.deinit();

    const id = try cal.schedule(100, 1, 0);
    try std.testing.expect(cal.cancel(id));
    cal.compactCancelled();
    try cal.advanceTo(100);
    const Sink = struct {
        n: usize = 0,
        fn on(self: *@This(), _: u32, _: u64) !void {
            self.n += 1;
        }
    };
    var sink: Sink = .{};
    try std.testing.expectEqual(@as(usize, 0), try cal.fireDue(&sink, Sink.on));

    const Box = struct {
        fired: bool = false,
        cancelled: bool = true,
        fn safetyOk(ctx: *@This()) !void {
            if (ctx.fired and ctx.cancelled) return error.SafetyViolation;
        }
        fn isEnabled(_: *@This()) bool {
            return true;
        }
        fn isGoal(ctx: *@This()) bool {
            return ctx.cancelled or ctx.fired;
        }
    };
    var box: Box = .{};
    var saf = state_tcas.monitor.Safety(*Box){ .ctx = &box, .checkFn = Box.safetyOk };
    var liv = state_tcas.monitor.Liveness(*Box){
        .ctx = &box,
        .enabledFn = Box.isEnabled,
        .goalFn = Box.isGoal,
    };
    try saf.observe();
    liv.note();
    try liv.finish();

    box.fired = true;
    try std.testing.expectError(error.SafetyViolation, saf.observe());
}
