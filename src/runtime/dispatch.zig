//! Generic host-to-JS dispatch helpers.
//!
//! Consumers should keep protocol semantics outside the engine, but common work like resolving a global function, creating JS argument values, invoking it, and draining pending jobs belongs here.

const std = @import("std");
const sync = @import("zev");
const backend = @import("../backend.zig");
const tsfn = @import("tsfn.zig");
const instance_map = @import("instance_map.zig");
const resource_limits = @import("resource_limits.zig");

const ActiveEngine = backend.ActiveEngine;

// ---------------------------------------------------------------------------
// Native task queue — lets any thread enqueue a Zig closure that the Driver runs on the instance's owning JS thread. Used by the inspector to marshal Runtime.evaluate work from a WebSocket reader thread onto the JS thread.
//
// Admission takes the instance registry lock before the instance native-task queue mutex. The task snapshot is taken under those locks, but run/cancel/complete callbacks always execute after both have been released.
// ---------------------------------------------------------------------------

pub const NativeTask = struct {
    // Set only by admission; its reservation survives detached task snapshots.
    resources: ?*resource_limits.Budget = null,
    /// The public submission queue uses script_task so hosts can account for copied source separately from arbitrary native work.
    resource_kind: resource_limits.Kind = .native_task,
    resource_bytes: usize = 0,
    /// Called while the instance admission lock is held, before resource reservation. It must not invoke JS or wait.
    admission_check: ?*const fn (?*anyopaque) bool = null,
    /// Called only after this task has been appended while the instance admission lock is still held. It must not invoke JS or wait.
    on_admitted: ?*const fn (?*anyopaque) void = null,
    ctx: ?*anyopaque,
    run: *const fn (?*anyopaque) void,
    cancel: ?*const fn (?*anyopaque) void = null,
    complete: ?*const fn (?*anyopaque) void = null,
    completion_ctx: ?*anyopaque = null,
    owner: ?*anyopaque = null,
    thread_id_slot: ?*std.atomic.Value(u64) = null,
    /// Explicit Inspector control work that may inspect or resume a paused JS stack. `drainPausedDebuggerControl` is the only path permitted to run these while an ordinary JS execution is paused.
    debugger_control: bool = false,
};

/// Identity of one published engine lifetime. Capture before starting async work, then use `postTaskWithToken` for its completion so an old completion cannot be delivered to a new instance that reused the numeric id.
pub const InstanceToken = extern struct {
    instance_id: i32,
    generation: u64,
};

/// A script submission reserves its copied payload budget before allocating source bytes. The control lease keeps the instance alive until the reservation is either released or committed into the native task queue.
pub const TaskReservation = struct {
    lease: ?instance_map.ControlLease,
    resources: ?*resource_limits.Budget,
    kind: resource_limits.Kind,
    bytes: usize,

    pub fn deinit(self: *TaskReservation) void {
        if (self.resources) |resources| {
            resources.release(self.kind, self.bytes);
            self.resources = null;
        }
        if (self.lease) |lease| {
            lease.end();
            self.lease = null;
        }
    }
};
pub const NativeTaskQueue = struct {
    mutex: sync.Mutex align(64) = .{},
    items: std.ArrayList(NativeTask) = .empty,
    head: usize = 0,
    closed: bool = false,

    pub fn pendingLen(self: *const NativeTaskQueue) usize {
        return self.items.items.len - self.head;
    }

    pub fn pendingSlice(self: *NativeTaskQueue) []NativeTask {
        return self.items.items[self.head..];
    }

    fn compact(self: *NativeTaskQueue) void {
        if (self.head == 0) return;
        const n = self.pendingLen();
        if (n == 0) {
            self.items.clearRetainingCapacity();
            self.head = 0;
            return;
        }
        var write: usize = 0;
        while (write < n) : (write += 1) {
            self.items.items[write] = self.items.items[self.head + write];
        }
        self.items.shrinkRetainingCapacity(n);
        self.head = 0;
    }

    pub fn push(self: *NativeTaskQueue, allocator: std.mem.Allocator, task: NativeTask) !void {
        if (self.head > 0 and self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        }
        try self.items.append(allocator, task);
    }

    pub fn popFront(self: *NativeTaskQueue) ?NativeTask {
        if (self.head >= self.items.items.len) return null;
        const task = self.items.items[self.head];
        self.head += 1;
        if (self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= 64 and self.head >= self.items.items.len / 2) {
            self.compact();
        }
        return task;
    }

    /// Remove the first matching pending task with one stable compress (keeps FIFO of the rest).
    pub fn takeFirst(self: *NativeTaskQueue, comptime pred: fn (NativeTask) bool) ?NativeTask {
        self.compact();
        const items = self.items.items;
        var idx: ?usize = null;
        for (items, 0..) |task, i| {
            if (pred(task)) {
                idx = i;
                break;
            }
        }
        const remove_at = idx orelse return null;
        const found = items[remove_at];
        var write: usize = 0;
        for (items, 0..) |task, i| {
            if (i == remove_at) continue;
            items[write] = task;
            write += 1;
        }
        self.items.shrinkRetainingCapacity(write);
        return found;
    }

    /// Runtime-predicate variant — used when the match key is not comptime-known.
    pub fn takeFirstMatch(self: *NativeTaskQueue, ctx: *anyopaque, pred: *const fn (*anyopaque, NativeTask) bool) ?NativeTask {
        self.compact();
        const items = self.items.items;
        var idx: ?usize = null;
        for (items, 0..) |task, i| {
            if (pred(ctx, task)) {
                idx = i;
                break;
            }
        }
        const remove_at = idx orelse return null;
        const found = items[remove_at];
        var write: usize = 0;
        for (items, 0..) |task, i| {
            if (i == remove_at) continue;
            items[write] = task;
            write += 1;
        }
        self.items.shrinkRetainingCapacity(write);
        return found;
    }

    pub fn takeAll(self: *NativeTaskQueue) std.ArrayList(NativeTask) {
        self.compact();
        const pending = self.items;
        self.items = .empty;
        self.head = 0;
        return pending;
    }
};

var post_checked_hook: ?*const fn (?*anyopaque) void = null;
var post_checked_hook_ctx: ?*anyopaque = null;
var fail_next_queue_allocation_for_testing = false;
/// Marks a synchronous engine callback as work owned by a subsystem. Use this around native callbacks that can re-enter lifecycle APIs without first passing through `drainTasks`.
pub const TaskOwnerFrame = struct {
    instance_id: i32,
    owner: ?*anyopaque,
    parent: ?*TaskOwnerFrame,
    deferred_destroy_generation: ?u64 = null,
    deferred_destroy: ?*const fn (i32, u64) void = null,
};
threadlocal var active_task_owner_frame: ?*TaskOwnerFrame = null;

pub fn enterTaskOwnerFrame(frame: *TaskOwnerFrame, instance_id: i32, owner: ?*anyopaque) void {
    frame.* = .{
        .instance_id = instance_id,
        .owner = owner,
        .parent = active_task_owner_frame,
        .deferred_destroy_generation = null,
        .deferred_destroy = null,
    };
    active_task_owner_frame = frame;
}

pub const DeferredDestroyAction = struct {
    instance_id: i32,
    generation: u64,
    func: *const fn (i32, u64) void,
};

const TeardownQueue = struct {
    var mu: sync.Mutex = .{};
    var cv: sync.Condition = .init;
    var cv_not_full: sync.Condition = .init;
    var thread: ?std.Thread = null;
    var initialized: bool = false;
    var queue: [32]DeferredDestroyAction = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    var count: usize = 0;

    fn worker() void {
        while (true) {
            mu.lock();
            while (count == 0) {
                cv.wait(&mu);
            }
            const action = queue[head];
            head = (head + 1) % queue.len;
            count -= 1;
            cv_not_full.signal();
            mu.unlock();

            action.func(action.instance_id, action.generation);
        }
    }

    pub fn ensureStarted() void {
        mu.lock();
        defer mu.unlock();
        if (!initialized) {
            if (std.Thread.spawn(.{}, worker, .{})) |t| {
                t.detach();
                thread = t;
                initialized = true;
            } else |_| {}
        }
    }

    pub fn push(action: DeferredDestroyAction) void {
        mu.lock();
        defer mu.unlock();
        if (!initialized) {
            action.func(action.instance_id, action.generation);
            return;
        }
        for (0..count) |i| {
            const idx = (head + i) % queue.len;
            if (queue[idx].instance_id == action.instance_id and queue[idx].generation == action.generation) {
                return;
            }
        }
        while (count >= queue.len) {
            cv_not_full.wait(&mu);
        }
        queue[tail] = action;
        tail = (tail + 1) % queue.len;
        count += 1;
        cv.signal();
    }
};

pub fn ensureTeardownWorkerStarted() void {
    TeardownQueue.ensureStarted();
}

pub fn handOffDeferredDestroy(action: DeferredDestroyAction) void {
    TeardownQueue.push(action);
}

pub fn leaveTaskOwnerFrameDeferred(frame: *TaskOwnerFrame) ?DeferredDestroyAction {
    std.debug.assert(active_task_owner_frame == frame);
    active_task_owner_frame = frame.parent;
    if (frame.deferred_destroy) |destroy| {
        return .{
            .instance_id = frame.instance_id,
            .generation = frame.deferred_destroy_generation.?,
            .func = destroy,
        };
    }
    return null;
}

pub fn leaveTaskOwnerFrame(frame: *TaskOwnerFrame) void {
    if (leaveTaskOwnerFrameDeferred(frame)) |action| {
        action.func(action.instance_id, action.generation);
    }
}

/// Defer instance destruction until the active owner callback has returned, without allocating or queueing work that can be rejected.
pub fn deferDestroyForCurrentTask(instance_id: i32, generation: u64, destroy: *const fn (i32, u64) void) bool {
    var frame = active_task_owner_frame;
    while (frame) |current| : (frame = current.parent) {
        if (current.instance_id != instance_id) continue;
        if (current.deferred_destroy) |existing| {
            std.debug.assert(existing == destroy and current.deferred_destroy_generation.? == generation);
            return true;
        }
        current.deferred_destroy_generation = generation;
        current.deferred_destroy = destroy;
        return true;
    }
    return false;
}

pub fn isRunningTaskForOwner(owner: *anyopaque) bool {
    var frame = active_task_owner_frame;
    while (frame) |current| : (frame = current.parent) {
        if (current.owner == owner) return true;
    }
    return false;
}

pub fn isRunningTaskForInstance(instance_id: i32) bool {
    var frame = active_task_owner_frame;
    while (frame) |current| : (frame = current.parent) {
        if (current.instance_id == instance_id) return true;
    }
    return false;
}

pub fn setPostCheckedHookForTesting(hook: ?*const fn (?*anyopaque) void, ctx: ?*anyopaque) void {
    post_checked_hook = hook;
    post_checked_hook_ctx = ctx;
}

pub fn failNextQueueAllocationForTesting() void {
    fail_next_queue_allocation_for_testing = true;
}

fn runPostCheckedHookForTesting() void {
    const hook = post_checked_hook;
    const ctx = post_checked_hook_ctx;
    if (hook) |callback| callback(ctx);
}

/// Wake the instance's event loop so a blocked owner thread drains the task.
fn wakeInstance(instance_id: i32) void {
    instance_map.withInstance(instance_id, struct {
        pub fn call(_: @This(), inst: *instance_map.EngineInstance) void {
            if (!inst.task_admission_closed) inst.loop.wake();
        }
    }{});
    @import("js_event_loop").host_wake.notify(instance_id);
}

/// Enqueue a native closure to run on the owning JS thread. Safe to call from any thread. The Driver drains tasks in FIFO order.
///
/// Returns `false` when the instance does not exist (engine destroyed) or when allocation fails. On success the owning thread is woken via the platform wait primitive so a consumer blocked in the event loop returns promptly.
pub fn postTask(instance_id: i32, task: NativeTask) bool {
    return postTaskChecked(instance_id, null, task);
}

pub fn captureInstanceToken(instance_id: i32) ?InstanceToken {
    const generation = instance_map.captureGeneration(instance_id) orelse return null;
    return .{ .instance_id = instance_id, .generation = generation };
}

/// Post an asynchronous result only if it still belongs to the same published instance lifetime captured before the operation began.
pub fn postTaskWithToken(token: InstanceToken, task: NativeTask) bool {
    return postTaskChecked(token.instance_id, token.generation, task);
}

/// Reserve payload accounting before a caller copies source bytes. The later commit rechecks admission while holding the instance registry lock.
pub fn reserveTaskWithToken(token: InstanceToken, kind: resource_limits.Kind, bytes: usize) ?TaskReservation {
    const lease = instance_map.beginControlPlane(token.instance_id) orelse return null;
    var reservation = TaskReservation{ .lease = lease, .resources = null, .kind = kind, .bytes = bytes };
    const accepted = instance_map.withInstanceReturn(token.instance_id, struct {
        lease_inst: *instance_map.EngineInstance,
        generation: u64,
        kind: resource_limits.Kind,
        bytes: usize,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?bool {
            if (inst != self.lease_inst or inst.task_admission_closed or inst.teardown_pending or inst.generation != self.generation) return false;
            inst.native_task_queue.mutex.lock();
            defer inst.native_task_queue.mutex.unlock();
            if (inst.native_task_queue.closed) return false;
            if (!inst.resources.reserve(self.kind, self.bytes)) return false;
            return true;
        }
    }{ .lease_inst = lease.inst, .generation = token.generation, .kind = kind, .bytes = bytes }) orelse false;
    if (!accepted) {
        reservation.deinit();
        return null;
    }
    reservation.resources = lease.inst.resources;
    return reservation;
}

/// Append a previously reserved task. The reservation remains owned by the caller when this returns false.
pub fn postReservedTaskWithToken(token: InstanceToken, reservation: *TaskReservation, task: NativeTask) bool {
    const lease = reservation.lease orelse return false;
    if (reservation.resources == null) return false;
    if (task.resource_kind != reservation.kind or task.resource_bytes != reservation.bytes) return false;
    const Commit = struct {
        lease_inst: *instance_map.EngineInstance,
        generation: u64,
        reservation: *TaskReservation,
        task: NativeTask,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?bool {
            if (inst != self.lease_inst or inst.task_admission_closed or inst.teardown_pending or inst.generation != self.generation) return false;
            if (self.task.admission_check) |check| {
                if (!check(self.task.ctx)) return false;
            }
            runPostCheckedHookForTesting();
            if (fail_next_queue_allocation_for_testing) {
                fail_next_queue_allocation_for_testing = false;
                return false;
            }
            inst.native_task_queue.mutex.lock();
            defer inst.native_task_queue.mutex.unlock();
            if (inst.native_task_queue.closed) return false;
            var admitted_task = self.task;
            admitted_task.resources = self.reservation.resources;
            inst.native_task_queue.push(std.heap.c_allocator, admitted_task) catch return false;
            self.reservation.resources = null;
            if (admitted_task.on_admitted) |on_admitted| on_admitted(admitted_task.ctx);
            inst.loop.wake();
            return true;
        }
    };
    const accepted = instance_map.withInstanceReturn(token.instance_id, Commit{
        .lease_inst = lease.inst,
        .generation = token.generation,
        .reservation = reservation,
        .task = task,
    }) orelse false;
    if (accepted) {
        lease.end();
        reservation.lease = null;
        wakeInstance(token.instance_id);
    }
    return accepted;
}

fn postTaskChecked(instance_id: i32, expected_generation: ?u64, task: NativeTask) bool {
    const Post = struct {
        task: NativeTask,
        expected_generation: ?u64,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?bool {
            if (inst.task_admission_closed) return false;
            if (self.expected_generation) |generation| {
                if (inst.teardown_pending or inst.generation != generation) return false;
            }
            if (self.task.admission_check) |check| {
                if (!check(self.task.ctx)) return false;
            }
            runPostCheckedHookForTesting();
            if (fail_next_queue_allocation_for_testing) {
                fail_next_queue_allocation_for_testing = false;
                return false;
            }
            inst.native_task_queue.mutex.lock();
            defer inst.native_task_queue.mutex.unlock();
            if (inst.native_task_queue.closed) return false;
            if (!inst.resources.reserve(self.task.resource_kind, self.task.resource_bytes)) return false;
            var admitted_task = self.task;
            admitted_task.resources = inst.resources;
            inst.native_task_queue.push(std.heap.c_allocator, admitted_task) catch {
                inst.resources.release(self.task.resource_kind, self.task.resource_bytes);
                return false;
            };
            if (admitted_task.on_admitted) |on_admitted| on_admitted(admitted_task.ctx);
            inst.loop.wake();
            return true;
        }
    };
    const accepted = instance_map.withInstanceReturn(instance_id, Post{ .task = task, .expected_generation = expected_generation }) orelse return false;
    if (!accepted) return false;

    wakeInstance(instance_id);
    return true;
}

/// Drop any pending tasks for this instance. Called during engine teardown (and by tests that want a clean slate). Safe to call with no queue allocated.
pub fn releaseAllTasksForInstance(instance_id: i32) void {
    var pending = instance_map.withInstanceReturn(instance_id, struct {
        pub fn call(_: @This(), inst: *instance_map.EngineInstance) ?std.ArrayList(NativeTask) {
            inst.native_task_queue.mutex.lock();
            defer inst.native_task_queue.mutex.unlock();
            const pending = inst.native_task_queue.takeAll();
            return pending;
        }
    }{}) orelse return;
    defer pending.deinit(std.heap.c_allocator);
    for (pending.items) |task| {
        defer if (task.resources) |resources| resources.release(task.resource_kind, task.resource_bytes);
        if (task.cancel) |cancel| cancel(task.ctx);
        if (task.complete) |complete| complete(task.completion_ctx);
    }
}

/// Atomically stop task admission and remove queued work before an engine context is torn down. `postTask` checks admission while holding the instance registry lock, so it cannot add work after this returns.
pub fn closeInstanceTasks(instance_id: i32) bool {
    var pending: std.ArrayList(NativeTask) = .empty;
    const Close = struct {
        pending: *std.ArrayList(NativeTask),
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?bool {
            inst.task_admission_closed = true;
            inst.native_task_queue.mutex.lock();
            defer inst.native_task_queue.mutex.unlock();
            inst.native_task_queue.closed = true;
            self.pending.* = inst.native_task_queue.takeAll();
            return true;
        }
    };
    const found = instance_map.withInstanceReturn(instance_id, Close{ .pending = &pending }) orelse false;
    if (!found) {
        return true;
    }
    for (pending.items) |task| {
        defer if (task.resources) |resources| resources.release(task.resource_kind, task.resource_bytes);
        if (task.cancel) |cancel| cancel(task.ctx);
        if (task.complete) |complete| complete(task.completion_ctx);
    }
    var to_free = pending;
    to_free.deinit(std.heap.c_allocator);
    return true;
}

pub fn waitForInstanceTasks(instance_id: i32) void {
    instance_map.waitForDispatchTasks(instance_id);
}

/// Cancel tasks belonging to one subsystem while preserving unrelated work queued for the same engine instance.
pub fn releaseTasksForOwner(instance_id: i32, owner: *anyopaque) void {
    while (true) {
        const task = instance_map.withInstanceReturn(instance_id, struct {
            owner: *anyopaque,
            pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?NativeTask {
                inst.native_task_queue.mutex.lock();
                defer inst.native_task_queue.mutex.unlock();
                const Ctx = struct {
                    owner: *anyopaque,
                    fn pred(ctx: *anyopaque, task: NativeTask) bool {
                        const self_ctx: *@This() = @ptrCast(@alignCast(ctx));
                        return task.owner == self_ctx.owner;
                    }
                };
                var ctx_val: Ctx = .{ .owner = self.owner };
                return inst.native_task_queue.takeFirstMatch(@ptrCast(&ctx_val), Ctx.pred);
            }
        }{ .owner = owner }) orelse return;
        defer if (task.resources) |resources| resources.release(task.resource_kind, task.resource_bytes);
        if (task.cancel) |cancel| cancel(task.ctx);
        if (task.complete) |complete| complete(task.completion_ctx);
    }
}

pub const TaskCompletion = struct {
    instance_lease: *instance_map.EngineInstance,
    task: NativeTask,
    queued: ?@import("js_scheduler.zig").Task = null,
    active: bool = true,

    pub fn finish(self: *TaskCompletion) void {
        if (!self.active) return;
        self.active = false;
        defer if (self.task.resources) |resources| resources.release(self.task.resource_kind, self.task.resource_bytes);
        if (self.queued) |*queued| queued.endBudget();
        if (self.task.complete) |complete| complete(self.task.completion_ctx);
        instance_map.endDispatchTask(self.instance_lease);
    }
};

/// Run one pending native task. Its completion and instance lease remain active until the enclosing turn has completed its microtask checkpoint.
pub fn runOneTask(instance_id: i32, completion: *?TaskCompletion) bool {
    const instance_lease = instance_map.beginDispatchTask(instance_id) orelse return false;
    var queued = @import("js_scheduler.zig").beginQueuedTask(instance_id) orelse {
        instance_map.endDispatchTask(instance_lease);
        return false;
    };
    const task = instance_map.withInstanceReturn(instance_id, struct {
        pub fn call(_: @This(), inst: *instance_map.EngineInstance) ?NativeTask {
            inst.native_task_queue.mutex.lock();
            defer inst.native_task_queue.mutex.unlock();
            return inst.native_task_queue.popFront();
        }
    }{}) orelse {
        _ = queued.end();
        instance_map.endDispatchTask(instance_lease);
        return false;
    };
    if (task.thread_id_slot) |slot| slot.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
    var owner_frame = TaskOwnerFrame{
        .instance_id = instance_id,
        .owner = task.owner,
        .parent = active_task_owner_frame,
    };
    active_task_owner_frame = &owner_frame;
    task.run(task.ctx);
    active_task_owner_frame = owner_frame.parent;
    _ = queued.endScheduler();
    completion.* = .{ .instance_lease = instance_lease, .task = task, .queued = queued };
    return true;
}

/// Run only Inspector control tasks while the debugger has paused an ordinary JavaScript execution. This deliberately does not touch TSFN work, timers, application dispatch, or the backend microtask queue. Non-control tasks remain in their original queue order for the next normal owner turn.
pub fn drainPausedDebuggerControl(instance_id: i32) usize {
    const engine_thread = @import("engine_thread.zig");
    const eval_lease = engine_thread.beginEval(instance_id);
    defer @import("../engine.zig").finishEvalEntry(instance_id, eval_lease);
    if (!eval_lease.allowed) return 0;

    var control = @import("js_scheduler.zig").beginDebuggerControl(instance_id) orelse return 0;
    defer control.end();
    const instance_lease = instance_map.beginDispatchTask(instance_id) orelse return 0;
    defer instance_map.endDispatchTask(instance_lease);

    var executed: usize = 0;
    while (true) {
        const task = instance_map.withInstanceReturn(instance_id, struct {
            pub fn call(_: @This(), inst: *instance_map.EngineInstance) ?NativeTask {
                inst.native_task_queue.mutex.lock();
                defer inst.native_task_queue.mutex.unlock();
                return inst.native_task_queue.takeFirst(struct {
                    fn pred(task: NativeTask) bool {
                        return task.debugger_control;
                    }
                }.pred);
            }
        }{}) orelse return executed;
        defer if (task.resources) |resources| resources.release(task.resource_kind, task.resource_bytes);
        if (task.thread_id_slot) |slot| slot.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
        {
            var owner_frame: TaskOwnerFrame = undefined;
            enterTaskOwnerFrame(&owner_frame, instance_id, task.owner);
            task.run(task.ctx);
            leaveTaskOwnerFrame(&owner_frame);
        }
        if (task.complete) |complete| complete(task.completion_ctx);
        executed += 1;
    }
}

pub const DispatchArg = union(enum) {
    string: []const u8,
    int32: i32,
    bool: bool,
};

pub fn callGlobalRetained(
    ctx: ActiveEngine.Context,
    name: [*:0]const u8,
    args: []const ActiveEngine.Value,
) ?ActiveEngine.Value {
    var execution = @import("js_scheduler.zig").beginContextExecution(ctx);
    if (!execution.admitted) return null;
    defer execution.end();
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);

    const func = ActiveEngine.getPropertyVal(ctx, global, name) orelse return null;
    defer ActiveEngine.freeValue(ctx, func);

    if (!ActiveEngine.isFunction(ctx, func)) return null;

    const result = ActiveEngine.callFunction(ctx, func, global, args);
    if (execution.isClosing()) {
        if (result) |value| ActiveEngine.freeValue(ctx, value);
        return null;
    }
    return result;
}

pub fn callGlobalRetainedArgs(
    ctx: ActiveEngine.Context,
    name: [*:0]const u8,
    args: []const DispatchArg,
) ?ActiveEngine.Value {
    const allocator = std.heap.c_allocator;
    const js_args = allocator.alloc(ActiveEngine.Value, args.len) catch return null;
    defer allocator.free(js_args);

    for (args, 0..) |arg, i| {
        js_args[i] = switch (arg) {
            .string => |s| ActiveEngine.newStringVal(ctx, s),
            .int32 => |v| ActiveEngine.newInt32Val(ctx, v),
            .bool => |v| ActiveEngine.newBoolVal(ctx, v),
        };
    }
    defer for (js_args) |arg| {
        ActiveEngine.freeValue(ctx, arg);
    };

    return callGlobalRetained(ctx, name, js_args);
}

pub fn emitGlobal(
    ctx: ActiveEngine.Context,
    name: [*:0]const u8,
    args: []const DispatchArg,
) bool {
    var execution = @import("js_scheduler.zig").beginContextExecution(ctx);
    if (!execution.admitted) return false;
    defer execution.end();
    const result = callGlobalRetainedArgs(ctx, name, args) orelse return false;
    ActiveEngine.freeValue(ctx, result);
    execution.checkpoint();
    return !execution.isClosing();
}

/// Internal per-instance turn hook used by the engine Driver. It drains native dispatch and TSFN work while preserving the scheduler's task and microtask boundaries.
///
/// Returns the total number of async calls dispatched. Idempotent and safe to call when there is nothing pending.
pub fn tickInstance(instance_id: i32) usize {
    const engine_thread = @import("engine_thread.zig");
    const eval_lease = engine_thread.beginEval(instance_id);
    defer @import("../engine.zig").finishEvalEntry(instance_id, eval_lease);
    if (!eval_lease.allowed) return 0;
    if (!@import("js_scheduler.zig").allowsQueuedWork(instance_id)) return 0;
    var tick_frame = TaskOwnerFrame{
        .instance_id = instance_id,
        .owner = null,
        .parent = active_task_owner_frame,
    };
    active_task_owner_frame = &tick_frame;
    defer active_task_owner_frame = tick_frame.parent;
    var turn = DispatchTurn{ .instance_id = instance_id };
    _ = @import("js_scheduler.zig").runTurn(instance_id, .{
        .context = &turn,
        .prepare_native_events = DispatchTurn.prepareNativeEvents,
        .run_one_task = DispatchTurn.runOneSource,
        .checkpoint = DispatchTurn.checkpoint,
        .finish_task = DispatchTurn.finishTask,
    });
    // Session-close cleanup originates on transport threads. A failed task queue allocation must not leave the backend async hook armed forever, so every owner tick also consumes the persistent reconciliation bit.
    if (comptime @import("build_options").inspector) {
        @import("../inspector/root.zig").debugger_cdp.reconcilePendingAsyncDepthOnOwner(instance_id);
    }
    return @intFromBool(turn.ran);
}

const DispatchTurn = struct {
    instance_id: i32,
    ran: bool = false,
    task_budget_armed: bool = false,
    completion: ?TaskCompletion = null,

    fn self(context: ?*anyopaque) *DispatchTurn {
        return @ptrCast(@alignCast(context.?));
    }
    fn prepareNativeEvents(_: ?*anyopaque) void {}
    fn runOneSource(context: ?*anyopaque, source: @import("js_event_loop").Scheduler.TaskSource) bool {
        const turn = self(context);
        const budget_armed = @import("runtime_control.zig").beginExecutionBudget(turn.instance_id);
        turn.ran = switch (source) {
            .native_dispatch => runOneTask(turn.instance_id, &turn.completion),
            .tsfn => tsfn.runOne(turn.instance_id),
            .host_script, .timer => false,
        };
        if (turn.ran) {
            turn.task_budget_armed = budget_armed;
        } else if (budget_armed) @import("runtime_control.zig").endExecutionBudget(turn.instance_id);
        return turn.ran;
    }
    fn checkpoint(context: ?*anyopaque) void {
        const turn = self(context);
        @import("js_scheduler.zig").checkpointInstance(turn.instance_id);
    }
    fn finishTask(context: ?*anyopaque) void {
        const turn = self(context);
        if (turn.task_budget_armed) {
            turn.task_budget_armed = false;
            @import("runtime_control.zig").endExecutionBudget(turn.instance_id);
        }
        if (turn.completion) |*completion| completion.finish();
    }
};
