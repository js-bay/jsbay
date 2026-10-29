//! Contracts owned by the engine's native dispatch queue.

const std = @import("std");
const testing = std.testing;
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const js_scheduler = @import("../runtime/js_scheduler.zig");
const helpers = @import("test_helpers.zig");

test "debugger pause drains only explicit control tasks" {
    const State = struct {
        const Self = @This();
        trace: [2]u8 = undefined,
        len: usize = 0,

        fn runApplication(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.trace[self.len] = 'a';
            self.len += 1;
        }

        fn runControl(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.trace[self.len] = 'c';
            self.len += 1;
        }
    };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var state: State = .{};
    try testing.expect(dispatch.postTask(id, .{ .ctx = &state, .run = State.runApplication }));
    try testing.expect(dispatch.postTask(id, .{ .ctx = &state, .run = State.runControl, .debugger_control = true }));

    var execution = js_scheduler.beginExecution(id) orelse return error.MissingScheduler;
    defer execution.end();
    try testing.expectEqual(@as(usize, 1), dispatch.drainPausedDebuggerControl(id));
    try testing.expectEqualStrings("c", state.trace[0..state.len]);
    try testing.expectEqual(@as(usize, 0), dispatch.tickInstance(id));

    execution.end();
    try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
    try testing.expectEqualStrings("ca", state.trace[0..state.len]);
}

test "dispatch task posted by a callback waits for the next tick" {
    const State = struct {
        const Self = @This();
        id: i32,
        first_runs: u8 = 0,
        second_runs: u8 = 0,

        fn second(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.second_runs += 1;
        }
        fn first(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.first_runs += 1;
            // This also proves dispatch does not retain its queue lock while invoking a callback.
            std.debug.assert(dispatch.postTask(self.id, .{ .ctx = self, .run = Self.second }));
        }
    };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var state = State{ .id = id };
    try testing.expect(dispatch.postTask(id, .{ .ctx = &state, .run = State.first }));

    try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
    try testing.expectEqual(@as(u8, 1), state.first_runs);
    try testing.expectEqual(@as(u8, 0), state.second_runs);
    try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
    try testing.expectEqual(@as(u8, 1), state.second_runs);
}

test "engine destroy cancels a pending dispatch task once and rejects reposting" {
    const Completion = struct { calls: u8 = 0 };
    const State = struct {
        const Self = @This();
        id: i32,
        runs: u8 = 0,
        cancels: u8 = 0,
        repost_accepted: bool = true,

        fn run(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.runs += 1;
        }
        fn cancel(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.cancels += 1;
            self.repost_accepted = dispatch.postTask(self.id, .{ .ctx = self, .run = Self.run });
        }
        fn complete(ctx: ?*anyopaque) void {
            const completion: *Completion = @ptrCast(@alignCast(ctx.?));
            completion.calls += 1;
        }
    };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var completion: Completion = .{};
    var state = State{ .id = id };
    errdefer engine.destroy(id);
    try testing.expect(dispatch.postTask(id, .{
        .ctx = &state,
        .run = State.run,
        .cancel = State.cancel,
        .complete = State.complete,
        .completion_ctx = &completion,
    }));

    engine.destroy(id);
    try testing.expectEqual(@as(u8, 0), state.runs);
    try testing.expectEqual(@as(u8, 1), state.cancels);
    try testing.expect(!state.repost_accepted);
    try testing.expectEqual(@as(u8, 1), completion.calls);
}

test "dispatch owner cancellation preserves FIFO work for other owners" {
    const State = struct {
        const Self = @This();
        trace: [8]u8 = undefined,
        len: usize = 0,
        cancels: u8 = 0,

        fn add(self: *Self, value: u8) void {
            self.trace[self.len] = value;
            self.len += 1;
        }
    };
    const Entry = struct {
        state: *State,
        value: u8,

        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.state.add(self.value);
        }
        fn cancel(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.state.cancels += 1;
        }
    };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var state: State = .{};
    var owner_a: u8 = 0;
    var owner_b: u8 = 0;
    var owner_c: u8 = 0;
    var first = Entry{ .state = &state, .value = 1 };
    var second = Entry{ .state = &state, .value = 2 };
    var third = Entry{ .state = &state, .value = 3 };
    var fourth = Entry{ .state = &state, .value = 4 };
    try testing.expect(dispatch.postTask(id, .{ .ctx = &first, .run = Entry.run, .cancel = Entry.cancel, .owner = &owner_a }));
    try testing.expect(dispatch.postTask(id, .{ .ctx = &second, .run = Entry.run, .cancel = Entry.cancel, .owner = &owner_b }));
    try testing.expect(dispatch.postTask(id, .{ .ctx = &third, .run = Entry.run, .cancel = Entry.cancel, .owner = &owner_a }));
    try testing.expect(dispatch.postTask(id, .{ .ctx = &fourth, .run = Entry.run, .cancel = Entry.cancel, .owner = &owner_c }));

    dispatch.releaseTasksForOwner(id, &owner_a);
    try testing.expectEqual(@as(u8, 2), state.cancels);
    try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
    try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
    try testing.expectEqualSlices(u8, &.{ 2, 4 }, state.trace[0..state.len]);
}

test "dispatch records the owner thread and completes with completion context" {
    const Completion = struct { calls: u8 = 0 };
    const State = struct {
        const Self = @This();
        runs: u8 = 0,
        fn run(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.runs += 1;
        }
        fn complete(ctx: ?*anyopaque) void {
            const completion: *Completion = @ptrCast(@alignCast(ctx.?));
            completion.calls += 1;
        }
    };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var state: State = .{};
    var completion: Completion = .{};
    var executed_thread = std.atomic.Value(u64).init(0);
    try testing.expect(dispatch.postTask(id, .{
        .ctx = &state,
        .run = State.run,
        .complete = State.complete,
        .completion_ctx = &completion,
        .thread_id_slot = &executed_thread,
    }));

    try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
    try testing.expectEqual(@as(u8, 1), state.runs);
    try testing.expectEqual(@as(u8, 1), completion.calls);
    try testing.expectEqual(@as(u64, @intCast(std.Thread.getCurrentId())), executed_thread.load(.seq_cst));
}

// The queue is FIFO, so each producer's tasks run in posting order; every accepted task runs exactly once; a callback can post a task; and the queue drains without blocking the owner.
const BurstProducers = 4;
const BurstPerProducer = 500;
const BurstRepostEvery = 50;
const BurstReposts = BurstProducers * (BurstPerProducer / BurstRepostEvery);

const Burst = struct {
    id: i32,
    items: []Item,
    reposts: []Item,
    last_seq: [BurstProducers]std.atomic.Value(i32) = @splat(std.atomic.Value(i32).init(-1)),
    order_violations: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    post_failures: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ran: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    reposts_ran: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const Item = struct {
        burst: *Burst,
        producer: usize,
        seq: i32,
    };

    fn runItem(ctx: ?*anyopaque) void {
        const item: *Item = @ptrCast(@alignCast(ctx.?));
        const burst = item.burst;
        const previous = burst.last_seq[item.producer].swap(item.seq, .seq_cst);
        if (previous != item.seq - 1) _ = burst.order_violations.fetchAdd(1, .seq_cst);
        _ = burst.ran.fetchAdd(1, .seq_cst);
        if (@mod(item.seq + 1, BurstRepostEvery) == 0) {
            const slot = item.producer * (BurstPerProducer / BurstRepostEvery) + @as(usize, @intCast(@divExact(item.seq + 1, BurstRepostEvery) - 1));
            const follow_up = &burst.reposts[slot];
            if (!dispatch.postTask(burst.id, .{ .ctx = follow_up, .run = runRepost })) {
                _ = burst.post_failures.fetchAdd(1, .seq_cst);
            }
        }
    }

    fn runRepost(ctx: ?*anyopaque) void {
        const item: *Item = @ptrCast(@alignCast(ctx.?));
        _ = item.burst.reposts_ran.fetchAdd(1, .seq_cst);
    }

    fn produce(self: *Burst, producer: usize) void {
        var seq: i32 = 0;
        while (seq < BurstPerProducer) : (seq += 1) {
            const item = &self.items[producer * BurstPerProducer + @as(usize, @intCast(seq))];
            item.* = .{ .burst = self, .producer = producer, .seq = seq };
            if (!dispatch.postTask(self.id, .{ .ctx = item, .run = runItem })) {
                _ = self.post_failures.fetchAdd(1, .seq_cst);
            }
        }
    }
};

test "dispatch queue absorbs a multi-producer burst in per-producer order without stalling" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const items = try testing.allocator.alloc(Burst.Item, BurstProducers * BurstPerProducer);
    defer testing.allocator.free(items);
    const reposts = try testing.allocator.alloc(Burst.Item, BurstReposts);
    defer testing.allocator.free(reposts);
    var burst = Burst{ .id = id, .items = items, .reposts = reposts };
    for (reposts) |*r| r.* = .{ .burst = &burst, .producer = 0, .seq = 0 };

    var threads: [BurstProducers]std.Thread = undefined;
    for (&threads, 0..) |*t, producer| t.* = try std.Thread.spawn(.{}, Burst.produce, .{ &burst, producer });
    var joined = false;
    defer if (!joined) for (threads) |t| t.join();

    // The owner keeps ticking while producers are still posting; a bounded spin turns a stall into a failure instead of a hang.
    const expected: u32 = BurstProducers * BurstPerProducer + BurstReposts;
    var spins: usize = 0;
    while (burst.ran.load(.seq_cst) + burst.reposts_ran.load(.seq_cst) < expected) : (spins += 1) {
        if (spins > 20_000_000) return error.DispatchQueueStalled;
        if (dispatch.tickInstance(id) == 0) std.Thread.yield() catch {};
    }
    for (threads) |t| t.join();
    joined = true;

    try testing.expectEqual(@as(u32, 0), burst.post_failures.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), burst.order_violations.load(.seq_cst));
    try testing.expectEqual(@as(u32, BurstProducers * BurstPerProducer), burst.ran.load(.seq_cst));
    try testing.expectEqual(@as(u32, BurstReposts), burst.reposts_ran.load(.seq_cst));
    for (&burst.last_seq) |*last| try testing.expectEqual(@as(i32, BurstPerProducer - 1), last.load(.seq_cst));
    // Nothing is left behind.
    try testing.expectEqual(@as(usize, 0), dispatch.tickInstance(id));
}
