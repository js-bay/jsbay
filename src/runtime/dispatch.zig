//! Generic host-to-JS dispatch helpers.
//!
//! Consumers should keep protocol semantics outside the engine, but common work like resolving a global function, creating JS argument values, invoking it, and draining pending jobs belongs here.

const std = @import("std");
const sync = @import("zev");
const backend = @import("../backend.zig");
const tsfn = @import("tsfn.zig");
const instance_map = @import("instance_map.zig");

const ActiveEngine = backend.ActiveEngine;

// ---------------------------------------------------------------------------
// Native task queue — lets any thread enqueue a Zig closure that the Driver runs on the instance's owning JS thread. Used by the inspector to marshal Runtime.evaluate work from a WebSocket reader thread onto the JS thread.
//
// Admission takes the instance registry lock before the instance native-task queue mutex. The task snapshot is taken under those locks, but run/cancel/complete callbacks always execute after both have been released.
// ---------------------------------------------------------------------------

pub const NativeTask = struct {
    // Set only by admission; its reservation survives detached task snapshots.
    resources: ?*@import("resource_limits.zig").Budget = null,
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
pub const NativeTaskQueue = struct {
    mutex: sync.Mutex = .{},
    items: std.ArrayList(NativeTask) = .empty,
    closed: bool = false,
};

var post_checked_hook: ?*const fn (?*anyopaque) void = null;
var post_checked_hook_ctx: ?*anyopaque = null;
var fail_next_queue_allocation_for_testing = false;
/// Marks a synchronous engine callback as work owned by a subsystem. Use this around native callbacks that can re-enter lifecycle APIs without first passing through `drainTasks`.
pub const TaskOwnerFrame = struct {
    instance_id: i32,
    owner: ?*anyopaque,
    parent: ?*TaskOwnerFrame,
};
threadlocal var active_task_owner_frame: ?*TaskOwnerFrame = null;

pub fn enterTaskOwnerFrame(frame: *TaskOwnerFrame, instance_id: i32, owner: ?*anyopaque) void {
    frame.* = .{
        .instance_id = instance_id,
        .owner = owner,
        .parent = active_task_owner_frame,
    };
    active_task_owner_frame = frame;
}

pub fn leaveTaskOwnerFrame(frame: *TaskOwnerFrame) void {
    std.debug.assert(active_task_owner_frame == frame);
    active_task_owner_frame = frame.parent;
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

fn postTaskChecked(instance_id: i32, expected_generation: ?u64, task: NativeTask) bool {
    const Post = struct {
        task: NativeTask,
        expected_generation: ?u64,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?bool {
            if (inst.task_admission_closed) return false;
            if (self.expected_generation) |generation| {
                if (inst.teardown_pending or inst.generation != generation) return false;
            }
            runPostCheckedHookForTesting();
            if (fail_next_queue_allocation_for_testing) {
                fail_next_queue_allocation_for_testing = false;
                return false;
            }
            inst.native_task_queue.mutex.lock();
            defer inst.native_task_queue.mutex.unlock();
            if (inst.native_task_queue.closed) return false;
            if (!inst.resources.reserve(.native_task, 0)) return false;
            var admitted_task = self.task;
            admitted_task.resources = inst.resources;
            inst.native_task_queue.items.append(std.heap.c_allocator, admitted_task) catch {
                inst.resources.release(.native_task, 0);
                return false;
            };
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
            const pending = inst.native_task_queue.items;
            inst.native_task_queue.items = .empty;
            return pending;
        }
    }{}) orelse return;
    defer pending.deinit(std.heap.c_allocator);
    for (pending.items) |task| {
        defer if (task.resources) |resources| resources.release(.native_task, 0);
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
            self.pending.* = inst.native_task_queue.items;
            inst.native_task_queue.items = .empty;
            return true;
        }
    };
    const found = instance_map.withInstanceReturn(instance_id, Close{ .pending = &pending }) orelse false;
    if (!found) {
        return true;
    }
    for (pending.items) |task| {
        defer if (task.resources) |resources| resources.release(.native_task, 0);
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
                for (inst.native_task_queue.items.items, 0..) |task, index| if (task.owner == self.owner) return inst.native_task_queue.items.orderedRemove(index);
                return null;
            }
        }{ .owner = owner }) orelse return;
        defer if (task.resources) |resources| resources.release(.native_task, 0);
        if (task.cancel) |cancel| cancel(task.ctx);
        if (task.complete) |complete| complete(task.completion_ctx);
    }
}

pub const TaskCompletion = struct {
    instance_lease: *instance_map.EngineInstance,
    task: NativeTask,
    active: bool = true,

    pub fn finish(self: *TaskCompletion) void {
        if (!self.active) return;
        self.active = false;
        defer if (self.task.resources) |resources| resources.release(.native_task, 0);
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
            if (inst.native_task_queue.items.items.len == 0) return null;
            return inst.native_task_queue.items.orderedRemove(0);
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
    _ = queued.end();
    completion.* = .{ .instance_lease = instance_lease, .task = task };
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
                for (inst.native_task_queue.items.items, 0..) |queued, index| {
                    if (queued.debugger_control) return inst.native_task_queue.items.orderedRemove(index);
                }
                return null;
            }
        }{}) orelse return executed;
        defer if (task.resources) |resources| resources.release(.native_task, 0);
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
    completion: ?TaskCompletion = null,

    fn self(context: ?*anyopaque) *DispatchTurn {
        return @ptrCast(@alignCast(context.?));
    }
    fn prepareNativeEvents(_: ?*anyopaque) void {}
    fn runOneSource(context: ?*anyopaque, source: @import("js_event_loop").Scheduler.TaskSource) bool {
        const turn = self(context);
        turn.ran = switch (source) {
            .native_dispatch => runOneTask(turn.instance_id, &turn.completion),
            .tsfn => tsfn.runOne(turn.instance_id),
            .host_script, .timer => false,
        };
        return turn.ran;
    }
    fn checkpoint(context: ?*anyopaque) void {
        const turn = self(context);
        if (instance_map.getPtrs(turn.instance_id)) |ptrs| @import("js_scheduler.zig").checkpoint(turn.instance_id, ptrs.ctx);
    }
    fn finishTask(context: ?*anyopaque) void {
        const turn = self(context);
        if (turn.completion) |*completion| completion.finish();
    }
};

const testing = std.testing;

fn withTestContext(comptime test_fn: fn (ActiveEngine.Context, ActiveEngine.Runtime) anyerror!void) !void {
    const rt = ActiveEngine.newRuntime() orelse return error.RuntimeCreationFailed;
    defer ActiveEngine.freeRuntime(rt);

    const ctx = ActiveEngine.newContext(rt) orelse return error.ContextCreationFailed;
    defer ActiveEngine.freeContext(ctx);

    try test_fn(ctx, rt);
}

test "dispatch: emitGlobal calls global function with typed args" {
    // Native Escargot/Hermes facades support eval + call + task queue used below.
    try withTestContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const eval_result = ActiveEngine.eval(
                ctx,
                \\globalThis.__dispatch_test__ = (id, name, payload) => {
                \\  globalThis.__dispatch_result__ = `${id}:${name}:${payload}`;
                \\};
            ,
                "<dispatch-test>",
            );
            // ActiveEngine.eval returns owned result/error strings even in module tests.
            defer if (eval_result.result) |s| std.heap.c_allocator.free(@constCast(s));
            defer if (eval_result.err_is_heap) {
                if (eval_result.err) |e| std.heap.c_allocator.free(@constCast(e));
            };
            if (eval_result.err != null) return error.JSException;

            const ok = emitGlobal(ctx, "__dispatch_test__", &.{
                .{ .int32 = 7 },
                .{ .string = "tap" },
                .{ .string = "{\"x\":1}" },
            });
            try testing.expect(ok);

            const read_back = ActiveEngine.eval(ctx, "globalThis.__dispatch_result__", "<dispatch-read>");
            // Free both success and heap error paths to keep this test ownership-neutral.
            defer if (read_back.result) |s| std.heap.c_allocator.free(@constCast(s));
            defer if (read_back.err_is_heap) {
                if (read_back.err) |e| std.heap.c_allocator.free(@constCast(e));
            };
            if (read_back.err != null) return error.JSException;
            try testing.expectEqualStrings("7:tap:{\"x\":1}", read_back.result.?);
        }
    }.run);
}

test "dispatch: missing global function returns false" {
    // Native Escargot/Hermes facades support eval + call + task queue used below.
    try withTestContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try testing.expect(!emitGlobal(ctx, "__dispatch_missing__", &.{}));
        }
    }.run);
}

// -- Native task queue tests ---------------------------------------------

// Static flag + bump counter used by the post-task closures. C ABI test constraint (callback cannot close over Zig locals) is loose here since NativeTask.run is a plain Zig fn pointer — we still use a module-level global so multiple tests in the file can share the closure signature.
var task_flag: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn bumpTaskFlag(_: ?*anyopaque) void {
    _ = task_flag.fetchAdd(1, .seq_cst);
}

fn markTaskCancelled(_: ?*anyopaque) void {
    _ = task_flag.fetchAdd(100, .seq_cst);
}

test "dispatch: postTask runs closure on tickInstance" {
    // Native Escargot/Hermes facades support eval + call + task queue used below.
    const engine = @import("../engine.zig");
    // Use a high id to avoid collision with engine_tests helpers (those start at 10_000 and only grow). We pick a distinct namespace.
    const instance_id: i32 = 5_551;
    task_flag.store(0, .seq_cst);
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    // Always release any leftover tasks so this test doesn't leak state into neighbours.
    defer releaseAllTasksForInstance(instance_id);

    try testing.expect(postTask(instance_id, .{
        .ctx = null,
        .run = bumpTaskFlag,
    }));

    const dispatched = tickInstance(instance_id);
    try testing.expect(dispatched >= 1);
    try testing.expectEqual(@as(u32, 1), task_flag.load(.seq_cst));

    // Second tick with nothing pending: no-op.
    const dispatched_again = tickInstance(instance_id);
    try testing.expectEqual(@as(usize, 0), dispatched_again);
    try testing.expectEqual(@as(u32, 1), task_flag.load(.seq_cst));
}

test "dispatch: postTask after engine destroy does not crash" {
    // Native Escargot/Hermes facades support eval + call + task queue used below.
    // 12345 is intentionally bogus — no engine.create() for this id.
    const bogus_id: i32 = 12_345;
    defer releaseAllTasksForInstance(bogus_id);

    const ok = postTask(bogus_id, .{
        .ctx = null,
        .run = bumpTaskFlag,
    });
    try testing.expect(!ok);

    // tickInstance on the same id must be a no-op and not crash.
    const n = tickInstance(bogus_id);
    try testing.expectEqual(@as(usize, 0), n);
}

test "dispatch: token rejects completion from a reused instance id" {
    // Native Escargot/Hermes facades support eval + call + task queue used below.
    const engine = @import("../engine.zig");
    const instance_id: i32 = 5_554;
    task_flag.store(0, .seq_cst);
    try testing.expect(engine.create(instance_id, .{}));
    const old_token = captureInstanceToken(instance_id) orelse return error.NoToken;
    engine.destroy(instance_id);

    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    const new_token = captureInstanceToken(instance_id) orelse return error.NoToken;
    try testing.expect(old_token.generation != new_token.generation);
    const LateProducer = struct {
        token: InstanceToken,
        accepted: *std.atomic.Value(bool),
        fn run(self: @This()) void {
            self.accepted.store(postTaskWithToken(self.token, .{ .ctx = null, .run = bumpTaskFlag }), .seq_cst);
        }
    };
    var late_accepted = std.atomic.Value(bool).init(true);
    const late = try std.Thread.spawn(.{}, LateProducer.run, .{LateProducer{ .token = old_token, .accepted = &late_accepted }});
    late.join();
    try testing.expect(!late_accepted.load(.seq_cst));
    try testing.expect(postTaskWithToken(new_token, .{ .ctx = null, .run = bumpTaskFlag }));
    _ = tickInstance(instance_id);
    try testing.expectEqual(@as(u32, 1), task_flag.load(.seq_cst));
}

test "dispatch: token rejects closed instance and cannot cross instances" {
    // Native Escargot/Hermes facades support eval + call + task queue used below.
    const engine = @import("../engine.zig");
    const first: i32 = 5_555;
    const second: i32 = 5_556;
    task_flag.store(0, .seq_cst);
    try testing.expect(engine.create(first, .{}));
    defer engine.destroy(first);
    try testing.expect(engine.create(second, .{}));
    defer engine.destroy(second);

    const first_token = captureInstanceToken(first) orelse return error.NoToken;
    const second_token = captureInstanceToken(second) orelse return error.NoToken;
    try testing.expect(first_token.generation != second_token.generation);
    try testing.expect(postTaskWithToken(second_token, .{ .ctx = null, .run = bumpTaskFlag }));
    _ = tickInstance(second);
    try testing.expectEqual(@as(u32, 1), task_flag.load(.seq_cst));

    instance_map.markTeardownPending(first);
    try testing.expect(!postTaskWithToken(first_token, .{ .ctx = null, .run = bumpTaskFlag }));
    try testing.expect(closeInstanceTasks(first));
    try testing.expect(captureInstanceToken(first) == null);
    try testing.expect(!postTaskWithToken(first_token, .{ .ctx = null, .run = bumpTaskFlag }));
}

test "dispatch: releaseAllTasksForInstance drops pending work" {
    // Native Escargot/Hermes facades support eval + call + task queue used below.
    const engine = @import("../engine.zig");
    // Distinct id from the other postTask test so they don't interfere.
    const instance_id: i32 = 5_552;
    task_flag.store(0, .seq_cst);
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    // Belt-and-braces — if the assertions below fail, we still want a clean queue for subsequent tests.
    defer releaseAllTasksForInstance(instance_id);

    // Post three tasks, then drop them all before ticking.
    try testing.expect(postTask(instance_id, .{ .ctx = null, .run = bumpTaskFlag }));
    try testing.expect(postTask(instance_id, .{ .ctx = null, .run = bumpTaskFlag }));
    try testing.expect(postTask(instance_id, .{ .ctx = null, .run = bumpTaskFlag }));

    releaseAllTasksForInstance(instance_id);

    // Queue is gone — tickInstance must report no dispatches, and the closure must not have run.
    const dispatched = tickInstance(instance_id);
    try testing.expectEqual(@as(usize, 0), dispatched);
    try testing.expectEqual(@as(u32, 0), task_flag.load(.seq_cst));
}

test "dispatch: releasing queued tasks invokes their cancellation cleanup" {
    // Native Escargot/Hermes facades support eval + call + task queue used below.
    const engine = @import("../engine.zig");
    const instance_id: i32 = 5_553;
    task_flag.store(0, .seq_cst);
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    defer releaseAllTasksForInstance(instance_id);

    try testing.expect(postTask(instance_id, .{
        .ctx = null,
        .run = bumpTaskFlag,
        .cancel = markTaskCancelled,
    }));
    releaseAllTasksForInstance(instance_id);
    try testing.expectEqual(@as(u32, 100), task_flag.load(.seq_cst));
}
