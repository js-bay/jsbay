//! Extended tests for notifier timer cancellation and reservation release.

const std = @import("std");
const zev = @import("zev");

const VirtualClock = struct {
    now: u64 = 0,
    fn read(ctx: ?*anyopaque) u64 {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.now;
    }
};

test "notifier can cancel or rearm timers already in the ready snapshot" {
    const State = struct {
        const Self = @This();
        timer: *zev.Timer,
        rearm: bool,
        calls: u8 = 0,
        fn onNotify(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.rearm) self.timer.startAt(20) catch unreachable else _ = self.timer.cancel();
        }
        fn onTimer(ctx: ?*anyopaque, _: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var clock: VirtualClock = .{ .now = 10 };
    loop.setClock(&clock, VirtualClock.read);
    defer loop.setClock(null, null);

    var cancelled_calls: u8 = 0;
    var cancelled_timer: zev.Timer = .{};
    cancelled_timer.init(loop, &cancelled_calls, struct {
        fn callback(ctx: ?*anyopaque, _: *zev.Timer) void {
            const calls: *u8 = @ptrCast(@alignCast(ctx.?));
            calls.* += 1;
        }
    }.callback);
    var cancel_state = State{ .timer = &cancelled_timer, .rearm = false };
    var cancel_notifier: zev.Notifier = .{};
    cancel_notifier.init(loop, &cancel_state, State.onNotify);
    try cancelled_timer.startAt(10);
    try std.testing.expect(cancel_notifier.notify());
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 0), cancelled_calls);
    try std.testing.expect(!cancelled_timer.isActive());

    var rearmed_calls: u8 = 0;
    var rearmed_timer: zev.Timer = .{};
    rearmed_timer.init(loop, &rearmed_calls, struct {
        fn callback(ctx: ?*anyopaque, _: *zev.Timer) void {
            const calls: *u8 = @ptrCast(@alignCast(ctx.?));
            calls.* += 1;
        }
    }.callback);
    var rearm_state = State{ .timer = &rearmed_timer, .rearm = true };
    var rearm_notifier: zev.Notifier = .{};
    rearm_notifier.init(loop, &rearm_state, State.onNotify);
    try rearmed_timer.startAt(10);
    try std.testing.expect(rearm_notifier.notify());
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 0), rearmed_calls);
    try std.testing.expect(rearmed_timer.isActive());
    clock.now = 20;
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 1), rearmed_calls);
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 1), rearmed_calls);
    cancel_notifier.close();
    rearm_notifier.close();
    cancelled_timer.close();
    rearmed_timer.close();
}

test "closing a reserved timer releases its heap capacity reservation" {
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var timer: zev.Timer = .{};
    timer.init(loop, null, struct {
        fn callback(_: ?*anyopaque, _: *zev.Timer) void {}
    }.callback);
    try timer.reserve();
    try std.testing.expect(timer.reserved);
    try std.testing.expectEqual(@as(usize, 1), loop.reserved_timer_count);
    timer.close();
    try std.testing.expectEqual(@as(usize, 0), loop.reserved_timer_count);
}
