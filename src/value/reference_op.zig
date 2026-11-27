//! Reference operation tracking and lifecycle state transitions.
const std = @import("std");
const instance_map = @import("../runtime/instance_map.zig");

pub const RefOperation = struct {
    instance_id: i32,
    lease: instance_map.RefLease,
    previous: ?*RefOperation = null,
    deferred_destroy: bool = false,
    active: bool = true,

    pub fn end(self: *RefOperation) void {
        std.debug.assert(ref_tls_top == self and self.active);
        _ = self.lease.end();
        ref_tls_top = self.previous;
        self.active = false;
        if (self.deferred_destroy) @import("../engine.zig").destroyForGeneration(self.instance_id, self.lease.generation);
    }
};

pub threadlocal var ref_tls_top: ?*RefOperation = null;

pub fn isRefOpActiveOnCurrentThread(instance_id: i32) bool {
    var current = ref_tls_top;
    while (current) |entry| : (current = entry.previous) if (entry.instance_id == instance_id) return true;
    return false;
}

pub fn requestDeferredDestroy(instance_id: i32) bool {
    var current = ref_tls_top;
    while (current) |entry| : (current = entry.previous) {
        if (entry.instance_id == instance_id) {
            entry.deferred_destroy = true;
            return true;
        }
    }
    return false;
}

pub fn beginRefOperation(operation: *RefOperation, instance_id: i32, generation: ?u64) bool {
    const lease = instance_map.beginRefOp(instance_id, generation) orelse return false;
    operation.* = .{ .instance_id = instance_id, .lease = lease, .previous = ref_tls_top };
    ref_tls_top = operation;
    return true;
}

pub fn unregisterEntry(inst: *instance_map.EngineInstance, entry: *instance_map.RefEntry) void {
    inst.ref_bookkeeping.mutex.lock();
    defer inst.ref_bookkeeping.mutex.unlock();
    if (entry.prev) |p| {
        p.next = entry.next;
    } else if (inst.ref_bookkeeping.head == entry) {
        inst.ref_bookkeeping.head = entry.next;
    }
    if (entry.next) |n| n.prev = entry.prev;
    entry.prev = null;
    entry.next = null;
}

pub fn abandonEntry(entry: *instance_map.RefEntry) void {
    while (true) {
        const old: instance_map.RefEntryState = @fromBackingInt(@intCast(entry.state.load(.acquire)));
        const next: ?instance_map.RefEntryState = switch (old) {
            .linked => .abandoned,
            .releasing => .releasing_abandoned,
            .released => .freed,
            .abandoned, .releasing_abandoned, .freed => null,
        };
        const target = next orelse return;
        if (entry.state.cmpxchgWeak(@backingInt(old), @backingInt(target), .acq_rel, .acquire) == null) {
            if (target == .freed) entry.free_fn(entry);
            return;
        }
    }
}

pub fn finishRefRelease(entry: *instance_map.RefEntry) void {
    while (true) {
        const state: instance_map.RefEntryState = @fromBackingInt(@intCast(entry.state.load(.acquire)));
        switch (state) {
            .releasing, .releasing_abandoned => {
                if (entry.state.cmpxchgWeak(@backingInt(state), @backingInt(instance_map.RefEntryState.freed), .acq_rel, .acquire) == null) {
                    entry.free_fn(entry);
                    return;
                }
            },
            .freed => return,
            .linked, .released, .abandoned => unreachable,
        }
    }
}

pub fn registerEntryDirect(inst: *instance_map.EngineInstance, entry: *instance_map.RefEntry) void {
    inst.ref_bookkeeping.mutex.lock();
    defer inst.ref_bookkeeping.mutex.unlock();
    entry.prev = null;
    entry.next = inst.ref_bookkeeping.head;
    if (inst.ref_bookkeeping.head) |h| h.prev = entry;
    inst.ref_bookkeeping.head = entry;
}
