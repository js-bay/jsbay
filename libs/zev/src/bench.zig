//! Microbenchmarks for zev Notifier/Timer P0–P1 changes.
//! `wake_delta` is `Loop.wakeGeneration()` growth and equals Waiter.signal / futexWake count.
//! Idle owner `notify`/`startAt` still wake (so other waiters are not starved); wake-skip applies while the owner is driving (`run` / `runOnce` / `dispatchEvents`). Pending coalesce still suppresses extra wakes. `*_force_wake` variants call `Loop.wake()` after each op for contrast.

const std = @import("std");
const zev = @import("zev");

const owner_iters: usize = 200_000;
const coalesce_iters: usize = 200_000;
const remote_iters: usize = 20_000;
const remote_blast_iters: usize = 100_000;
const dispatch_count: usize = 4_000;
const warmup: usize = 1_000;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) @panic("clock_gettime failed");
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn nsPerOp(elapsed_ns: u64, ops: usize) f64 {
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ops));
}

fn opsPerSec(elapsed_ns: u64, ops: usize) f64 {
    if (elapsed_ns == 0) return 0;
    return @as(f64, @floatFromInt(ops)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns));
}

fn printRow(name: []const u8, ops: usize, elapsed_ns: u64, wake_delta: u64, extra: []const u8) void {
    std.debug.print("{s}: ops={d} elapsed_ns={d} ns_per_op={d:.1} ops_per_sec={d:.0} wake_delta={d}{s}\n", .{
        name,
        ops,
        elapsed_ns,
        nsPerOp(elapsed_ns, ops),
        opsPerSec(elapsed_ns, ops),
        wake_delta,
        extra,
    });
}

fn emptyNotify(_: ?*anyopaque, _: *zev.Notifier) void {}
fn emptyTimer(_: ?*anyopaque, _: *zev.Timer) void {}

fn benchOwnerNestedNotifySkip() !void {
    const State = struct {
        rearm: *zev.Notifier,
        fn onNotify(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = self.rearm.notify();
        }
    };
    const loop = try zev.Loop.create(std.heap.page_allocator);
    defer loop.destroy();
    var rearm: zev.Notifier = .{};
    rearm.init(loop, null, emptyNotify);
    defer rearm.close();
    var state: State = .{ .rearm = &rearm };
    var handle: zev.Notifier = .{};
    handle.init(loop, &state, State.onNotify);
    defer handle.close();

    for (0..warmup) |_| {
        _ = handle.notify();
        loop.dispatchEvents();
        loop.dispatchEvents();
    }

    const before_gen = loop.wakeGeneration();
    const t0 = nowNs();
    for (0..owner_iters) |_| {
        _ = handle.notify();
        // Idle notify wakes once; nested rearm.notify inside dispatch must not add another.
        loop.dispatchEvents();
        loop.dispatchEvents();
    }
    const elapsed: u64 = nowNs() - t0;
    const wake_delta = loop.wakeGeneration() - before_gen;
    printRow("owner_nested_notify_in_dispatch", owner_iters, elapsed, wake_delta, " (expect wake_delta==iters; nested skips)");
}

fn benchOwnerNotifyCycle(force_wake: bool) !void {
    const loop = try zev.Loop.create(std.heap.page_allocator);
    defer loop.destroy();
    var handle: zev.Notifier = .{};
    handle.init(loop, null, emptyNotify);
    defer handle.close();

    for (0..warmup) |_| {
        _ = handle.notify();
        if (force_wake) loop.wake();
        loop.dispatchEvents();
    }

    const before_gen = loop.wakeGeneration();
    const t0 = nowNs();
    for (0..owner_iters) |_| {
        _ = handle.notify();
        if (force_wake) loop.wake();
        loop.dispatchEvents();
    }
    const elapsed: u64 = nowNs() - t0;
    const wake_delta = loop.wakeGeneration() - before_gen;
    const name = if (force_wake) "owner_notify_cycle_force_wake" else "owner_notify_cycle";
    printRow(name, owner_iters, elapsed, wake_delta, "");
}

fn benchOwnerTimerStartAt(force_wake: bool) !void {
    const loop = try zev.Loop.create(std.heap.page_allocator);
    defer loop.destroy();
    var timer: zev.Timer = .{};
    timer.init(loop, null, emptyTimer);
    defer timer.close();

    for (0..warmup) |_| {
        try timer.startAt(0);
        if (force_wake) loop.wake();
        loop.dispatchEvents();
    }

    const before_gen = loop.wakeGeneration();
    const t0 = nowNs();
    for (0..owner_iters) |_| {
        try timer.startAt(0);
        if (force_wake) loop.wake();
        loop.dispatchEvents();
    }
    const elapsed: u64 = nowNs() - t0;
    const wake_delta = loop.wakeGeneration() - before_gen;
    const name = if (force_wake) "owner_timer_startAt_force_wake" else "owner_timer_startAt";
    printRow(name, owner_iters, elapsed, wake_delta, "");
}

fn benchOwnerNotifyCoalesce(force_wake: bool) !void {
    const loop = try zev.Loop.create(std.heap.page_allocator);
    defer loop.destroy();
    var handle: zev.Notifier = .{};
    handle.init(loop, null, emptyNotify);
    defer handle.close();

    _ = handle.notify();
    if (force_wake) loop.wake();

    const before_gen = loop.wakeGeneration();
    const t0 = nowNs();
    for (0..coalesce_iters) |_| {
        _ = handle.notify();
        if (force_wake) loop.wake();
    }
    const elapsed: u64 = nowNs() - t0;
    const wake_delta = loop.wakeGeneration() - before_gen;
    loop.dispatchEvents();
    const name = if (force_wake) "owner_notify_coalesce_force_wake" else "owner_notify_coalesce";
    printRow(name, coalesce_iters, elapsed, wake_delta, "");
}

fn benchRemotePingPong() !void {
    const State = struct {
        calls: std.atomic.Value(usize) = .init(0),
        fn onNotify(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = self.calls.fetchAdd(1, .release);
        }
    };
    const Sender = struct {
        handle: *zev.Notifier,
        ready: *std.atomic.Value(bool),
        acked: *std.atomic.Value(usize),
        fn run(self: *@This()) void {
            while (!self.ready.load(.acquire)) std.atomic.spinLoopHint();
            var i: usize = 0;
            while (i < remote_iters) : (i += 1) {
                while (!self.handle.notify()) std.atomic.spinLoopHint();
                while (self.acked.load(.acquire) <= i) std.atomic.spinLoopHint();
            }
        }
    };

    const loop = try zev.Loop.create(std.heap.page_allocator);
    defer loop.destroy();
    var state: State = .{};
    var handle: zev.Notifier = .{};
    handle.init(loop, &state, State.onNotify);
    defer handle.close();

    var ready = std.atomic.Value(bool).init(false);
    var sender: Sender = .{ .handle = &handle, .ready = &ready, .acked = &state.calls };
    const thread = try std.Thread.spawn(.{}, Sender.run, .{&sender});

    ready.store(true, .release);
    const before_gen = loop.wakeGeneration();
    const t0 = nowNs();
    while (state.calls.load(.acquire) < remote_iters) {
        const seen = loop.wakeGeneration();
        _ = loop.runOnce(.{});
        if (state.calls.load(.acquire) >= remote_iters) break;
        _ = loop.waitForWake(seen, 10);
    }
    const elapsed: u64 = nowNs() - t0;
    thread.join();
    const wake_delta = loop.wakeGeneration() - before_gen;
    printRow("remote_notify_pingpong", remote_iters, elapsed, wake_delta, "");
}

fn benchRemoteBlast() !void {
    const State = struct {
        calls: std.atomic.Value(usize) = .init(0),
        fn onNotify(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = self.calls.fetchAdd(1, .release);
        }
    };
    const Blaster = struct {
        handle: *zev.Notifier,
        start: *std.atomic.Value(bool),
        sent: *std.atomic.Value(usize),
        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            var i: usize = 0;
            while (i < remote_blast_iters) : (i += 1) {
                // Busy-notify; coalescing means drained callbacks << sent.
                _ = self.handle.notify();
            }
            self.sent.store(remote_blast_iters, .release);
        }
    };

    const loop = try zev.Loop.create(std.heap.page_allocator);
    defer loop.destroy();
    var state: State = .{};
    var handle: zev.Notifier = .{};
    handle.init(loop, &state, State.onNotify);
    defer handle.close();

    var start = std.atomic.Value(bool).init(false);
    var sent = std.atomic.Value(usize).init(0);
    var blaster: Blaster = .{ .handle = &handle, .start = &start, .sent = &sent };
    const thread = try std.Thread.spawn(.{}, Blaster.run, .{&blaster});

    start.store(true, .release);
    const before_gen = loop.wakeGeneration();
    const t0 = nowNs();
    while (sent.load(.acquire) < remote_blast_iters or hasPendingWork(loop)) {
        const seen = loop.wakeGeneration();
        _ = loop.runOnce(.{});
        if (sent.load(.acquire) >= remote_blast_iters and !hasPendingWork(loop)) break;
        _ = loop.waitForWake(seen, 1);
    }
    // Drain any leftover
    while (hasPendingWork(loop)) _ = loop.runOnce(.{});
    const elapsed: u64 = nowNs() - t0;
    thread.join();
    const wake_delta = loop.wakeGeneration() - before_gen;
    var extra_buf: [96]u8 = undefined;
    const extra = try std.fmt.bufPrint(&extra_buf, " sent={d} callbacks={d}", .{ sent.load(.acquire), state.calls.load(.acquire) });
    printRow("remote_notify_blast", remote_blast_iters, elapsed, wake_delta, extra);
}

/// `nextDeadline() == 0` means pending/ready notifiers (or ready timers) remain.
fn hasPendingWork(loop: *zev.Loop) bool {
    const deadline = loop.nextDeadline() orelse return false;
    return deadline == 0;
}

fn benchDispatchBudget() !void {
    const State = struct {
        calls: usize = 0,
        fn onNotify(ctx: ?*anyopaque, _: *zev.Notifier) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
    };
    const gpa = std.heap.page_allocator;

    const loop = try zev.Loop.create(gpa);
    defer loop.destroy();
    var state: State = .{};
    const handles = try gpa.alloc(zev.Notifier, dispatch_count);
    defer gpa.free(handles);
    for (handles) |*h| {
        h.* = .{};
        h.init(loop, &state, State.onNotify);
    }
    defer for (handles) |*h| h.close();

    for (handles) |*h| _ = h.notify();
    state.calls = 0;
    const t0 = nowNs();
    loop.dispatchEvents();
    const unlimited_ns: u64 = nowNs() - t0;
    const unlimited_calls = state.calls;

    for (handles) |*h| _ = h.notify();
    state.calls = 0;
    var turns: usize = 0;
    const t1 = nowNs();
    while (state.calls < dispatch_count) {
        loop.dispatchEventsLimited(64, null);
        turns += 1;
    }
    const budget_ns: u64 = nowNs() - t1;
    const budget_calls = state.calls;

    printRow("dispatch_unlimited", unlimited_calls, unlimited_ns, 0, "");
    var extra_buf: [48]u8 = undefined;
    const extra = try std.fmt.bufPrint(&extra_buf, " turns={d}", .{turns});
    printRow("dispatch_budget_64", budget_calls, budget_ns, 0, extra);
    const overhead_pct = if (unlimited_ns == 0) 0 else (@as(f64, @floatFromInt(budget_ns)) / @as(f64, @floatFromInt(unlimited_ns)) - 1.0) * 100.0;
    std.debug.print("dispatch_budget_overhead_pct={d:.1} (budgeted vs unlimited for {d} notifiers)\n", .{ overhead_pct, dispatch_count });
}

pub fn main() !void {
    std.debug.print("zev microbench (wake_delta counts Waiter.signal / futex wakes)\n", .{});
    std.debug.print("owner_iters={d} coalesce_iters={d} remote_iters={d} remote_blast_iters={d} dispatch_count={d}\n", .{
        owner_iters,
        coalesce_iters,
        remote_iters,
        remote_blast_iters,
        dispatch_count,
    });
    try benchOwnerNotifyCycle(false);
    try benchOwnerNotifyCycle(true);
    try benchOwnerNestedNotifySkip();
    try benchOwnerTimerStartAt(false);
    try benchOwnerTimerStartAt(true);
    try benchOwnerNotifyCoalesce(false);
    try benchOwnerNotifyCoalesce(true);
    try benchRemotePingPong();
    try benchRemoteBlast();
    try benchDispatchBudget();
}
