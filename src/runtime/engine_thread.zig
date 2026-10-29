//! Library-owned thread that runs posted scripts for one engine instance.
//!
//! The thread that created the instance is not the thread that runs posted work. Public synchronous evaluation entry points stay on the calling thread.
//!
//! Wait, barrier, and run are re-entrant from a host callback already on the engine thread: that path pumps the queue inline. Blocking the engine thread would deadlock, and a non-recursive lock must not be held across the JS call or the host callback. A caller on any other thread blocks until the engine thread finishes the job, the timeout expires, or stop / destroy wakes it with status 2.
//!
//! Idle: the engine thread blocks in the native event-loop waiter while the Zig scheduler tracks timer deadlines. Posting a job signals that waiter; the owner drains the queue and returns to blocking when no work is pending. Timed waits use the caller's deadline. Destroy and join wake the owner immediately so it can leave the runtime before teardown.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const api_backend = @import("../abi/api_backend.zig");
const debugger_mod = @import("../inspector/debugger.zig");
const host_value = @import("../abi/host_value.zig");
const instance_map = @import("instance_map.zig");
const io = @import("../platform/io.zig");
const sync = @import("zev");
const types = @import("../types.zig");

const ActiveEngine = backend.ActiveEngine;

pub const status_ok: c_int = 0;
pub const status_timeout: c_int = 1;
pub const status_destroyed: c_int = 2;
pub const status_exception: c_int = 3;
pub const status_invalid: c_int = 4;
pub const status_out_of_memory: c_int = 5;

// Test-only seam for the caller-owned result copy.  The job has already reached a terminal state when this allocation is attempted, which is why a failure must consume a synchronous run just like any other terminal result.
var fail_next_output_copy_for_testing = false;

pub fn failNextOutputCopyForTesting() void {
    if (builtin.is_test) fail_next_output_copy_for_testing = true;
}

fn consumeOutputCopyFault() bool {
    if (!builtin.is_test or !fail_next_output_copy_for_testing) return false;
    fail_next_output_copy_for_testing = false;
    return true;
}

const Job = struct {
    id: u64,
    seq: u64,
    src: []u8,
    filename: []u8,
    next: ?*Job = null,
    settled: bool = false,
    on_stack: bool = false,
    status: c_int = status_ok,
    result: ?[]u8 = null,
    err: ?[]u8 = null,
    waiters: usize = 0,
    auto_release: bool = false,
};

const DestroyOwner = enum(u8) { none, external, engine };

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

const DestroyGateLease = struct {
    gate: *DestroyGate,
    previous: ?*DestroyGateLease,
    owns_mutex: bool,
};

threadlocal var g_held_destroy_gates: ?*DestroyGateLease = null;

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

const State = struct {
    instance_id: i32,
    life_mu: sync.Mutex = .{},
    queue_mu: sync.Mutex = .{},
    jobs: std.AutoHashMap(u64, *Job),
    head: ?*Job = null,
    tail: ?*Job = null,
    next_id: u64 = 1,
    last_seq: u64 = 0,
    thread: ?std.Thread = null,
    thread_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Number of public `threadStop` calls that have not finished observing the generation they stopped. A replacement must wait until this drops to zero, otherwise an older stop can join the replacement.
    stop_requests: u32 = 0,
    joining: bool = false,
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Destroy was requested on this engine thread. The runtime stays alive until that thread leaves the JS call, then this thread frees it.
    deferred_destroy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// A direct eval callback requested destruction of this instance. The owning eval entry consumes this after the outermost JS stack unwinds.
    deferred_eval_destroy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Exactly one teardown path owns this State and its runtime. This claim uses no allocation, so OOM cannot strand destroy waiters.
    destroy_owner: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(DestroyOwner.none)),
    detached_hook_for_testing: ?*const fn (?*anyopaque) void = null,
    detached_hook_data_for_testing: ?*anyopaque = null,
    release_hook_for_testing: ?*const fn (?*anyopaque) void = null,
    release_hook_data_for_testing: ?*anyopaque = null,
    shutdown_before_life_hook_for_testing: ?*const fn (?*anyopaque) void = null,
    shutdown_before_life_hook_data_for_testing: ?*anyopaque = null,
    /// Engine thread has dropped its claim so another thread may eval. Nesting is `yield_depth`, touched only by the engine thread.
    yielded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    yield_depth: u32 = 0,
    /// JavaScriptCore allows only one thread to touch a context at a time. This lease serializes foreign evaluations while the engine thread has yielded; QuickJS enforces ownership in its backend lifecycle.
    external_eval_mu: sync.Mutex = .{},
    external_eval_owner: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    external_eval_depth: u32 = 0,
    exclusive_eval: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// `postToEngineThread` queued a native callback this thread has not taken.
    has_native: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    native_task: ?NativeTask = null,
    /// This thread is inside a blocking event-loop call. A wake ends the current block only while this is set and work or stop is pending.
    blocking_in_loop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Public event-loop calls can also hold an owner inside a blocking wait. Track their nested scope and owner separately from the worker park hint.
    loop_scope_mu: sync.Mutex = .{},
    loop_scope_wake: sync.Condition = .init,
    loop_scope_depth: usize = 0,
    loop_scope_owner: u64 = 0,
    loop_scope_closing: bool = false,
    /// Idle thread, job waiters, barrier, and shutdown share this.
    wake: sync.Condition = .init,
};

var g_mu: sync.Mutex = .{};
var g_wake: sync.Condition = .init;
var g_states: std.AutoHashMap(i32, *State) = std.AutoHashMap(i32, *State).init(std.heap.c_allocator);

fn claimDestroyOwner(state: *State, owner: DestroyOwner) bool {
    return state.destroy_owner.cmpxchgStrong(
        @backingInt(DestroyOwner.none),
        @backingInt(owner),
        .seq_cst,
        .seq_cst,
    ) == null;
}

fn currentThreadId() u64 {
    return @as(u64, std.Thread.getCurrentId());
}

fn isEngineThread(state: *State) bool {
    const id = state.thread_id.load(.seq_cst);
    return id != 0 and id == currentThreadId();
}

/// True only on the owner thread while it has yielded the JS context to an admitted foreign evaluator. The owner may still run loop-control work, but must not inspect scheduler or timer state owned by that evaluator.
pub fn ownerHasYielded(instance_id: i32) bool {
    const state = retain(instance_id) orelse return false;
    defer release(state);
    return isEngineThread(state) and state.yielded.load(.seq_cst);
}

fn teardownClaimed(state: *State) bool {
    return state.destroy_owner.load(.seq_cst) != @backingInt(DestroyOwner.none);
}

fn retain(instance_id: i32) ?*State {
    g_mu.lock();
    defer g_mu.unlock();
    const state = g_states.get(instance_id) orelse return null;
    _ = state.refs.fetchAdd(1, .seq_cst);
    return state;
}

fn release(state: *State) void {
    // Teardown rechecks `refs` while holding queue_mu. Keep the final decrement and its wake under that same lock so it cannot free State while the last releaser is still publishing the zero-ref transition.
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    const prev = state.refs.fetchSub(1, .seq_cst);
    // Last external ref. Destroy waits on `wake` for this while holding the same mutex, so it cannot observe zero before this notification finishes.
    if (prev == 1) {
        if (state.release_hook_for_testing) |hook| hook(state.release_hook_data_for_testing);
        notifyLocked(state);
    }
}

fn ensureState(instance_id: i32) ?*State {
    if (instance_map.getPtrs(instance_id) == null) return null;
    g_mu.lock();
    defer g_mu.unlock();
    if (g_states.get(instance_id)) |existing| {
        _ = existing.refs.fetchAdd(1, .seq_cst);
        return existing;
    }
    const state = std.heap.c_allocator.create(State) catch return null;
    state.* = .{
        .instance_id = instance_id,
        .jobs = std.AutoHashMap(u64, *Job).init(std.heap.c_allocator),
    };
    g_states.put(instance_id, state) catch {
        state.jobs.deinit();
        deinitStateSynchronization(state);
        std.heap.c_allocator.destroy(state);
        return null;
    };
    _ = state.refs.fetchAdd(1, .seq_cst);
    return state;
}

fn retainOrEnsureState(instance_id: i32) ?*State {
    if (retain(instance_id)) |state| return state;
    const gate = destroyGate(instance_id);
    var lease: DestroyGateLease = undefined;
    lockDestroyGate(gate, &lease);
    defer unlockDestroyGate(&lease);
    return ensureState(instance_id);
}

fn detach(instance_id: i32) ?*State {
    g_mu.lock();
    defer g_mu.unlock();
    const kv = g_states.fetchRemove(instance_id) orelse return null;
    return kv.value;
}

pub fn threadStart(instance_id: i32) bool {
    if (instance_map.isTeardownPending(instance_id)) return false;
    const gate = destroyGate(instance_id);
    var gate_lease: DestroyGateLease = undefined;
    lockDestroyGate(gate, &gate_lease);
    defer unlockDestroyGate(&gate_lease);

    const state = ensureState(instance_id) orelse return false;
    defer release(state);

    if (instance_map.isTeardownPending(instance_id) or teardownClaimed(state)) return false;

    // Starting from inside an already-held pre-start eval lease would wait on this thread's own non-recursive context gate.
    if (state.external_eval_owner.load(.seq_cst) == currentThreadId()) return false;

    state.life_mu.lock();
    if (state.thread != null or state.stop_requests != 0) {
        state.life_mu.unlock();
        return false;
    }
    // A pre-start eval/capture owns the same context even though no engine thread has been published yet. Do not expose started/running until it has left the context.
    state.external_eval_mu.lock();
    if (instance_map.isTeardownPending(instance_id)) {
        state.external_eval_mu.unlock();
        state.life_mu.unlock();
        return false;
    }
    state.stopping.store(false, .seq_cst);
    // QuickJS compares the C stack pointer with its JS stack budget. Harmony creates this thread with a 128MB stack. Zig's default is 16MB, so a deep call faults before QuickJS can throw.
    const thread = std.Thread.spawn(.{ .stack_size = 128 * 1024 * 1024 }, threadMain, .{state}) catch {
        state.external_eval_mu.unlock();
        state.life_mu.unlock();
        return false;
    };
    state.thread = thread;
    state.started.store(true, .seq_cst);
    state.running.store(true, .seq_cst);
    state.external_eval_mu.unlock();
    state.life_mu.unlock();
    return true;
}

pub fn threadStop(instance_id: i32) void {
    const state = retain(instance_id) orelse return;
    state.life_mu.lock();
    state.stop_requests += 1;
    state.life_mu.unlock();
    shutdown(state);

    const deferred = state.deferred_destroy.load(.seq_cst);
    const owner = state.destroy_owner.load(.seq_cst);
    state.life_mu.lock();
    std.debug.assert(state.stop_requests != 0);
    state.stop_requests -= 1;
    state.life_mu.unlock();
    release(state);

    // A host callback may request destruction while this caller owns the join. Let the joiner finish first, then take the ordinary external teardown path after dropping this State reference.
    if (deferred and owner == @backingInt(DestroyOwner.none)) beforeDestroy(instance_id);
}

pub fn threadId(instance_id: i32) u64 {
    const state = retain(instance_id) orelse return 0;
    defer release(state);
    if (!state.running.load(.seq_cst)) return 0;
    return state.thread_id.load(.seq_cst);
}

/// Internal test observability for job ownership; this is not part of the C API.
pub fn jobCountForTesting(instance_id: i32) usize {
    const state = retain(instance_id) orelse return 0;
    defer release(state);
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    return state.jobs.count();
}

pub fn hasJobWaiterForTesting(instance_id: i32) bool {
    const state = retain(instance_id) orelse return false;
    defer release(state);
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    var jobs = state.jobs.valueIterator();
    while (jobs.next()) |job| {
        if (job.*.waiters != 0) return true;
    }
    return false;
}

pub fn isJoiningForTesting(instance_id: i32) bool {
    const state = retain(instance_id) orelse return false;
    defer release(state);
    state.life_mu.lock();
    defer state.life_mu.unlock();
    return state.joining;
}

pub fn nativeTaskPendingForTesting(instance_id: i32) bool {
    const state = retain(instance_id) orelse return false;
    defer release(state);
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    return state.native_task != null;
}

pub fn setDetachedTeardownHookForTesting(
    instance_id: i32,
    hook: *const fn (?*anyopaque) void,
    data: ?*anyopaque,
) bool {
    const state = retain(instance_id) orelse return false;
    defer release(state);
    state.queue_mu.lock();
    state.detached_hook_for_testing = hook;
    state.detached_hook_data_for_testing = data;
    state.queue_mu.unlock();
    return true;
}

pub fn setShutdownBeforeLifeHookForTesting(
    instance_id: i32,
    hook: *const fn (?*anyopaque) void,
    data: ?*anyopaque,
) bool {
    const state = retain(instance_id) orelse return false;
    defer release(state);
    state.queue_mu.lock();
    state.shutdown_before_life_hook_for_testing = hook;
    state.shutdown_before_life_hook_data_for_testing = data;
    state.queue_mu.unlock();
    return true;
}

pub fn destroyGateWaitersForTesting(instance_id: i32) u32 {
    return destroyGate(instance_id).waiters.load(.seq_cst);
}

pub fn exclusiveEvalForTesting(instance_id: i32) bool {
    const state = retain(instance_id) orelse return false;
    defer release(state);
    return state.exclusive_eval.load(.seq_cst);
}

/// Static error used when eval is refused. Not heap-owned.
pub const foreign_eval_err: []const u8 = "cannot eval from a thread other than the engine thread";

pub const EvalLease = struct {
    allowed: bool = true,
    state: ?*State = null,
    gated: bool = false,
    outermost: bool = false,
    exclusive: bool = false,
    restore_yielded: bool = false,
    tls_slot: u8 = 0,
    tracked_eval: bool = false,
};

const EvalDepth = struct {
    instance_id: i32 = 0,
    depth: u32 = 0,
};

threadlocal var tls_eval_depths: [64]EvalDepth = @splat(.{});

fn registerEval(instance_id: i32) ?u8 {
    var free_slot: ?usize = null;
    for (&tls_eval_depths, 0..) |*entry, index| {
        if (entry.depth != 0 and entry.instance_id == instance_id) {
            entry.depth += 1;
            return @intCast(index);
        }
        if (entry.depth == 0 and free_slot == null) free_slot = index;
    }
    const index = free_slot orelse return null;
    tls_eval_depths[index] = .{ .instance_id = instance_id, .depth = 1 };
    return @intCast(index);
}

fn unregisterEval(lease: EvalLease) bool {
    if (!lease.tracked_eval) return false;
    const entry = &tls_eval_depths[lease.tls_slot];
    std.debug.assert(entry.instance_id == lease.state.?.instance_id and entry.depth > 0);
    entry.depth -= 1;
    if (entry.depth == 0) {
        entry.instance_id = 0;
        return true;
    }
    return false;
}

/// True while this thread is inside a JS API entry for the given instance, including all nested eval/capture calls. Engine destruction uses this to defer freeing a runtime from inside a native callback.
pub fn isEvalActiveOnCurrentThread(instance_id: i32) bool {
    for (tls_eval_depths) |entry| {
        if (entry.depth != 0 and entry.instance_id == instance_id) return true;
    }
    return false;
}

/// Mark teardown requested by a native callback inside this thread's eval. The per-instance bit survives nested evals for other instances and is consumed only when the owning outermost lease exits.
pub fn requestDeferredEvalDestroy(instance_id: i32) bool {
    const state = retain(instance_id) orelse return false;
    state.deferred_eval_destroy.store(true, .seq_cst);
    _ = @import("runtime_control.zig").requestStopInterrupt(instance_id);
    // A callback may request destruction while the owner is inside the event loop. Stop on the owner; a foreign caller wakes it to observe the request.
    state.loop_scope_mu.lock();
    const loop_owner = if (state.loop_scope_depth == 0) null else state.loop_scope_owner;
    state.loop_scope_mu.unlock();
    if (loop_owner) |owner| {
        if (owner == currentThreadId()) {
            engine.stopEventLoop(instance_id);
        } else {
            engine.wakeAsync(instance_id);
        }
    }
    release(state);
    return true;
}

pub const LoopScope = struct {
    state: ?*State = null,
    allowed: bool = false,
};

/// Register the thread currently executing a blocking event-loop call. Scopes nest on the same owner and are released before their enclosing eval lease.
pub fn beginLoopScope(lease: EvalLease) LoopScope {
    if (!lease.allowed) return .{};
    const state = lease.state orelse return .{};
    const owner = currentThreadId();
    state.loop_scope_mu.lock();
    if (state.loop_scope_closing or instance_map.isTeardownPending(state.instance_id)) {
        state.loop_scope_mu.unlock();
        return .{};
    }
    if (state.loop_scope_depth == 0) {
        state.loop_scope_owner = owner;
    } else {
        std.debug.assert(state.loop_scope_owner == owner);
    }
    state.loop_scope_depth += 1;
    state.loop_scope_mu.unlock();
    return .{ .state = state, .allowed = true };
}

pub fn endLoopScope(scope: LoopScope) void {
    if (!scope.allowed) return;
    const state = scope.state orelse return;
    state.loop_scope_mu.lock();
    std.debug.assert(state.loop_scope_depth != 0);
    std.debug.assert(state.loop_scope_owner == currentThreadId());
    state.loop_scope_depth -= 1;
    if (state.loop_scope_depth == 0) state.loop_scope_owner = 0;
    state.loop_scope_wake.broadcast();
    state.loop_scope_mu.unlock();
}

fn closeLoopScopesAndWait(state: *State) void {
    state.loop_scope_mu.lock();
    state.loop_scope_closing = true;
    while (state.loop_scope_depth != 0) {
        state.loop_scope_wake.wait(&state.loop_scope_mu);
    }
    state.loop_scope_mu.unlock();
}

/// Acquire permission to enter a context. JSC's yielded owner is a boolean permission, so it additionally needs a mutex lease to exclude other foreign callers. Nested evals from the current lease owner remain legal.
pub fn beginEval(instance_id: i32) EvalLease {
    // Teardown admission closes before the runtime is freed. Do not recreate an engine thread for public JS while that is in progress.
    if (instance_map.isTeardownPending(instance_id)) return .{ .allowed = false };
    const state = retainOrEnsureState(instance_id) orelse return .{ .allowed = false };

    // Teardown may have become pending while retainOrEnsureState acquired or created State. Recheck before granting access to the context.
    if (instance_map.isTeardownPending(instance_id)) {
        release(state);
        return .{ .allowed = false };
    }

    if (teardownClaimed(state)) {
        release(state);
        return .{ .allowed = false };
    }

    const owner = isEngineThread(state);
    const running = state.running.load(.seq_cst);
    if (running and !owner and !state.yielded.load(.seq_cst)) {
        release(state);
        return .{ .allowed = false };
    }
    const thread_id = currentThreadId();
    if (state.exclusive_eval.load(.seq_cst)) {
        release(state);
        return .{ .allowed = false };
    }

    const needs_gate = !owner;
    var outermost = false;
    var gated = false;
    if (needs_gate) {
        if (state.external_eval_owner.load(.seq_cst) == thread_id) {
            state.external_eval_depth += 1;
            gated = true;
        } else {
            state.external_eval_mu.lock();
            const still_running = state.running.load(.seq_cst);
            if (state.exclusive_eval.load(.seq_cst) or
                teardownClaimed(state) or
                instance_map.isTeardownPending(instance_id) or
                (still_running and (!state.yielded.load(.seq_cst) or state.stopping.load(.seq_cst))))
            {
                state.external_eval_mu.unlock();
                release(state);
                return .{ .allowed = false };
            }
            state.external_eval_owner.store(thread_id, .seq_cst);
            state.external_eval_depth = 1;
            gated = true;
            outermost = true;
        }
    }

    // The teardown latch may have changed while waiting for the external context gate. Undo that gate before refusing the public JS entry.
    if (instance_map.isTeardownPending(instance_id)) {
        if (gated) {
            state.external_eval_depth -= 1;
            if (outermost) {
                state.external_eval_owner.store(0, .seq_cst);
                state.external_eval_mu.unlock();
            }
        }
        release(state);
        return .{ .allowed = false };
    }

    const tls_slot = registerEval(instance_id) orelse {
        if (gated) {
            state.external_eval_depth -= 1;
            if (outermost) {
                state.external_eval_owner.store(0, .seq_cst);
                state.external_eval_mu.unlock();
            }
        }
        release(state);
        return .{ .allowed = false };
    };
    const lease: EvalLease = .{
        .state = state,
        .gated = gated,
        .outermost = outermost,
        .tls_slot = tls_slot,
        .tracked_eval = true,
    };
    // Transport-side disconnects can fail to allocate a dispatch queue. Apply their retained reconciliation request before any newly admitted JS work (and therefore before a Promise job can observe an obsolete hook).
    if (comptime @import("build_options").inspector) {
        if (@import("../inspector/root.zig").state.hasPendingAsyncDepthReconciliation()) {
            @import("../inspector/root.zig").debugger_cdp.reconcilePendingAsyncDepthOnOwner(instance_id);
        }
    }
    return lease;
}

pub fn endEval(lease: EvalLease) void {
    _ = endEvalAndTakeDeferred(lease);
}

/// End a JS entry and report whether it consumed a deferred destroy request after leaving this instance's outermost active eval frame.
pub fn endEvalAndTakeDeferred(lease: EvalLease) bool {
    const state = lease.state orelse return false;
    const outermost_eval = unregisterEval(lease);
    if (lease.exclusive) {
        if (lease.restore_yielded) state.yielded.store(true, .seq_cst);
        state.exclusive_eval.store(false, .seq_cst);
        state.external_eval_mu.unlock();
    } else if (lease.gated) {
        state.external_eval_depth -= 1;
        if (lease.outermost) {
            state.external_eval_owner.store(0, .seq_cst);
            state.external_eval_mu.unlock();
        }
    }
    const destroy_after_unwind = outermost_eval and state.deferred_eval_destroy.swap(false, .seq_cst);
    release(state);
    return destroy_after_unwind;
}

/// Read-only observation for an admitted lease. Callers use this to avoid scheduling another checkpoint after the same outer evaluation requested deferred teardown.
pub fn deferredDestroyRequested(lease: EvalLease) bool {
    const state = lease.state orelse return false;
    return state.deferred_eval_destroy.load(.seq_cst);
}

/// Internal typed evaluation whose admission remains held until result conversion has released every backend value.  This module is not exported by root.zig, so it cannot create a second host execution surface.
pub const TypedEvalEntry = struct {
    instance_id: i32,
    lease: EvalLease,
    result: ?@import("../script/typed_eval.zig").Result,
    execution: ?@import("js_event_loop").Scheduler.Execution = null,

    pub fn finish(self: *TypedEvalEntry) bool {
        if (self.execution) |value| {
            var guard = value;
            guard.end();
            if (instance_map.getPtrs(self.instance_id)) |ptrs| @import("js_scheduler.zig").checkpoint(self.instance_id, ptrs.ctx);
        }
        if (!endEvalAndTakeDeferred(self.lease)) return false;
        engine.destroy(self.instance_id);
        return true;
    }
};

pub fn beginTypedEval(instance_id: i32, script: []const u8, filename: []const u8) ?TypedEvalEntry {
    if (instance_map.getPtrs(instance_id) == null) return null;
    const lease = beginEval(instance_id);
    if (!lease.allowed) return .{ .instance_id = instance_id, .lease = lease, .result = null };
    const ptrs = instance_map.getPtrs(instance_id) orelse return .{ .instance_id = instance_id, .lease = lease, .result = null };
    @import("../inspector/root.zig").drainRetired(instance_id);
    debugger_mod.noteScript(instance_id, filename, script);
    debugger_mod.clearExceptionHold(instance_id);
    const execution = @import("js_scheduler.zig").beginExecution(instance_id) orelse return .{ .instance_id = instance_id, .lease = lease, .result = null };
    return .{
        .instance_id = instance_id,
        .lease = lease,
        .result = @import("../script/typed_eval.zig").evaluate(ptrs.ctx, script, filename, "", ""),
        .execution = execution,
    };
}

/// Acquire exclusive access before an engine-thread teardown touches JS-owned values. Unlike beginEval, this lease must be acquired by the engine owner when its JSC context is yielded.
pub fn beginExclusiveTeardown(instance_id: i32) EvalLease {
    const state = retainOrEnsureState(instance_id) orelse return .{};
    if (teardownClaimed(state)) {
        release(state);
        return .{ .allowed = false };
    }
    const thread_id = currentThreadId();
    if (state.external_eval_owner.load(.seq_cst) == thread_id) {
        // Inspector may drain retired values after an eval has returned but before the outer foreign EvalLease is released. That caller already owns the JSC gate, so this nested lease only retains State.
        return .{ .state = state };
    }
    const running = state.running.load(.seq_cst);
    if (running and !isEngineThread(state)) {
        release(state);
        return .{ .allowed = false };
    }

    // Close the admission gate before waiting for any foreign evaluation already holding the mutex. This also fences calls after threadStop, where an existing foreign EvalLease may still hold the context.
    state.exclusive_eval.store(true, .seq_cst);
    const restore_yielded = state.yielded.swap(false, .seq_cst);
    state.external_eval_mu.lock();
    return .{
        .state = state,
        .gated = true,
        .outermost = true,
        .exclusive = true,
        .restore_yielded = restore_yielded,
    };
}

/// True when `threadStart` has succeeded and this thread is not the engine thread. False before start, after stop, and on the engine thread itself (posted jobs call `evalScript` from that thread).
pub fn foreignEvalBlocked(instance_id: i32) bool {
    const state = retain(instance_id) orelse return false;
    defer release(state);
    if (!state.started.load(.seq_cst) or !state.running.load(.seq_cst)) return false;
    // ExitEngine: while the owner has yielded, a foreign eval is allowed.
    if (state.yielded.load(.seq_cst)) return false;
    return !isEngineThread(state);
}

/// True only while `engine.destroy` is tearing this instance's runtime down on this thread. Ordinary `runGc` does not set it. Duktape's `FINALIZER_NORESCUE` / heap-destruct flag.
threadlocal var destroying_id: ?i32 = null;

pub fn isDestroying(instance_id: i32) bool {
    const current = destroying_id orelse return false;
    return current == instance_id;
}

/// Let another thread `evalScript` this instance. Only the engine thread may call it, and only after `threadStart`. Before the engine thread exists this is a no-op and returns true. A foreign caller returns false and does not abort.
///
/// The owner drops its claim so another thread can enter; `reacquire` takes the claim back.
pub fn releaseForExternalEval(instance_id: i32) bool {
    const state = retain(instance_id) orelse return true;
    defer release(state);
    if (!state.started.load(.seq_cst) or state.thread_id.load(.seq_cst) == 0) return true;
    if (!isEngineThread(state)) return false;
    state.yield_depth += 1;
    if (state.yield_depth == 1) {
        suspendBackend(instance_id);
        state.yielded.store(true, .seq_cst);
    }
    return true;
}

/// Inverse of `releaseForExternalEval`. No-op before the engine thread exists, and when this thread does not hold a yield. A foreign caller returns false and does not abort.
pub fn reacquire(instance_id: i32) bool {
    const state = retain(instance_id) orelse return true;
    defer release(state);
    if (!state.started.load(.seq_cst) or state.thread_id.load(.seq_cst) == 0) return true;
    if (!isEngineThread(state)) return false;
    if (state.yield_depth == 0) return true;
    state.yield_depth -= 1;
    if (state.yield_depth == 0) {
        // Block foreign eval before this thread owns the runtime again.
        state.yielded.store(false, .seq_cst);
        if (backend.active_backend == .jsc) {
            // Wait for an evaluation already admitted during the yield. Any queued caller rechecks `yielded` after acquiring the mutex.
            state.external_eval_mu.lock();
            state.external_eval_mu.unlock();
        }
        resumeBackend(instance_id);
        // While yielded the loop reports no runnable work, so work queued meanwhile needs a wake to run.
        engine.wakeAsync(instance_id);
    }
    return true;
}

fn suspendBackend(instance_id: i32) void {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const ctx = engine.getContext(instance_id) orelse return;
            @import("../backend.zig").ActiveEngineModule.lifecycle.suspendJsOwner(ctx);
        },
        .jsc => {},
    }
}

fn resumeBackend(instance_id: i32) void {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const ctx = engine.getContext(instance_id) orelse return;
            @import("../backend.zig").ActiveEngineModule.lifecycle.resumeJsOwner(ctx);
        },
        .jsc => {},
    }
}

/// `weakcb` installs this so `processPendingJobs` can run deferred finalizers without a container-level import cycle.
var deferred_drain_mu: sync.Mutex = .{};
var deferred_drain: ?*const fn (instance_id: i32) void = null;

pub fn setDeferredDrain(f: *const fn (instance_id: i32) void) void {
    deferred_drain_mu.lock();
    defer deferred_drain_mu.unlock();
    deferred_drain = f;
}

pub fn runDeferredDrain(instance_id: i32) void {
    deferred_drain_mu.lock();
    const f = deferred_drain;
    deferred_drain_mu.unlock();
    if (f) |cb| cb(instance_id);
}

const NativeTask = struct {
    func: *const fn (?*anyopaque) void,
    data: ?*anyopaque,
};

/// Ask the engine thread to run `func` outside any JavaScript call so the owner can yield while in native code, not inside eval. Returns false when the thread is not running or a task is already queued.
pub fn postToEngineThread(instance_id: i32, func: *const fn (?*anyopaque) void, data: ?*anyopaque) bool {
    const state = retain(instance_id) orelse return false;
    defer release(state);
    if (!state.running.load(.seq_cst) or state.stopping.load(.seq_cst)) return false;
    state.queue_mu.lock();
    if (state.native_task != null) {
        state.queue_mu.unlock();
        return false;
    }
    state.native_task = .{ .func = func, .data = data };
    state.has_native.store(true, .seq_cst);
    notifyLocked(state);
    state.queue_mu.unlock();
    notify(state);
    engine.wakeAsync(instance_id);
    return true;
}

fn takeNative(state: *State) ?NativeTask {
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    const task = state.native_task orelse return null;
    state.native_task = null;
    state.has_native.store(false, .seq_cst);
    return task;
}

fn freeRuntimeArmed(instance_id: i32) void {
    const prev = destroying_id;
    destroying_id = instance_id;
    defer destroying_id = prev;
    engine.destroyRuntime(instance_id);
    // Finalizers may have enqueued deferred work while the runtime was already going away. Drop it; the context is gone, so it must not run JS.
    runDeferredDrain(instance_id);
}

pub fn postScript(
    instance_id: i32,
    src: []const u8,
    filename: []const u8,
) u64 {
    const state = retain(instance_id) orelse return 0;
    defer release(state);
    return postScriptOnState(state, src, filename);
}

/// The caller keeps `state` retained across posting and acquiring the job. This closes the destroy race in synchronous run APIs: a script can destroy its own instance before `postScript` returns to the caller.
fn postScriptOnState(
    state: *State,
    src: []const u8,
    filename: []const u8,
) u64 {
    if (!state.running.load(.seq_cst) or state.stopping.load(.seq_cst)) return 0;

    const src_copy = std.heap.c_allocator.dupe(u8, src) catch return 0;
    const name_copy = std.heap.c_allocator.dupe(u8, filename) catch {
        std.heap.c_allocator.free(src_copy);
        return 0;
    };
    const job = std.heap.c_allocator.create(Job) catch {
        std.heap.c_allocator.free(src_copy);
        std.heap.c_allocator.free(name_copy);
        return 0;
    };

    state.queue_mu.lock();
    if (state.stopping.load(.seq_cst) or !state.running.load(.seq_cst)) {
        state.queue_mu.unlock();
        std.heap.c_allocator.free(src_copy);
        std.heap.c_allocator.free(name_copy);
        std.heap.c_allocator.destroy(job);
        return 0;
    }
    const id = state.next_id;
    state.next_id += 1;
    if (state.next_id == 0) state.next_id = 1;
    state.last_seq += 1;
    job.* = .{
        .id = id,
        .seq = state.last_seq,
        .src = src_copy,
        .filename = name_copy,
    };
    state.jobs.put(id, job) catch {
        state.last_seq -= 1;
        state.queue_mu.unlock();
        std.heap.c_allocator.free(src_copy);
        std.heap.c_allocator.free(name_copy);
        std.heap.c_allocator.destroy(job);
        return 0;
    };
    enqueueLocked(state, job);
    state.queue_mu.unlock();
    engine.wakeAsync(state.instance_id);
    return id;
}

/// Wait for a posted job. A successful or terminal wait consumes its job id and stored result; a timeout leaves it available for a later wait.
pub fn waitJob(
    instance_id: i32,
    job_id: u64,
    timeout_ms: u64,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    out_result.* = null;
    out_error.* = null;
    if (job_id == 0) return status_invalid;

    const state = retain(instance_id) orelse return status_invalid;
    defer release(state);

    const job = acquireJob(state, job_id) orelse return status_invalid;
    const status = waitOn(state, job, timeout_ms, out_result, out_error);
    releaseJobWaiter(state, job, status);
    return status;
}

pub fn barrier(instance_id: i32, timeout_ms: u64) c_int {
    const state = retain(instance_id) orelse return status_invalid;
    defer release(state);
    if (!state.started.load(.seq_cst)) return status_invalid;

    const watermark = blk: {
        state.queue_mu.lock();
        defer state.queue_mu.unlock();
        break :blk state.last_seq;
    };
    const deadline = deadlineFrom(timeout_ms);
    while (true) {
        if (state.stopping.load(.seq_cst)) return status_destroyed;
        if (!pendingBefore(state, watermark)) return status_ok;
        if (io.monotonicMilliseconds() >= deadline) return status_timeout;
        if (isEngineThread(state)) {
            if (dequeueMatching(state, watermark)) |job| {
                execute(state, job);
                continue;
            }
            if (takeNative(state)) |task| {
                task.func(task.data);
                continue;
            }
            blockUntil(state, deadline);
        } else {
            state.queue_mu.lock();
            const done = !pendingBeforeLocked(state, watermark, false) or state.stopping.load(.seq_cst);
            if (!done and io.monotonicMilliseconds() < deadline) waitUntil(state, deadline);
            state.queue_mu.unlock();
        }
        if (!pendingBefore(state, watermark)) return status_ok;
        if (state.stopping.load(.seq_cst)) return status_destroyed;
        if (io.monotonicMilliseconds() >= deadline) return status_timeout;
    }
}

pub fn runScript(
    instance_id: i32,
    src: []const u8,
    filename: []const u8,
    timeout_ms: u64,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    out_result.* = null;
    out_error.* = null;
    const state = retain(instance_id) orelse return status_invalid;
    defer release(state);
    const id = postScriptOnState(state, src, filename);
    if (id == 0) return status_invalid;
    const job = acquireJob(state, id) orelse return if (state.stopping.load(.seq_cst)) status_destroyed else status_invalid;
    const status = waitOn(state, job, timeout_ms, out_result, out_error);
    releaseJobWaiter(state, job, status);
    if (status == status_timeout) releaseRunScriptJobOnState(state, id);
    return status;
}

/// Length-preserving public-thread result path. The C-string helpers above remain private test plumbing; this path never creates a sentinel string and therefore preserves embedded NUL bytes.
pub fn runScriptBytes(
    instance_id: i32,
    src: []const u8,
    filename: []const u8,
    timeout_ms: u64,
    out_result: *?[]u8,
    out_error: *?[]u8,
) c_int {
    out_result.* = null;
    out_error.* = null;
    const state = retain(instance_id) orelse return status_invalid;
    defer release(state);
    const id = postScriptOnState(state, src, filename);
    if (id == 0) return status_invalid;
    const job = acquireJob(state, id) orelse return if (state.stopping.load(.seq_cst)) status_destroyed else status_invalid;
    const status = waitOnBytes(state, job, timeout_ms, out_result, out_error);
    releaseJobWaiter(state, job, status);
    if (status == status_timeout) releaseRunScriptJobOnState(state, id);
    return status;
}

/// `runScript` does not expose its job id, so a timeout cannot be retried by its caller. Mark that job for release when execution or cancellation ends. Explicit `postScript` + `waitJob` timeouts remain retryable.
fn releaseRunScriptJob(instance_id: i32, job_id: u64) void {
    const state = retain(instance_id) orelse return;
    defer release(state);
    releaseRunScriptJobOnState(state, job_id);
}

fn releaseRunScriptJobOnState(state: *State, job_id: u64) void {
    var free_job: ?*Job = null;
    state.queue_mu.lock();
    if (state.jobs.get(job_id)) |job| {
        job.auto_release = true;
        if (job.settled and !job.on_stack and job.waiters == 0) {
            _ = state.jobs.remove(job_id);
            free_job = job;
        }
    }
    state.queue_mu.unlock();
    if (free_job) |job| freeJob(job);
}

pub fn evalBytes(
    instance_id: i32,
    src: []const u8,
    filename: []const u8,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    out_result.* = null;
    out_error.* = null;
    if (instance_map.getPtrs(instance_id) == null) return status_invalid;
    // Filename is a display name only. evalScript copies these slices and does not open the path.
    const result = engine.evalScript(instance_id, src, filename);
    return writeEval(result, out_result, out_error);
}

pub fn hostInstall(
    instance_id: i32,
    name: []const u8,
    func: host_value.HostFn,
    user_data: ?*anyopaque,
) bool {
    if (instance_map.getPtrs(instance_id) == null) return false;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => return backend.ActiveEngineModule.host_abi.install(instance_id, name, func, user_data),
        .jsc => return @import("../backend/jsc/host_abi.zig").install(instance_id, name, func, user_data),
    }
}

/// Wake waiters and arrange teardown.
///
/// Returns true when the caller must not free the runtime. Destroy on the engine thread still has the JS call on the stack, so the runtime stays alive until that call returns. The engine thread then frees it. A later destroy from another thread waits for that teardown instead of freeing the runtime again.
pub fn beginDestroy(instance_id: i32) bool {
    const state = retain(instance_id) orelse return false;
    if (!isEngineThread(state)) {
        const deferred = state.deferred_destroy.load(.seq_cst);
        release(state);
        if (!deferred) return false;
        waitInstanceGone(instance_id);
        return true;
    }
    // This thread may still hold an API ref, and the JS call has not returned. Waiting for refs here would deadlock.
    state.life_mu.lock();
    if (state.stop_requests == 0) _ = claimDestroyOwner(state, .engine);
    state.life_mu.unlock();
    if (!state.deferred_destroy.swap(true, .seq_cst)) {
        state.stopping.store(true, .seq_cst);
        _ = @import("runtime_control.zig").requestStopInterrupt(instance_id);
        cancelAll(state);
    }
    release(state);
    return true;
}

fn instanceStillLive(instance_id: i32) bool {
    if (instance_map.getPtrs(instance_id) != null) return true;
    g_mu.lock();
    defer g_mu.unlock();
    return g_states.get(instance_id) != null;
}

/// Stop the engine thread, wake blocked waiters, and drop thread bookkeeping. Used when destroy runs on a thread other than the engine thread, before the event-loop waiter or JS runtime is torn down.
pub fn beforeDestroy(instance_id: i32) void {
    // threadStop's deferred-destroy path enters here without going through engine.destroyNow, so close public JS admission before detaching State.
    instance_map.markTeardownPending(instance_id);
    const gate = destroyGate(instance_id);
    var gate_lease: DestroyGateLease = undefined;
    lockDestroyGate(gate, &gate_lease);
    defer unlockDestroyGate(&gate_lease);

    const state = retain(instance_id) orelse {
        releaseHostBindings(instance_id);
        // No engine thread. destroyRuntime follows this return; run it here so finalizers observe isDestroying on this same thread.
        freeRuntimeArmed(instance_id);
        return;
    };
    // A direct evaluator may have a State but no library-owned thread. The interrupt handler was installed at engine creation, so destruction can still break its currently executing JS before we wait for its lease.
    _ = @import("runtime_control.zig").requestStopInterrupt(instance_id);
    if (!claimDestroyOwner(state, .external)) {
        release(state);
        waitInstanceGone(instance_id);
        return;
    }
    shutdown(state);
    closeLoopScopesAndWait(state);

    // Keep State in g_states until any public loop owner and engine thread have left their blocking calls.
    const detached = detach(instance_id);
    release(state);
    const owned = detached orelse {
        waitInstanceGone(instance_id);
        return;
    };
    if (owned != state) {
        waitInstanceGone(instance_id);
        return;
    }
    waitRefsDrain(owned);
    freeJobs(owned);
    owned.jobs.deinit();
    deinitStateSynchronization(owned);
    std.heap.c_allocator.destroy(owned);
    releaseHostBindings(instance_id);
    freeRuntimeArmed(instance_id);
    // `waitInstanceGone` also watches the runtime map, which drops here.
    notifyGlobal();
}

fn releaseHostBindings(instance_id: i32) void {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => backend.ActiveEngineModule.host_abi.releaseInstance(instance_id),
        .jsc => @import("../backend/jsc/host_abi.zig").releaseInstance(instance_id),
    }
}

fn shutdown(state: *State) void {
    state.stopping.store(true, .seq_cst);
    cancelAll(state);
    // `cancelAll` signals the event-loop waiter so the owner can leave the loop.
    engine.wakeAsync(state.instance_id);

    // A self-stop happens from a host callback. It cannot join itself, but the current JS execution still has to see the stop request after returning from the callback.
    if (isEngineThread(state)) {
        _ = @import("runtime_control.zig").requestStopInterrupt(state.instance_id);
        return;
    }
    // Only an engine-owned deferred teardown may skip joining. If the external path owns teardown, it must join even if a callback requested destroy while that join was in progress.
    if (state.destroy_owner.load(.seq_cst) == @backingInt(DestroyOwner.engine)) return;

    state.queue_mu.lock();
    const hook = state.shutdown_before_life_hook_for_testing;
    const hook_data = state.shutdown_before_life_hook_data_for_testing;
    state.queue_mu.unlock();
    if (hook) |callback| callback(hook_data);

    state.life_mu.lock();
    const thread = state.thread;
    if (thread == null) {
        state.running.store(false, .seq_cst);
        state.life_mu.unlock();
        notify(state);
        return;
    }
    if (state.joining) {
        state.life_mu.unlock();
        waitRunningClear(state);
        return;
    }
    state.joining = true;
    state.life_mu.unlock();

    // Only a real engine thread is interrupted by threadStop. With no thread, a foreign synchronous eval is not owned by this stop request.
    _ = @import("runtime_control.zig").requestStopInterrupt(state.instance_id);

    thread.?.join();

    state.life_mu.lock();
    state.thread = null;
    state.joining = false;
    _ = @import("runtime_control.zig").clearStopInterrupt(state.instance_id);
    state.running.store(false, .seq_cst);
    state.life_mu.unlock();
    notify(state);
}

fn threadMain(state: *State) void {
    state.thread_id.store(currentThreadId(), .seq_cst);

    while (!state.stopping.load(.seq_cst)) {
        if (dequeue(state)) |job| {
            execute(state, job);
            continue;
        }
        if (takeNative(state)) |task| {
            task.func(task.data);
            continue;
        }
        if (state.stopping.load(.seq_cst)) break;
        park(state);
    }

    const deferred = state.deferred_destroy.load(.seq_cst) and
        state.destroy_owner.load(.seq_cst) == @backingInt(DestroyOwner.engine);
    if (deferred) {
        // Clear the id before any free so a deferred teardown does not touch State from a defer after the allocation is gone.
        state.thread_id.store(0, .seq_cst);
        finishDeferredDestroy(state);
        return;
    }
    finishStoppedThread(state);
}

/// A stop requested from a host callback cannot join this thread: the callback has to return before the thread can exit. Once it has exited, detach its self-handle and publish the same stopped state that an external joiner publishes. If an external stop or destroy is already joining, that owner publishes the state after its join returns.
fn finishStoppedThread(state: *State) void {
    state.life_mu.lock();
    if (state.joining) {
        state.life_mu.unlock();
        state.thread_id.store(0, .seq_cst);
        return;
    }
    // Keep State alive after dropping life_mu: a concurrent destroy will see no joinable thread and may otherwise free State before this thread has cleared its id and published the stopped state.
    state.queue_mu.lock();
    _ = state.refs.fetchAdd(1, .seq_cst);
    state.queue_mu.unlock();
    const handle = state.thread;
    state.thread = null;
    _ = @import("runtime_control.zig").clearStopInterrupt(state.instance_id);
    state.running.store(false, .seq_cst);
    // Publish that the old owner is gone before another caller can acquire life_mu and start a replacement thread.
    state.thread_id.store(0, .seq_cst);
    state.life_mu.unlock();
    if (handle) |thread| thread.detach();
    release(state);
}

fn finishDeferredDestroy(state: *State) void {
    const instance_id = state.instance_id;
    const gate = destroyGate(instance_id);
    var gate_lease: DestroyGateLease = undefined;
    lockDestroyGate(gate, &gate_lease);
    defer unlockDestroyGate(&gate_lease);

    state.life_mu.lock();
    const handle = state.thread;
    state.thread = null;
    state.running.store(false, .seq_cst);
    state.joining = false;
    state.life_mu.unlock();
    if (handle) |thread| thread.detach();

    // External waiters drop their refs after observing stop. This thread does not hold one.
    g_mu.lock();
    if (g_states.get(instance_id) == state) {
        _ = g_states.fetchRemove(instance_id);
    }
    g_wake.broadcast();
    g_mu.unlock();
    state.queue_mu.lock();
    const hook = state.detached_hook_for_testing;
    const hook_data = state.detached_hook_data_for_testing;
    state.queue_mu.unlock();
    if (hook) |callback| callback(hook_data);
    waitRefsDrain(state);

    freeJobs(state);
    state.jobs.deinit();
    deinitStateSynchronization(state);
    std.heap.c_allocator.destroy(state);
    releaseHostBindings(instance_id);
    freeRuntimeArmed(instance_id);
    // Runtime map drops in freeRuntimeArmed. Wake waitInstanceGone.
    notifyGlobal();
}

fn execute(state: *State, job: *Job) void {
    state.queue_mu.lock();
    if (job.settled) {
        job.on_stack = false;
        if (job.waiters == 0 and state.jobs.get(job.id) != job) {
            state.queue_mu.unlock();
            freeJob(job);
            return;
        }
        state.queue_mu.unlock();
        return;
    }
    job.on_stack = true;
    state.queue_mu.unlock();

    const adopted: Adopted = if (beginTypedEval(state.instance_id, job.src, job.filename)) |entry_value| blk: {
        var entry = entry_value;
        var value: Adopted = if (entry.result) |eval_result|
            adoptTypedEval(state.instance_id, eval_result)
        else
            Adopted{ .status = if (instance_map.getPtrs(state.instance_id) == null) status_destroyed else status_invalid, .result = null, .err = null };
        if (entry.finish()) {
            freeOptional(value.result);
            freeOptional(value.err);
            value = .{ .status = status_destroyed, .result = null, .err = null };
        }
        break :blk value;
    } else .{ .status = if (instance_map.getPtrs(state.instance_id) == null) status_destroyed else status_invalid, .result = null, .err = null };

    state.queue_mu.lock();
    job.on_stack = false;
    if (!job.settled) {
        job.settled = true;
        job.status = adopted.status;
        job.result = adopted.result;
        job.err = adopted.err;
        notifyLocked(state);
    } else {
        freeOptional(adopted.result);
        freeOptional(adopted.err);
    }
    if (job.auto_release and job.waiters == 0 and state.jobs.get(job.id) == job) {
        _ = state.jobs.remove(job.id);
    }
    const free_job = job.waiters == 0 and !job.on_stack and state.jobs.get(job.id) != job;
    state.queue_mu.unlock();
    if (free_job) freeJob(job);
}

/// Block until `deadline`, a posted job, a native task, or stop. On the engine thread, prefer the event loop so timers keep firing. Callers must not hold `queue_mu`. A host callback already inside the event loop waits on `wake` instead of nesting a blocking run.
fn blockUntil(state: *State, deadline: i64) void {
    if (io.monotonicMilliseconds() >= deadline) return;
    if (state.blocking_in_loop.load(.seq_cst)) {
        state.queue_mu.lock();
        defer state.queue_mu.unlock();
        if (state.stopping.load(.seq_cst) or state.head != null or state.has_native.load(.seq_cst)) return;
        waitUntil(state, deadline);
        return;
    }
    if (engine.loopAlive(state.instance_id)) {
        state.blocking_in_loop.store(true, .seq_cst);
        defer state.blocking_in_loop.store(false, .seq_cst);
        if (!attentionPending(state)) {
            const now = io.monotonicMilliseconds();
            if (now < deadline) {
                const remain: u64 = @intCast(deadline - now);
                engine.blockOnLoopFor(state.instance_id, remain);
            }
        }
        state.blocking_in_loop.store(false, .seq_cst);
        engine.settleAfterLoop(state.instance_id);
        return;
    }
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    if (state.stopping.load(.seq_cst) or state.head != null or state.has_native.load(.seq_cst)) return;
    waitUntil(state, deadline);
}

fn park(state: *State) void {
    if (engine.loopAlive(state.instance_id)) {
        state.blocking_in_loop.store(true, .seq_cst);
        if (!attentionPending(state)) engine.blockOnLoop(state.instance_id);
        state.blocking_in_loop.store(false, .seq_cst);
        engine.settleAfterLoop(state.instance_id);
        return;
    }
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    while (!state.stopping.load(.seq_cst) and state.head == null and !state.has_native.load(.seq_cst)) {
        state.wake.wait(&state.queue_mu);
    }
}

fn attentionPending(state: *State) bool {
    if (state.stopping.load(.seq_cst) or state.has_native.load(.seq_cst)) return true;
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    return state.head != null;
}

/// Called on the loop thread from the instance async callback.
pub fn onLoopAsync(instance_id: i32) void {
    const state = retain(instance_id) orelse return;
    defer release(state);
    state.loop_scope_mu.lock();
    const is_loop_owner = state.loop_scope_depth != 0 and state.loop_scope_owner == currentThreadId();
    state.loop_scope_mu.unlock();
    if (!is_loop_owner) return;
    const deferred_destroy = state.deferred_eval_destroy.load(.seq_cst);
    const shutdown_requested = state.stopping.load(.seq_cst);
    const worker_attention = state.blocking_in_loop.load(.seq_cst) and
        (state.has_native.load(.seq_cst) or queueNonEmpty(state));
    if (deferred_destroy or shutdown_requested or worker_attention) {
        engine.stopEventLoop(instance_id);
    }
}

fn queueNonEmpty(state: *State) bool {
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    return state.head != null;
}

fn waitOn(
    state: *State,
    job: *Job,
    timeout_ms: u64,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    var result: ?[]u8 = null;
    var err: ?[]u8 = null;
    defer if (result) |bytes| std.heap.c_allocator.free(bytes);
    defer if (err) |bytes| std.heap.c_allocator.free(bytes);
    const status = waitOnBytes(state, job, timeout_ms, &result, &err);
    if (status != status_ok and status != status_exception) return status;
    if (result) |bytes| {
        out_result.* = host_value.dupeCString(bytes) orelse return status_out_of_memory;
    }
    if (err) |bytes| {
        out_error.* = host_value.dupeCString(bytes) orelse return status_out_of_memory;
    }
    return status;
}

fn waitOnBytes(
    state: *State,
    job: *Job,
    timeout_ms: u64,
    out_result: *?[]u8,
    out_error: *?[]u8,
) c_int {
    const deadline = deadlineFrom(timeout_ms);
    while (true) {
        if (snapshot(state, job)) |status| {
            if (status == status_ok or status == status_exception) {
                if (!fillOutputsBytes(state, job, out_result, out_error)) return status_out_of_memory;
            }
            return status;
        }
        if (state.stopping.load(.seq_cst)) return status_destroyed;
        if (!state.running.load(.seq_cst)) return if (state.started.load(.seq_cst)) status_destroyed else status_invalid;
        if (io.monotonicMilliseconds() >= deadline) return status_timeout;
        if (isEngineThread(state)) {
            if (dequeue(state)) |next| {
                execute(state, next);
                continue;
            }
            if (takeNative(state)) |task| {
                task.func(task.data);
                continue;
            }
            blockUntil(state, deadline);
        } else {
            state.queue_mu.lock();
            const settled = job.settled or state.stopping.load(.seq_cst) or !state.running.load(.seq_cst);
            if (!settled and io.monotonicMilliseconds() < deadline) waitUntil(state, deadline);
            state.queue_mu.unlock();
        }
    }
}

fn snapshot(state: *State, job: *Job) ?c_int {
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    if (!job.settled) return null;
    return job.status;
}

fn fillOutputsBytes(state: *State, job: *Job, out_result: *?[]u8, out_error: *?[]u8) bool {
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    out_result.* = null;
    out_error.* = null;
    if (job.status == status_ok) {
        if (job.result) |text| {
            if (consumeOutputCopyFault()) return false;
            out_result.* = std.heap.c_allocator.dupe(u8, text) catch return false;
        }
    } else if (job.status == status_exception) {
        if (job.err) |text| {
            if (consumeOutputCopyFault()) return false;
            out_error.* = std.heap.c_allocator.dupe(u8, text) catch return false;
        }
    }
    return true;
}

fn pendingBefore(state: *State, watermark: u64) bool {
    const on_engine = isEngineThread(state);
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    return pendingBeforeLocked(state, watermark, on_engine);
}

fn pendingBeforeLocked(state: *State, watermark: u64, on_engine: bool) bool {
    var it = state.jobs.iterator();
    while (it.next()) |entry| {
        const job = entry.value_ptr.*;
        if (job.seq > watermark or job.settled) continue;
        if (on_engine and job.on_stack) continue;
        return true;
    }
    return false;
}

fn acquireJob(state: *State, job_id: u64) ?*Job {
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    const job = state.jobs.get(job_id) orelse return null;
    job.waiters += 1;
    return job;
}

/// A successful wait consumes the result. Timed-out waits keep the job so the caller can retry; multiple waiters already in flight retain their own reference until they return.
fn releaseJobWaiter(state: *State, job: *Job, status: c_int) void {
    state.queue_mu.lock();
    job.waiters -= 1;
    // A synchronous run has no job id to retry after its terminal result could not be copied.  Treat that local OOM as consumed so the settled source/result cannot remain resident forever.
    if (status == status_ok or status == status_exception or status == status_destroyed or status == status_out_of_memory) {
        if (state.jobs.get(job.id) == job) _ = state.jobs.remove(job.id);
    }
    const free_job = job.waiters == 0 and !job.on_stack and state.jobs.get(job.id) != job;
    state.queue_mu.unlock();
    if (free_job) freeJob(job);
}

fn dequeue(state: *State) ?*Job {
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    return dequeueLocked(state, null);
}

fn dequeueMatching(state: *State, watermark: u64) ?*Job {
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    return dequeueLocked(state, watermark);
}

fn dequeueLocked(state: *State, watermark: ?u64) ?*Job {
    var prev: ?*Job = null;
    var job = state.head;
    while (job) |current| {
        const skip = if (watermark) |wm| current.seq > wm else false;
        if (!skip) {
            if (prev) |p| p.next = current.next else state.head = current.next;
            if (state.tail == current) state.tail = prev;
            current.next = null;
            // Claim execution ownership while still under queue_mu so a concurrent cancel/wait cannot free the dequeued job before execute() reaches its first lock.
            current.on_stack = true;
            return current;
        }
        prev = current;
        job = current.next;
    }
    return null;
}

fn enqueueLocked(state: *State, job: *Job) void {
    job.next = null;
    if (state.tail) |tail| {
        tail.next = job;
    } else {
        state.head = job;
    }
    state.tail = job;
    notifyLocked(state);
}

fn cancelAll(state: *State) void {
    state.queue_mu.lock();
    var reap: ?*Job = null;
    var it = state.jobs.iterator();
    while (it.next()) |entry| {
        const job = entry.value_ptr.*;
        if (job.settled) continue;
        job.settled = true;
        job.status = status_destroyed;
        if (job.auto_release and job.waiters == 0 and !job.on_stack) {
            job.next = reap;
            reap = job;
        }
    }
    state.head = null;
    state.tail = null;
    // A queued native task belongs to the current thread run. Stop cancels it before restart can accidentally execute its borrowed data pointer.
    state.native_task = null;
    state.has_native.store(false, .seq_cst);
    var current = reap;
    while (current) |job| : (current = job.next) {
        _ = state.jobs.remove(job.id);
    }
    notifyLocked(state);
    state.queue_mu.unlock();

    current = reap;
    while (current) |job| {
        const next = job.next;
        freeJob(job);
        current = next;
    }
}

const Adopted = struct {
    status: c_int,
    result: ?[]u8,
    err: ?[]u8,
};

/// The enclosing TypedEvalEntry keeps engine admission active. QuickJS still needs its backend stack anchor for this individual VM entry.
fn serializeThreadValue(ctx: ActiveEngine.Context, value: ActiveEngine.Value) api_backend.BytesResult {
    const entered = if (comptime backend.isQuickJsApiBackend(backend.active_backend))
        backend.ActiveEngineModule.lifecycle.enterJs(ctx)
    else
        true;
    if (!entered) return .{ .out_of_memory = true };
    defer if (comptime backend.isQuickJsApiBackend(backend.active_backend)) backend.ActiveEngineModule.lifecycle.leaveJs(ctx);
    return api_backend.toUtf8(ctx, value);
}

fn adoptTypedValue(ctx: ActiveEngine.Context, value: ActiveEngine.Value, status: c_int) Adopted {
    defer ActiveEngine.freeValue(ctx, value);
    const serialized = serializeThreadValue(ctx, value);
    // ToString itself may enqueue microtasks.  Drain them before the enclosing admission closes, unless that conversion asked to destroy this runtime.
    if (!instance_map.isTeardownPending(ActiveEngine.instanceIdFromCtx(ctx))) ActiveEngine.processPendingJobs(ctx);
    if (serialized.out_of_memory) return .{ .status = status_out_of_memory, .result = null, .err = null };
    if (serialized.bytes) |bytes| return if (status == status_ok)
        .{ .status = status_ok, .result = bytes, .err = null }
    else
        .{ .status = status_exception, .result = null, .err = bytes };
    if (serialized.exception) |serialization_exception| {
        defer ActiveEngine.freeValue(ctx, serialization_exception);
        const thrown = serializeThreadValue(ctx, serialization_exception);
        if (!instance_map.isTeardownPending(ActiveEngine.instanceIdFromCtx(ctx))) ActiveEngine.processPendingJobs(ctx);
        if (thrown.bytes) |bytes| return .{ .status = status_exception, .result = null, .err = bytes };
        if (thrown.exception) |nested| ActiveEngine.freeValue(ctx, nested);
        if (thrown.out_of_memory) return .{ .status = status_out_of_memory, .result = null, .err = null };
    }
    const fallback = std.heap.c_allocator.dupe(u8, "Unable to serialize JavaScript result") catch
        return .{ .status = status_out_of_memory, .result = null, .err = null };
    return .{ .status = status_exception, .result = null, .err = fallback };
}

fn adoptTypedEval(instance_id: i32, result: @import("../script/typed_eval.zig").Result) Adopted {
    if (result.out_of_memory) return .{ .status = status_out_of_memory, .result = null, .err = null };
    const ctx = engine.getContext(instance_id) orelse return .{ .status = status_destroyed, .result = null, .err = null };
    if (result.exception) |exception| return adoptTypedValue(ctx, exception, status_exception);
    if (result.value) |value| return adoptTypedValue(ctx, value, status_ok);
    return .{ .status = status_out_of_memory, .result = null, .err = null };
}

fn adoptEval(res: types.EvalResult) Adopted {
    if (res.err) |err_slice| {
        const owned: ?[]u8 = if (res.err_is_heap)
            @constCast(err_slice)
        else
            std.heap.c_allocator.dupe(u8, err_slice) catch null;
        if (res.result) |result_slice| std.heap.c_allocator.free(@constCast(result_slice));
        return .{ .status = status_exception, .result = null, .err = owned };
    }
    if (res.result) |result_slice| {
        return .{
            .status = status_ok,
            .result = @constCast(result_slice),
            .err = null,
        };
    }
    return .{ .status = status_ok, .result = null, .err = null };
}

fn writeEval(
    res: types.EvalResult,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    const adopted = adoptEval(res);
    if (adopted.status == status_exception) {
        if (adopted.err) |text| {
            out_error.* = host_value.dupeCString(text);
            std.heap.c_allocator.free(text);
        }
        return status_exception;
    }
    if (adopted.result) |text| {
        out_result.* = host_value.dupeCString(text);
        std.heap.c_allocator.free(text);
    }
    return status_ok;
}

fn freeJobs(state: *State) void {
    var it = state.jobs.iterator();
    while (it.next()) |entry| {
        const job = entry.value_ptr.*;
        freeJob(job);
    }
    state.jobs.clearRetainingCapacity();
}

fn freeJob(job: *Job) void {
    std.heap.c_allocator.free(job.src);
    std.heap.c_allocator.free(job.filename);
    freeOptional(job.result);
    freeOptional(job.err);
    std.heap.c_allocator.destroy(job);
}

fn freeOptional(slice: ?[]u8) void {
    if (slice) |text| std.heap.c_allocator.free(text);
}

fn deinitStateSynchronization(state: *State) void {
    state.loop_scope_wake.deinit();
    state.wake.deinit();
    state.loop_scope_mu.deinit();
    state.external_eval_mu.deinit();
    state.queue_mu.deinit();
    state.life_mu.deinit();
}

fn notifyLocked(state: *State) void {
    state.wake.broadcast();
}

fn notify(state: *State) void {
    state.queue_mu.lock();
    defer state.queue_mu.unlock();
    notifyLocked(state);
}

fn notifyGlobal() void {
    g_mu.lock();
    defer g_mu.unlock();
    g_wake.broadcast();
}

fn waitUntil(state: *State, deadline: i64) void {
    const now = io.monotonicMilliseconds();
    if (now >= deadline) return;
    _ = state.wake.waitTimeout(&state.queue_mu, @intCast(deadline - now));
}

fn waitBrief(cond: *sync.Condition, mutex: *sync.Mutex) void {
    _ = cond.waitTimeout(mutex, 1);
}

fn waitRefsDrain(state: *State) void {
    while (true) {
        state.queue_mu.lock();
        if (state.refs.load(.seq_cst) == 0) {
            state.queue_mu.unlock();
            return;
        }
        waitBrief(&state.wake, &state.queue_mu);
        state.queue_mu.unlock();
    }
}

test "last state release holds the drain mutex through notification" {
    const testing = std.testing;
    const Probe = struct {
        entered: std.atomic.Value(bool) = .init(false),
        continue_release: std.atomic.Value(bool) = .init(false),

        fn pause(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.entered.store(true, .seq_cst);
            while (!self.continue_release.load(.seq_cst)) std.atomic.spinLoopHint();
        }

        fn dropRef(state: *State) void {
            release(state);
        }
    };

    var state = State{
        .instance_id = -1,
        .jobs = std.AutoHashMap(u64, *Job).init(std.heap.c_allocator),
    };
    defer state.jobs.deinit();
    defer deinitStateSynchronization(&state);
    state.refs.store(1, .seq_cst);

    var probe = Probe{};
    state.release_hook_for_testing = &Probe.pause;
    state.release_hook_data_for_testing = &probe;

    var thread: ?std.Thread = try std.Thread.spawn(.{}, Probe.dropRef, .{&state});
    defer if (thread) |release_thread| {
        probe.continue_release.store(true, .seq_cst);
        release_thread.join();
    };
    while (!probe.entered.load(.seq_cst)) std.atomic.spinLoopHint();

    const acquired_drain_mutex = state.queue_mu.tryLock();
    if (acquired_drain_mutex) state.queue_mu.unlock();
    try testing.expect(!acquired_drain_mutex);

    probe.continue_release.store(true, .seq_cst);
    thread.?.join();
    thread = null;
    waitRefsDrain(&state);
    try testing.expectEqual(@as(u32, 0), state.refs.load(.seq_cst));
}

fn waitRunningClear(state: *State) void {
    while (state.running.load(.seq_cst)) {
        state.queue_mu.lock();
        if (!state.running.load(.seq_cst)) {
            state.queue_mu.unlock();
            return;
        }
        waitBrief(&state.wake, &state.queue_mu);
        state.queue_mu.unlock();
    }
}

fn waitInstanceGone(instance_id: i32) void {
    while (instanceStillLive(instance_id)) {
        g_mu.lock();
        waitBrief(&g_wake, &g_mu);
        g_mu.unlock();
    }
}

fn deadlineFrom(timeout_ms: u64) i64 {
    const now = io.monotonicMilliseconds();
    const room = std.math.maxInt(i64) - now;
    if (room <= 0) return now;
    const add: i64 = if (timeout_ms > @as(u64, @intCast(room))) room else @intCast(timeout_ms);
    return now + add;
}
