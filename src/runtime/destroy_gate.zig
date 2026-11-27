//! Synchronization gate for instance teardown across threads.
const std = @import("std");
const builtin = @import("builtin");
const sync = @import("zev");

pub const DestroyGate = struct {
    mutex: sync.Mutex = .{},
    waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

var g_destroy_gates: [64]DestroyGate = @splat(.{});

pub fn destroyGate(instance_id: i32) *DestroyGate {
    const bits: u32 = @bitCast(instance_id);
    return &g_destroy_gates[@as(usize, bits) % g_destroy_gates.len];
}

pub const DestroyGateLease = struct {
    gate: *DestroyGate,
    previous: ?*DestroyGateLease,
    owns_mutex: bool,
};

threadlocal var g_held_destroy_gates: ?*DestroyGateLease = null;

pub fn lockDestroyGate(gate: *DestroyGate, lease: *DestroyGateLease) void {
    var current = g_held_destroy_gates;
    while (current) |held| : (current = held.previous) {
        if (held.gate == gate) {
            lease.* = .{ .gate = gate, .previous = g_held_destroy_gates, .owns_mutex = false };
            g_held_destroy_gates = lease;
            return;
        }
    }

    _ = gate.waiters.fetchAdd(1, .seq_cst);
    gate.mutex.lock();
    _ = gate.waiters.fetchSub(1, .seq_cst);
    lease.* = .{ .gate = gate, .previous = g_held_destroy_gates, .owns_mutex = true };
    g_held_destroy_gates = lease;
}

pub fn unlockDestroyGate(lease: *DestroyGateLease) void {
    std.debug.assert(g_held_destroy_gates == lease);
    g_held_destroy_gates = lease.previous;
    if (lease.owns_mutex) lease.gate.mutex.unlock();
}

pub fn destroyGateWaitersForTesting(instance_id: i32) u32 {
    if (!builtin.is_test) return 0;
    return destroyGate(instance_id).waiters.load(.seq_cst);
}
