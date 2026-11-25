const std = @import("std");
const sync = @import("zev");
const instance_map = @import("instance_map.zig");

const DestroyGate = struct {
    mutex: sync.Mutex = .{},
    waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

// Serializes teardown for an instance even after its State is detached. The engine callback path never acquires this gate, so an external joiner may hold it while waiting for that callback to return.
var g_destroy_gates: [64]DestroyGate = @splat(.{});

fn destroyGate(instance_id: i32) *DestroyGate {
    const bits: u32 = @bitCast(instance_id);
    return &g_destroy_gates[@as(usize, bits) % g_destroy_gates.len];
}

pub const DestroyGateLease = struct {
    gate: *DestroyGate,
    previous: ?*DestroyGateLease,
    owns_mutex: bool,
};

threadlocal var g_held_destroy_gates: ?*DestroyGateLease = null;
pub const TeardownOwner = struct { instance_id: i32, generation: u64 };
pub const TeardownOwnerLease = struct {
    instance_id: i32,
    generation: u64,
    previous: ?*TeardownOwnerLease,
};
threadlocal var g_teardown_owner: ?*TeardownOwnerLease = null;
threadlocal var g_destroying_generation: ?TeardownOwner = null;

pub fn isDestroying(instance_id: i32) bool {
    if (g_destroying_generation) |current| if (current.instance_id == instance_id) return true;
    return isTeardownOwnerInstance(instance_id);
}

pub fn isDestroyingGeneration(instance_id: i32, generation: u64) bool {
    if (g_destroying_generation) |current| {
        if (current.instance_id == instance_id and current.generation == generation) return true;
    }
    return isTeardownOwnerThread(instance_id, generation);
}

pub fn enterGenerationDestroy(instance_id: i32, generation: u64) ?TeardownOwner {
    const previous = g_destroying_generation;
    g_destroying_generation = .{ .instance_id = instance_id, .generation = generation };
    return previous;
}

pub fn leaveGenerationDestroy(previous: ?TeardownOwner) void {
    g_destroying_generation = previous;
}

pub fn enterTeardownOwner(lease: *TeardownOwnerLease, instance_id: i32, generation: u64) void {
    lease.* = .{ .instance_id = instance_id, .generation = generation, .previous = g_teardown_owner };
    g_teardown_owner = lease;
}

pub fn leaveTeardownOwner(lease: *TeardownOwnerLease) void {
    std.debug.assert(g_teardown_owner == lease);
    g_teardown_owner = lease.previous;
}

pub fn isTeardownOwnerThread(instance_id: i32, generation: u64) bool {
    var owner = g_teardown_owner;
    while (owner) |current| : (owner = current.previous) {
        if (current.instance_id == instance_id and current.generation == generation) return true;
    }
    return false;
}

pub fn isTeardownOwnerInstance(instance_id: i32) bool {
    var owner = g_teardown_owner;
    while (owner) |current| : (owner = current.previous) {
        if (current.instance_id == instance_id) return true;
    }
    return false;
}

fn lockDestroyGate(gate: *DestroyGate, lease: *DestroyGateLease) void {
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

fn unlockDestroyGate(lease: *DestroyGateLease) void {
    std.debug.assert(g_held_destroy_gates == lease);
    g_held_destroy_gates = lease.previous;
    if (lease.owns_mutex) lease.gate.mutex.unlock();
}

pub fn lockDestroyGateForGeneration(instance_id: i32, generation: u64, lease: *DestroyGateLease) bool {
    if (generation == 0) return false;
    lockDestroyGate(destroyGate(instance_id), lease);
    if (instance_map.generationOf(instance_id) == generation) return true;
    unlockDestroyGate(lease);
    return false;
}

pub fn unlockGenerationDestroyGate(lease: *DestroyGateLease) void {
    unlockDestroyGate(lease);
}

pub fn waitersForTesting(instance_id: i32) u32 {
    return destroyGate(instance_id).waiters.load(.seq_cst);
}
