//! Engine integration for event-loop Notifier and Timer notifications.

const std = @import("std");
const testing = std.testing;
const engine = @import("../engine.zig");
const dispatch = @import("../runtime/dispatch.zig");
const instance_map = @import("../runtime/instance_map.zig");
const event_loop = @import("js_event_loop");
const helpers = @import("test_helpers.zig");

test "native event notification: engine tick dispatches async and synthetic timer" {
    const State = struct {
        const Self = @This();
        async_calls: u8 = 0,
        timer_calls: u8 = 0,
        fn asyncCallback(ctx: ?*anyopaque, _: *event_loop.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.async_calls += 1;
        }
        fn timerCallback(ctx: ?*anyopaque, _: *event_loop.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.timer_calls += 1;
        }
    };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const loop = (instance_map.getPtrs(id) orelse return error.InstanceMissing).loop;
    var state: State = .{};
    var notifier_handle: event_loop.Notifier = .{};
    var timer: event_loop.Timer = .{};
    notifier_handle.init(loop, &state, State.asyncCallback);
    timer.init(loop, &state, State.timerCallback);
    try testing.expect(notifier_handle.notify());
    try timer.startAt(100);
    try testing.expectEqual(@as(i64, 100), engine.testing.advance(id, 99));
    try testing.expectEqual(@as(u8, 1), state.async_calls);
    try testing.expectEqual(@as(u8, 0), state.timer_calls);
    _ = engine.testing.advance(id, 100);
    try testing.expectEqual(@as(u8, 1), state.timer_calls);
    notifier_handle.close();
    timer.close();
}

test "native event notification: blocking timer callback posts a dispatch task" {
    const State = struct {
        const Self = @This();
        id: i32,
        task_calls: u8 = 0,
        fn task(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.task_calls += 1;
            engine.stopEventLoop(self.id);
        }
        fn timerCallback(ctx: ?*anyopaque, _: *event_loop.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            std.debug.assert(dispatch.postTask(self.id, .{ .ctx = self, .run = Self.task }));
        }
    };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const loop = (instance_map.getPtrs(id) orelse return error.InstanceMissing).loop;
    var state = State{ .id = id };
    var timer: event_loop.Timer = .{};
    timer.init(loop, &state, State.timerCallback);
    try timer.startAfter(1);
    engine.blockOnLoopFor(id, 1_000);
    try testing.expectEqual(@as(u8, 1), state.task_calls);
    timer.close();
}

test "native event notification: timer rearm waits for a later blocking turn" {
    const State = struct {
        const Self = @This();
        loop: *event_loop.Driver,
        id: i32,
        calls: u8 = 0,
        task_ran: bool = false,
        task_ran_before_second: bool = false,
        fn task(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.task_ran = true;
        }
        fn callback(ctx: ?*anyopaque, timer: *event_loop.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.calls == 1) {
                timer.startAt(0) catch unreachable;
                std.debug.assert(dispatch.postTask(self.id, .{ .ctx = self, .run = Self.task }));
            } else {
                self.task_ran_before_second = self.task_ran;
                self.loop.requestStop();
            }
        }
    };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const loop = (instance_map.getPtrs(id) orelse return error.InstanceMissing).loop;
    var state = State{ .loop = loop, .id = id };
    var timer: event_loop.Timer = .{};
    timer.init(loop, &state, State.callback);
    try timer.startAfter(0);
    engine.blockOnLoopFor(id, 1_000);
    try testing.expectEqual(@as(u8, 2), state.calls);
    try testing.expect(state.task_ran_before_second);
    timer.close();
}
