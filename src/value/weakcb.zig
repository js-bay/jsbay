//! Weak-callback / finalize registration — N-API `napi_wrap` + finalize equivalent, or the V8 weak-persistent-with-finalizer pattern.
//!
//! Use this when native code needs to release a resource at the same moment a JavaScript object becomes unreachable. Common cases:
//!   - clean up native state tied to a host object
//!   - track liveness of a JS-exposed value to free a side table
//!   - fire a "dropped" notification into a Zig data structure
//!
//! ### How it works
//!
//! `attachFinalizer` installs a holder object on the target as a writable property under a unique `__$jsbay_qjs_Finalizer${n}$__` key. The holder is a backend-private object whose GC finalizer hands control back to the user's callback (QuickJS: a `native_handle`-class holder; JSC: a dedicated `JSClassRef` holder whose `finalize` entrypoint is our trampoline). Because nothing else references the holder, it becomes unreachable exactly when the target does — which triggers the backend finalizer and, in turn, the user callback.
//!
//! Multiple finalizers can be attached to the same object; each gets its own holder + callback and all will fire when the object is collected. Firing order across holders on the same target is unspecified.
//!
//! ### Lifetime notes
//!
//! - `target` must be a JS object (plain object, array, function, typed array, NativeHandle, External, ...). Primitives (numbers, strings, booleans, null, undefined) are not supported — the function returns `false` without side effects.
//! - The finalizer runs during GC or engine destroy. It MUST NOT execute JavaScript or re-enter the engine context — just release native resources and return.
//! - `attachDestroyingFinalizer` is the same synchronous native callback with Duktape's second argument: `destroying` is true only while `engine.destroy` is tearing the runtime down (`FINALIZER_NORESCUE`), and false for an ordinary collection.
//! - `attachDeferredFinalizer` only enqueues from the GC callback. The user function runs on the next `processPendingJobs` or `runEventLoopOnce`, on that thread, when `inFinalizer` is false, so it may eval.
//! - When `engine.destroy` tears down the runtime, any un-fired finalizers fire as part of runtime teardown, so `user_data` boxes are reclaimed.
//! - A registration that has already run is not run again at destroy.
//! - The same registration is not re-entered from inside its own callback. Distinct callbacks on one object are independent and all still run.
//!
//! ### Contract
//!
//! Operations on a given `instance_id` MUST happen on the owning thread — same as the rest of the JS Bay public API.

const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const sync = @import("zev");

const ActiveEngine = backend.ActiveEngine;

/// Depth of native finalizer frames on this thread. Deferred user callbacks run only after this returns to zero.
threadlocal var finalizer_depth: u32 = 0;

/// True while a GC / destroy finalizer frame is on this thread's stack.
pub fn inFinalizer() bool {
    return finalizer_depth != 0;
}

/// Finalizer signature. Receives the `user_data` that was passed to `attachFinalizer`. Runs during GC / engine teardown.
pub const FinalizerCallback = *const fn (user_data: ?*anyopaque) callconv(.c) void;

/// Register a callback to fire when `target` becomes GC-unreachable.
///
/// `target` must be a JS object. Returns false if `target` is a primitive, the engine instance has been destroyed, or the backend refused to install the holder (e.g. a frozen target on QuickJS).
///
/// Multiple finalizers can be attached to the same object; each gets its own callback and `user_data`. Firing order across finalizers on the same target is unspecified.
///
/// The `user_data` pointer is passed through opaquely — this module does not interpret it. The caller is responsible for the lifetime of whatever `user_data` references (though in practice the pattern is to heap-allocate a small box and let the finalizer free it).
pub fn attachFinalizer(
    instance_id: i32,
    target: ActiveEngine.Value,
    user_data: ?*anyopaque,
    on_finalize: FinalizerCallback,
) bool {
    const ctx = engine.getContext(instance_id) orelse return false;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            return qjs_mod.qjsWeakAttachFinalizer(ctx, target, user_data, on_finalize);
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            return jsc_mod.jscWeakAttachFinalizer(@ptrCast(ctx), target, user_data, on_finalize);
        },
        .escargot => {
            const c = @import("../backend/escargot/c_api.zig");
            return c.escargot_weak_attach_finalizer(ctx, target, user_data, @ptrCast(on_finalize));
        },
        .hermes => {
            const c = @import("../backend/hermes/c_api.zig");
            return c.hermes_weak_attach_finalizer(ctx, target, user_data, @ptrCast(on_finalize));
        },
    }
}

/// Synchronous finalizer with Duktape's heap-destruct flag as the second argument. `destroying` is true on the `engine.destroy` path and false for an ordinary collection. The callback still must not run JavaScript.
pub const DestroyingFinalizerCallback = *const fn (user_data: ?*anyopaque, destroying: bool) callconv(.c) void;

pub fn attachDestroyingFinalizer(
    instance_id: i32,
    target: ActiveEngine.Value,
    user_data: ?*anyopaque,
    on_finalize: DestroyingFinalizerCallback,
) bool {
    return attachDispatch(instance_id, target, .{
        .instance_id = instance_id,
        .user_data = user_data,
        .destroying_cb = on_finalize,
    });
}

/// User function invoked from `processPendingJobs` / `runEventLoopOnce`, not from the GC finalizer. It may eval.
pub const DeferredFinalizerCallback = *const fn (user_data: ?*anyopaque) callconv(.c) void;

pub fn attachDeferredFinalizer(
    instance_id: i32,
    target: ActiveEngine.Value,
    user_data: ?*anyopaque,
    on_finalize: DeferredFinalizerCallback,
) bool {
    @import("../runtime/engine_thread.zig").setDeferredDrain(drainDeferred);
    return attachDispatch(instance_id, target, .{
        .instance_id = instance_id,
        .user_data = user_data,
        .deferred_cb = on_finalize,
    });
}

const Dispatch = struct {
    instance_id: i32,
    user_data: ?*anyopaque,
    destroying_cb: ?DestroyingFinalizerCallback = null,
    deferred_cb: ?DeferredFinalizerCallback = null,
};

fn attachDispatch(instance_id: i32, target: ActiveEngine.Value, dispatch: Dispatch) bool {
    const ctx = engine.getContext(instance_id) orelse return false;
    const box = std.heap.c_allocator.create(Dispatch) catch return false;
    box.* = dispatch;
    const installed = switch (backend.active_backend) {
        .quickjs, .quickjs_ng => blk: {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            break :blk qjs_mod.qjsWeakAttachFinalizer(ctx, target, @ptrCast(box), dispatchFinalizer);
        },
        .jsc => blk: {
            const jsc_mod = @import("../backend/jsc.zig");
            break :blk jsc_mod.jscWeakAttachFinalizer(@ptrCast(ctx), target, @ptrCast(box), dispatchFinalizer);
        },
        .escargot => blk: {
            const c = @import("../backend/escargot/c_api.zig");
            break :blk c.escargot_weak_attach_finalizer(ctx, target, @ptrCast(box), dispatchFinalizer);
        },
        .hermes => blk: {
            const c = @import("../backend/hermes/c_api.zig");
            break :blk c.hermes_weak_attach_finalizer(ctx, target, @ptrCast(box), dispatchFinalizer);
        },
    };
    if (!installed) std.heap.c_allocator.destroy(box);
    return installed;
}

fn dispatchFinalizer(user_data: ?*anyopaque) callconv(.c) void {
    const box: *Dispatch = @ptrCast(@alignCast(user_data orelse return));
    finalizer_depth += 1;
    defer {
        finalizer_depth -= 1;
        std.heap.c_allocator.destroy(box);
    }
    if (box.deferred_cb) |cb| {
        enqueueDeferred(box.instance_id, box.user_data, cb);
        return;
    }
    if (box.destroying_cb) |cb| {
        const destroying = @import("../runtime/engine_thread.zig").isDestroying(box.instance_id);
        cb(box.user_data, destroying);
    }
}

const DeferredJob = struct {
    instance_id: i32,
    user_data: ?*anyopaque,
    cb: DeferredFinalizerCallback,
    next: ?*DeferredJob = null,
};

var deferred_mu: sync.Mutex = .{};
var deferred_head: ?*DeferredJob = null;
var deferred_tail: ?*DeferredJob = null;

fn enqueueDeferred(instance_id: i32, user_data: ?*anyopaque, cb: DeferredFinalizerCallback) void {
    const job = std.heap.c_allocator.create(DeferredJob) catch return;
    job.* = .{
        .instance_id = instance_id,
        .user_data = user_data,
        .cb = cb,
    };
    deferred_mu.lock();
    defer deferred_mu.unlock();
    if (deferred_tail) |tail| {
        tail.next = job;
    } else {
        deferred_head = job;
    }
    deferred_tail = job;
}

fn popDeferred(instance_id: i32) ?*DeferredJob {
    deferred_mu.lock();
    defer deferred_mu.unlock();
    var prev: ?*DeferredJob = null;
    var it = deferred_head;
    while (it) |job| {
        if (job.instance_id == instance_id) {
            if (prev) |p| p.next = job.next else deferred_head = job.next;
            if (deferred_tail == job) deferred_tail = prev;
            job.next = null;
            return job;
        }
        prev = job;
        it = job.next;
    }
    return null;
}

/// Called from `processPendingJobs` and, after teardown, from destroy. While a finalizer frame is still on the stack this returns without running user code. While `engine.destroy` is in progress, queued jobs are dropped instead of evaluated.
pub fn drainDeferred(instance_id: i32) void {
    if (finalizer_depth != 0) return;
    const destroying = @import("../runtime/engine_thread.zig").isDestroying(instance_id);
    while (popDeferred(instance_id)) |job| {
        const cb = job.cb;
        const ud = job.user_data;
        std.heap.c_allocator.destroy(job);
        if (destroying) continue;
        cb(ud);
    }
}
