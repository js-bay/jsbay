const std = @import("std");
const zev = @import("zev");

const producer_count = 4;
const signals_per_producer = 250_000;
const total_signals = producer_count * signals_per_producer;
const max_runtime_ms: u64 = 120_000;

const Producer = struct {
    loop: *zev.Loop,
    published: *std.atomic.Value(u32),
    start: *std.atomic.Value(bool),

    fn run(self: *Producer) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        for (0..signals_per_producer) |_| {
            _ = self.published.fetchAdd(1, .monotonic);
            self.loop.wake();
        }
    }
};

test "event loop stress: zero-timeout waits and one million concurrent signals" {
    const testing = std.testing;
    const loop = try zev.Loop.create(std.testing.allocator);
    defer loop.destroy();

    const initial_generation = loop.wakeGeneration();
    for (0..100_000) |_| try testing.expect(!loop.waitForWake(initial_generation, 0));
    try testing.expectEqual(initial_generation, loop.wakeGeneration());

    var published = std.atomic.Value(u32).init(0);
    var start = std.atomic.Value(bool).init(false);
    var producers: [producer_count]Producer = undefined;
    var threads: [producer_count]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        start.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }

    for (&producers, 0..) |*producer, index| {
        producer.* = .{ .loop = loop, .published = &published, .start = &start };
        threads[index] = try std.Thread.spawn(.{}, Producer.run, .{producer});
        spawned += 1;
    }

    const started_ms = zev.monotonicMilliseconds();
    var timed_out_without_wake = false;
    start.store(true, .release);
    while (published.load(.acquire) < total_signals) {
        const generation = loop.wakeGeneration();
        if (published.load(.acquire) == total_signals) break;
        if (zev.monotonicMilliseconds() - started_ms >= max_runtime_ms) {
            timed_out_without_wake = true;
            break;
        }

        if (!loop.waitForWake(generation, 5_000)) {
            timed_out_without_wake = true;
            break;
        }
    }

    for (threads[0..spawned]) |thread| thread.join();
    spawned = 0;

    const elapsed_ms = zev.monotonicMilliseconds() - started_ms;
    try testing.expect(!timed_out_without_wake);
    try testing.expectEqual(@as(u32, total_signals), published.load(.acquire));
    try testing.expectEqual(initial_generation + total_signals, loop.wakeGeneration());
    std.debug.print(
        "event-loop stress: signals={d} producers={d} elapsed_ms={d}\n",
        .{ total_signals, producer_count, elapsed_ms },
    );
}
