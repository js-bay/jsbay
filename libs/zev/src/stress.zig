const std = @import("std");
const builtin = @import("builtin");
const waiter = @import("zev");
const producer_count = 4;
const signals_per_producer = 250_000;
const total_signals = producer_count * signals_per_producer;
const max_runtime_ms: u64 = 120_000;
const lifecycle_count = 20_000;
const mutex_contention_window_ms: u64 = 200;
const mutex_contention_worker_count = 4;
const mutex_contention_handoff_yields = 10_000;

const MutexContention = struct {
    mutex: waiter.Mutex = .{},
    attempted: waiter.Waiter = .init,
    thread_cpu_ms: std.atomic.Value(u32) = .init(0),
    cpu_measurements: std.atomic.Value(u32) = .init(0),

    fn run(self: *MutexContention) void {
        self.attempted.signal();
        const cpu_before = threadCpuMilliseconds();
        self.mutex.lock();
        defer self.mutex.unlock();
        const cpu_after = threadCpuMilliseconds();
        if (cpu_before != null and cpu_after != null) {
            _ = self.thread_cpu_ms.fetchAdd(@intCast(cpu_after.? - cpu_before.?), .release);
            _ = self.cpu_measurements.fetchAdd(1, .release);
        }
    }
};

/// Measures CPU consumed by a single thread while it waits on a held mutex. The window is deliberately a bounded benchmark phase rather than an event loop deadline. It is coordinated through Waiter and Condition, so it does not infer correctness from a wall-clock scheduling threshold.
fn measureMutexContention() !void {
    var subject: MutexContention = .{};
    defer subject.attempted.deinit();
    defer subject.mutex.deinit();
    var delay_mutex: waiter.Mutex = .{};
    defer delay_mutex.deinit();
    var delay_condition: waiter.Condition = .init;
    defer delay_condition.deinit();

    subject.mutex.lock();
    var subject_locked = true;
    const generation = subject.attempted.generation();
    var threads: [mutex_contention_worker_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        if (subject_locked) subject.mutex.unlock();
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, MutexContention.run, .{&subject});
        spawned += 1;
    }
    const required_generation = generation + mutex_contention_worker_count;
    var observed_generation = generation;
    while (observed_generation < required_generation) {
        if (subject.attempted.waitUntilChange(observed_generation, 5_000)) {
            observed_generation = subject.attempted.generation();
            continue;
        }
        return error.ContentionWorkerDidNotAttempt;
    }

    delay_mutex.lock();
    const wall_before = waiter.monotonicMilliseconds();
    _ = delay_condition.waitTimeout(&delay_mutex, mutex_contention_window_ms);
    delay_mutex.unlock();
    // The timed wait intentionally leaves the measured mutex held. Explicit handoffs give contending threads CPU time before it is released, so this phase distinguishes a parked waiter from a spin loop without asserting a scheduling deadline.
    for (0..mutex_contention_handoff_yields) |_| std.Thread.yield() catch {};
    const elapsed_ms = waiter.monotonicMilliseconds() - wall_before;
    subject.mutex.unlock();
    subject_locked = false;
    for (threads[0..spawned]) |thread| thread.join();

    const measurements = subject.cpu_measurements.load(.acquire);
    if (measurements != spawned) return error.ThreadCpuMeasurementUnavailable;
    std.debug.print("mutex_contention window_ms={d} elapsed_ms={d} waiting_threads_cpu_ms={d} attempts={d} cpu_samples={d} handoff_yields={d} measurement=available\n", .{
        mutex_contention_window_ms,
        elapsed_ms,
        subject.thread_cpu_ms.load(.acquire),
        spawned,
        measurements,
        mutex_contention_handoff_yields,
    });
}

fn runNativeMutexChecks() !void {
    const worker_count = 4;
    const iterations_per_worker = 20_000;
    for (0..1_000) |_| {
        var mutex: waiter.Mutex = .{};
        mutex.lock();
        if (mutex.tryLock()) return error.TryLockSucceededWhileHeld;
        mutex.unlock();
        if (!mutex.tryLock()) return error.TryLockFailedAfterRelease;
        mutex.unlock();
        mutex.deinit();
    }

    const Shared = struct {
        mutex: waiter.Mutex = .{},
        count: usize = 0,
        value: usize = 0,
        complement: usize = ~@as(usize, 0),
        failed: std.atomic.Value(bool) = .init(false),
    };
    const Counter = struct {
        fn run(shared: *Shared, start: *waiter.Waiter) void {
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
    var start: waiter.Waiter = .init;
    defer start.deinit();
    var counter_threads: [worker_count]std.Thread = undefined;
    var counter_spawned: usize = 0;
    var counter_started = false;
    var counter_joined = false;
    errdefer {
        if (!counter_joined) {
            if (!counter_started) start.broadcast();
            for (counter_threads[0..counter_spawned]) |thread| thread.join();
        }
    }
    for (&counter_threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Counter.run, .{ &shared, &start });
        counter_spawned += 1;
    }
    start.broadcast();
    counter_started = true;
    for (counter_threads[0..counter_spawned]) |thread| thread.join();
    counter_joined = true;
    if (shared.failed.load(.acquire) or shared.count != worker_count * iterations_per_worker or shared.complement != ~shared.value) return error.MutexCounterInvariantFailed;

    const Broadcast = struct {
        mutex: waiter.Mutex = .{},
        condition: waiter.Condition = .init,
        waiting: usize = 0,
        ready: bool = false,
        completed: std.atomic.Value(usize) = .init(0),
    };
    const WaiterThread = struct {
        fn run(state: *Broadcast, entered: *waiter.Waiter) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            while (!state.ready) {
                state.waiting += 1;
                entered.signal();
                state.condition.wait(&state.mutex);
            }
            _ = state.completed.fetchAdd(1, .release);
        }
    };
    var broadcast: Broadcast = .{};
    defer broadcast.condition.deinit();
    defer broadcast.mutex.deinit();
    var entered: waiter.Waiter = .init;
    defer entered.deinit();
    const initial_generation = entered.generation();
    var wait_threads: [worker_count]std.Thread = undefined;
    var wait_spawned: usize = 0;
    var wait_joined = false;
    defer if (!wait_joined) {
        broadcast.mutex.lock();
        broadcast.ready = true;
        broadcast.condition.broadcast();
        broadcast.mutex.unlock();
        for (wait_threads[0..wait_spawned]) |thread| thread.join();
    };
    for (&wait_threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, WaiterThread.run, .{ &broadcast, &entered });
        wait_spawned += 1;
    }
    const required_generation = initial_generation + worker_count;
    var observed_generation = initial_generation;
    while (observed_generation < required_generation) {
        if (!entered.waitUntilChange(observed_generation, 5_000)) return error.ConditionWaitersDidNotEnter;
        observed_generation = entered.generation();
    }
    broadcast.mutex.lock();
    if (broadcast.waiting != worker_count) {
        broadcast.mutex.unlock();
        return error.ConditionWaiterCountMismatch;
    }
    broadcast.ready = true;
    broadcast.condition.broadcast();
    broadcast.mutex.unlock();
    for (wait_threads[0..wait_spawned]) |thread| thread.join();
    wait_joined = true;
    if (broadcast.completed.load(.acquire) != worker_count) return error.ConditionBroadcastFailed;
    std.debug.print("native_mutex_checks=PASS lifecycle_rounds=1000 counter={d} condition_waiters={d}\n", .{ shared.count, broadcast.completed.load(.acquire) });
}

fn threadCpuMilliseconds() ?u64 {
    if (comptime builtin.os.tag == .windows) return windowsThreadCpuMilliseconds();
    if (comptime builtin.os.tag.isDarwin()) return darwinThreadCpuMilliseconds();
    if (comptime builtin.os.tag == .linux) {
        const usage = std.posix.getrusage(1); // RUSAGE_THREAD on Linux-family targets.
        return timevalMilliseconds(usage.utime) + timevalMilliseconds(usage.stime);
    }
    return null;
}

fn timevalMilliseconds(value: anytype) u64 {
    return @as(u64, @intCast(value.sec)) * 1_000 + @as(u64, @intCast(value.usec)) / 1_000;
}

fn windowsThreadCpuMilliseconds() ?u64 {
    if (comptime builtin.os.tag != .windows) return null;
    const windows = std.os.windows;
    var creation: windows.FILETIME = undefined;
    var exit: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    if (@backingInt(GetThreadTimes(GetCurrentThread(), &creation, &exit, &kernel, &user)) == 0) return null;
    return (fileTimeTicks(kernel) + fileTimeTicks(user)) / 10_000;
}

fn darwinThreadCpuMilliseconds() ?u64 {
    if (comptime !builtin.os.tag.isDarwin()) return null;
    var info: std.c.thread_basic_info = undefined;
    var count = std.c.THREAD.BASIC.INFO_COUNT;
    if (std.c.thread_info(mach_thread_self(), std.c.THREAD.BASIC.INFO, @ptrCast(&info), &count) != 0) return null;
    return machTimeMilliseconds(info.user_time) + machTimeMilliseconds(info.system_time);
}

fn machTimeMilliseconds(value: std.c.time_value_t) u64 {
    return @as(u64, @intCast(value.seconds)) * 1_000 + @as(u64, @intCast(value.microseconds)) / 1_000;
}

fn fileTimeTicks(value: std.os.windows.FILETIME) u64 {
    return (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
}

extern "kernel32" fn GetCurrentThread() callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn GetThreadTimes(
    thread: std.os.windows.HANDLE,
    creation_time: *std.os.windows.FILETIME,
    exit_time: *std.os.windows.FILETIME,
    kernel_time: *std.os.windows.FILETIME,
    user_time: *std.os.windows.FILETIME,
) callconv(.winapi) std.os.windows.BOOL;
extern "c" fn mach_thread_self() std.c.thread_act_t;
const Producer = struct {
    subject: *waiter.Waiter,
    published: *std.atomic.Value(u32),
    start: *std.atomic.Value(bool),
    fn run(self: *Producer) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        for (0..signals_per_producer) |_| {
            _ = self.published.fetchAdd(1, .release);
            self.subject.signal();
        }
    }
};
pub fn main() !void {
    try runNativeMutexChecks();
    try measureMutexContention();
    const lifecycle_started = waiter.monotonicMilliseconds();
    for (0..lifecycle_count) |_| {
        var lifecycle_subject: waiter.Waiter = .init;
        const before = lifecycle_subject.generation();
        lifecycle_subject.signal();
        if (!lifecycle_subject.waitUntilChange(before, 0)) return error.LifecycleWakeLost;
        lifecycle_subject.deinit();
    }
    const lifecycle_elapsed = waiter.monotonicMilliseconds() - lifecycle_started;
    var subject: waiter.Waiter = .init;
    defer subject.deinit();
    const initial_generation = subject.generation();
    for (0..100_000) |_| if (subject.waitUntilChange(initial_generation, 0)) return error.UnexpectedWake;
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
        producer.* = .{ .subject = &subject, .published = &published, .start = &start };
        threads[index] = try std.Thread.spawn(.{}, Producer.run, .{producer});
        spawned += 1;
    }
    const started = waiter.monotonicMilliseconds();
    start.store(true, .release);
    while (published.load(.acquire) < total_signals) {
        const generation = subject.generation();
        if (published.load(.acquire) == total_signals) break;
        const elapsed = waiter.monotonicMilliseconds() - started;
        if (elapsed >= max_runtime_ms) return error.SignalTimeout;
        if (!subject.waitUntilChange(generation, @max(@as(u64, 1), max_runtime_ms - elapsed))) return error.SignalTimeout;
    }
    for (threads[0..spawned]) |thread| thread.join();
    spawned = 0;
    const final_generation = subject.generation();
    const elapsed = waiter.monotonicMilliseconds() - started;
    const passed = published.load(.acquire) == total_signals and final_generation == initial_generation + total_signals;
    std.debug.print("signals={d} producers={d} elapsed_ms={d} zero_timeout_waits=100000 generation_delta={d} lifecycles={d} lifecycle_ms={d} result={s}\n", .{ total_signals, producer_count, elapsed, final_generation - initial_generation, lifecycle_count, lifecycle_elapsed, if (passed) "PASS" else "FAIL" });
    if (!passed) return error.StressInvariantFailed;
    std.debug.print("native_mutex_checks=PASS mutex_contention_measurement=available result=PASS\n", .{});
}
