//! Behavioral tests for the host-owned work contract of `Loop`.

const std = @import("std");
const zev = @import("zev");
const Loop = zev.Loop;
const RunOptions = zev.RunOptions;

const Trace = struct {
    values: [16]u8 = undefined,
    len: usize = 0,
    fn add(self: *Trace, value: u8) void {
        self.values[self.len] = value;
        self.len += 1;
    }
};

const HostQueue = struct {
    mutex: zev.Mutex = .{},
    items: std.ArrayList(u8) = .empty,
    head: usize = 0,
    fn deinit(self: *HostQueue) void {
        self.items.deinit(std.testing.allocator);
        self.mutex.deinit();
    }
    fn append(self: *HostQueue, value: u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.items.append(std.testing.allocator, value) catch unreachable;
    }
    fn takeOne(self: *HostQueue) ?u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.head >= self.items.items.len) return null;
        const value = self.items.items[self.head];
        self.head += 1;
        if (self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= 32) {
            const remain = self.items.items[self.head..];
            var write: usize = 0;
            while (write < remain.len) : (write += 1) {
                self.items.items[write] = remain[write];
            }
            self.items.shrinkRetainingCapacity(remain.len);
            self.head = 0;
        }
        return value;
    }
};

test "runOnce delegates one host tick and returns its deadline" {
    const State = struct {
        const Self = @This();
        calls: u8 = 0,
        fn tick(ctx: ?*anyopaque, _: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            return 321;
        }
    };
    const loop = try Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    const options: RunOptions = .{ .ctx = &state, .tick = State.tick };
    const deadline = loop.runOnce(options);
    try std.testing.expectEqual(@as(?u64, 321), deadline);
    try std.testing.expectEqual(@as(u8, 1), state.calls);
}

test "runOnce honors host stop before calling the host" {
    const State = struct {
        const Self = @This();
        calls: u8 = 0,
        fn tick(ctx: ?*anyopaque, _: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            return null;
        }
        fn shouldStop(_: ?*anyopaque) bool {
            return true;
        }
    };
    const loop = try Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    try std.testing.expectEqual(@as(?u64, null), loop.runOnce(.{
        .ctx = &state,
        .tick = State.tick,
        .should_stop = State.shouldStop,
    }));
    try std.testing.expectEqual(@as(u8, 0), state.calls);
}

test "the host chooses the order of its work sources" {
    const State = struct {
        const Self = @This();
        task_pending: bool = true,
        timer_pending: bool = true,
        trace: Trace = .{},
        fn tick(ctx: ?*anyopaque, _: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.timer_pending) {
                self.timer_pending = false;
                self.trace.add(2);
            } else if (self.task_pending) {
                self.task_pending = false;
                self.trace.add(1);
            }
            return null;
        }
    };
    const loop = try Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    _ = loop.runOnce(.{ .ctx = &state, .tick = State.tick });
    _ = loop.runOnce(.{ .ctx = &state, .tick = State.tick });
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, state.trace.values[0..state.trace.len]);
}

test "the host can make one item of progress per runOnce" {
    const State = struct {
        const Self = @This();
        pending: u8 = 3,
        completed: u8 = 0,
        fn tick(ctx: ?*anyopaque, _: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.pending != 0) {
                self.pending -= 1;
                self.completed += 1;
            }
            return null;
        }
    };
    const loop = try Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state: State = .{};
    _ = loop.runOnce(.{ .ctx = &state, .tick = State.tick });
    try std.testing.expectEqual(@as(u8, 1), state.completed);
    try std.testing.expectEqual(@as(u8, 2), state.pending);
    _ = loop.runOnce(.{ .ctx = &state, .tick = State.tick });
    try std.testing.expectEqual(@as(u8, 2), state.completed);
}

test "run waits for a host deadline" {
    const State = struct {
        const Self = @This();
        loop: *Loop,
        deadline: ?u64 = null,
        calls: u8 = 0,
        fn tick(ctx: ?*anyopaque, now_ms: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            const deadline = self.deadline orelse {
                const first_deadline = now_ms + 10;
                self.deadline = first_deadline;
                return first_deadline;
            };
            if (now_ms >= deadline) self.loop.requestStop();
            return deadline;
        }
    };
    const loop = try Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state = State{ .loop = loop };
    loop.run(.{ .ctx = &state, .tick = State.tick, .deadline_ms = zev.monotonicMilliseconds() + 1_000 });
    try std.testing.expect(state.calls >= 2);
}

test "run stops when the host requests it and can be reused" {
    const State = struct {
        const Self = @This();
        loop: *Loop,
        calls: u8 = 0,
        stop: bool = true,
        fn tick(ctx: ?*anyopaque, _: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.stop) self.loop.requestStop();
            return null;
        }
    };
    const loop = try Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state = State{ .loop = loop };
    loop.run(.{ .ctx = &state, .tick = State.tick });
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    state.stop = false;
    loop.run(.{
        .ctx = &state,
        .tick = State.tick,
        .should_stop = struct {
            fn stop(ctx: ?*anyopaque) bool {
                const subject: *State = @ptrCast(@alignCast(ctx.?));
                return subject.calls == 2;
            }
        }.stop,
    });
    try std.testing.expectEqual(@as(u8, 2), state.calls);
}

test "a host queue append and wake resumes a blocking run" {
    const State = struct {
        const Self = @This();
        loop: *Loop,
        queue: *HostQueue,
        entered: zev.Waiter = .init,
        processed: std.atomic.Value(u8) = .init(0),
        fn tick(ctx: ?*anyopaque, _: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.queue.takeOne()) |_| {
                _ = self.processed.fetchAdd(1, .seq_cst);
                self.loop.requestStop();
            }
            self.entered.signal();
            return null;
        }
        fn runLoop(state: *Self) void {
            state.loop.run(.{ .ctx = state, .tick = Self.tick });
        }
    };
    const loop = try Loop.create(std.testing.allocator);
    defer loop.destroy();
    var queue: HostQueue = .{};
    defer queue.deinit();
    var state = State{ .loop = loop, .queue = &queue };
    defer state.entered.deinit();
    const entered_before = state.entered.generation();
    const thread = try std.Thread.spawn(.{}, State.runLoop, .{&state});
    var joined = false;
    defer if (!joined) {
        loop.requestStop();
        thread.join();
    };
    try std.testing.expect(state.entered.waitUntilChange(entered_before, 1_000));
    queue.append(1);
    loop.wake();
    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(u8, 1), state.processed.load(.seq_cst));
}

test "a wake during host work is observed before run waits" {
    const State = struct {
        const Self = @This();
        loop: *Loop,
        entered_work: zev.Waiter = .init,
        wake_sent: zev.Waiter = .init,
        calls: u8 = 0,
        fn tick(ctx: ?*anyopaque, now_ms: u64) ?u64 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.calls == 1) {
                const before = self.wake_sent.generation();
                self.entered_work.signal();
                std.debug.assert(self.wake_sent.waitUntilChange(before, 1_000));
                return now_ms + 1_000;
            }
            self.loop.requestStop();
            return null;
        }
        fn wakeDuringWork(state: *Self, entered_before: u64) void {
            std.debug.assert(state.entered_work.waitUntilChange(entered_before, 1_000));
            state.loop.wake();
            state.wake_sent.signal();
        }
    };
    const loop = try Loop.create(std.testing.allocator);
    defer loop.destroy();
    var state = State{ .loop = loop };
    defer state.entered_work.deinit();
    defer state.wake_sent.deinit();
    const entered_before = state.entered_work.generation();
    const thread = try std.Thread.spawn(.{}, State.wakeDuringWork, .{ &state, entered_before });
    loop.run(.{ .ctx = &state, .tick = State.tick });
    thread.join();
    try std.testing.expectEqual(@as(u8, 2), state.calls);
}
