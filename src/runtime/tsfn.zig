//! Thread-safe function (TSFN) — call a pinned JS callback from any thread.
//!
//! This is the js-bay analog of napi's `ThreadSafeFunction`. The JS runtime is single-threaded per instance; native code sometimes needs to trigger JS work from another thread (I/O completion, native timers, background workers). TSFN bridges that by pinning a JS callback on the JS thread and letting any thread enqueue a call that is later drained on the JS thread.
//!
//! ## Usage
//!
//! ```zig
//! // On the JS thread:
//! const handle = tsfn.acquire(instance_id, js_callback) orelse return;
//!
//! // On some other thread:
//! _ = tsfn.call(handle, "{\"progress\":42}");
//!
//! // The Driver wakes the owner thread and delivers pending calls.
//!
//! // When done:
//! tsfn.release(handle);
//! ```
//!
//! ## Drain semantics
//!
//! - The engine Driver iterates all live handles belonging to the instance and drains their pending queues, invoking the pinned callback with each payload as a single UTF-8 string argument.
//! - Callbacks are dispatched in their actual enqueue order across all handles for one instance.
//! - Any pending exceptions are drained so they do not poison the next script evaluation — TSFN drain is a "fire and forget" path by design.
//!
//! ## Release semantics
//!
//! `release(handle)` unpins the callback, frees any pending payloads that had not yet been drained, and marks the handle dead. Subsequent `call` on the released handle returns `false`. The handle id is retired; a fresh id is assigned on the next `acquire`.
//!
//! ## Wakeup
//!
//! `call` wakes the Driver so the owner loop delivers the payload.
//!
//! ## Thread-safety summary
//!
//! - Global handle table: `sync.Mutex`.
//! - Per-handle queue: `sync.Mutex`.
//! - JS value in the handle is only touched on the JS thread (acquire, release, drain). `call` never dereferences the pinned value.

const std = @import("std");
const sync = @import("zev");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const instance_map = @import("instance_map.zig");

const ActiveEngine = backend.ActiveEngine;

/// Opaque handle to a pinned JS function. Returned by `acquire` and passed back into `call` / `release`. A zero `id` is never a valid handle.
pub const TsfnHandle = extern struct {
    id: u64,
};

/// Single queued call targeted at a specific handle.
const PendingCall = struct {
    /// Owned, heap-allocated UTF-8 payload (c_allocator). Freed after the call is dispatched or when the handle is released.
    payload: []u8,
    sequence: u64,
};

/// Per-handle state. Pinned value is touched only on the JS thread.
const HandleEntry = struct {
    id: u64,
    resources: *@import("resource_limits.zig").Budget = undefined,
    instance_id: i32,
    /// The pinned JS function. Duped/protected on `acquire`, freed on `release`. Must only be accessed from the instance's owning thread.
    pinned: ActiveEngine.Value,
    queue: std.ArrayList(PendingCall),
    queue_head: usize = 0,
    queue_mutex: sync.Mutex = .{},
    /// True once released; further `call`s return false.
    dead: bool = false,
    /// One reference belongs to the handle table. Foreign `call`s and drain snapshots retain their own reference before dropping the table lock. `release` drops only the table reference, so native entry storage stays alive until those users have stopped inspecting it.
    refs: std.atomic.Value(usize) = .init(1),
};

fn queuePendingLen(entry: *const HandleEntry) usize {
    return entry.queue.items.len - entry.queue_head;
}

fn queueFront(entry: *const HandleEntry) ?*const PendingCall {
    if (entry.queue_head >= entry.queue.items.len) return null;
    return &entry.queue.items[entry.queue_head];
}

fn queuePopFront(entry: *HandleEntry) ?PendingCall {
    if (entry.queue_head >= entry.queue.items.len) return null;
    const pending = entry.queue.items[entry.queue_head];
    entry.queue_head += 1;
    if (entry.queue_head == entry.queue.items.len) {
        entry.queue.clearRetainingCapacity();
        entry.queue_head = 0;
    } else if (entry.queue_head >= 32) {
        const remain = entry.queue.items[entry.queue_head..];
        var write: usize = 0;
        while (write < remain.len) : (write += 1) {
            entry.queue.items[write] = remain[write];
        }
        entry.queue.shrinkRetainingCapacity(remain.len);
        entry.queue_head = 0;
    }
    return pending;
}

fn queueClear(entry: *HandleEntry, allocator: std.mem.Allocator) void {
    entry.queue.deinit(allocator);
    entry.queue = .empty;
    entry.queue_head = 0;
}

fn queueTakeAll(entry: *HandleEntry) std.ArrayList(PendingCall) {
    if (entry.queue_head == 0) {
        const pending = entry.queue;
        entry.queue = .empty;
        entry.queue_head = 0;
        return pending;
    }
    var pending: std.ArrayList(PendingCall) = .empty;
    const slice = entry.queue.items[entry.queue_head..];
    pending.appendSlice(std.heap.c_allocator, slice) catch {
        // Compact onto existing storage, then detach.
        var write: usize = 0;
        while (write < slice.len) : (write += 1) {
            entry.queue.items[write] = entry.queue.items[entry.queue_head + write];
        }
        entry.queue.shrinkRetainingCapacity(slice.len);
        entry.queue_head = 0;
        pending = entry.queue;
        entry.queue = .empty;
        return pending;
    };
    entry.queue.clearRetainingCapacity();
    entry.queue_head = 0;
    return pending;
}

// Global handle table — protected by `table_mutex`.
var table_mutex: sync.Mutex = .{};
var handles: std.AutoHashMap(u64, *HandleEntry) = std.AutoHashMap(u64, *HandleEntry).init(std.heap.c_allocator);
var next_id: u64 = 1;
var next_call_sequence: u64 = 1;

fn retainRef(entry: *HandleEntry) void {
    _ = entry.refs.fetchAdd(1, .seq_cst);
}

fn releaseRef(entry: *HandleEntry) void {
    const previous = entry.refs.fetchSub(1, .seq_cst);
    std.debug.assert(previous != 0);
    if (previous == 1) {
        entry.queue_mutex.deinit();
        const resources = entry.resources;
        std.heap.c_allocator.destroy(entry);
        resources.release(.tsfn_handle, 0);
    }
}

/// Pin a JS function so it can be invoked from any thread. Must be called on the JS (owning) thread for `instance_id`.
///
/// Returns null if the instance is not live, the value is not callable, or allocation fails.
pub fn acquire(instance_id: i32, js_function: ActiveEngine.Value) ?TsfnHandle {
    // Retain the context for the entire pin operation. Destruction waits for this lease before freeing JS values, including if a foreign thread starts teardown immediately after we entered.
    const lease = @import("engine_thread.zig").beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return null;
    const ctx = engine.getContext(instance_id) orelse return null;
    if (!ActiveEngine.isFunction(ctx, js_function)) return null;

    const entry = std.heap.c_allocator.create(HandleEntry) catch return null;
    errdefer std.heap.c_allocator.destroy(entry);

    entry.* = .{
        .id = 0, // set below under the table lock
        .instance_id = instance_id,
        .pinned = ActiveEngine.dupValue(ctx, js_function),
        .queue = .empty,
    };
    errdefer {
        ActiveEngine.freeValue(ctx, entry.pinned);
        entry.queue.deinit(std.heap.c_allocator);
    }

    // Serialize admission with teardown under the instance-map lock. No path takes table_mutex before this lock, so this cannot invert the table/VM ordering while still making close and insertion one decision.
    const inserted = instance_map.withInstanceReturn(instance_id, struct {
        entry: *HandleEntry,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?bool {
            if (inst.teardown_pending) return false;
            table_mutex.lock();
            defer table_mutex.unlock();
            if (next_id == std.math.maxInt(u64)) return false;
            if (!inst.resources.reserve(.tsfn_handle, 0)) return false;
            const id = next_id;
            next_id += 1;
            handles.put(id, self.entry) catch {
                inst.resources.release(.tsfn_handle, 0);
                return false;
            };
            self.entry.resources = inst.resources;
            self.entry.id = id;
            return true;
        }
    }{ .entry = entry }) orelse false;
    if (!inserted) {
        ActiveEngine.freeValue(ctx, entry.pinned);
        entry.queue.deinit(std.heap.c_allocator);
        entry.queue_mutex.deinit();
        std.heap.c_allocator.destroy(entry);
        return null;
    }

    return TsfnHandle{ .id = entry.id };
}

/// Enqueue a call to the pinned JS function. Safe to call from any thread. The bytes are copied — caller owns its buffer after this returns.
///
/// Returns `true` iff the call was successfully enqueued. Returns `false` when the handle id is unknown, when the handle has been released, or when payload allocation fails.
pub fn call(handle: TsfnHandle, payload: []const u8) bool {
    if (handle.id == 0) return false;
    table_mutex.lock();
    const entry = handles.get(handle.id) orelse {
        table_mutex.unlock();
        return false;
    };
    const inst_id = entry.instance_id;
    retainRef(entry);
    defer releaseRef(entry);
    entry.queue_mutex.lock();
    if (entry.dead or next_call_sequence == std.math.maxInt(u64) or !entry.resources.reserve(.tsfn_call, payload.len)) {
        entry.queue_mutex.unlock();
        table_mutex.unlock();
        return false;
    }
    const copy = std.heap.c_allocator.dupe(u8, payload) catch {
        entry.resources.release(.tsfn_call, payload.len);
        entry.queue_mutex.unlock();
        table_mutex.unlock();
        return false;
    };
    const sequence = next_call_sequence;
    next_call_sequence += 1;
    entry.queue.append(std.heap.c_allocator, .{ .payload = copy, .sequence = sequence }) catch {
        std.heap.c_allocator.free(copy);
        entry.resources.release(.tsfn_call, payload.len);
        entry.queue_mutex.unlock();
        table_mutex.unlock();
        return false;
    };
    entry.queue_mutex.unlock();
    table_mutex.unlock();
    signalInstance(inst_id);
    return true;
}

/// Release the handle. Must be called on the JS thread. Any pending calls that have not been drained yet are dropped (their payloads are freed).
pub fn release(handle: TsfnHandle) void {
    if (handle.id == 0) return;

    table_mutex.lock();
    const kv = handles.fetchRemove(handle.id) orelse {
        table_mutex.unlock();
        return;
    };
    table_mutex.unlock();

    releaseEntry(kv.value);
}

/// Release a detached entry. The caller must have removed it from `handles`. JS values are released outside the table lock because freeing one can run a finalizer that re-enters host code.
fn releaseEntry(entry: *HandleEntry) void {

    // Mark dead + snapshot the queue under the per-handle mutex so any concurrent `call` that raced past the table lookup observes `dead` before appending, or appends into a queue we're about to drain.
    entry.queue_mutex.lock();
    entry.dead = true;
    var pending = queueTakeAll(entry);
    entry.queue_mutex.unlock();

    // Free dropped payloads.
    for (pending.items) |pc| {
        std.heap.c_allocator.free(pc.payload);
        entry.resources.release(.tsfn_call, pc.payload.len);
    }
    pending.deinit(std.heap.c_allocator);

    // Free the pinned value on the JS thread (freeValue requires a live ctx).
    if (engine.getContext(entry.instance_id)) |ctx| {
        ActiveEngine.freeValue(ctx, entry.pinned);
    }

    entry.queue.deinit(std.heap.c_allocator);
    // Removing the table owner does not invalidate concurrent foreign calls or a drain snapshot. The final such user frees the native entry.
    releaseRef(entry);
}

/// Drain all pending calls for every live handle bound to `instance_id`. Must be called on the JS thread. Returns the number of calls dispatched.
///
/// Idempotent and safe to call when there are no pending calls. Exceptions raised by JS callbacks are swallowed (drained) so they do not poison a subsequent script evaluation — TSFN is a "fire and forget" dispatch path.
pub fn hasPending(instance_id: i32) bool {
    table_mutex.lock();
    defer table_mutex.unlock();
    var it = handles.valueIterator();
    while (it.next()) |entry_ptr| {
        const entry = entry_ptr.*;
        if (entry.instance_id != instance_id) continue;
        entry.queue_mutex.lock();
        const pending = !entry.dead and queuePendingLen(entry) != 0;
        entry.queue_mutex.unlock();
        if (pending) return true;
    }
    return false;
}

/// Run the oldest payload for this instance across all live handles. The caller owns the microtask checkpoint.
pub fn runOne(instance_id: i32) bool {
    const engine_thread = @import("engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed or engine_thread.deferredDestroyRequested(lease)) return false;
    const ctx = engine.getContext(instance_id) orelse return false;
    var queued = @import("js_scheduler.zig").beginQueuedTask(instance_id) orelse return false;

    table_mutex.lock();
    var selected: ?*HandleEntry = null;
    var selected_sequence: u64 = std.math.maxInt(u64);
    var it = handles.valueIterator();
    while (it.next()) |entry_ptr| {
        const entry = entry_ptr.*;
        if (entry.instance_id != instance_id) continue;
        entry.queue_mutex.lock();
        if (!entry.dead) {
            if (queueFront(entry)) |front| {
                if (front.sequence < selected_sequence) {
                    selected = entry;
                    selected_sequence = front.sequence;
                }
            }
        }
        entry.queue_mutex.unlock();
    }
    const entry = selected orelse {
        table_mutex.unlock();
        _ = queued.end();
        return false;
    };
    retainRef(entry);
    table_mutex.unlock();
    defer releaseRef(entry);

    entry.queue_mutex.lock();
    if (entry.dead or queuePendingLen(entry) == 0) {
        entry.queue_mutex.unlock();
        _ = queued.end();
        return false;
    }
    const pending = queuePopFront(entry).?;
    if (queuePendingLen(entry) == 0) {
        queueClear(entry, std.heap.c_allocator);
    }
    const callback = ActiveEngine.dupValue(ctx, entry.pinned);
    entry.queue_mutex.unlock();
    defer {
        std.heap.c_allocator.free(pending.payload);
        entry.resources.release(.tsfn_call, pending.payload.len);
    }
    defer ActiveEngine.freeValue(ctx, callback);

    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const arg = ActiveEngine.newStringVal(ctx, pending.payload);
    defer ActiveEngine.freeValue(ctx, arg);
    const args = [_]ActiveEngine.Value{arg};
    if (ActiveEngine.callFunction(ctx, callback, global, &args)) |result| ActiveEngine.freeValue(ctx, result);
    _ = queued.end();
    return true;
}

pub fn drainPending(instance_id: i32) usize {
    // The Driver may reach this path outside engine.evalScript. Keep the context admitted across callback and microtask execution.
    const engine_thread = @import("engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return 0;
    if (!@import("js_scheduler.zig").allowsQueuedWork(instance_id) or @import("js_scheduler.zig").isTurnActive(instance_id)) return 0;
    const ctx = engine.getContext(instance_id) orelse return 0;
    const initial_count = pendingCount(instance_id);
    var dispatched: usize = 0;
    while (dispatched < initial_count) {
        if (!runOne(instance_id)) break;
        @import("js_scheduler.zig").checkpoint(instance_id, ctx);
        dispatched += 1;
    }
    return dispatched;
}

/// Count work present when an explicit bulk pump begins. The table and each queue are inspected under their normal lock order, and no JavaScript runs while either lock is held.
fn pendingCount(instance_id: i32) usize {
    var count: usize = 0;
    table_mutex.lock();
    defer table_mutex.unlock();
    var it = handles.valueIterator();
    while (it.next()) |entry_ptr| {
        const entry = entry_ptr.*;
        if (entry.instance_id != instance_id) continue;
        entry.queue_mutex.lock();
        if (!entry.dead) count += queuePendingLen(entry);
        entry.queue_mutex.unlock();
    }
    return count;
}

/// Wake the instance's event loop so it drains.
fn signalInstance(instance_id: i32) void {
    instance_map.withInstance(instance_id, struct {
        pub fn call(_: @This(), inst: *instance_map.EngineInstance) void {
            inst.loop.wake();
        }
    }{});
    @import("js_event_loop").host_wake.notify(instance_id);
}

// ---------------------------------------------------------------------------
// Test-only helper — not exported publicly via root.zig. Used to cleanly tear down the global table between tests that exercise failure paths. Real consumers should rely on `release` + instance destruction.
// ---------------------------------------------------------------------------

/// Release every handle owned by `instance_id`. This performs no allocation:
/// teardown must be able to invalidate all handles even under OOM.
pub fn releaseAllForInstance(instance_id: i32) void {
    while (true) {
        table_mutex.lock();
        var found_id: ?u64 = null;
        var it = handles.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.*.instance_id == instance_id) {
                found_id = kv.key_ptr.*;
                break;
            }
        }
        const entry = if (found_id) |id| handles.fetchRemove(id).?.value else null;
        table_mutex.unlock();
        const detached = entry orelse break;
        releaseEntry(detached);
    }
}
