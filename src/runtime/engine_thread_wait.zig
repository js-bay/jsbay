const std = @import("std");
const io = @import("../platform/io.zig");

pub fn waitUntil(state: anytype, deadline: i64) void {
    const now = io.monotonicMilliseconds();
    if (now >= deadline) return;
    _ = state.wake.waitTimeout(&state.queue_mu, @intCast(deadline - now));
}

pub fn waitBrief(cond: anytype, mutex: anytype) void {
    _ = cond.waitTimeout(mutex, 1);
}

pub fn waitRefsDrain(state: anytype, is_test: bool) void {
    if (is_test) {
        state.queue_mu.lock();
        const hook = state.refs_drain_hook_for_testing;
        const hook_data = state.refs_drain_hook_data_for_testing;
        state.queue_mu.unlock();
        if (hook) |callback| callback(hook_data);
    }
    while (true) {
        state.queue_mu.lock();
        if (state.refs.load(.seq_cst) == 0) {
            state.queue_mu.unlock();
            return;
        }
        waitBrief(&state.wake, &state.queue_mu);
        state.queue_mu.unlock();
    }
}

pub fn waitRunningClear(state: anytype) void {
    while (state.running.load(.seq_cst)) {
        state.queue_mu.lock();
        if (!state.running.load(.seq_cst)) {
            state.queue_mu.unlock();
            return;
        }
        waitBrief(&state.wake, &state.queue_mu);
        state.queue_mu.unlock();
    }
}

pub fn deadlineFrom(timeout_ms: u64) i64 {
    const now = io.monotonicMilliseconds();
    const room = std.math.maxInt(i64) - now;
    if (room <= 0) return now;
    const add: i64 = if (timeout_ms > @as(u64, @intCast(room))) room else @intCast(timeout_ms);
    return now + add;
}
