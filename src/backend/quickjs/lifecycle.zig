//! QuickJsBackend struct — lifecycle (Runtime/Context create/free), evaluation, console + timer registration, and the cross-backend Value/Context type aliases the rest of the engine consumes via `backend.zig`.
//!
//! Value / type-predicate / extractor / ArrayBuffer-and-friends methods are forwarded into this struct via explicit `pub const foo = value_mixin.foo;` declarations so the external surface (`QuickJsBackend.isUndefined`, etc.) stays identical to the pre-split file while letting that ~330-line block live in its own sibling module.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

const console_cb = @import("console.zig");
const timers_cb = @import("timers.zig");
const exception = @import("exception.zig");
const value_mixin = @import("value.zig");

const types = @import("../../types.zig");
const sync = @import("zev");
const stack_budget = @import("../../platform/stack_budget.zig");

/// Per-runtime JS execution state.
///
/// `owner` is the synchronization point: 0 when idle, else the thread currently inside. It is claimed atomically so two threads racing on the outermost entry cannot both start executing. `depth` counts nested entries by the owner so the owner is released only at the outermost leave. Both are only touched by the owner.
///
/// `anchor_sp`/`anchor_thread` remember the HIGHEST native frame address the limit was anchored at, per thread. The stack grows down, so a later entry that is deeper (lower address) must NOT re-anchor: doing so would set `stack_top` to that deeper pointer and hand the in-progress recursion a fresh full budget, letting it overflow the native stack instead of raising `RangeError`. This holds even for JS entry points that are not wrapped here (getters, `toString`/`toJSON`, other hosts' raw `JS_Eval`): the anchor can only ever move up.
const ExecState = struct {
    depth: u32 = 0,
    owner: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    anchor_thread: ?std.Thread.Id = null,
    anchor_sp: usize = 0,
    /// True after [syncStackTopForJs] has absorbed Zig frames for the current [anchor_sp]. Prevents repeated `JS_UpdateStackTop` on depth==1 re-entry after `leaveJs` (unwrapped host getter recursion) from chasing the native stack into a segfault.
    synced_for_anchor: bool = false,
    configured_stack_size: usize = 0,
};

/// Runtime -> [ExecState]. Keyed by the runtime pointer rather than parked in the runtime opaque slot: the opaque slot is a host-visible field and reading a pointer we did not write would be an unsafe dereference, and a host that uses the slot for its own data must not be disturbed. The registry keeps the engine's state completely private.
///
/// Every access is under [install_mutex], which therefore also provides the happens-before edge publishing an initialized [ExecState] to other threads.
const StateMap = std.AutoHashMapUnmanaged(*qjs.JSRuntime, *ExecState);

var install_mutex: sync.Mutex = .{};
var state_map: StateMap = .{};

/// Number of [ExecState] values installed. Test-only observability.
pub var debug_state_installs: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Number of [ExecState] values freed by [runtimeFinalizer]. Test-only.
pub var debug_state_frees: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Fetch (or lazily install) the runtime's [ExecState].
///
/// Runtimes created through [newRuntime] already have one installed. Runtimes created directly with `JS_NewRuntime` by an embedder or test (the native-handle suites do this) get one installed on first entry so they do not share a single thread-local depth across distinct runtimes. A runtime finalizer frees the state when the runtime is destroyed, however it is destroyed.
///
/// CONTRACT: registering the finalizer calls the runtime's allocator while [install_mutex] is held. A custom `JS_NewRuntime2` allocator must therefore not re-enter the engine (on this or any other runtime); the default allocator does not.
fn execState(rt: ?*qjs.JSRuntime) ?*ExecState {
    const runtime = rt orelse return null;
    install_mutex.lock();
    defer install_mutex.unlock();

    if (state_map.get(runtime)) |s| return s;

    // Reserve the map slot before registering the finalizer, so a later OOM cannot leave a registered finalizer with no entry to remove.
    state_map.ensureUnusedCapacity(std.heap.c_allocator, 1) catch return null;
    const state = std.heap.c_allocator.create(ExecState) catch {
        releaseIdleMap();
        return null;
    };
    state.* = .{};
    if (qjs.JS_AddRuntimeFinalizer(runtime, &runtimeFinalizer, @ptrCast(state)) != 0) {
        std.heap.c_allocator.destroy(state);
        releaseIdleMap();
        return null;
    }
    state_map.putAssumeCapacity(runtime, state);
    _ = debug_state_installs.fetchAdd(1, .monotonic);
    return state;
}

/// Release the registry's backing memory once the last runtime is gone, so a process that creates and destroys many runtimes does not retain the peak capacity forever. Caller must hold [install_mutex].
fn releaseIdleMap() void {
    if (state_map.count() != 0) return;
    state_map.deinit(std.heap.c_allocator);
    state_map = .{};
}

/// Drops the runtime's [ExecState]. Registered on the runtime so it runs whether the runtime is freed through `QuickJsBackend.freeRuntime` or a raw `JS_FreeRuntime` by an embedder. Destroying a runtime is required to be serialized with any use of it, so taking [install_mutex] here cannot race an in-flight entry.
fn runtimeFinalizer(rt: ?*qjs.JSRuntime, arg: ?*anyopaque) callconv(.c) void {
    install_mutex.lock();
    defer install_mutex.unlock();
    _ = state_map.remove(rt.?);
    const state: *ExecState = @ptrCast(@alignCast(arg.?));
    std.heap.c_allocator.destroy(state);
    _ = debug_state_frees.fetchAdd(1, .monotonic);
    releaseIdleMap();
}

/// Error text surfaced when an instance is entered from a different thread while an execution is already in progress. Static (never heap-owned) so a caller can attach it to an `EvalResult` with `err_is_heap = false`.
pub const cross_thread_reentry_msg =
    "js-bay: re-entered from a different thread while an execution is in progress";

/// Anchor QuickJS's JS-stack limit to *this* thread's native stack and mark entry into JS. Returns false (and enters nothing) if the runtime is already executing on a *different* thread.
///
/// `JS_SetMaxStackSize` calibrates `stack_limit` against the creating thread's stack pointer and quickjs.c calls `JS_UpdateStackTop` only once, at runtime creation, so an instance evaluated from another thread trips `js_check_stack_overflow` on its first call regardless of recursion depth. Re-anchoring here lets the runtime run on this thread.
///
/// The anchor moves only UP the stack (see [ExecState]): it is (re)computed when the owning thread first enters, when the thread changes, or when the current frame is at or above the highest frame seen on this thread so far -- never when the current frame is deeper. A nested entry (same thread) is therefore always deeper and never re-anchors, so no entry point can widen the budget, whether or not it is wrapped.
///
/// A nested entry from a *different* thread (or a race on the outermost entry) is refused: ownership is claimed atomically and lost callers get false. This is DIAGNOSTIC ONLY -- callers must still serialize access to an instance, because a caller may touch the runtime before or after calling here (e.g. preparing call arguments), which this cannot guard. A refused caller MUST NOT touch `ctx`.
///
/// HOST CONTRACT: the first entry into a runtime installs per-runtime state under a process-wide lock, and registering the runtime finalizer calls the runtime's allocator while that lock is held. A custom `JS_NewRuntime2` allocator must therefore NOT re-enter the engine (on this or any other runtime, including destroying one). The default allocator never does.
///
/// Pair every successful call with [leaveJs].
pub fn enterJs(ctx: ?*qjs.JSContext) bool {
    if (ctx == null) return true;
    const rt = qjs.JS_GetRuntime(ctx);
    const st = execState(rt) orelse {
        // Could not establish state (OOM / finalizer registration failed). Refuse rather than anchor blindly: anchoring every entry would re-open the downward-drift this guard exists to prevent.
        return false;
    };
    const cur = std.Thread.getCurrentId();
    const cur_bits: usize = @intCast(cur);
    const sp = anchorFrame();

    const owner_now = st.owner.load(.acquire);
    if (owner_now != 0) {
        if (owner_now != cur_bits) return false;
        // Nested same-thread entry: always deeper than the anchor, so skip it.
        st.depth += 1;
        return true;
    }
    // Outermost entry: claim ownership atomically so two racing threads cannot both start executing on this runtime.
    if (st.owner.cmpxchgStrong(0, cur_bits, .acquire, .monotonic) != null) return false;
    st.depth = 1;
    if (st.anchor_thread == null or st.anchor_thread.? != cur or sp >= st.anchor_sp) {
        st.anchor_thread = cur;
        st.anchor_sp = sp;
        st.synced_for_anchor = false;
        updateStackBudget(rt, st, sp);
    } else {
        // stack_top still names anchor_sp. Recompute the limit from that same frame, rather than pairing a deeper frame's available space with an older, higher stack_top and moving the guard below the native stack.
        setStackBudget(rt, st, st.anchor_sp);
    }
    return true;
}

/// Sample the current frame address in its own non-inlined frame so samples from different call sites are comparable: if this were inlined, the compiler could place callers' frames inconsistently and break the monotonic rule.
noinline fn anchorFrame() usize {
    return @frameAddress();
}

/// Mark exit from JS; mirrors [enterJs].
pub fn leaveJs(ctx: ?*qjs.JSContext) void {
    if (ctx == null) return;
    const st = execState(qjs.JS_GetRuntime(ctx)) orelse return;
    if (st.depth == 0) return;
    st.depth -= 1;
    if (st.depth == 0) st.owner.store(0, .release);
}

const SuspendedOwner = struct {
    depth: u32,
    anchor_sp: usize,
    anchor_thread: ?std.Thread.Id,
};

/// One yielded runtime per thread. `releaseForExternalEval` drops ownership so another thread can `enterJs`; `reacquire` restores it.
threadlocal var suspended_owner: ?SuspendedOwner = null;

/// Release this thread's JS ownership. No-op when this thread does not own the runtime. Pair with `resumeJsOwner` on the same thread.
pub fn suspendJsOwner(ctx: ?*qjs.JSContext) void {
    if (ctx == null or suspended_owner != null) return;
    const rt = qjs.JS_GetRuntime(ctx);
    const st = execState(rt) orelse return;
    const cur_bits: usize = @intCast(std.Thread.getCurrentId());
    if (st.owner.load(.acquire) != cur_bits or st.depth == 0) return;
    suspended_owner = .{
        .depth = st.depth,
        .anchor_sp = st.anchor_sp,
        .anchor_thread = st.anchor_thread,
    };
    st.depth = 0;
    st.owner.store(0, .release);
}

/// Take ownership back after `suspendJsOwner` and point QuickJS's stack limit at this thread again. A foreign `enterJs` moved `stack_top`.
pub fn resumeJsOwner(ctx: ?*qjs.JSContext) void {
    const saved = suspended_owner orelse return;
    suspended_owner = null;
    if (ctx == null) return;
    const rt = qjs.JS_GetRuntime(ctx);
    const st = execState(rt) orelse return;
    if (st.owner.load(.acquire) != 0) return;
    const cur_bits: usize = @intCast(std.Thread.getCurrentId());
    const sp = anchorFrame();
    // This is a new outer entry after the foreign evaluation moved QuickJS's stack_top, so the bookkeeping anchor must match the stack_top we set.
    st.anchor_sp = sp;
    st.anchor_thread = std.Thread.getCurrentId();
    st.synced_for_anchor = false;
    st.depth = saved.depth;
    st.owner.store(cur_bits, .release);
    updateStackBudget(rt, st, sp);
}

/// Re-anchor and cap QuickJS to the native stack that is actually executing this turn. JS_SetMaxStackSize alone may carry a creation-thread budget onto a much smaller worker stack.
fn updateStackBudget(rt: ?*qjs.JSRuntime, st: *ExecState, sp: usize) void {
    setStackBudget(rt, st, sp);
    qjs.JS_UpdateStackTop(rt);
}

/// Set a limit using the exact frame QuickJS currently has as stack_top.
fn setStackBudget(rt: ?*qjs.JSRuntime, st: *ExecState, stack_top_sp: usize) void {
    qjs.JS_SetMaxStackSize(rt, stack_budget.capToCurrentThread(st.configured_stack_size, stack_top_sp));
}

/// Re-pin QuickJS `stack_top` to the calling frame on an outermost entry.
///
/// `enterJs` anchors above Zig frames that still run before the engine call (`JS_Eval` / `JS_Call` / …). On a small native thread those frames can consume the entire capped VM budget in Debug builds (~50KiB+ observed), so even `6 * 7` fails with a stack overflow. Calling this immediately before the C engine entry drops that overhead out of the budget while keeping the size calibrated to the outermost [ExecState.anchor_sp] (so the allowance cannot widen past the native stack). Nested entries (depth != 1) are no-ops.
pub fn syncStackTopForJs(ctx: ?*qjs.JSContext) void {
    if (ctx == null) return;
    const rt = qjs.JS_GetRuntime(ctx);
    const st = execState(rt) orelse return;
    if (st.depth != 1) return;
    // Keep the size pinned to the outermost anchor. Only the first sync for this anchor may call JS_UpdateStackTop (to drop Zig frames between enterJs and the C engine entry out of the budget). Later depth==1 entries that did not re-anchor — classic unwrapped host getter recursion — must not move stack_top downward again.
    setStackBudget(rt, st, st.anchor_sp);
    if (st.synced_for_anchor) return;
    qjs.JS_UpdateStackTop(rt);
    st.synced_for_anchor = true;
}

/// Test-only: the thread id this instance's JS-stack limit is currently anchored to, or null if it was never anchored. Lets regression tests assert that an instance entered from a native callback is anchored on the calling thread -- deterministic, unlike relying on native stack addresses.
pub fn debugStackAnchorThread(ctx: ?*qjs.JSContext) ?std.Thread.Id {
    if (ctx == null) return null;
    const st = execState(qjs.JS_GetRuntime(ctx)) orelse return null;
    return st.anchor_thread;
}

/// Test-only: the frame address the limit is currently anchored at.
pub fn debugStackAnchorSp(ctx: ?*qjs.JSContext) usize {
    if (ctx == null) return 0;
    const st = execState(qjs.JS_GetRuntime(ctx)) orelse return 0;
    return st.anchor_sp;
}

/// Nesting depth of processPendingJobsImpl on this thread. Unhandled rejections flush only when the outermost drain finishes, so a .catch queued as a sibling microtask still cancels the report.
threadlocal var job_drain_depth: u32 = 0;

fn shouldStopPendingJobDrain(instance_id: i32) bool {
    const runtime_control = @import("../../runtime/runtime_control.zig");
    if (runtime_control.isInterruptRequested(instance_id)) return true;
    return if (runtime_control.remainingExecutionLimitMillis(instance_id)) |remaining| remaining == 0 else false;
}

pub fn processPendingJobsImpl(ctx: ?*qjs.JSContext) void {
    if (ctx == null) return;
    const instance_id: i32 = @bitCast(@as(u32, @truncate(@intFromPtr(qjs.JS_GetContextOpaque(ctx)))));
    if (shouldStopPendingJobDrain(instance_id)) return;
    if (!@import("../../runtime/scheduler_gate.zig").allows(@ptrCast(ctx))) return;
    defer @import("../../runtime/scheduler_gate.zig").finished(@ptrCast(ctx));
    if (!enterJs(ctx)) return;
    defer leaveJs(ctx);
    syncStackTopForJs(ctx);
    job_drain_depth += 1;
    defer {
        job_drain_depth -= 1;
        if (job_drain_depth == 0) exception.flushPendingRejections(ctx);
    }
    const rt = qjs.JS_GetRuntime(ctx);
    var ctx1: ?*qjs.JSContext = null;
    while (true) {
        if (shouldStopPendingJobDrain(instance_id)) break;
        const status = qjs.JS_ExecutePendingJob(rt, &ctx1);
        if (status > 0) continue;
        if (status < 0 and ctx1 != null) {
            const opaque_id = qjs.JS_GetContextOpaque(ctx1);
            const failed_instance_id: i32 = @bitCast(@as(u32, @truncate(@intFromPtr(opaque_id))));
            if (exception.getAndFormatException(ctx1)) |message| {
                defer std.heap.c_allocator.free(message);
                @import("../../inspector/root.zig").exceptions.reportUncaught(failed_instance_id, message, "");
            }
            if (shouldStopPendingJobDrain(failed_instance_id)) break;
            continue;
        }
        break;
    }
}

pub const QuickJsBackend = struct {
    pub const Runtime = ?*qjs.JSRuntime;
    pub const Context = ?*qjs.JSContext;
    pub const Value = qjs.JSValue;

    // Splice the value-method namespace (predicates, conversions, ArrayBuffer helpers, Map/Set/Date/DataView/BigInt dispatch shims) onto the struct so external callers keep using `QuickJsBackend.<method>` exactly as before. Value-method forwards (predicates, conversions, ArrayBuffer helpers, Map/Set/Date/DataView/BigInt dispatch shims) so external callers keep using `QuickJsBackend.<method>` exactly as before.
    pub const undefinedValue = value_mixin.undefinedValue;
    pub const nullValue = value_mixin.nullValue;
    pub const dupValue = value_mixin.dupValue;
    pub const freeValue = value_mixin.freeValue;
    pub const isFunction = value_mixin.isFunction;
    pub const isUndefined = value_mixin.isUndefined;
    pub const isNull = value_mixin.isNull;
    pub const isBool = value_mixin.isBool;
    pub const isNumber = value_mixin.isNumber;
    pub const isString = value_mixin.isString;
    pub const isSymbol = value_mixin.isSymbol;
    pub const isObjectVal = value_mixin.isObjectVal;
    pub const isArray = value_mixin.isArray;
    pub const sameValue = value_mixin.sameValue;
    pub const toBool = value_mixin.toBool;
    pub const toInt32 = value_mixin.toInt32;
    pub const toFloat64 = value_mixin.toFloat64;
    pub const newBoolVal = value_mixin.newBoolVal;
    pub const newInt32Val = value_mixin.newInt32Val;
    pub const newFloat64Val = value_mixin.newFloat64Val;
    pub const newStringVal = value_mixin.newStringVal;
    pub const newArray = value_mixin.newArray;
    pub const newNullVal = value_mixin.newNullVal;
    pub const newUndefinedVal = value_mixin.newUndefinedVal;
    pub const getPropertyVal = value_mixin.getPropertyVal;
    pub const hasProperty = value_mixin.hasProperty;
    pub const getIndex = value_mixin.getIndex;
    pub const getLength = value_mixin.getLength;
    pub const callFunction = value_mixin.callFunction;
    pub const jsonParseVal = value_mixin.jsonParseVal;
    pub const jsonStringifyVal = value_mixin.jsonStringifyVal;
    pub const valueToStringAlloc = value_mixin.valueToStringAlloc;
    pub const valueToStringVal = value_mixin.valueToStringVal;
    pub const isArrayBufferVal = value_mixin.isArrayBufferVal;
    pub const isTypedArrayVal = value_mixin.isTypedArrayVal;
    pub const getArrayBufferSliceVal = value_mixin.getArrayBufferSliceVal;
    pub const getTypedArrayBytesVal = value_mixin.getTypedArrayBytesVal;
    pub const newArrayBufferCopyVal = value_mixin.newArrayBufferCopyVal;
    pub const newArrayBufferNoCopyVal = value_mixin.newArrayBufferNoCopyVal;
    pub const newTypedArrayFromBufferVal = value_mixin.newTypedArrayFromBufferVal;
    pub const jsIsException = value_mixin.jsIsException;
    pub const jsIsUndefined = value_mixin.jsIsUndefined;
    pub const jsIsNull = value_mixin.jsIsNull;
    pub const jsIsObject = value_mixin.jsIsObject;
    pub const getAndFormatException = value_mixin.getAndFormatException;
    pub const jsonStringify = value_mixin.jsonStringify;
    pub const valueToString = value_mixin.valueToString;
    pub const isDate = value_mixin.isDate;
    pub const toDateMs = value_mixin.toDateMs;
    pub const newDate = value_mixin.newDate;
    pub const isBigInt = value_mixin.isBigInt;
    pub const toBigIntI64 = value_mixin.toBigIntI64;
    pub const toBigIntU64 = value_mixin.toBigIntU64;
    pub const newBigIntI64 = value_mixin.newBigIntI64;
    pub const newBigIntU64 = value_mixin.newBigIntU64;
    pub const isMap = value_mixin.isMap;
    pub const isSet = value_mixin.isSet;
    pub const mapSetToJson = value_mixin.mapSetToJson;
    pub const newMapFromJson = value_mixin.newMapFromJson;
    pub const newSetFromJson = value_mixin.newSetFromJson;
    pub const mapSize = value_mixin.mapSize;
    pub const setSize = value_mixin.setSize;
    pub const newMap = value_mixin.newMap;
    pub const newSet = value_mixin.newSet;
    pub const mapSet = value_mixin.mapSet;
    pub const setAdd = value_mixin.setAdd;
    pub const isDataView = value_mixin.isDataView;
    pub const BackendDataViewInfo = value_mixin.BackendDataViewInfo;
    pub const dataViewInfo = value_mixin.dataViewInfo;
    pub const newDataViewFromBuffer = value_mixin.newDataViewFromBuffer;
    pub const MapForEachFn = value_mixin.MapForEachFn;
    pub const SetForEachFn = value_mixin.SetForEachFn;
    pub const mapForEach = value_mixin.mapForEach;
    pub const setForEach = value_mixin.setForEach;

    // ---- Lifecycle ----

    pub fn newRuntime() ?Runtime {
        const rt = qjs.JS_NewRuntime() orelse return null;
        @import("jobs.zig").install(rt);
        if (execState(rt) == null) {
            qjs.JS_FreeRuntime(rt);
            return null;
        }
        return rt;
    }

    pub fn setMaxStackSize(rt: Runtime, size: usize) void {
        const st = execState(rt) orelse {
            // A raw host runtime can fail to allocate our bookkeeping state. Keep QuickJS's guard enabled with the conservative fallback.
            qjs.JS_SetMaxStackSize(rt, stack_budget.conservative_limit);
            return;
        };
        st.configured_stack_size = size;
        updateStackBudget(rt, st, anchorFrame());
    }

    pub fn newContext(rt: Runtime) ?Context {
        const ctx = qjs.JS_NewContext(rt);
        return if (ctx != null) ctx else null;
    }

    pub fn freeContext(ctx: Context) void {
        // Drop dup'd rejection records while the context can still free them.
        exception.dropRejectionState(ctx);
        qjs.JS_FreeContext(ctx);
    }

    pub fn freeRuntime(rt: Runtime) void {
        exception.forgetRejectionRuntime(rt);
        // The ExecState is freed by the runtime finalizer registered in execState, so this works uniformly for runtimes the engine created and for foreign runtimes an embedder frees with a raw JS_FreeRuntime.
        qjs.JS_FreeRuntime(rt);
    }

    pub fn runGc(rt: Runtime) void {
        qjs.JS_RunGC(rt);
    }

    // ---- Context opaque ----

    pub fn setContextOpaque(ctx: Context, data: ?*anyopaque) void {
        qjs.JS_SetContextOpaque(ctx, data);
    }

    pub fn getContextOpaque(ctx: Context) ?*anyopaque {
        return qjs.JS_GetContextOpaque(ctx);
    }

    pub fn instanceIdFromCtx(ctx: Context) i32 {
        const ptr = getContextOpaque(ctx);
        return @bitCast(@as(u32, @truncate(@intFromPtr(ptr))));
    }

    // ---- Evaluation ----

    pub fn eval(ctx: Context, script: []const u8, filename: []const u8) types.EvalResult {
        if (!enterJs(ctx)) return .{ .result = null, .err = cross_thread_reentry_msg, .err_is_heap = false };
        defer leaveJs(ctx);
        const fname = std.heap.c_allocator.dupeSentinel(u8, filename, 0) catch {
            return .{ .result = null, .err = "Failed to allocate filename", .err_is_heap = false };
        };
        defer std.heap.c_allocator.free(fname);
        // QuickJS JS_Eval expects a NUL-terminated input buffer (it may read one past input_len during lexing). Defensively copy into a sentinel-terminated allocation so callers can pass arbitrary slices.
        const src = std.heap.c_allocator.dupeSentinel(u8, script, 0) catch {
            return .{ .result = null, .err = "Failed to allocate script", .err_is_heap = false };
        };
        defer std.heap.c_allocator.free(src);
        syncStackTopForJs(ctx);
        const result = qjs.JS_Eval(
            ctx,
            src.ptr,
            src.len,
            fname.ptr,
            qjs.JS_EVAL_TYPE_GLOBAL,
        );
        // JavaScript jobs belong to this eval turn even when evaluation throws. In particular, queueMicrotask() scheduled before a later throw must not require an unrelated future tick to run.
        defer processPendingJobs(ctx);

        if (c.jsIsException(result)) {
            const msg = exception.getAndFormatException(ctx);
            return .{ .result = null, .err = msg, .err_is_heap = true };
        }

        const ret = if (c.jsIsUndefined(result) or c.jsIsNull(result))
            null
        else if (c.jsIsObject(result))
            exception.jsonStringify(ctx, result)
        else
            exception.valueToString(ctx, result);

        c.jsbay_qjs_JS_FreeValue(ctx, result);
        return .{ .result = ret, .err = null };
    }

    // ---- Pending jobs ----

    pub fn processPendingJobs(ctx: Context) void {
        processPendingJobsImpl(ctx);
        // Deferred finalizers were only enqueued from the GC callback. Run them on this turn, after pending jobs, off the finalizer stack.
        if (ctx == null) return;
        @import("../../runtime/engine_thread.zig").runDeferredDrain(instanceIdFromCtx(ctx));
    }

    // ---- API registration ----

    pub fn registerConsole(ctx: Context) void {
        const global = qjs.JS_GetGlobalObject(ctx);
        const console = qjs.JS_NewObject(ctx);

        for (console_cb.console_bindings) |binding| {
            _ = qjs.JS_SetPropertyStr(ctx, console, binding.js_name, c.jsbay_qjs_JS_NewCFunctionMagic(
                ctx,
                &console_cb.jsConsoleLog,
                binding.js_name,
                1,
                qjs.JS_CFUNC_generic_magic,
                binding.magic,
            ));
        }

        _ = qjs.JS_SetPropertyStr(ctx, global, "console", console);
        c.jsbay_qjs_JS_FreeValue(ctx, global);
    }

    pub fn registerTimers(ctx: Context) void {
        const global = qjs.JS_GetGlobalObject(ctx);
        _ = qjs.JS_SetPropertyStr(ctx, global, "setTimeout", c.jsbay_qjs_JS_NewCFunction(ctx, &timers_cb.jsSetTimeout, "setTimeout", 2));
        _ = qjs.JS_SetPropertyStr(ctx, global, "setInterval", c.jsbay_qjs_JS_NewCFunction(ctx, &timers_cb.jsSetInterval, "setInterval", 2));
        const clear = c.jsbay_qjs_JS_NewCFunction(ctx, &timers_cb.jsClearTimer, "clearTimeout", 1);
        _ = qjs.JS_SetPropertyStr(ctx, global, "clearTimeout", c.jsbay_qjs_JS_DupValue(ctx, clear));
        _ = qjs.JS_SetPropertyStr(ctx, global, "clearInterval", clear);
        c.jsbay_qjs_JS_FreeValue(ctx, global);
        _ = c.jsbay_qjs_JS_InstallQueueMicrotask(ctx);
    }

    pub fn callFunctionNoArgs(ctx: Context, func: Value) ?[]const u8 {
        if (!enterJs(ctx)) return null;
        defer leaveJs(ctx);
        const global = qjs.JS_GetGlobalObject(ctx);
        syncStackTopForJs(ctx);
        const result = qjs.JS_Call(ctx, func, global, 0, null);
        c.jsbay_qjs_JS_FreeValue(ctx, global);
        if (c.jsIsException(result)) {
            const err_msg = exception.getAndFormatException(ctx);
            c.jsbay_qjs_JS_FreeValue(ctx, result);
            return err_msg;
        }
        c.jsbay_qjs_JS_FreeValue(ctx, result);
        return null;
    }

    // ---- Public helpers for consumers (bridge, etc.) ----

    pub fn getGlobalObject(ctx: Context) Value {
        return qjs.JS_GetGlobalObject(ctx);
    }

    pub fn newObject(ctx: Context) Value {
        return qjs.JS_NewObject(ctx);
    }

    /// Set a property keyed by a NUL-terminated name string.
    ///
    /// Ownership contract (cross-backend uniform, matches JSC backend): this function CONSUMES `val`. After the call the caller must NOT use `val` again, and must NOT `freeValue` it — QJS's `JS_SetPropertyStr` steals the reference on both success and failure paths. If the caller needs to retain a usable handle after the set, pass `dupValue(ctx, val)` instead.
    pub fn setPropertyStr(ctx: Context, obj: Value, name: [*:0]const u8, val: Value) void {
        _ = qjs.JS_SetPropertyStr(ctx, obj, name, val);
    }

    pub fn newCFunction(ctx: Context, func: ?*const fn (?*qjs.JSContext, qjs.JSValue, c_int, [*c]qjs.JSValue) callconv(.c) qjs.JSValue, name: [*:0]const u8, length: c_int) Value {
        return c.jsbay_qjs_JS_NewCFunction(ctx, func, name, length);
    }
};
