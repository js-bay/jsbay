const std = @import("std");
const zev = @import("zev");

test "mutex serializes updates and publishes protected state" {
    const worker_count = 4;
    const iterations_per_worker = 20_000;
    const Shared = struct {
        mutex: zev.Mutex = .{},
        count: usize = 0,
        value: usize = 0,
        complement: usize = ~@as(usize, 0),
        failed: std.atomic.Value(bool) = .init(false),
    };
    const Worker = struct {
        fn run(shared: *Shared, start: *zev.Waiter) void {
            _ = start.waitUntilChange(0, null);
            for (0..iterations_per_worker) |_| {
                shared.mutex.lock();
                if (shared.complement != ~shared.value) {
                    shared.failed.store(true, .release);
                    shared.mutex.unlock();
                    return;
                }
                shared.value = shared.count;
                shared.complement = ~shared.value;
                shared.count += 1;
                shared.mutex.unlock();
            }
        }
    };

    var shared: Shared = .{};
    defer shared.mutex.deinit();
    var start: zev.Waiter = .init;
    defer start.deinit();
    var threads: [worker_count]std.Thread = undefined;
    var spawned: usize = 0;
    var started = false;
    var joined = false;
    defer if (!joined) {
        if (!started) start.broadcast();
        for (threads[0..spawned]) |thread| thread.join();
    };
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &shared, &start });
        spawned += 1;
    }
    start.broadcast();
    started = true;
    for (threads[0..spawned]) |thread| thread.join();
    joined = true;

    try std.testing.expect(!shared.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, worker_count * iterations_per_worker), shared.count);
    try std.testing.expectEqual(~shared.value, shared.complement);
}

test "mutex tryLock reports contention and succeeds after release" {
    const Result = struct {
        attempted: zev.Waiter = .init,
        while_locked: std.atomic.Value(bool) = .init(true),
        after_release: std.atomic.Value(bool) = .init(false),
    };
    const Worker = struct {
        fn run(mutex: *zev.Mutex, result: *Result) void {
            const while_locked = mutex.tryLock();
            result.while_locked.store(while_locked, .release);
            if (while_locked) mutex.unlock();
            result.attempted.signal();
            mutex.lock();
            result.after_release.store(true, .release);
            mutex.unlock();
        }
    };

    var mutex: zev.Mutex = .{};
    defer mutex.deinit();
    var result: Result = .{};
    defer result.attempted.deinit();
    mutex.lock();
    var mutex_locked = true;
    const generation = result.attempted.generation();
    const thread = std.Thread.spawn(.{}, Worker.run, .{ &mutex, &result }) catch |err| {
        mutex.unlock();
        mutex_locked = false;
        return err;
    };
    var joined = false;
    defer if (!joined) thread.join();
    defer if (mutex_locked) mutex.unlock();
    try std.testing.expect(result.attempted.waitUntilChange(generation, 1_000));
    try std.testing.expect(!result.while_locked.load(.acquire));
    mutex.unlock();
    mutex_locked = false;
    thread.join();
    joined = true;
    try std.testing.expect(result.after_release.load(.acquire));
}

test "mutex instances can be initialized, destroyed, and reused" {
    for (0..1_000) |_| {
        var mutex: zev.Mutex = .{};
        mutex.lock();
        try std.testing.expect(!mutex.tryLock());
        mutex.unlock();
        mutex.deinit();
    }
    var final_mutex: zev.Mutex = .{};
    defer final_mutex.deinit();
    final_mutex.lock();
    final_mutex.unlock();
}

test "condition wait loops after a signal without its predicate" {
    const Shared = struct {
        mutex: zev.Mutex = .{},
        condition: zev.Condition = .init,
        waiting: usize = 0,
        ready: bool = false,
        completed: std.atomic.Value(bool) = .init(false),
    };
    const Worker = struct {
        fn run(shared: *Shared, waiting: *zev.Waiter) void {
            shared.mutex.lock();
            defer shared.mutex.unlock();
            while (!shared.ready) {
                shared.waiting += 1;
                waiting.signal();
                shared.condition.wait(&shared.mutex);
            }
            shared.completed.store(true, .release);
        }
    };

    var shared: Shared = .{};
    defer shared.condition.deinit();
    defer shared.mutex.deinit();
    var waiting: zev.Waiter = .init;
    defer waiting.deinit();
    const before_first_wait = waiting.generation();
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &shared, &waiting });
    var joined = false;
    defer if (!joined) {
        shared.mutex.lock();
        shared.ready = true;
        shared.condition.broadcast();
        shared.mutex.unlock();
        thread.join();
    };
    try std.testing.expect(waiting.waitUntilChange(before_first_wait, 1_000));

    const before_second_wait = waiting.generation();
    shared.mutex.lock();
    shared.condition.signal();
    shared.mutex.unlock();

    try std.testing.expect(waiting.waitUntilChange(before_second_wait, 1_000));
    shared.mutex.lock();
    try std.testing.expect(!shared.ready);
    try std.testing.expectEqual(@as(usize, 2), shared.waiting);
    shared.ready = true;
    shared.condition.signal();
    shared.mutex.unlock();
    thread.join();
    joined = true;
    try std.testing.expect(shared.completed.load(.acquire));
}

test "condition broadcast wakes all predicate waiters" {
    const worker_count = 4;
    const Shared = struct {
        mutex: zev.Mutex = .{},
        condition: zev.Condition = .init,
        waiting: usize = 0,
        ready: bool = false,
        completed: std.atomic.Value(usize) = .init(0),
    };
    const Worker = struct {
        fn run(shared: *Shared, waiting: *zev.Waiter) void {
            shared.mutex.lock();
            defer shared.mutex.unlock();
            while (!shared.ready) {
                shared.waiting += 1;
                waiting.signal();
                shared.condition.wait(&shared.mutex);
            }
            _ = shared.completed.fetchAdd(1, .release);
        }
    };

    var shared: Shared = .{};
    defer shared.condition.deinit();
    defer shared.mutex.deinit();
    var waiting: zev.Waiter = .init;
    defer waiting.deinit();
    const initial_generation = waiting.generation();
    var threads: [worker_count]std.Thread = undefined;
    var spawned: usize = 0;
    var joined = false;
    defer if (!joined) {
        shared.mutex.lock();
        shared.ready = true;
        shared.condition.broadcast();
        shared.mutex.unlock();
        for (threads[0..spawned]) |thread| thread.join();
    };
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &shared, &waiting });
        spawned += 1;
    }
    const required_generation = initial_generation + worker_count;
    var generation = initial_generation;
    while (generation < required_generation) {
        try std.testing.expect(waiting.waitUntilChange(generation, 1_000));
        generation = waiting.generation();
    }
    shared.mutex.lock();
    try std.testing.expectEqual(@as(usize, worker_count), shared.waiting);
    shared.ready = true;
    shared.condition.broadcast();
    shared.mutex.unlock();
    for (threads[0..spawned]) |thread| thread.join();
    joined = true;
    try std.testing.expectEqual(@as(usize, worker_count), shared.completed.load(.acquire));
}
