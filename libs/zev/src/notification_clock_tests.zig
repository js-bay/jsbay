//! Virtual-clock coverage for notification dispatch.

const std = @import("std");
const zev = @import("zev");

const VirtualClock = struct {
    now: u64 = 0,
    fn read(ctx: ?*anyopaque) u64 {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.now;
    }
};

test "dispatchEvents uses nowMs for timer due checks" {
    const State = struct {
        const Self = @This();
        calls: u8 = 0,
        fn callback(ctx: ?*anyopaque, _: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var clock: VirtualClock = .{ .now = 50 };
    loop.setClock(&clock, VirtualClock.read);
    defer loop.setClock(null, null);
    var state: State = .{};
    var timer: zev.Timer = .{};
    timer.init(loop, &state, State.callback);
    defer timer.close();
    try timer.startAt(100);
    // Due checks follow nowMs (50), not a host-supplied stale sample.
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 0), state.calls);
    clock.now = 100;
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 1), state.calls);
}

test "frozen virtual clock keeps a time budget from elapsing" {
    const State = struct {
        const Self = @This();
        calls: u8 = 0,
        fn callback(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var clock: VirtualClock = .{ .now = 1_000 };
    loop.setClock(&clock, VirtualClock.read);
    defer loop.setClock(null, null);
    var state: State = .{};
    var first: zev.Notifier = .{};
    var second: zev.Notifier = .{};
    first.init(loop, &state, State.callback);
    second.init(loop, &state, State.callback);
    defer first.close();
    defer second.close();
    try std.testing.expect(first.notify());
    try std.testing.expect(second.notify());
    // Clock stays at 1000 across callbacks, so a positive time budget never trips.
    loop.dispatchEventsLimited(null, 5);
    try std.testing.expectEqual(@as(u8, 2), state.calls);
}
