const std = @import("std");
const builtin = @import("builtin");
const instance_map = @import("instance_map.zig");

pub var ref_wait_hook_for_testing: ?*const fn (?*anyopaque) void = null;
pub var ref_drain_hook_for_testing: ?*const fn (?*anyopaque) void = null;
pub var ref_hook_context_for_testing: ?*anyopaque = null;

pub fn setRefHooksForTesting(wait_hook: ?*const fn (?*anyopaque) void, drain_hook: ?*const fn (?*anyopaque) void, ctx: ?*anyopaque) void {
    if (!builtin.is_test) return;
    ref_wait_hook_for_testing = wait_hook;
    ref_drain_hook_for_testing = drain_hook;
    ref_hook_context_for_testing = ctx;
}

pub fn noteRefBookkeepingDrainedForTesting() void {
    if (!builtin.is_test) return;
    if (ref_drain_hook_for_testing) |hook| hook(ref_hook_context_for_testing);
}

pub const RefLease = struct {
    inst: *instance_map.EngineInstance,
    generation: u64,

    pub fn end(self: RefLease) bool {
        self.inst.ref_bookkeeping.mutex.lock();
        std.debug.assert(self.inst.ref_bookkeeping.active_ops != 0);
        self.inst.ref_bookkeeping.active_ops -= 1;
        const outermost = self.inst.ref_bookkeeping.active_ops == 0;
        self.inst.ref_bookkeeping.wake.broadcast();
        self.inst.ref_bookkeeping.mutex.unlock();
        return outermost;
    }
};

pub fn beginRefOp(instance_id: i32, expected_generation: ?u64) ?RefLease {
    instance_map.mutex.lock();
    defer instance_map.mutex.unlock();
    const inst = instance_map.instances.get(instance_id) orelse return null;
    if (inst.teardown_pending or inst.ref_bookkeeping.admission_closed) return null;
    if (expected_generation) |generation| {
        if (inst.generation != generation) return null;
    }
    inst.ref_bookkeeping.mutex.lock();
    inst.ref_bookkeeping.active_ops += 1;
    inst.ref_bookkeeping.mutex.unlock();
    return .{ .inst = inst, .generation = inst.generation };
}

pub fn waitForRefOps(instance_id: i32) void {
    instance_map.mutex.lock();
    const inst = instance_map.instances.get(instance_id) orelse {
        instance_map.mutex.unlock();
        return;
    };
    instance_map.mutex.unlock();
    inst.ref_bookkeeping.mutex.lock();
    if (inst.ref_bookkeeping.active_ops != 0 and builtin.is_test) {
        inst.ref_bookkeeping.mutex.unlock();
        if (ref_wait_hook_for_testing) |hook| hook(ref_hook_context_for_testing);
        inst.ref_bookkeeping.mutex.lock();
    }
    while (inst.ref_bookkeeping.active_ops != 0) {
        inst.ref_bookkeeping.wake.wait(&inst.ref_bookkeeping.mutex);
    }
    inst.ref_bookkeeping.mutex.unlock();
}

pub fn forceResetBookkeeping(book: *instance_map.RefBookkeeping) void {
    while (true) {
        book.mutex.lock();
        const entry = book.head orelse {
            book.mutex.unlock();
            break;
        };
        book.head = entry.next;
        if (book.head) |h| h.prev = null;
        entry.prev = null;
        entry.next = null;
        book.mutex.unlock();
        while (true) {
            const state: instance_map.RefEntryState = @fromBackingInt(@intCast(entry.state.load(.acquire)));
            const next: instance_map.RefEntryState = switch (state) {
                .linked => .releasing,
                .abandoned => .releasing_abandoned,
                .releasing, .released, .releasing_abandoned, .freed => unreachable,
            };
            if (entry.state.cmpxchgWeak(@backingInt(state), @backingInt(next), .acq_rel, .acquire) == null) {
                break;
            }
        }
        entry.reset_fn(entry);
        while (true) {
            const current: instance_map.RefEntryState = @fromBackingInt(@intCast(entry.state.load(.acquire)));
            const next: instance_map.RefEntryState = switch (current) {
                .releasing => .released,
                .releasing_abandoned => .freed,
                .linked, .released, .abandoned, .freed => unreachable,
            };
            if (entry.state.cmpxchgWeak(@backingInt(current), @backingInt(next), .acq_rel, .acquire) == null) {
                if (next == .freed) entry.free_fn(entry);
                break;
            }
        }
    }
    noteRefBookkeepingDrainedForTesting();
}
