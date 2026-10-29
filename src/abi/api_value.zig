//! Opaque Value API state. Handles are allocated monotonically and are never reused, so an old handle cannot become valid after an instance is recreated.

const std = @import("std");
const sync = @import("zev");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");

const Owner = struct { thread_id: u64 };
const ActiveEngine = backend.ActiveEngine;

pub const Entry = struct {
    instance_id: i32,
    value: ActiveEngine.Value,
    borrowed: bool = false,
};

var mutex: sync.Mutex = .{};
var owners = std.AutoHashMap(i32, Owner).init(std.heap.c_allocator);
var values = std.AutoHashMap(u64, Entry).init(std.heap.c_allocator);
var next_handle: u64 = 1;

/// Record the owner of a successfully-created public C API instance.
pub fn noteCreated(instance_id: i32) bool {
    mutex.lock();
    defer mutex.unlock();
    owners.put(instance_id, .{ .thread_id = std.Thread.getCurrentId() }) catch return false;
    return true;
}

/// Drop all public API state for an instance before its backend context dies. engine.destroy uses this hook to release the value table.
pub fn dropInstance(instance_id: i32) void {
    mutex.lock();
    _ = owners.remove(instance_id);
    mutex.unlock();

    // Detach one entry at a time. Never hold metadata state while entering a backend, and never allocate while tearing down (OOM must not leak a JS value or leave a live public handle behind).
    while (true) {
        mutex.lock();
        var found: ?u64 = null;
        var it = values.iterator();
        while (it.next()) |item| {
            if (item.value_ptr.instance_id == instance_id) {
                found = item.key_ptr.*;
                break;
            }
        }
        const entry = if (found) |handle| values.fetchRemove(handle) else null;
        mutex.unlock();
        const removed = entry orelse break;
        // Callback-local handles borrow the VM's stack values and carry no backend reference.  They are normally revoked by the trampoline; teardown defensively removes a leaked one without freeing it.
        if (!removed.value.borrowed) {
            if (instance_map.getPtrs(instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, removed.value.value);
        }
    }
}

/// Owner OS thread id recorded at create, or null if the instance is unknown / already dropped.
pub fn ownerThreadId(instance_id: i32) ?u64 {
    mutex.lock();
    defer mutex.unlock();
    const owner = owners.get(instance_id) orelse return null;
    return owner.thread_id;
}

/// Public Value operations use this to enforce the owner-thread contract.
pub fn isOwner(instance_id: i32) bool {
    mutex.lock();
    defer mutex.unlock();
    const owner = owners.get(instance_id) orelse return false;
    return owner.thread_id == std.Thread.getCurrentId();
}

/// True while noteCreated has recorded an owner and dropInstance has not yet cleared it.
pub fn hasOwner(instance_id: i32) bool {
    mutex.lock();
    defer mutex.unlock();
    return owners.contains(instance_id);
}

pub fn instanceFor(value: u64) ?i32 {
    mutex.lock();
    defer mutex.unlock();
    return (values.get(value) orelse return null).instance_id;
}

pub fn get(value: u64) ?Entry {
    mutex.lock();
    defer mutex.unlock();
    return values.get(value);
}

/// Store an owned backend value. The caller transfers its reference here.
pub fn putOwned(instance_id: i32, value: ActiveEngine.Value) ?u64 {
    mutex.lock();
    defer mutex.unlock();
    if (next_handle == 0 or next_handle > std.math.maxInt(i64)) return null;
    const handle = next_handle;
    next_handle += 1;
    values.put(handle, .{ .instance_id = instance_id, .value = value }) catch return null;
    return handle;
}

/// Publish a callback-local view without acquiring a backend reference.  The trampoline revokes it before returning to JavaScript; callers can retain it to obtain an ordinary owned handle.
pub fn putBorrowed(instance_id: i32, value: ActiveEngine.Value) ?u64 {
    mutex.lock();
    defer mutex.unlock();
    if (next_handle == 0 or next_handle > std.math.maxInt(i64)) return null;
    const handle = next_handle;
    next_handle += 1;
    values.put(handle, .{ .instance_id = instance_id, .value = value, .borrowed = true }) catch return null;
    return handle;
}

pub fn revokeBorrowed(value: u64) void {
    mutex.lock();
    defer mutex.unlock();
    const entry = values.get(value) orelse return;
    if (entry.borrowed) _ = values.remove(value);
}

/// Remove an owned reference for transfer back into a backend callback.
pub fn takeOwned(value: u64) ?Entry {
    mutex.lock();
    defer mutex.unlock();
    const entry = values.get(value) orelse return null;
    if (entry.borrowed) return null;
    return (values.fetchRemove(value) orelse return null).value;
}

pub fn freeTaken(entry: Entry) void {
    if (instance_map.getPtrs(entry.instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, entry.value);
}

/// Duplicate a backend value and store the duplicate as a new handle.
pub fn retain(value: u64) ?u64 {
    mutex.lock();
    const entry = values.get(value);
    mutex.unlock();
    const live_entry = entry orelse return null;
    const ctx = (instance_map.getPtrs(live_entry.instance_id) orelse return null).ctx;
    const duplicate = ActiveEngine.dupValue(ctx, live_entry.value);
    mutex.lock();
    defer mutex.unlock();
    const handle = next_handle;
    if (handle == 0 or handle > std.math.maxInt(i64)) {
        ActiveEngine.freeValue(ctx, duplicate);
        return null;
    }
    values.put(handle, .{ .instance_id = live_entry.instance_id, .value = duplicate }) catch {
        ActiveEngine.freeValue(ctx, duplicate);
        return null;
    };
    next_handle += 1;
    return handle;
}

pub fn release(value: u64) bool {
    mutex.lock();
    if ((values.get(value) orelse {
        mutex.unlock();
        return false;
    }).borrowed) {
        mutex.unlock();
        return false;
    }
    const entry = values.fetchRemove(value);
    mutex.unlock();
    const removed = entry orelse return false;
    if (instance_map.getPtrs(removed.value.instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, removed.value.value);
    return true;
}
