const std = @import("std");
const destroy_gate = @import("destroy_gate.zig");
const instance_map = @import("instance_map.zig");

pub const DestroyGateLease = destroy_gate.DestroyGateLease;
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

pub fn lockDestroyGateForGeneration(instance_id: i32, generation: u64, lease: *DestroyGateLease) bool {
    if (generation == 0) return false;
    destroy_gate.lockDestroyGate(destroy_gate.destroyGate(instance_id), lease);
    if (instance_map.generationOf(instance_id) == generation) return true;
    destroy_gate.unlockDestroyGate(lease);
    return false;
}

pub fn unlockGenerationDestroyGate(lease: *DestroyGateLease) void {
    destroy_gate.unlockDestroyGate(lease);
}

pub fn waitersForTesting(instance_id: i32) u32 {
    return destroy_gate.destroyGateWaitersForTesting(instance_id);
}
