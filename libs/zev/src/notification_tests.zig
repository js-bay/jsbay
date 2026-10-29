//! Public Notifier and Timer notification behavior.

const std = @import("std");
const zev = @import("zev");

test "async send from another thread runs on the owner" {
    const State = struct {
        const Self = @This();
        entered: zev.Waiter = .init,
        calls: std.atomic.Value(u8) = .init(0),
        thread_id: std.atomic.Value(u64) = .init(0),
        fn callback(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            _ = self.calls.fetchAdd(1, .seq_cst);
            self.thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
        }
        fn send(state: *Self, handle: *zev.Notifier) void {
            state.entered.signal();
            std.debug.assert(handle.notify());
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    defer state.entered.deinit();
    var handle: zev.Notifier = .{};
    handle.init(loop, &state, State.callback);
    const before = state.entered.generation();
    const sender = try std.Thread.spawn(.{}, State.send, .{ &state, &handle });
    try std.testing.expect(state.entered.waitUntilChange(before, 1_000));
    sender.join();
    loop.dispatchEvents(zev.monotonicMilliseconds());
    try std.testing.expectEqual(@as(u8, 1), state.calls.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, @intCast(std.Thread.getCurrentId())), state.thread_id.load(.seq_cst));
    handle.close();
}

test "async notifications coalesce and self-send waits for the next dispatch" {
    const State = struct {
        const Self = @This();
        calls: u8 = 0,
        fn callback(ctx: ?*anyopaque, handle: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.calls == 1) std.debug.assert(handle.notify());
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    var handle: zev.Notifier = .{};
    handle.init(loop, &state, State.callback);
    try std.testing.expect(handle.notify());
    try std.testing.expect(handle.notify());
    loop.dispatchEvents(0);
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    loop.dispatchEvents(0);
    try std.testing.expectEqual(@as(u8, 2), state.calls);
    handle.close();
}

test "pending async reports an immediate deadline until consumed" {
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
    var state: State = .{};
    var handle: zev.Notifier = .{};
    handle.init(loop, &state, State.callback);
    try std.testing.expect(handle.notify());
    try std.testing.expectEqual(@as(?u64, 0), loop.nextDeadline());
    loop.dispatchEvents(0);
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    try std.testing.expectEqual(@as(?u64, null), loop.nextDeadline());
    handle.close();
}

test "host dispatch mode leaves event delivery to the host tick" {
    const State = struct {
        const Self = @This();
        calls: u8 = 0,
        fn callback(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
        fn tick(_: ?*anyopaque, _: u64) ?u64 {
            return null;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    var handle: zev.Notifier = .{};
    handle.init(loop, &state, State.callback);
    try std.testing.expect(handle.notify());
    _ = loop.runOnce(.{ .ctx = &state, .tick = State.tick, .event_dispatch = .host });
    try std.testing.expectEqual(@as(u8, 0), state.calls);
    loop.dispatchEvents(0);
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    handle.close();
}

test "async close discards pending work and can close another ready handle" {
    const State = struct {
        const Self = @This();
        other: *zev.Notifier,
        first_calls: u8 = 0,
        second_calls: u8 = 0,
        fn first(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.first_calls += 1;
            self.other.close();
        }
        fn second(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.second_calls += 1;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var second: zev.Notifier = .{};
    var state = State{ .other = &second };
    var first: zev.Notifier = .{};
    first.init(loop, &state, State.first);
    second.init(loop, &state, State.second);
    try std.testing.expect(first.notify());
    try std.testing.expect(second.notify());
    loop.dispatchEvents(0);
    try std.testing.expectEqual(@as(u8, 1), state.first_calls);
    try std.testing.expectEqual(@as(u8, 0), state.second_calls);
    try std.testing.expect(!second.notify());
    first.close();
}

test "timers do not fire early and keep equal deadlines in FIFO order" {
    const State = struct {
        const Self = @This();
        trace: [4]u8 = undefined,
        len: usize = 0,
        fn first(ctx: ?*anyopaque, _: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.trace[self.len] = 1;
            self.len += 1;
        }
        fn second(ctx: ?*anyopaque, _: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.trace[self.len] = 2;
            self.len += 1;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    var first: zev.Timer = .{};
    var second: zev.Timer = .{};
    first.init(loop, &state, State.first);
    second.init(loop, &state, State.second);
    try first.startAt(100);
    try second.startAt(100);
    loop.dispatchEvents(99);
    try std.testing.expectEqual(@as(usize, 0), state.len);
    loop.dispatchEvents(100);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, state.trace[0..state.len]);
    try std.testing.expect(!first.isActive());
    first.close();
    second.close();
}

test "timer cancel and rearm defer the next callback to a later dispatch" {
    const State = struct {
        const Self = @This();
        calls: u8 = 0,
        fn callback(ctx: ?*anyopaque, timer: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.calls == 1) timer.startAt(100) catch unreachable;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    var timer: zev.Timer = .{};
    timer.init(loop, &state, State.callback);
    try timer.startAt(50);
    try std.testing.expect(timer.cancel());
    try std.testing.expect(!timer.cancel());
    loop.dispatchEvents(50);
    try std.testing.expectEqual(@as(u8, 0), state.calls);
    try timer.startAt(100);
    loop.dispatchEvents(100);
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    loop.dispatchEvents(100);
    try std.testing.expectEqual(@as(u8, 2), state.calls);
    timer.close();
}

test "timer reset replaces its existing deadline" {
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
    var state: State = .{};
    var timer: zev.Timer = .{};
    timer.init(loop, &state, State.callback);
    try timer.startAt(10);
    try timer.startAt(20);
    loop.dispatchEvents(10);
    try std.testing.expectEqual(@as(u8, 0), state.calls);
    loop.dispatchEvents(20);
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    timer.close();
}

test "timer callback can close another ready timer" {
    const State = struct {
        const Self = @This();
        other: *zev.Timer,
        first: u8 = 0,
        second: u8 = 0,
        fn firstCallback(ctx: ?*anyopaque, _: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.first += 1;
            self.other.close();
        }
        fn secondCallback(ctx: ?*anyopaque, _: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.second += 1;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var second: zev.Timer = .{};
    var state = State{ .other = &second };
    var first: zev.Timer = .{};
    first.init(loop, &state, State.firstCallback);
    second.init(loop, &state, State.secondCallback);
    try first.startAt(10);
    try second.startAt(10);
    loop.dispatchEvents(10);
    try std.testing.expectEqual(@as(u8, 1), state.first);
    try std.testing.expectEqual(@as(u8, 0), state.second);
    first.close();
}

test "notification callbacks may close and free their own handles" {
    const State = struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        calls: u8 = 0,
        fn asyncCallback(ctx: ?*anyopaque, handle: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            handle.close();
            self.allocator.destroy(handle);
        }
        fn timerCallback(ctx: ?*anyopaque, handle: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            handle.close();
            self.allocator.destroy(handle);
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state = State{ .allocator = std.testing.allocator };
    const notifier_handle = try std.testing.allocator.create(zev.Notifier);
    notifier_handle.* = .{};
    notifier_handle.init(loop, &state, State.asyncCallback);
    const timer = try std.testing.allocator.create(zev.Timer);
    timer.* = .{};
    timer.init(loop, &state, State.timerCallback);
    try std.testing.expect(notifier_handle.notify());
    try timer.startAt(10);
    loop.dispatchEvents(10);
    try std.testing.expectEqual(@as(u8, 2), state.calls);
}

test "recursive dispatch does not execute a notification twice" {
    const State = struct {
        const Self = @This();
        loop: *zev.Loop,
        second: *zev.Notifier,
        first_calls: u8 = 0,
        second_calls: u8 = 0,
        fn first(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.first_calls += 1;
            self.loop.dispatchEvents(0);
        }
        fn secondCallback(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.second_calls += 1;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var second: zev.Notifier = .{};
    var state = State{ .loop = loop, .second = &second };
    var first: zev.Notifier = .{};
    first.init(loop, &state, State.first);
    second.init(loop, &state, State.secondCallback);
    try std.testing.expect(first.notify());
    try std.testing.expect(second.notify());
    loop.dispatchEvents(0);
    try std.testing.expectEqual(@as(u8, 1), state.first_calls);
    try std.testing.expectEqual(@as(u8, 1), state.second_calls);
    first.close();
    second.close();
}

test "timer registration failure leaves earlier timers active" {
    const State = struct {
        fn callback(_: ?*anyopaque, _: *zev.Timer) void {}
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const loop = try zev.Loop.create(failing.allocator());
    defer loop.destroy();
    var handles: [128]zev.Timer = undefined;
    handles[0] = .{};
    handles[0].init(loop, null, State.callback);
    try handles[0].startAt(10);
    // The first live timer is our preservation baseline. From here, force the next allocation or in-place resize to fail without assuming how much spare capacity the implementation chose.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    var successful: usize = 1;
    var failed: ?usize = null;
    while (successful < handles.len) : (successful += 1) {
        handles[successful] = .{};
        handles[successful].init(loop, null, State.callback);
        handles[successful].startAt(@intCast(10 + successful)) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed = successful;
            break;
        };
    }
    const failed_index = failed orelse return error.ExpectedOutOfMemory;
    try std.testing.expect(successful > 0);
    try std.testing.expect(handles[0].isActive());
    try std.testing.expect(!handles[failed_index].isActive());
    try std.testing.expectEqual(@as(?u64, 10), loop.nextDeadline());
    for (handles[0 .. failed_index + 1]) |*handle| handle.close();
}

test "dispatching an already queued timer does not allocate" {
    const State = struct {
        const Self = @This();
        calls: u8 = 0,
        fn callback(ctx: ?*anyopaque, _: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const loop = try zev.Loop.create(failing.allocator());
    defer loop.destroy();
    var state: State = .{};
    var timer: zev.Timer = .{};
    timer.init(loop, &state, State.callback);
    try timer.startAt(10);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    loop.dispatchEvents(10);
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    timer.close();
}

test "run wakes for the earlier timer deadline and host deadline" {
    const State = struct {
        const Self = @This();
        loop: *zev.Loop,
        timer: *zev.Timer,
        timer_calls: u8 = 0,
        ticks: u8 = 0,
        fn timerCallback(ctx: ?*anyopaque, _: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.timer_calls += 1;
            self.loop.requestStop();
        }
        fn tick(ctx: ?*anyopaque, now_ms: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.ticks += 1;
            return now_ms + 1_000;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var timer: zev.Timer = .{};
    var state = State{ .loop = loop, .timer = &timer };
    timer.init(loop, &state, State.timerCallback);
    try timer.startAfter(10);
    loop.run(.{ .ctx = &state, .tick = State.tick });
    try std.testing.expectEqual(@as(u8, 1), state.timer_calls);
    try std.testing.expect(state.ticks >= 1);
    timer.close();
}

test "standalone dispatch callback cannot reenter runOnce" {
    const State = struct {
        const Self = @This();
        loop: *zev.Loop,
        callbacks: u8 = 0,
        host_ticks: u8 = 0,
        fn tick(ctx: ?*anyopaque, _: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.host_ticks += 1;
            return null;
        }
        fn callback(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.callbacks += 1;
            _ = self.loop.runOnce(.{ .ctx = self, .tick = Self.tick });
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state = State{ .loop = loop };
    var notifier_handle: zev.Notifier = .{};
    notifier_handle.init(loop, &state, State.callback);
    try std.testing.expect(notifier_handle.notify());
    loop.dispatchEvents(0);
    try std.testing.expectEqual(@as(u8, 1), state.callbacks);
    try std.testing.expectEqual(@as(u8, 0), state.host_ticks);
    notifier_handle.close();
}

test "callback recursive run returns without changing the outer run" {
    const State = struct {
        const Self = @This();
        loop: *zev.Loop,
        callbacks: u8 = 0,
        outer_ticks: u8 = 0,
        nested_ticks: u8 = 0,
        fn outerTick(ctx: ?*anyopaque, _: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.outer_ticks += 1;
            return null;
        }
        fn nestedTick(ctx: ?*anyopaque, _: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.nested_ticks += 1;
            return null;
        }
        fn callback(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.callbacks += 1;
            self.loop.run(.{
                .ctx = self,
                .tick = Self.nestedTick,
                .deadline_ms = zev.monotonicMilliseconds(),
            });
            self.loop.requestStop();
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state = State{ .loop = loop };
    var notifier_handle: zev.Notifier = .{};
    notifier_handle.init(loop, &state, State.callback);
    try std.testing.expect(notifier_handle.notify());
    loop.run(.{ .ctx = &state, .tick = State.outerTick, .deadline_ms = zev.monotonicMilliseconds() + 100 });
    try std.testing.expectEqual(@as(u8, 1), state.callbacks);
    try std.testing.expectEqual(@as(u8, 0), state.outer_ticks);
    try std.testing.expectEqual(@as(u8, 0), state.nested_ticks);
    notifier_handle.close();
}

test "loop destruction detaches active handles without callbacks" {
    const State = struct {
        const Self = @This();
        calls: u8 = 0,
        fn asyncCallback(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
        fn timerCallback(ctx: ?*anyopaque, _: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    var state: State = .{};
    var notifier_handle: zev.Notifier = .{};
    var timer: zev.Timer = .{};
    notifier_handle.init(loop, &state, State.asyncCallback);
    timer.init(loop, &state, State.timerCallback);
    try std.testing.expect(notifier_handle.notify());
    try timer.startAt(0);
    loop.destroy();
    try std.testing.expectEqual(@as(u8, 0), state.calls);
    try std.testing.expect(!notifier_handle.notify());
}

test "closed handles remain inert after their loop is destroyed" {
    const State = struct {
        fn asyncCallback(_: ?*anyopaque, _: *zev.Notifier) void {}
        fn timerCallback(_: ?*anyopaque, _: *zev.Timer) void {}
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    var notifier_handle: zev.Notifier = .{};
    var timer: zev.Timer = .{};
    notifier_handle.init(loop, null, State.asyncCallback);
    timer.init(loop, null, State.timerCallback);
    notifier_handle.close();
    timer.close();
    loop.destroy();

    notifier_handle.close();
    timer.close();
    try std.testing.expect(!notifier_handle.notify());
    try std.testing.expectError(error.Closed, timer.startAt(1));
    try std.testing.expect(!timer.cancel());
    try std.testing.expect(!timer.isActive());
}
