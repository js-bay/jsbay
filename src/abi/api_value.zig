//! Opaque Value API state. Handles are allocated as generational slots in HyperBox layout with O(1) ABA validation.

const std = @import("std");
const sync = @import("zev");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");
const OwnedValue = @import("../value/root.zig").OwnedValue;
const hyper_box = @import("hyper_box");

const Owner = struct { thread_id: u64 };
const ActiveEngine = backend.ActiveEngine;

pub const HyperValue = hyper_box.Value;
pub const SlotMap = hyper_box.GenerationalSlotMap(ActiveEngine.Value);
pub const Entry = SlotMap.Entry;

var mutex: sync.Mutex = .{};
var registry_allocator: ?std.mem.Allocator = null;
var owners: std.AutoHashMapUnmanaged(i32, Owner) = .{};
var slot_map: ?SlotMap = null;
var initialized = std.atomic.Value(bool).init(false);

/// Ensure the value registry is initialized with the supplied allocator.
/// If already initialized, this is a thread-safe no-op that preserves existing state and returns true.
pub fn ensureInitialized(allocator: std.mem.Allocator) bool {
    if (initialized.load(.acquire)) return true;
    mutex.lock();
    defer mutex.unlock();
    if (initialized.load(.monotonic)) return true;
    registry_allocator = allocator;
    owners = .{};
    slot_map = SlotMap.init(allocator);
    initialized.store(true, .release);
    return true;
}

/// Reset and reinitialize the value registry lifecycle with an explicitly supplied allocator.
/// Callers (such as test suites) govern all slot-array and instance-index allocations.
pub fn init(allocator: std.mem.Allocator) void {
    mutex.lock();
    defer mutex.unlock();
    if (slot_map) |*sm| sm.deinit();
    if (registry_allocator) |alloc| owners.deinit(alloc);
    registry_allocator = allocator;
    owners = .{};
    slot_map = SlotMap.init(allocator);
    initialized.store(true, .release);
}

/// Reset and deinitialize the registry, releasing all slot and owner memory back to the supplied allocator.
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    initialized.store(false, .release);
    if (slot_map) |*sm| sm.deinit();
    if (registry_allocator) |alloc| owners.deinit(alloc);
    owners = .{};
    slot_map = null;
    registry_allocator = null;
}

pub fn isInitialized() bool {
    return initialized.load(.acquire);
}

/// Record the owner of a successfully-created public C API instance.
pub fn noteCreated(instance_id: i32) bool {
    mutex.lock();
    defer mutex.unlock();
    const alloc = registry_allocator orelse return false;
    owners.put(alloc, instance_id, .{ .thread_id = std.Thread.getCurrentId() }) catch return false;
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
        const removed = if (slot_map) |*sm| sm.detachFirstForInstance(instance_id) else null;
        mutex.unlock();
        const entry = removed orelse break;
        // Callback-local handles borrow the VM's stack values and carry no backend reference. They are normally revoked by the trampoline; teardown defensively removes a leaked one without freeing it.
        if (!entry.borrowed and !entry.reserved) {
            if (instance_map.getPtrs(instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, entry.value);
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
    const val = HyperValue{ .raw = value };
    if (!val.isHandle()) return null;
    mutex.lock();
    defer mutex.unlock();
    const sm = slot_map orelse return null;
    return sm.instanceFor(value);
}

pub fn get(value: u64) ?Entry {
    const val = HyperValue{ .raw = value };
    if (!val.isHandle()) return null;
    mutex.lock();
    defer mutex.unlock();
    const sm = slot_map orelse return null;
    return sm.get(value);
}

/// Store an owned backend value. The caller transfers its reference here.
pub fn putOwned(instance_id: i32, value: ActiveEngine.Value) ?u64 {
    mutex.lock();
    defer mutex.unlock();
    if (!owners.contains(instance_id)) return null;
    var sm = &(slot_map orelse return null);
    return sm.insert(instance_id, value, false) catch return null;
}

pub const ReserveHandleError = error{
    HandleExhausted,
    OutOfMemory,
};

pub const ReservedHandle = struct {
    handle: u64,

    pub fn commit(self: ReservedHandle, owned: *OwnedValue) bool {
        mutex.lock();
        defer mutex.unlock();
        var sm = &(slot_map orelse return false);
        if (sm.commit(self.handle, owned.borrow())) {
            _ = owned.release();
            return true;
        }
        return false;
    }

    pub fn cancel(self: ReservedHandle) void {
        mutex.lock();
        defer mutex.unlock();
        if (slot_map) |*sm| {
            _ = sm.cancel(self.handle);
        }
    }
};

/// Reserve a handle and actual table slot in advance so publishing can never fail with out-of-memory or capacity race.
pub fn reserveHandle(instance_id: i32) ReserveHandleError!ReservedHandle {
    mutex.lock();
    defer mutex.unlock();
    if (!owners.contains(instance_id)) return error.OutOfMemory;
    var sm = &(slot_map orelse return error.OutOfMemory);
    const handle = sm.reserve(instance_id, ActiveEngine.nullValue()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .handle = handle };
}

/// Publish a callback-local view without acquiring a backend reference. The trampoline revokes it before returning to JavaScript; callers can retain it to obtain an ordinary owned handle.
pub fn putBorrowed(instance_id: i32, value: ActiveEngine.Value) ?u64 {
    mutex.lock();
    defer mutex.unlock();
    if (!owners.contains(instance_id)) return null;
    var sm = &(slot_map orelse return null);
    return sm.insert(instance_id, value, true) catch return null;
}

pub fn revokeBorrowed(value: u64) void {
    const val = HyperValue{ .raw = value };
    if (!val.isHandle()) return;
    mutex.lock();
    defer mutex.unlock();
    if (slot_map) |*sm| {
        if (sm.get(value)) |entry| {
            if (entry.borrowed) _ = sm.remove(value);
        }
    }
}

/// Remove an owned reference for transfer back into a backend callback.
pub fn takeOwned(value: u64) ?Entry {
    const val = HyperValue{ .raw = value };
    if (!val.isHandle()) return null;
    mutex.lock();
    defer mutex.unlock();
    var sm = &(slot_map orelse return null);
    const entry = sm.get(value) orelse return null;
    if (entry.borrowed or entry.reserved) return null;
    return sm.remove(value);
}

/// Remove an owned reference for transfer back into a backend callback, synthesizing an entry for unboxed primitives.
pub fn takeOwnedOrSynthesize(instance_id: i32, value: u64) ?Entry {
    const val = HyperValue{ .raw = value };
    if (val.isEmpty()) return null;
    if (val.isUndefined()) return .{ .instance_id = instance_id, .value = ActiveEngine.undefinedValue() };
    if (val.isNull()) return .{ .instance_id = instance_id, .value = ActiveEngine.nullValue() };
    if (val.isPrimitive()) {
        const ptrs = instance_map.getPtrs(instance_id) orelse return null;
        if (val.isBool()) return .{ .instance_id = instance_id, .value = ActiveEngine.newBoolVal(ptrs.ctx, val.asBool()) };
        if (val.isInt32()) return .{ .instance_id = instance_id, .value = ActiveEngine.newInt32Val(ptrs.ctx, val.asInt32()) };
        if (val.isDouble()) return .{ .instance_id = instance_id, .value = ActiveEngine.newFloat64Val(ptrs.ctx, val.asFloat()) };
        if (val.isSso()) {
            const sso_buf = val.asSsoBytes();
            return .{ .instance_id = instance_id, .value = ActiveEngine.newStringVal(ptrs.ctx, sso_buf.slice()) };
        }
    }
    return takeOwned(value);
}

pub fn freeTaken(entry: Entry) void {
    if (instance_map.getPtrs(entry.instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, entry.value);
}

/// Duplicate a backend value and store the duplicate as a new handle.
pub fn retain(value: u64) ?u64 {
    const val = HyperValue{ .raw = value };
    if (val.isPrimitive()) return value;
    if (!val.isHandle()) return null;

    mutex.lock();
    const entry = if (slot_map) |sm| sm.get(value) else null;
    mutex.unlock();
    const live_entry = entry orelse return null;
    const ctx = (instance_map.getPtrs(live_entry.instance_id) orelse return null).ctx;
    const duplicate = ActiveEngine.dupValue(ctx, live_entry.value);
    mutex.lock();
    defer mutex.unlock();
    if (!owners.contains(live_entry.instance_id)) {
        ActiveEngine.freeValue(ctx, duplicate);
        return null;
    }
    var sm = &(slot_map orelse {
        ActiveEngine.freeValue(ctx, duplicate);
        return null;
    });
    return sm.insert(live_entry.instance_id, duplicate, false) catch {
        ActiveEngine.freeValue(ctx, duplicate);
        return null;
    };
}

pub fn release(value: u64) bool {
    const val = HyperValue{ .raw = value };
    if (val.isPrimitive()) return true;
    if (!val.isHandle()) return false;

    mutex.lock();
    const existing = if (slot_map) |sm| sm.get(value) else null;
    if (existing == null) {
        mutex.unlock();
        return false;
    }
    if (existing.?.borrowed or existing.?.reserved) {
        mutex.unlock();
        return false;
    }
    var sm = &(slot_map orelse {
        mutex.unlock();
        return false;
    });
    const entry = sm.remove(value);
    mutex.unlock();
    const removed = entry orelse return false;
    if (instance_map.getPtrs(removed.instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, removed.value);
    return true;
}

pub fn isBorrowed(value: u64) bool {
    const val = HyperValue{ .raw = value };
    if (!val.isHandle()) return false;
    mutex.lock();
    defer mutex.unlock();
    const sm = slot_map orelse return false;
    const entry = sm.get(value) orelse return false;
    return entry.borrowed;
}

pub fn isReserved(value: u64) bool {
    const val = HyperValue{ .raw = value };
    if (!val.isHandle()) return false;
    mutex.lock();
    defer mutex.unlock();
    const sm = slot_map orelse return false;
    return sm.isReserved(value);
}

test "api_value: handle reservation, commit, cancel, and access invariants" {
    init(std.testing.allocator);
    defer deinit();

    const instance_id: i32 = 98_765;
    try std.testing.expect(noteCreated(instance_id));
    defer dropInstance(instance_id);

    // 1. Reserve handle
    const reserved = try reserveHandle(instance_id);
    try std.testing.expect(reserved.handle != 0);

    // Invariant: Uncommitted reserved handle cannot be retrieved via get()
    try std.testing.expect(get(reserved.handle) == null);

    // Invariant: Uncommitted reserved handle cannot be queried via instanceFor()
    try std.testing.expect(instanceFor(reserved.handle) == null);

    // Invariant: Uncommitted reserved handle cannot be released via release()
    try std.testing.expect(!release(reserved.handle));

    // Invariant: Uncommitted reserved handle cannot be taken via takeOwned()
    try std.testing.expect(takeOwned(reserved.handle) == null);

    // Commit handle
    var owned = OwnedValue.init(undefined, ActiveEngine.nullValue());
    try std.testing.expect(reserved.commit(&owned));

    // After commit, get() returns the entry and is not reserved
    const entry = get(reserved.handle);
    try std.testing.expect(entry != null);
    try std.testing.expect(!entry.?.reserved);
    try std.testing.expectEqual(instance_id, entry.?.instance_id);

    // takeOwned succeeds after commit
    const taken = takeOwned(reserved.handle);
    try std.testing.expect(taken != null);
    try std.testing.expectEqual(instance_id, taken.?.instance_id);

    // After takeOwned, handle is completely gone
    try std.testing.expect(get(reserved.handle) == null);

    // 2. Cancellation removes the reserved placeholder
    const reserved2 = try reserveHandle(instance_id);
    try std.testing.expect(reserved2.handle != 0);
    reserved2.cancel();
    try std.testing.expect(get(reserved2.handle) == null);
    try std.testing.expect(takeOwned(reserved2.handle) == null);

    // 3. dropInstance with concurrent reserved handles safely skips placeholders
    const reserved3 = try reserveHandle(instance_id);
    dropInstance(instance_id);
    reserved3.cancel();
    try std.testing.expect(get(reserved3.handle) == null);

    // 4. Committing a cancelled or dropped reservation fails cleanly
    var dead_owned = OwnedValue.init(undefined, ActiveEngine.nullValue());
    try std.testing.expect(!reserved3.commit(&dead_owned));

    // 5. Retaining after instance is dropped returns null cleanly
    try std.testing.expect(retain(reserved.handle) == null);
}

test "api_value: concurrent ensureInitialized is idempotent and preserves registrations" {
    init(std.testing.allocator);
    defer deinit();

    const Worker = struct {
        fn run(alloc: std.mem.Allocator) void {
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                _ = ensureInitialized(alloc);
            }
        }
    };

    const thread1 = try std.Thread.spawn(.{}, Worker.run, .{std.testing.allocator});
    const thread2 = try std.Thread.spawn(.{}, Worker.run, .{std.testing.allocator});
    const thread3 = try std.Thread.spawn(.{}, Worker.run, .{std.testing.allocator});

    Worker.run(std.testing.allocator);

    thread1.join();
    thread2.join();
    thread3.join();

    try std.testing.expect(isInitialized());
    const instance_id: i32 = 12_345;
    try std.testing.expect(noteCreated(instance_id));
    defer dropInstance(instance_id);
    try std.testing.expect(isOwner(instance_id));
}
