const std = @import("std");
const waiter = @import("zev");
comptime {
    _ = @import("zev").ios_stdlib_overlay;
    _ = @import("loop_driver_tests.zig");
    _ = @import("notification_tests.zig");
    _ = @import("sync_tests.zig");
}

test "stop applies only to the current run" {
    const State = struct {
        calls: u8 = 0,
        loop: *waiter.Loop,
        fn tick(ctx: ?*anyopaque, _: u64) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.loop.requestStop();
            return null;
        }
    };
    const loop = try waiter.Loop.create(std.testing.allocator);
    defer loop.destroy();
    loop.requestStop();
    var state = State{ .loop = loop };
    loop.run(.{ .ctx = &state, .tick = State.tick });
    try std.testing.expectEqual(@as(u8, 1), state.calls);
}

test "loop records wake before wait" {
    const loop = try waiter.Loop.create(std.testing.allocator);
    defer loop.destroy();
    const before = loop.wakeGeneration();
    loop.wake();
    try std.testing.expect(loop.waitForWake(before, 100));
}

test "condition timeout relocks its mutex" {
    var mutex: waiter.Mutex = .{};
    defer mutex.deinit();
    var changed: waiter.Condition = .init;
    defer changed.deinit();
    mutex.lock();
    try std.testing.expectEqual(waiter.Condition.WaitResult.timed_out, changed.waitTimeout(&mutex, 1));
    try std.testing.expect(!mutex.tryLock());
    mutex.unlock();
}

test "condition notification relocks its mutex" {
    var mutex: waiter.Mutex = .{};
    defer mutex.deinit();
    var changed: waiter.Condition = .init;
    defer changed.deinit();
    const State = struct {
        fn signal(lock: *waiter.Mutex, condition: *waiter.Condition) void {
            lock.lock();
            condition.signal();
            lock.unlock();
        }
    };
    mutex.lock();
    const thread = std.Thread.spawn(.{}, State.signal, .{ &mutex, &changed }) catch |err| {
        mutex.unlock();
        return err;
    };
    defer thread.join();
    defer mutex.unlock();
    try std.testing.expectEqual(waiter.Condition.WaitResult.notified, changed.waitTimeout(&mutex, 1_000));
    try std.testing.expect(!mutex.tryLock());
}

test "condition signal wakes a waiting thread" {
    var mutex: waiter.Mutex = .{};
    defer mutex.deinit();
    var changed: waiter.Condition = .init;
    defer changed.deinit();
    var ready = std.atomic.Value(bool).init(false);
    const Worker = struct {
        fn run(lock: *waiter.Mutex, condition: *waiter.Condition, flag: *std.atomic.Value(bool)) void {
            lock.lock();
            while (!flag.load(.acquire)) condition.wait(lock);
            lock.unlock();
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &mutex, &changed, &ready });
    mutex.lock();
    ready.store(true, .release);
    changed.signal();
    mutex.unlock();
    thread.join();
}
const producer_count = 4;
const signals_per_producer = 25_000;
// A wake that never arrives shows up as a wait that runs long; the generous timeout only keeps the test from hanging, and finishing late also fails.
const lost_wake_timeout_ms = 10_000;
const lost_wake_limit_ms = 2_000;
const jittered_items_per_producer = 5_000;
const ping_pong_rounds = 50_000;

fn jitter(random: std.Random) void {
    switch (random.uintLessThan(u8, 64)) {
        0 => waiter.sleepMilliseconds(1),
        1...8 => std.Thread.yield() catch {},
        else => for (0..random.uintLessThan(u32, 400)) |_| std.atomic.spinLoopHint(),
    }
}

fn awaitTurn(subject: *waiter.Waiter, turn: *std.atomic.Value(u32), wanted: u32) bool {
    while (true) {
        const observed = subject.generation();
        if (turn.load(.acquire) == wanted) return true;
        if (!waitPromptly(subject, observed)) return false;
    }
}

fn waitPromptly(subject: *waiter.Waiter, observed: u64) bool {
    const start = waiter.monotonicMilliseconds();
    if (!subject.waitUntilChange(observed, lost_wake_timeout_ms)) return false;
    return waiter.monotonicMilliseconds() - start < lost_wake_limit_ms;
}

test "unused waiter deinitializes" {
    var subject: waiter.Waiter = .init;
    subject.deinit();
}
test "signal before wait advances generation without blocking" {
    var subject: waiter.Waiter = .init;
    defer subject.deinit();
    const before = subject.generation();
    subject.signal();
    try std.testing.expectEqual(before + 1, subject.generation());
    try std.testing.expect(subject.waitUntilChange(before, 0));
}
test "timeout expires within its deadline" {
    var subject: waiter.Waiter = .init;
    defer subject.deinit();
    const generation = subject.generation();
    const start = waiter.monotonicMilliseconds();
    try std.testing.expect(!subject.waitUntilChange(generation, 20));
    const elapsed_ms = waiter.monotonicMilliseconds() - start;
    try std.testing.expect(elapsed_ms >= 15);
    try std.testing.expect(elapsed_ms < 250);
}
test "repeated finite waits expire independently" {
    var subject: waiter.Waiter = .init;
    defer subject.deinit();
    const generation = subject.generation();
    const start = waiter.monotonicMilliseconds();
    try std.testing.expect(!subject.waitUntilChange(generation, 3));
    try std.testing.expect(!subject.waitUntilChange(generation, 3));
    const elapsed_ms = waiter.monotonicMilliseconds() - start;
    try std.testing.expect(elapsed_ms >= 4);
    try std.testing.expect(elapsed_ms < 250);
}

test "infinite wait wakes after another thread signals" {
    var subject: waiter.Waiter = .init;
    defer subject.deinit();
    const generation = subject.generation();
    const Signaler = struct {
        fn run(target: *waiter.Waiter) void {
            waiter.sleepMilliseconds(5);
            target.signal();
        }
    };
    const thread = try std.Thread.spawn(.{}, Signaler.run, .{&subject});
    defer thread.join();
    try std.testing.expect(subject.waitUntilChange(generation, null));
}
test "large finite timeout remains interruptible" {
    var subject: waiter.Waiter = .init;
    defer subject.deinit();
    const generation = subject.generation();
    const Signaler = struct {
        fn run(target: *waiter.Waiter) void {
            waiter.sleepMilliseconds(5);
            target.signal();
        }
    };
    const thread = try std.Thread.spawn(.{}, Signaler.run, .{&subject});
    defer thread.join();
    try std.testing.expect(subject.waitUntilChange(generation, std.math.maxInt(u64)));
}
test "broadcast wakes every waiter" {
    var subject: waiter.Waiter = .init;
    defer subject.deinit();
    const generation = subject.generation();
    var started = std.atomic.Value(u32).init(0);
    var woke = std.atomic.Value(u32).init(0);
    const Worker = struct {
        fn run(target: *waiter.Waiter, expected: u64, started_ptr: *std.atomic.Value(u32), woke_ptr: *std.atomic.Value(u32)) void {
            _ = started_ptr.fetchAdd(1, .release);
            if (target.waitUntilChange(expected, 2_000)) _ = woke_ptr.fetchAdd(1, .release);
        }
    };
    var threads: [producer_count]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &subject, generation, &started, &woke });
    while (started.load(.acquire) != producer_count) std.Thread.yield() catch {};
    subject.broadcast();
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, producer_count), woke.load(.acquire));
}
test "concurrent signalers preserve every generation" {
    var subject: waiter.Waiter = .init;
    defer subject.deinit();
    const initial = subject.generation();
    var start = std.atomic.Value(bool).init(false);
    const Producer = struct {
        fn run(target: *waiter.Waiter, start_ptr: *std.atomic.Value(bool)) void {
            while (!start_ptr.load(.acquire)) std.atomic.spinLoopHint();
            for (0..signals_per_producer) |_| target.signal();
        }
    };
    var threads: [producer_count]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Producer.run, .{ &subject, &start });
    start.store(true, .release);
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(initial + producer_count * signals_per_producer, subject.generation());
}
test "clocks expose monotonic and realtime timestamps" {
    const first = waiter.monotonicMilliseconds();
    waiter.sleepMilliseconds(1);
    const second = waiter.monotonicMilliseconds();
    try std.testing.expect(second >= first);
    try std.testing.expect(waiter.realtimeMilliseconds() > 0);
}
test "ping-pong across two waiters never loses a wake" {
    var ping: waiter.Waiter = .init;
    defer ping.deinit();
    var pong: waiter.Waiter = .init;
    defer pong.deinit();
    var turn = std.atomic.Value(u32).init(0);
    var peer_failed = std.atomic.Value(bool).init(false);
    const Peer = struct {
        fn run(ping_ptr: *waiter.Waiter, pong_ptr: *waiter.Waiter, turn_ptr: *std.atomic.Value(u32), failed: *std.atomic.Value(bool)) void {
            for (0..ping_pong_rounds) |round| {
                const base: u32 = @intCast(round * 2);
                if (!awaitTurn(ping_ptr, turn_ptr, base + 1)) {
                    failed.store(true, .release);
                    return;
                }
                turn_ptr.store(base + 2, .release);
                pong_ptr.signal();
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Peer.run, .{ &ping, &pong, &turn, &peer_failed });
    defer thread.join();
    for (0..ping_pong_rounds) |round| {
        const base: u32 = @intCast(round * 2);
        turn.store(base + 1, .release);
        ping.signal();
        try std.testing.expect(awaitTurn(&pong, &turn, base + 2));
    }
    try std.testing.expect(!peer_failed.load(.acquire));
}
test "jittered producers never leave the consumer asleep" {
    var subject: waiter.Waiter = .init;
    defer subject.deinit();
    var pending = std.atomic.Value(u32).init(0);
    const Producer = struct {
        fn run(target: *waiter.Waiter, pending_ptr: *std.atomic.Value(u32), seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            const random = prng.random();
            for (0..jittered_items_per_producer) |index| {
                jitter(random);
                _ = pending_ptr.fetchAdd(1, .release);
                if (index % 4 == 0) target.broadcast() else target.signal();
            }
        }
    };
    var threads: [producer_count]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{ &subject, &pending, 0x5eed + index });
        spawned += 1;
    }
    var consumed: u32 = 0;
    const total: u32 = producer_count * jittered_items_per_producer;
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    while (consumed < total) {
        const observed = subject.generation();
        const taken = pending.swap(0, .acq_rel);
        if (taken != 0) {
            consumed += taken;
            jitter(prng.random());
            continue;
        }
        try std.testing.expect(waitPromptly(&subject, observed));
    }
}
