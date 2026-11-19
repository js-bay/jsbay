//! Thread-safe global registry of engine instances.
//!
//! Design: The global Mutex protects only the HashMap. All accessors either:
//! - getPtrs(): copy raw pointers out and release the lock (does not refuse teardown)
//! - beginControlPlane(): lease ptrs while refusing teardown_pending; destroy waits
//! - beginLifecycleControlPlane(): same lease, admitted after teardown so stop/destroy can still trigger Hermes interrupts; destroyRuntime still waits on active_control_ops
//! - withInstance(): hold the lock for a short closure (no JS callbacks inside)

const std = @import("std");
const sync = @import("zev");
const backend = @import("../backend.zig");
const types = @import("../types.zig");
const timers = @import("timers.zig");
const event_loop = @import("js_event_loop");

const ActiveEngine = backend.ActiveEngine;

/// Intrusive bookkeeping cell for Global/Weak references so engine.destroy can force-reset live references before the JS runtime is freed. The entry itself is heap-allocated; the owning Global/Weak holds a pointer to it so it can unlink on reset.
pub const RefEntry = struct {
    next: ?*RefEntry = null,
    prev: ?*RefEntry = null,
    /// Called by engine.destroy to release the retained JS value (if any) BEFORE the context is freed. The entry is already unlinked from the bookkeeping list by the caller, so implementations must not touch the list — they only need to freeValue/mark the cell released.
    reset_fn: *const fn (entry: *RefEntry) void,
};

/// Per-engine intrusive list of live Global/Weak references. Mutex-protected because Global.reset may be invoked from a finalizer or another thread during teardown.
pub const RefBookkeeping = struct {
    head: ?*RefEntry = null,
    mutex: sync.Mutex = .{},
};

pub const EngineHandles = union(enum) {
    /// Pack primary — typed ActiveEngine handles used by the monomorphic shared layers.
    mono: struct {
        runtime: ActiveEngine.Runtime,
        ctx: ActiveEngine.Context,
    },
    /// Non-primary packed backend — erased pointers; lifecycle via `backend_dispatch`.
    packed_alt: struct {
        tag: backend.BackendType,
        runtime_addr: usize,
        ctx_addr: usize,
    },
};

pub const GcSubmissionState = enum(u8) {
    idle = 0,
    submitting = 1,
    queued = 2,
};

pub const EngineInstance = struct {
    /// Called after registry removal and all admitted users have drained.
    pub fn deinitSynchronization(self: *EngineInstance) void {
        self.dispatch_wake.deinit();
        self.dispatch_mutex.deinit();
        self.native_task_queue.mutex.deinit();
        self.task_mutex.deinit();
        self.ref_bookkeeping.mutex.deinit();
    }

    pub fn backendTag(self: *const EngineInstance) backend.BackendType {
        return switch (self.engine_handles) {
            .mono => backend.active_backend,
            .packed_alt => |a| a.tag,
        };
    }

    pub fn isPrimaryBackend(self: *const EngineInstance) bool {
        return self.engine_handles == .mono;
    }

    pub fn monoCtx(self: *const EngineInstance) ?ActiveEngine.Context {
        return switch (self.engine_handles) {
            .mono => |m| m.ctx,
            .packed_alt => null,
        };
    }

    pub fn monoRuntime(self: *const EngineInstance) ?ActiveEngine.Runtime {
        return switch (self.engine_handles) {
            .mono => |m| m.runtime,
            .packed_alt => null,
        };
    }

    allocator: std.mem.Allocator,
    instance_id: i32,
    /// Changes on every successful publication, including when an id is reused. Asynchronous producers must capture this with `dispatch.captureInstanceToken` before starting work and use it when posting the result.
    generation: u64 = 0,
    resources: *@import("resource_limits.zig").Budget,
    execution_cpu: ?*@import("execution_cpu.zig").Ledger = null,
    engine_handles: EngineHandles,
    loop: *event_loop.Driver,
    timers: timers.TimerRegistry,
    task_queue: TaskQueue = .{},
    task_mutex: sync.Mutex = .{},
    task_admission_closed: bool = false,
    native_task_queue: @import("dispatch.zig").NativeTaskQueue = .{},
    /// Blocks new work before destruction can detach engine-thread state.
    teardown_pending: bool = false,
    dispatch_mutex: sync.Mutex = .{},
    dispatch_wake: sync.Condition = .init,
    active_dispatch_tasks: usize = 0,
    /// In-flight cross-thread control-plane ops (suspend/resume/stop/is_suspended). Destroy waits before freeing the Driver.
    active_control_ops: usize = 0,
    /// OS thread that created the JS runtime/context. Escargot Context is affine to this thread: `delete ctx` on another thread SIGSEGVs even after threadEnter.
    js_owner_tid: std.Thread.Id = undefined,
    error_observer: ?types.ErrorObserver = null,
    error_observer_userdata: ?*anyopaque = null,
    /// Set only after owner (or destroyer) JS teardown has returned, not when cleanup is merely claimed.
    ///
    /// Together with `js_teardown_in_progress` this is the wait handshake: destroyers may not `allocator.destroy` the instance until cleanup finishes. This is also the anti-double-free claim after the wait.
    js_teardown_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Touched only under `dispatch_mutex`. Set before the owner drops the mutex to run `releaseJsResources`, and cleared after that call returns (and after `js_teardown_done` is published).
    ///
    /// `waitForControlOps` waits on this as well as `active_control_ops`, so a destroyer that enters wait after the last lease hits zero still cannot proceed during owner cleanup.
    js_teardown_in_progress: bool = false,
    /// Coalesces concurrent cross-thread post_gc requests before the scheduled run executes.
    gc_state: std.atomic.Value(GcSubmissionState) = std.atomic.Value(GcSubmissionState).init(.idle),
    // Extension points for host apps
    log_handler: ?types.LogHandler = null,
    log_user_data: ?*anyopaque = null,
    event_handler: ?types.EngineEventHandler = null,
    event_user_data: ?*anyopaque = null,
    /// Bookkeeping list for live Global(T) / Weak(T) references.
    ref_bookkeeping: RefBookkeeping = .{},
    /// Frame bump arena for per-turn transient memory, bulk-reset at checkpoint boundaries.
    turn_arena: FrameArena = .{},
};

/// Fixed-capacity cache-line aligned bump arena for per-turn transient allocations.
pub const FrameArena = struct {
    const BUFFER_CAP: usize = 64 * 1024;
    buffer: [BUFFER_CAP]u8 align(64) = undefined,
    offset: usize = 0,

    pub fn allocator(self: *FrameArena) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *FrameArena = @ptrCast(@alignCast(ctx));
        const align_size = @as(usize, 1) << @intCast(ptr_align);
        const aligned = std.mem.alignForward(usize, self.offset, align_size);
        if (aligned > BUFFER_CAP or len > BUFFER_CAP - aligned) return null;
        self.offset = aligned + len;
        return @ptrCast(&self.buffer[aligned]);
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        _ = .{ ctx, buf, buf_align, new_len, ret_addr };
        return false;
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = .{ ctx, buf, buf_align, ret_addr };
    }

    pub fn reset(self: *FrameArena) void {
        self.offset = 0;
    }
};

/// Queue for dispatched tasks (thread-safe via task_mutex on EngineInstance).
const TaskQueue = struct {
    items: std.ArrayList([:0]const u8) = .empty,
    head: usize = 0,

    pub fn pendingLen(self: *const TaskQueue) usize {
        return self.items.items.len - self.head;
    }

    pub fn pendingSlice(self: *const TaskQueue) []const [:0]const u8 {
        return self.items.items[self.head..];
    }

    pub fn push(self: *TaskQueue, allocator: std.mem.Allocator, script: [:0]const u8) !void {
        if (self.head > 0 and self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        }
        try self.items.append(allocator, script);
    }

    pub fn popFront(self: *TaskQueue) ?[:0]const u8 {
        if (self.head >= self.items.items.len) return null;
        const script = self.items.items[self.head];
        self.head += 1;
        if (self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= 64 and self.head >= self.items.items.len / 2) {
            const remain = self.items.items[self.head..];
            var write: usize = 0;
            while (write < remain.len) : (write += 1) {
                self.items.items[write] = remain[write];
            }
            self.items.shrinkRetainingCapacity(remain.len);
            self.head = 0;
        }
        return script;
    }

    pub fn clear(self: *TaskQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.items = .empty;
        self.head = 0;
    }
};

const InstanceMap = std.AutoHashMap(i32, *EngineInstance);

var instances: InstanceMap = InstanceMap.init(std.heap.c_allocator);
var mutex: sync.Mutex = .{};
var next_generation: u64 = 1;

pub fn insert(instance: *EngineInstance) bool {
    return insertWith(instance, struct {
        fn call(_: @This(), _: *EngineInstance) bool {
            return true;
        }
    }{});
}

/// Publish an instance and finish its non-reentrant initialization while readers and teardown are excluded by the registry mutex. The callback must not look up instances or run JS callbacks.
pub fn insertWith(instance: *EngineInstance, on_inserted: anytype) bool {
    mutex.lock();
    defer mutex.unlock();
    if (instances.contains(instance.instance_id)) return false;
    if (next_generation == 0) return false;
    instance.generation = next_generation;
    next_generation +%= 1;
    instance.js_owner_tid = std.Thread.getCurrentId();
    instances.put(instance.instance_id, instance) catch return false;
    if (!on_inserted.call(instance)) {
        _ = instances.fetchRemove(instance.instance_id);
        return false;
    }
    return true;
}

/// Read the current generation while the registry still admits work. This is intentionally one operation so callers cannot accidentally capture a token from an instance that teardown has already closed.
pub fn captureGeneration(instance_id: i32) ?u64 {
    mutex.lock();
    defer mutex.unlock();
    const inst = instances.get(instance_id) orelse return null;
    if (inst.task_admission_closed or inst.teardown_pending) return null;
    return inst.generation;
}

pub fn remove(instance_id: i32) ?*EngineInstance {
    mutex.lock();
    defer mutex.unlock();
    const kv = instances.fetchRemove(instance_id) orelse return null;
    return kv.value;
}

/// Returns true once the requested generation is no longer registered. Unlike control-plane queries, teardown-pending entries remain visible so hosts can wait for physical runtime destruction.
pub fn isDestroyed(instance_id: i32, generation: u64) bool {
    if (generation == 0) return false;
    mutex.lock();
    defer mutex.unlock();
    const inst = instances.get(instance_id) orelse return true;
    return inst.generation != generation;
}

pub const InstancePtrs = struct {
    /// Valid ActiveEngine context only when `backend_tag == active_backend` (mono handle).
    ctx: ActiveEngine.Context,
    loop: *event_loop.Driver,
    backend_tag: backend.BackendType = backend.active_backend,
};

pub fn getPtrs(instance_id: i32) ?InstancePtrs {
    mutex.lock();
    defer mutex.unlock();
    const inst = instances.get(instance_id) orelse return null;
    return switch (inst.engine_handles) {
        .mono => |m| .{ .ctx = m.ctx, .loop = inst.loop, .backend_tag = backend.active_backend },
        // Existence must succeed for packed-alt; ctx is a typed placeholder and must not be used with ActiveEngine.* — use backend_dispatch instead.
        .packed_alt => |a| .{
            .ctx = @ptrFromInt(0),
            .loop = inst.loop,
            .backend_tag = a.tag,
        },
    };
}

/// Short-lived lease for cross-thread control-plane entry points that touch `loop` outside the registry lock.
/// Refuses `teardown_pending` so Hide/Show/stop cannot start after destroy has closed admission.
/// Destroy waits via `waitForControlOps` before `loop.destroy`, closing the getPtrs∩destroy UAF window.
pub const ControlLease = struct {
    inst: *EngineInstance,
    ptrs: InstancePtrs,

    pub fn end(self: ControlLease) void {
        endControlPlane(self.inst);
    }
};

pub fn beginControlPlane(instance_id: i32) ?ControlLease {
    return beginControlPlaneInner(instance_id, false);
}

/// Like `beginControlPlane`, but still admitted after `markTeardownPending`.
///
/// Hide/Show and public stop must keep using `beginControlPlane` so they cannot start after admission closes.
///
/// Stop/destroy interrupt (`asyncTriggerTimeout`, `watchTimeLimit`, idle drain) must use this lease: `destroyNow` marks teardown first, and `destroyRuntime` already waits on `active_control_ops` before freeing the runtime.
pub fn beginLifecycleControlPlane(instance_id: i32) ?ControlLease {
    return beginControlPlaneInner(instance_id, true);
}

fn beginControlPlaneInner(instance_id: i32, allow_teardown: bool) ?ControlLease {
    mutex.lock();
    defer mutex.unlock();
    const inst = instances.get(instance_id) orelse return null;
    if (!allow_teardown and inst.teardown_pending) return null;
    inst.dispatch_mutex.lock();
    inst.active_control_ops += 1;
    inst.dispatch_mutex.unlock();
    return .{
        .inst = inst,
        .ptrs = switch (inst.engine_handles) {
            .mono => |m| .{ .ctx = m.ctx, .loop = inst.loop, .backend_tag = backend.active_backend },
            .packed_alt => |a| .{
                .ctx = @ptrFromInt(0),
                .loop = inst.loop,
                .backend_tag = a.tag,
            },
        },
    };
}

pub fn endControlPlane(inst: *EngineInstance) void {
    inst.dispatch_mutex.lock();
    std.debug.assert(inst.active_control_ops != 0);
    inst.active_control_ops -= 1;
    const last = inst.active_control_ops == 0;
    // Escargot: if this last lease is dropped on the JS owner thread after
    // teardown started, free the Context here *before* waking destroyRuntime.
    // The crash test holds the reservation on the creator thread, drops it,
    // then join()s the foreign destroyer — hopping delete after join starts
    // would deadlock, and threadEnter on the destroyer is not enough.
    const owner_js = (comptime backend.isEscargotBackend(backend.active_backend)) and last and inst.teardown_pending and inst.js_owner_tid == std.Thread.getCurrentId() and !inst.js_teardown_done.load(.acquire);
    if (!owner_js) {
        inst.dispatch_wake.broadcast();
        inst.dispatch_mutex.unlock();
        return;
    }
    // Publish in-progress under the same lock as the decrement so a late waitForControlOps cannot observe ops==0 with cleanup not yet started (and must not observe in_progress==false before cleanup returns).
    inst.js_teardown_in_progress = true;
    inst.dispatch_mutex.unlock();
    defer {
        inst.dispatch_mutex.lock();
        inst.js_teardown_in_progress = false;
        inst.dispatch_wake.broadcast();
        inst.dispatch_mutex.unlock();
    }
    @import("../engine.zig").finishOwnerThreadJsTeardown(inst.instance_id);
}

/// Wait until control-plane leases admitted before teardown have completed, and until any owner JS cleanup started on last-lease drop has returned.
///
/// The instance stays in the map until this returns.
pub fn waitForControlOps(instance_id: i32) void {
    if (comptime @import("builtin").is_test) testing.parkBeforeWaitIfHooked();
    mutex.lock();
    const inst = instances.get(instance_id) orelse {
        mutex.unlock();
        if (comptime @import("builtin").is_test) testing.markWaitReturnedIfHooked();
        return;
    };
    mutex.unlock();
    inst.dispatch_mutex.lock();
    while (inst.active_control_ops != 0 or inst.js_teardown_in_progress) {
        inst.dispatch_wake.wait(&inst.dispatch_mutex);
    }
    inst.dispatch_mutex.unlock();
    if (comptime @import("builtin").is_test) testing.markWaitReturnedIfHooked();
}

/// Return the EngineInstance pointer for the given id, or null if missing. The pointer is stable between insert and remove; callers that need to mutate shared state on the instance must use their own synchronisation (e.g. RefBookkeeping.mutex for the ref list).
pub fn getInstance(instance_id: i32) ?*EngineInstance {
    mutex.lock();
    defer mutex.unlock();
    return instances.get(instance_id);
}

/// Block new public JS entries while teardown finishes and preserves runtime state for any admitted work.
pub fn markTeardownPending(instance_id: i32) void {
    mutex.lock();
    defer mutex.unlock();
    const inst = instances.get(instance_id) orelse return;
    // Admission readers hold the registry mutex; owner lease release reads this flag under dispatch_mutex. Writers hold both in registry-to-dispatch order.
    inst.dispatch_mutex.lock();
    defer inst.dispatch_mutex.unlock();
    inst.teardown_pending = true;
}

/// Checked by engine-thread admission both before and after it creates or retains its per-instance state. The instance-map mutex serializes this transition with teardown marking.
pub fn isTeardownPending(instance_id: i32) bool {
    mutex.lock();
    defer mutex.unlock();
    const inst = instances.get(instance_id) orelse return true;
    return inst.teardown_pending;
}

/// Access an instance with a short operation. Lock is held only for the call. IMPORTANT: Do NOT call JS execution or anything that may trigger JS callbacks inside — that would deadlock.
pub fn withInstance(instance_id: i32, op: anytype) void {
    mutex.lock();
    defer mutex.unlock();
    const inst = instances.get(instance_id) orelse return;
    op.call(inst);
}

/// withInstance variant that returns a value from the callback.
pub fn withInstanceReturn(instance_id: i32, op: anytype) @typeInfo(@TypeOf(@TypeOf(op).call)).@"fn".return_type.? {
    mutex.lock();
    defer mutex.unlock();
    const inst = instances.get(instance_id) orelse return null;
    return op.call(inst);
}

/// Acquire an in-flight lease for a NativeTask snapshot. Teardown uses the same instance-map mutex to close admission before waiting on these leases.
pub fn beginDispatchTask(instance_id: i32) ?*EngineInstance {
    mutex.lock();
    defer mutex.unlock();
    const inst = instances.get(instance_id) orelse return null;
    if (inst.task_admission_closed) return null;
    inst.dispatch_mutex.lock();
    inst.active_dispatch_tasks += 1;
    inst.dispatch_mutex.unlock();
    return inst;
}

pub fn endDispatchTask(inst: *EngineInstance) void {
    inst.dispatch_mutex.lock();
    std.debug.assert(inst.active_dispatch_tasks != 0);
    inst.active_dispatch_tasks -= 1;
    inst.dispatch_wake.broadcast();
    inst.dispatch_mutex.unlock();
}

/// Wait until snapshots admitted before task closure have completed. The runtime stays in `instances` until this returns.
pub fn waitForDispatchTasks(instance_id: i32) void {
    mutex.lock();
    const inst = instances.get(instance_id) orelse {
        mutex.unlock();
        return;
    };
    mutex.unlock();
    inst.dispatch_mutex.lock();
    while (inst.active_dispatch_tasks != 0) {
        inst.dispatch_wake.wait(&inst.dispatch_mutex);
    }
    inst.dispatch_mutex.unlock();
}

/// Copy up to `cap` live, non-teardown-pending instance ids into `out_ids` (arbitrary order).
/// Returns the total count of such ids (may exceed `cap`). Pass `out_ids == null` for a count-only query.
/// Omitting teardown-pending ids keeps list consistent with snapshot (which refuses them).
pub fn listIds(out_ids: ?[*]i32, cap: usize) usize {
    mutex.lock();
    defer mutex.unlock();
    var total: usize = 0;
    var written: usize = 0;
    var it = instances.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.teardown_pending) continue;
        total += 1;
        if (out_ids) |buf| {
            if (written < cap) {
                buf[written] = entry.key_ptr.*;
                written += 1;
            }
        }
    }
    return total;
}

/// Match a raw JS context pointer against mono or packed-alt instance handles.
/// Used by scheduler_gate callbacks that may receive a non-primary packed context.
pub fn findByContextAddr(ctx_addr: usize) ?i32 {
    if (ctx_addr == 0) return null;
    mutex.lock();
    defer mutex.unlock();
    var it = instances.iterator();
    while (it.next()) |entry| {
        const inst = entry.value_ptr.*;
        if (inst.teardown_pending) continue;
        const match = switch (inst.engine_handles) {
            .mono => |m| @intFromPtr(m.ctx) == ctx_addr,
            .packed_alt => |a| a.ctx_addr == ctx_addr,
        };
        if (match) return entry.key_ptr.*;
    }
    return null;
}

/// Recover instance_id from a raw context via the backend's opaque data slot.
pub fn instanceIdFromCtx(ctx: ActiveEngine.Context) i32 {
    return ActiveEngine.instanceIdFromCtx(ctx);
}

pub const testing = if (@import("builtin").is_test) struct {
    /// Deterministic overlap barrier for last-lease owner JS teardown vs a destroyer that has marked teardown but has not yet entered `waitForControlOps`.
    pub const Gate = struct {
        mutex: sync.Mutex = .{},
        cond: sync.Condition = .init,
        arrived: bool = false,
        allowed: bool = false,

        pub fn deinit(self: *Gate) void {
            self.cond.deinit();
            self.mutex.deinit();
        }

        pub fn arriveAndWait(self: *Gate) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.arrived = true;
            self.cond.broadcast();
            while (!self.allowed) self.cond.wait(&self.mutex);
        }

        pub fn signalArrived(self: *Gate) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.arrived = true;
            self.cond.broadcast();
        }

        pub fn waitArrived(self: *Gate) error{Timeout}!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.arrived) {
                if (self.cond.waitTimeout(&self.mutex, 8_000) == .timed_out and !self.arrived) return error.Timeout;
            }
        }

        pub fn allow(self: *Gate) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.allowed = true;
            self.cond.broadcast();
        }
    };

    pub const TeardownOverlapHook = struct {
        before_wait: Gate = .{},
        cleanup: Gate = .{},
        entered_gate: Gate = .{},
        entered_wait: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        wait_returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn deinit(self: *TeardownOverlapHook) void {
            self.before_wait.deinit();
            self.cleanup.deinit();
            self.entered_gate.deinit();
        }
    };

    var overlap_hook: ?*TeardownOverlapHook = null;

    pub fn installTeardownOverlapHook(hook: ?*TeardownOverlapHook) void {
        overlap_hook = hook;
    }

    pub fn parkBeforeWaitIfHooked() void {
        if (overlap_hook) |h| {
            h.before_wait.arriveAndWait();
            h.entered_wait.store(true, .release);
            h.entered_gate.signalArrived();
        }
    }

    pub fn markWaitReturnedIfHooked() void {
        if (overlap_hook) |h| h.wait_returned.store(true, .release);
    }

    pub fn parkOwnerCleanupIfHooked() void {
        if (overlap_hook) |h| h.cleanup.arriveAndWait();
    }
} else struct {};
