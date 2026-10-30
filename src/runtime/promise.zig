//! Promise support — native-side create / resolve / reject / detect.
//!
//! Enables native code to hand a Promise back to JS and settle it later, which is the building block for async native functions (e.g. timer-backed I/O, dispatched work).
//!
//! ## API shape
//!
//! ```zig
//! var d = promise.create(instance_id) orelse return error.NoPromise;
//! defer d.deinit();
//! // d.promise is a BORROWED handle — valid while `d` lives.
//!
//! // Later, from the loop thread:
//! d.resolve(some_local); // Invokes JS .then; releases the functions.
//! // Or d.reject(err_local).
//! ```
//!
//! ## Lifetime
//!
//! Every retained handle (the promise itself, plus resolve_fn / reject_fn) lives inside a `Global(Local)`. Those register bookkeeping entries with the engine, so `engine.destroy` will force-release any still-live values even if the caller forgot to `deinit`. The `promise` field is exposed as a borrowed view for convenience.
//!
//! ## Microtasks
//!
//! On QuickJS, calling the resolve/reject function schedules the `.then` / `.catch` handlers as pending jobs. `resolve`/`reject` explicitly drains the job queue via `processPendingJobs` so callers see the side effects synchronously, mirroring the behaviour of `evalScript`. On JSC microtasks are drained automatically by the engine when control returns to the VM.
//!
//! `state` / `result` report pending, fulfilled, or rejected. On QuickJS that is `JS_PromiseState` / `JS_PromiseResult` (result fails while pending). On JSC the public C API cannot read promise state, so the record is the one written by `create` / `resolve` / `reject`.
//!
//! `setRejectionTracker` registers a per-instance host callback. QuickJS uses `JS_SetHostPromiseRejectionTracker`; Escargot uses `VMInstanceRef::registerPromiseRejectCallback`. Both report an unhandled rejection only after the current microtask drain. A synchronous `.catch` therefore does not notify; a later `.catch` notifies with `handled=true`. JSC has no equivalent public hook (returns false). Hermes uses HermesInternal.enablePromiseRejectionTracker plus a host flush after microtask drain (Escargot-style).

const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("engine_thread.zig");
const instance_map = @import("instance_map.zig");
const reference = @import("../value/reference.zig");

const ActiveEngine = backend.ActiveEngine;

pub const Local = reference.Local;
pub const GlobalLocal = reference.Global(Local);

/// A pending promise plus its resolving functions.
///
/// - `promise` is a BORROWED backend Value — valid while the Deferred is alive. Do not call `ActiveEngine.freeValue` on it directly; let `deinit` release it.
/// - `resolve_fn` / `reject_fn` are retained across scope boundaries.
///
/// Every retained handle is registered in the engine's ref bookkeeping so a Deferred that is dropped without deinit (e.g. test-forgotten) does not leak a live JS object across `engine.destroy`.
pub const Deferred = struct {
    instance_id: i32,
    /// Borrowed view — the owning refcount lives in `promise_keep`.
    promise: Local,
    promise_keep: GlobalLocal,
    resolve_fn: GlobalLocal,
    reject_fn: GlobalLocal,
    /// True after resolve/reject has been invoked (or deinit without settling). Guards against double-settle.
    settled: bool = false,

    /// Resolve the promise with `value`. Takes no ownership of `value` — caller is responsible for freeing it afterwards if they allocated it. (The backend JS_Call / JSObjectCallAsFunction dup the argument as needed.) Returns false if already settled or the engine is gone.
    pub fn resolve(self: *Deferred, value: Local) bool {
        return self.settleWith(&self.resolve_fn, value);
    }

    /// Reject with `value` (typically an Error). Same ownership rules as resolve.
    pub fn reject(self: *Deferred, value: Local) bool {
        return self.settleWith(&self.reject_fn, value);
    }

    fn settleWith(self: *Deferred, slot: *GlobalLocal, value: Local) bool {
        if (self.settled) return false;
        const lease = engine_thread.beginEval(self.instance_id);
        defer engine.finishEvalEntry(self.instance_id, lease);
        if (!lease.allowed) {
            // Teardown may have marked admission closed before it has joined a concurrent JS entry. Do not touch retained JS values without a lease; the caller may retry or deinit after that entry exits.
            return false;
        }
        const ctx = ctxFor(self.instance_id) orelse {
            return false;
        };
        var execution = @import("js_scheduler.zig").beginExecution(self.instance_id) orelse return false;
        defer {
            execution.end();
            @import("js_scheduler.zig").checkpoint(self.instance_id, ctx);
        }
        const fn_val = slot.get() orelse {
            self.abandonSettlement();
            return false;
        };
        defer ActiveEngine.freeValue(ctx, fn_val);

        // A previous eval may have left a QuickJS exception pending when the caller did not inspect the exception object. Drop it so resolve / reject still run. This does not make later evals fail; it clears the slot the same way a caught exception would.
        if (comptime backend.isQuickJsApiBackend(backend.active_backend)) clearStaleQuickJsException(ctx);

        var args = [_]Local{value};
        const undef = ActiveEngine.newUndefinedVal(ctx);
        defer ActiveEngine.freeValue(ctx, undef);
        const called = ActiveEngine.callFunction(ctx, fn_val, undef, args[0..]);
        const call_ok = called != null;
        if (called) |r| {
            ActiveEngine.freeValue(ctx, r);
        }

        // Drain microtask queue so .then / .catch callbacks run synchronously.
        ActiveEngine.processPendingJobs(ctx);

        self.settled = true;
        if (backend.isJscApiBackend(backend.active_backend) and call_ok) {
            noteJscSettlement(ctx, self.instance_id, self.promise, slot == &self.resolve_fn, value);
        }
        if (comptime backend.active_backend == .hermes) {
            if (call_ok) {
                const c = @import("../backend/hermes/c_api.zig");
                const st: c_int = if (slot == &self.resolve_fn) 1 else 2;
                c.hermes_promise_note_settled(ctx, self.promise, st, value);
            }
        }
        // Release the resolving callbacks but keep `promise_keep` alive — the caller may still be holding `self.promise` (e.g. it was already returned to JS, but the Deferred remains on their stack until deinit).
        self.resolve_fn.reset();
        self.reject_fn.reset();
        return true;
    }

    /// Settle native ownership without calling into JS. This keeps a deferred completion from leaking its resolving Globals when runtime teardown leaves the context alive only for native request cleanup.
    fn abandonSettlement(self: *Deferred) void {
        self.settled = true;
        self.resolve_fn.reset();
        self.reject_fn.reset();
    }

    /// Release the promise Local and any still-held resolving callbacks. Safe to call multiple times, and safe if the promise was already settled.
    pub fn deinit(self: *Deferred) void {
        if (backend.isJscApiBackend(backend.active_backend)) {
            if (ctxFor(self.instance_id)) |ctx| forgetJscPromise(ctx, self.promise);
        }
        if (comptime backend.active_backend == .hermes) {
            if (ctxFor(self.instance_id)) |ctx| {
                const c = @import("../backend/hermes/c_api.zig");
                c.hermes_promise_forget(ctx, self.promise);
            }
        }
        self.promise_keep.reset();
        self.promise = ActiveEngine.undefinedValue();
        self.resolve_fn.reset();
        self.reject_fn.reset();
        self.settled = true;
    }
};

// ----------------------------------------------------------------------
// Public API
// ----------------------------------------------------------------------

/// Create a pending promise on the given engine. Returns null if the engine does not exist or the backend fails to produce resolving functions.
pub fn create(instance_id: i32) ?Deferred {
    const lease = engine_thread.beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return null;
    const ctx = ctxFor(instance_id) orelse return null;
    return backendCreate(instance_id, ctx);
}

/// Detect whether `value` is a Promise.
pub fn isPromise(instance_id: i32, value: Local) bool {
    const ctx = ctxFor(instance_id) orelse return false;
    return backendIsPromise(ctx, value);
}

/// Lifecycle of a promise. `null` when `value` is not a promise (or, on JSC, not a promise this module created or settled).
pub const PromiseState = enum {
    pending,
    fulfilled,
    rejected,
};

/// `null` when `value` is not a queryable promise.
pub fn state(instance_id: i32, value: Local) ?PromiseState {
    const ctx = ctxFor(instance_id) orelse return null;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => return quickjsPromiseState(ctx, value),
        .jsc => return jscPromiseState(value),
        .escargot => return escargotPromiseState(ctx, value),
        .hermes => return hermesPromiseState(ctx, value),
    }
}

/// Fulfillment value or rejection reason. `null` when the promise is still pending, is not a promise, or the engine is gone. The caller owns the returned value and must `ActiveEngine.freeValue` it.
///
/// Reading a rejected result does not mark the rejection handled.
pub fn result(instance_id: i32, value: Local) ?Local {
    const ctx = ctxFor(instance_id) orelse return null;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => return quickjsPromiseResult(ctx, value),
        .jsc => return jscPromiseResult(ctx, value),
        .escargot => return escargotPromiseResult(ctx, value),
        .hermes => return hermesPromiseResult(ctx, value),
    }
}

/// Host notification for promise rejections. `reason_ptr` is valid only for the duration of the call; copy it if you need to keep it. `handled == false` means the rejection was still uncaught when the current microtask drain finished. `handled == true` means a handler was attached after that report.
pub const RejectionTracker = *const fn (
    instance_id: i32,
    handled: bool,
    reason_ptr: [*]const u8,
    reason_len: usize,
    userdata: ?*anyopaque,
) callconv(.c) void;

/// Register `tracker` for `instance_id`. Pass `null` to unregister. Returns false on JSC. Hermes installs HermesInternal.enablePromiseRejectionTracker (plus module-shim reports). Escargot uses `registerPromiseRejectCallback`.
pub fn setRejectionTracker(instance_id: i32, tracker: ?RejectionTracker, userdata: ?*anyopaque) bool {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const ctx = ctxFor(instance_id) orelse return false;
            const exception = backend.ActiveEngineModule.exception;
            exception.setRejectionTracker(ctx, instance_id, tracker, userdata);
            return true;
        },
        .jsc => return false,
        .escargot => {
            const ctx = ctxFor(instance_id) orelse return false;
            const c = @import("../backend/escargot/c_api.zig");
            // RejectionTracker and EscargotRejectionTrackerFn share the C callconv layout.
            c.escargot_set_rejection_tracker(ctx, instance_id, tracker, userdata);
            return true;
        },
        .hermes => {
            const ctx = ctxFor(instance_id) orelse return false;
            const c = @import("../backend/hermes/c_api.zig");
            return c.hermes_set_rejection_tracker(ctx, instance_id, tracker, userdata);
        },
    }
}

// ----------------------------------------------------------------------
// Backend-specific implementations
// ----------------------------------------------------------------------

fn ctxFor(instance_id: i32) ?ActiveEngine.Context {
    const ptrs = instance_map.getPtrs(instance_id) orelse return null;
    return ptrs.ctx;
}

fn backendCreate(instance_id: i32, ctx: ActiveEngine.Context) ?Deferred {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => return quickjsCreate(instance_id, ctx),
        .jsc => return jscCreate(instance_id, ctx),
        .escargot => return escargotCreate(instance_id, ctx),
        .hermes => return hermesCreate(instance_id, ctx),
    }
}

fn backendIsPromise(ctx: ActiveEngine.Context, value: Local) bool {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => return quickjsIsPromise(ctx, value),
        .jsc => return jscIsPromise(ctx, value),
        .escargot => {
            const c = @import("../backend/escargot/c_api.zig");
            return c.escargot_is_promise(ctx, value);
        },
        .hermes => {
            const c = @import("../backend/hermes/c_api.zig");
            return c.hermes_is_promise(ctx, value);
        },
    }
}

// ---- QuickJS ----

fn quickjsCreate(instance_id: i32, ctx: ActiveEngine.Context) ?Deferred {
    const qjs_mod = backend.ActiveEngineModule;
    const qjs = qjs_mod.qjs;

    var resolving_funcs: [2]qjs.JSValue = .{ qjs_mod.JS_UNDEFINED, qjs_mod.JS_UNDEFINED };
    const promise = qjs.JS_NewPromiseCapability(ctx, &resolving_funcs[0]);
    if (qjs_mod.Backend.jsIsException(promise)) {
        return null;
    }

    // Wrap the two raw function values in Globals so they survive across scope boundaries. Global.init dups, so we must free the originals.
    var resolve_g = GlobalLocal.init(instance_id, resolving_funcs[0]);
    var reject_g = GlobalLocal.init(instance_id, resolving_funcs[1]);
    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, resolving_funcs[0]);
    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, resolving_funcs[1]);

    // Retain the promise via bookkeeping too. Global.init dups, so we release the local refcount afterwards — the only retained ref is now the one inside `promise_keep` (which teardown will release for us).
    var promise_keep = GlobalLocal.init(instance_id, promise);
    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, promise);

    if (resolve_g.isEmpty() or reject_g.isEmpty() or promise_keep.isEmpty()) {
        resolve_g.reset();
        reject_g.reset();
        promise_keep.reset();
        return null;
    }

    return Deferred{
        .instance_id = instance_id,
        .promise = promise,
        .promise_keep = promise_keep,
        .resolve_fn = resolve_g,
        .reject_fn = reject_g,
    };
}

fn quickjsIsPromise(ctx: ActiveEngine.Context, value: Local) bool {
    const c_api = @import("../backend.zig").ActiveEngineModule.c_api;
    return c_api.jsbay_qjs_JS_IsPromise(ctx, value) != 0;
}

// ---- JSC ----

fn jscCreate(instance_id: i32, ctx: ActiveEngine.Context) ?Deferred {
    const jsc_mod = backend.EngineModule(.jsc);
    const jsc = jsc_mod.jsc;

    const jsc_ctx: jsc.JSContextRef = @ptrCast(ctx);
    var resolve_obj: jsc.JSObjectRef = null;
    var reject_obj: jsc.JSObjectRef = null;
    var exc: jsc.JSValueRef = null;
    const promise_obj = jsc.JSObjectMakeDeferredPromise(jsc_ctx, &resolve_obj, &reject_obj, &exc);
    if (exc != null or promise_obj == null or resolve_obj == null or reject_obj == null) {
        return null;
    }

    // Promote to retained values. Globals dup via JSValueProtect.
    const promise_val: jsc.JSValueRef = @ptrCast(promise_obj);
    const resolve_val: jsc.JSValueRef = @ptrCast(resolve_obj);
    const reject_val: jsc.JSValueRef = @ptrCast(reject_obj);

    // Retain through Global (calls JSValueProtect internally). The JSObjectMakeDeferredPromise result is otherwise unprotected, so we don't need a matching Unprotect here.
    var resolve_g = GlobalLocal.init(instance_id, resolve_val);
    var reject_g = GlobalLocal.init(instance_id, reject_val);
    var promise_keep = GlobalLocal.init(instance_id, promise_val);

    if (resolve_g.isEmpty() or reject_g.isEmpty() or promise_keep.isEmpty()) {
        resolve_g.reset();
        reject_g.reset();
        promise_keep.reset();
        return null;
    }

    const eh = @import("../backend/jsc/error_handling.zig");
    eh.jscPromiseNote(@ptrCast(ctx), instance_id, promise_val, .pending, null);

    return Deferred{
        .instance_id = instance_id,
        .promise = promise_val,
        .promise_keep = promise_keep,
        .resolve_fn = resolve_g,
        .reject_fn = reject_g,
    };
}

fn jscIsPromise(ctx: ActiveEngine.Context, value: Local) bool {
    const jsc_mod = backend.EngineModule(.jsc);
    const jsc = jsc_mod.jsc;

    if (value == null) return false;
    const jsc_ctx: jsc.JSContextRef = @ptrCast(ctx);
    if (!jsc.JSValueIsObject(jsc_ctx, value)) return false;

    const global = jsc.JSContextGetGlobalObject(jsc_ctx);
    const name = jsc.JSStringCreateWithUTF8CString("Promise");
    defer jsc.JSStringRelease(name);
    var exc: jsc.JSValueRef = null;
    const ctor = jsc.JSObjectGetProperty(jsc_ctx, global, name, &exc);
    if (exc != null or ctor == null or !jsc.JSValueIsObject(jsc_ctx, ctor)) return false;
    const ctor_obj: jsc.JSObjectRef = @constCast(ctor);
    var inst_exc: jsc.JSValueRef = null;
    const is_instance = jsc.JSValueIsInstanceOfConstructor(jsc_ctx, value, ctor_obj, &inst_exc);
    if (inst_exc != null) return false;
    return is_instance;
}

fn clearStaleQuickJsException(ctx: ActiveEngine.Context) void {
    const qjs_mod = backend.ActiveEngineModule;
    const pending = qjs_mod.qjs.JS_GetException(ctx);
    if (pending.tag != qjs_mod.qjs.JS_TAG_UNINITIALIZED and !qjs_mod.Backend.jsIsNull(pending)) {
        qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
    }
}

fn quickjsPromiseState(ctx: ActiveEngine.Context, value: Local) ?PromiseState {
    const c_api = @import("../backend.zig").ActiveEngineModule.c_api;
    const qjs = backend.ActiveEngineModule.qjs;
    if (c_api.jsbay_qjs_JS_IsPromise(ctx, value) == 0) return null;
    const st = qjs.JS_PromiseState(ctx, value);
    if (st == qjs.JS_PROMISE_PENDING) return .pending;
    if (st == qjs.JS_PROMISE_FULFILLED) return .fulfilled;
    if (st == qjs.JS_PROMISE_REJECTED) return .rejected;
    return null;
}

fn quickjsPromiseResult(ctx: ActiveEngine.Context, value: Local) ?Local {
    const qjs_mod = backend.ActiveEngineModule;
    const qjs = qjs_mod.qjs;
    const st = qjs.JS_PromiseState(ctx, value);
    if (st != qjs.JS_PROMISE_FULFILLED and st != qjs.JS_PROMISE_REJECTED) return null;
    const out = qjs.JS_PromiseResult(ctx, value);
    if (qjs_mod.jsIsException(out)) return null;
    return out;
}

fn jscPromiseState(value: Local) ?PromiseState {
    const eh = @import("../backend/jsc/error_handling.zig");
    const view = eh.jscPromiseQuery(value) orelse return null;
    return switch (view.state) {
        .pending => .pending,
        .fulfilled => .fulfilled,
        .rejected => .rejected,
    };
}

fn jscPromiseResult(ctx: ActiveEngine.Context, value: Local) ?Local {
    const eh = @import("../backend/jsc/error_handling.zig");
    const view = eh.jscPromiseQuery(value) orelse return null;
    if (view.state == .pending) return null;
    const stored = view.result orelse return null;
    return ActiveEngine.dupValue(ctx, stored);
}

fn noteJscSettlement(ctx: ActiveEngine.Context, instance_id: i32, promise: Local, fulfilled: bool, value: Local) void {
    if (comptime !backend.isJscApiBackend(backend.active_backend)) return;
    const eh = @import("../backend/jsc/error_handling.zig");
    eh.jscPromiseNote(
        @ptrCast(ctx),
        instance_id,
        @ptrCast(promise),
        if (fulfilled) .fulfilled else .rejected,
        @ptrCast(value),
    );
}

fn forgetJscPromise(ctx: ActiveEngine.Context, promise: Local) void {
    if (comptime !backend.isJscApiBackend(backend.active_backend)) return;
    const eh = @import("../backend/jsc/error_handling.zig");
    eh.jscPromiseForget(@ptrCast(ctx), @ptrCast(promise));
}

fn escargotCreate(instance_id: i32, ctx: ActiveEngine.Context) ?Deferred {
    const c = @import("../backend/escargot/c_api.zig");
    var promise: c.Value = null;
    var resolve: c.Value = null;
    var reject: c.Value = null;
    if (!c.escargot_promise_create(ctx, &promise, &resolve, &reject)) return null;
    var resolve_g = GlobalLocal.init(instance_id, resolve);
    var reject_g = GlobalLocal.init(instance_id, reject);
    var promise_keep = GlobalLocal.init(instance_id, promise);
    // Global.init dups; free the bridge-retained locals.
    ActiveEngine.freeValue(ctx, resolve);
    ActiveEngine.freeValue(ctx, reject);
    ActiveEngine.freeValue(ctx, promise);
    if (resolve_g.isEmpty() or reject_g.isEmpty() or promise_keep.isEmpty()) {
        resolve_g.reset();
        reject_g.reset();
        promise_keep.reset();
        return null;
    }
    return Deferred{
        .instance_id = instance_id,
        .promise = promise,
        .promise_keep = promise_keep,
        .resolve_fn = resolve_g,
        .reject_fn = reject_g,
    };
}

fn escargotPromiseState(ctx: ActiveEngine.Context, value: Local) ?PromiseState {
    const c = @import("../backend/escargot/c_api.zig");
    return switch (c.escargot_promise_state(ctx, value)) {
        0 => .pending,
        1 => .fulfilled,
        2 => .rejected,
        else => null,
    };
}

fn escargotPromiseResult(ctx: ActiveEngine.Context, value: Local) ?Local {
    const c = @import("../backend/escargot/c_api.zig");
    const st = c.escargot_promise_state(ctx, value);
    if (st != 1 and st != 2) return null;
    return c.escargot_promise_result(ctx, value);
}

fn hermesCreate(instance_id: i32, ctx: ActiveEngine.Context) ?Deferred {
    const c = @import("../backend/hermes/c_api.zig");
    var promise: c.Value = null;
    var resolve: c.Value = null;
    var reject: c.Value = null;
    if (!c.hermes_promise_create(ctx, &promise, &resolve, &reject)) return null;
    var resolve_g = GlobalLocal.init(instance_id, resolve);
    var reject_g = GlobalLocal.init(instance_id, reject);
    var promise_keep = GlobalLocal.init(instance_id, promise);
    ActiveEngine.freeValue(ctx, resolve);
    ActiveEngine.freeValue(ctx, reject);
    ActiveEngine.freeValue(ctx, promise);
    if (resolve_g.isEmpty() or reject_g.isEmpty() or promise_keep.isEmpty()) {
        resolve_g.reset();
        reject_g.reset();
        promise_keep.reset();
        return null;
    }
    return Deferred{
        .instance_id = instance_id,
        .promise = promise,
        .promise_keep = promise_keep,
        .resolve_fn = resolve_g,
        .reject_fn = reject_g,
    };
}

fn hermesPromiseState(ctx: ActiveEngine.Context, value: Local) ?PromiseState {
    const c = @import("../backend/hermes/c_api.zig");
    return switch (c.hermes_promise_state(ctx, value)) {
        0 => .pending,
        1 => .fulfilled,
        2 => .rejected,
        else => null,
    };
}

fn hermesPromiseResult(ctx: ActiveEngine.Context, value: Local) ?Local {
    const c = @import("../backend/hermes/c_api.zig");
    const st = c.hermes_promise_state(ctx, value);
    if (st != 1 and st != 2) return null;
    return c.hermes_promise_result(ctx, value);
}
