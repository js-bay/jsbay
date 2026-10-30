//! Public Notifier and Timer notification behavior.

const std = @import("std");
const zev = @import("zev");

/// Shared virtual clock for timer due-check tests. Dispatch always reads `Loop.nowMs`.
const VirtualClock = struct {
    now: u64 = 0,
    fn read(ctx: ?*anyopaque) u64 {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.now;
    }
};

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
    loop.dispatchEvents();
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
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 2), state.calls);
    handle.close();
}

test "pending notify coalesces without an extra wake" {
    const State = struct {
        const Self = @This();
        entered: zev.Waiter = .init,
        fn callback(_: ?*anyopaque, _: *zev.Notifier) void {}
        fn send(state: *Self, handle: *zev.Notifier, done: *zev.Waiter) void {
            state.entered.signal();
            std.debug.assert(handle.notify());
            std.debug.assert(handle.notify());
            done.signal();
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    defer state.entered.deinit();
    var done: zev.Waiter = .init;
    defer done.deinit();
    var handle: zev.Notifier = .{};
    handle.init(loop, &state, State.callback);
    const before = loop.wakeGeneration();
    const entered_before = state.entered.generation();
    const done_before = done.generation();
    const sender = try std.Thread.spawn(.{}, State.send, .{ &state, &handle, &done });
    try std.testing.expect(state.entered.waitUntilChange(entered_before, 1_000));
    try std.testing.expect(done.waitUntilChange(done_before, 1_000));
    sender.join();
    // Remote first notify wakes once; the second pending notify must not bump generation again.
    try std.testing.expect(loop.wakeGeneration() == before + 1);
    loop.dispatchEvents();
    handle.close();
}

test "notifier returns to idle after a successful dispatch" {
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
    try std.testing.expectEqual(.idle, handle.state);
    try std.testing.expect(handle.notify());
    try std.testing.expectEqual(.pending, handle.state);
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    try std.testing.expectEqual(.idle, handle.state);
    try std.testing.expectEqual(@as(?u64, null), loop.nextDeadline());
    try std.testing.expect(handle.notify());
    try std.testing.expectEqual(.pending, handle.state);
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
    loop.dispatchEvents();
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
    loop.dispatchEvents();
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
    loop.dispatchEvents();
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
    var clock: VirtualClock = .{};
    loop.setClock(&clock, VirtualClock.read);
    defer loop.setClock(null, null);
    var state: State = .{};
    var first: zev.Timer = .{};
    var second: zev.Timer = .{};
    first.init(loop, &state, State.first);
    second.init(loop, &state, State.second);
    try first.startAt(100);
    try second.startAt(100);
    clock.now = 99;
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(usize, 0), state.len);
    clock.now = 100;
    loop.dispatchEvents();
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
    var clock: VirtualClock = .{};
    loop.setClock(&clock, VirtualClock.read);
    defer loop.setClock(null, null);
    var state: State = .{};
    var timer: zev.Timer = .{};
    timer.init(loop, &state, State.callback);
    try timer.startAt(50);
    try std.testing.expect(timer.cancel());
    try std.testing.expect(!timer.cancel());
    clock.now = 50;
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 0), state.calls);
    try timer.startAt(100);
    clock.now = 100;
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    loop.dispatchEvents();
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
    var clock: VirtualClock = .{};
    loop.setClock(&clock, VirtualClock.read);
    defer loop.setClock(null, null);
    var state: State = .{};
    var timer: zev.Timer = .{};
    timer.init(loop, &state, State.callback);
    try timer.startAt(10);
    try timer.startAt(20);
    clock.now = 10;
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 0), state.calls);
    clock.now = 20;
    loop.dispatchEvents();
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
    var clock: VirtualClock = .{ .now = 10 };
    loop.setClock(&clock, VirtualClock.read);
    defer loop.setClock(null, null);
    var second: zev.Timer = .{};
    var state = State{ .other = &second };
    var first: zev.Timer = .{};
    first.init(loop, &state, State.firstCallback);
    second.init(loop, &state, State.secondCallback);
    try first.startAt(10);
    try second.startAt(10);
    loop.dispatchEvents();
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
    var clock: VirtualClock = .{ .now = 10 };
    loop.setClock(&clock, VirtualClock.read);
    defer loop.setClock(null, null);
    var state = State{ .allocator = std.testing.allocator };
    const notifier_handle = try std.testing.allocator.create(zev.Notifier);
    notifier_handle.* = .{};
    notifier_handle.init(loop, &state, State.asyncCallback);
    const timer = try std.testing.allocator.create(zev.Timer);
    timer.* = .{};
    timer.init(loop, &state, State.timerCallback);
    try std.testing.expect(notifier_handle.notify());
    try timer.startAt(10);
    loop.dispatchEvents();
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
            self.loop.dispatchEvents();
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
    loop.dispatchEvents();
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
    var clock: VirtualClock = .{ .now = 10 };
    loop.setClock(&clock, VirtualClock.read);
    defer loop.setClock(null, null);
    var state: State = .{};
    var timer: zev.Timer = .{};
    timer.init(loop, &state, State.callback);
    try timer.startAt(10);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    timer.close();
}

test "run wakes for the earlier timer deadline and host deadline" {
    const Clock = struct {
        now: u64 = 0,
        fn read(ctx: ?*anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.now;
        }
    };
    const State = struct {
        const Self = @This();
        loop: *zev.Loop,
        clock: *Clock,
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
        fn advance(clock: *Clock, loop: *zev.Loop) void {
            zev.sleepMilliseconds(1);
            clock.now = 10;
            loop.wake();
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var clock: Clock = .{};
    loop.setClock(&clock, Clock.read);
    var timer: zev.Timer = .{};
    var state = State{ .loop = loop, .clock = &clock };
    timer.init(loop, &state, State.timerCallback);
    try timer.startAfter(10);
    const advancer = try std.Thread.spawn(.{}, State.advance, .{ &clock, loop });
    defer advancer.join();
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
    loop.dispatchEvents();
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

test "owner-thread notify and startAt skip the waiter wake" {
    const State = struct {
        const Self = @This();
        rearm: ?*zev.Notifier = null,
        timer: ?*zev.Timer = null,
        seen_before_nested: u64 = 0,
        nested_wake: u64 = 0,
        fn onNotify(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.rearm) |handle| {
                self.seen_before_nested = handle.loop.?.wakeGeneration();
                std.debug.assert(handle.notify());
                self.nested_wake = handle.loop.?.wakeGeneration();
            }
            if (self.timer) |timer| {
                const before = timer.loop.?.wakeGeneration();
                timer.startAt(999) catch unreachable;
                // Nested startAt while dispatching must not wake.
                std.debug.assert(timer.loop.?.wakeGeneration() == before);
            }
        }
        fn onTimer(_: ?*anyopaque, _: *zev.Timer) void {}
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    try std.testing.expect(loop.isOwnerThread());
    var state: State = .{};
    var notifier_handle: zev.Notifier = .{};
    var rearm: zev.Notifier = .{};
    var timer: zev.Timer = .{};
    notifier_handle.init(loop, &state, State.onNotify);
    rearm.init(loop, null, struct {
        fn cb(_: ?*anyopaque, _: *zev.Notifier) void {}
    }.cb);
    timer.init(loop, null, State.onTimer);
    state.rearm = &rearm;
    state.timer = &timer;

    // Idle owner must still wake (manual waiters on other threads).
    const idle_before = loop.wakeGeneration();
    try std.testing.expect(notifier_handle.notify());
    try std.testing.expect(loop.wakeGeneration() == idle_before + 1);

    loop.dispatchEvents();
    try std.testing.expectEqual(state.seen_before_nested, state.nested_wake);
    try std.testing.expectEqual(.pending, rearm.state);
    loop.dispatchEvents();
    try std.testing.expectEqual(.idle, rearm.state);
    notifier_handle.close();
    rearm.close();
    timer.close();
}

test "remote notify still wakes the owner waiter" {
    const State = struct {
        const Self = @This();
        entered: zev.Waiter = .init,
        fn callback(_: ?*anyopaque, _: *zev.Notifier) void {}
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
    const before = loop.wakeGeneration();
    const entered_before = state.entered.generation();
    const sender = try std.Thread.spawn(.{}, State.send, .{ &state, &handle });
    try std.testing.expect(state.entered.waitUntilChange(entered_before, 1_000));
    sender.join();
    try std.testing.expect(loop.wakeGeneration() != before);
    loop.dispatchEvents();
    handle.close();
}

test "dispatch budget preserves notifier-before-timer and leaves ready work" {
    const State = struct {
        const Self = @This();
        trace: [4]u8 = undefined,
        len: usize = 0,
        fn note(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.trace[self.len] = 1;
            self.len += 1;
        }
        fn tick(ctx: ?*anyopaque, _: *zev.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.trace[self.len] = 2;
            self.len += 1;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    var first: zev.Notifier = .{};
    var second: zev.Notifier = .{};
    var timer: zev.Timer = .{};
    first.init(loop, &state, State.note);
    second.init(loop, &state, State.note);
    timer.init(loop, &state, State.tick);
    try std.testing.expect(first.notify());
    try std.testing.expect(second.notify());
    try timer.startAt(0);
    loop.dispatchEventsLimited(2, null);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1 }, state.trace[0..state.len]);
    try std.testing.expectEqual(@as(?u64, 0), loop.nextDeadline());
    loop.dispatchEventsLimited(1, null);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 2 }, state.trace[0..state.len]);
    try std.testing.expectEqual(@as(?u64, null), loop.nextDeadline());
    first.close();
    second.close();
    timer.close();
}

test "runOnce default budget still drains a full ready snapshot" {
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
    var handles: [3]zev.Notifier = undefined;
    for (&handles) |*handle| {
        handle.* = .{};
        handle.init(loop, &state, State.callback);
        try std.testing.expect(handle.notify());
    }
    _ = loop.runOnce(.{});
    try std.testing.expectEqual(@as(u8, 3), state.calls);
    for (&handles) |*handle| handle.close();
}

test "virtual clock drives startAfter without wall time" {
    const Clock = struct {
        now: u64 = 1_000,
        fn read(ctx: ?*anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.now;
        }
    };
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
    var clock: Clock = .{};
    loop.setClock(&clock, Clock.read);
    var state: State = .{};
    var timer: zev.Timer = .{};
    timer.init(loop, &state, State.callback);
    try timer.startAfter(25);
    try std.testing.expectEqual(@as(?u64, 1_025), loop.nextDeadline());
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 0), state.calls);
    clock.now = 1_025;
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    timer.close();
    loop.setClock(null, null);
    _ = loop.nowMs();
}

test "idle owner notify wakes a different waiting thread" {
    // Regression: owner wake-skip must not apply while the create thread is idle, or a
    // manual waiter on another thread starves.
    const State = struct {
        const Self = @This();
        calls: u8 = 0,
        entered: zev.Waiter = .init,
        fn callback(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
        fn wait(self: *Self, loop: *zev.Loop, seen: u64, done: *zev.Waiter) void {
            self.entered.signal();
            _ = loop.waitForWake(seen, 2_000);
            done.signal();
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    defer state.entered.deinit();
    var handle: zev.Notifier = .{};
    handle.init(loop, &state, State.callback);
    var done: zev.Waiter = .init;
    defer done.deinit();
    const seen = loop.wakeGeneration();
    const entered_before = state.entered.generation();
    const done_before = done.generation();
    const waiter = try std.Thread.spawn(.{}, State.wait, .{ &state, loop, seen, &done });
    try std.testing.expect(state.entered.waitUntilChange(entered_before, 2_000));
    // Tiny yield so the waiter is likely blocked in waitForWake after signaling entered.
    zev.sleepMilliseconds(1);
    try std.testing.expect(handle.notify());
    try std.testing.expect(done.waitUntilChange(done_before, 2_000));
    waiter.join();
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    handle.close();
}

test "notify while ready with again still runs and re-arms across budget turns" {
    const Rearm = struct {
        const Self = @This();
        target: *zev.Notifier,
        calls: u8 = 0,
        fn on_second(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            _ = self.target.notify();
        }
        fn on_first(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 10;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var rearm: Rearm = undefined;
    var first: zev.Notifier = .{};
    var second: zev.Notifier = .{};
    first.init(loop, &rearm, Rearm.on_first);
    second.init(loop, &rearm, Rearm.on_second);
    rearm = .{ .target = &first };
    // Pending order: second then first, so budget=1 runs second and notifies first while ready.
    try std.testing.expect(second.notify());
    try std.testing.expect(first.notify());
    loop.dispatchEventsLimited(1, null);
    try std.testing.expectEqual(@as(u8, 1), rearm.calls);
    try std.testing.expectEqual(.ready, first.state);
    try std.testing.expect(first.again);
    loop.dispatchEventsLimited(1, null);
    try std.testing.expectEqual(@as(u8, 11), rearm.calls);
    try std.testing.expectEqual(.pending, first.state);
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 21), rearm.calls);
    try std.testing.expectEqual(.idle, first.state);
    first.close();
    second.close();
}

test "close during callback skips idle restore without losing the close" {
    const State = struct {
        const Self = @This();
        handle: *zev.Notifier = undefined,
        calls: u8 = 0,
        fn callback(ctx: ?*anyopaque, handle: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            handle.close();
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    var handle: zev.Notifier = .{};
    handle.init(loop, &state, State.callback);
    state.handle = &handle;
    try std.testing.expect(handle.notify());
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    try std.testing.expectEqual(.closed, handle.state);
    try std.testing.expect(!handle.notify());
}

test "nested notify during callback stays pending after idle-restore path" {
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
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    try std.testing.expectEqual(.pending, handle.state);
    loop.dispatchEvents();
    try std.testing.expectEqual(@as(u8, 2), state.calls);
    try std.testing.expectEqual(.idle, handle.state);
    handle.close();
}

test "dispatch time budget stops further callbacks under a virtual clock" {
    const Clock = struct {
        now: u64 = 1_000,
        fn read(ctx: ?*anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.now;
        }
    };
    const State = struct {
        const Self = @This();
        clock: *Clock,
        calls: u8 = 0,
        fn callback(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            // Advance virtual time past the turn's time budget after the first callback.
            self.clock.now += 10;
        }
    };
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var clock: Clock = .{};
    loop.setClock(&clock, Clock.read);
    var state: State = .{ .clock = &clock };
    var first: zev.Notifier = .{};
    var second: zev.Notifier = .{};
    first.init(loop, &state, State.callback);
    second.init(loop, &state, State.callback);
    try std.testing.expect(first.notify());
    try std.testing.expect(second.notify());
    loop.dispatchEventsLimited(null, 5);
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    try std.testing.expectEqual(@as(?u64, 0), loop.nextDeadline());
    loop.dispatchEventsLimited(null, 5);
    try std.testing.expectEqual(@as(u8, 2), state.calls);
    try std.testing.expectEqual(@as(?u64, null), loop.nextDeadline());
    first.close();
    second.close();
    loop.setClock(null, null);
}

test "runOnce with exhausted count budget still reports immediate deadline" {
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
    var handles: [2]zev.Notifier = undefined;
    for (&handles) |*handle| {
        handle.* = .{};
        handle.init(loop, &state, State.callback);
        try std.testing.expect(handle.notify());
    }
    const next = loop.runOnce(.{ .dispatch_budget = 1 });
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    try std.testing.expectEqual(@as(?u64, loop.nowMs()), next);
    _ = loop.runOnce(.{});
    try std.testing.expectEqual(@as(u8, 2), state.calls);
    for (&handles) |*handle| handle.close();
}

test "beginRun enables owner wake-skip for the blocking-run window" {
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();
    var handle: zev.Notifier = .{};
    handle.init(loop, null, struct {
        fn cb(_: ?*anyopaque, _: *zev.Notifier) void {}
    }.cb);
    defer handle.close();

    try std.testing.expect(!loop.isRunning());
    const idle_before = loop.wakeGeneration();
    try std.testing.expect(handle.notify());
    try std.testing.expectEqual(idle_before + 1, loop.wakeGeneration());
    loop.dispatchEvents();

    try std.testing.expect(loop.beginRun());
    try std.testing.expect(loop.isRunning());
    try std.testing.expect(!loop.beginRun()); // nested begin rejected
    const running_before = loop.wakeGeneration();
    try std.testing.expect(handle.notify());
    try std.testing.expectEqual(running_before, loop.wakeGeneration());
    loop.dispatchEvents();
    try std.testing.expect(loop.isRunning());
    loop.requestStop();
    try std.testing.expect(loop.isRunning()); // stopped still in session until endRun
    const after_stop = loop.wakeGeneration();
    try std.testing.expect(handle.notify());
    try std.testing.expectEqual(after_stop, loop.wakeGeneration());
    loop.endRun();
    try std.testing.expect(!loop.isRunning());
}

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
