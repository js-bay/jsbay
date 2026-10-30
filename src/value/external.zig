//! External values — wrap a raw native pointer as an opaque JS value.
//!
//! Use this when JavaScript only needs to carry a native pointer through a one-shot FFI bridge.
//!
//! The resulting JS value is an object of a private class. It has no properties and is not callable from JS — it exists solely as a container the engine can GC-track. When the value is collected, the user-supplied finalizer (if any) runs with the native pointer so the owner can release the backing resource.
//!
//! Contract: operations on a given `instance_id` MUST happen on the owning thread.

const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const instance_map = @import("../runtime/instance_map.zig");

const ActiveEngine = backend.ActiveEngine;

/// Finalizer signature. Receives the pointer passed to `newExternal`. The callback runs during GC or context teardown — it MUST NOT execute JavaScript or touch the engine context (QuickJS finalizers receive a runtime, JSC finalizers receive nothing; both forbid re-entering JS).
pub const ExternalFinalizer = *const fn (*anyopaque) callconv(.c) void;

/// Wrap an opaque native pointer as a JS object. The returned JS value is opaque to JS code — it has no properties and cannot be called.
///
/// When the JS value is garbage-collected, `finalizer(ptr)` runs on the native side. Pass `null` to skip finalization.
///
/// Returns `null` if the instance is not found or the backend failed to allocate the wrapper. The caller owns the returned value and must eventually release it via `ActiveEngine.freeValue` (or hand it off to JS, which will GC it).
pub fn newExternal(
    instance_id: i32,
    ptr: *anyopaque,
    finalizer: ?ExternalFinalizer,
) ?ActiveEngine.Value {
    const ctx = engine.getContext(instance_id) orelse return null;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const val = qjs_mod.qjsNewExternal(ctx, ptr, finalizer);
            if (qjs_mod.Backend.jsIsException(val)) {
                // Drain the pending exception so we don't poison the next eval.
                const pending = qjs_mod.qjs.JS_GetException(ctx);
                if (!qjs_mod.Backend.jsIsNull(pending)) {
                    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
                }
                return null;
            }
            return val;
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const obj = jsc_mod.jscNewExternal(@ptrCast(ctx), ptr, finalizer);
            if (obj == null) return null;
            // Protect so the caller can freeValue symmetrically with other Values.
            const v: ActiveEngine.Value = @ptrCast(obj);
            _ = jsc_mod.jsc.JSValueProtect(@ptrCast(ctx), v);
            return v;
        },
        .escargot => {
            const c = @import("../backend/escargot/c_api.zig");
            const fin_c: ?c.ExternalFinalizer = if (finalizer) |f| @ptrCast(f) else null;
            return c.escargot_new_external(ctx, ptr, fin_c);
        },
        .hermes => {
            const c = @import("../backend/hermes/c_api.zig");
            const fin_c: ?c.ExternalFinalizer = if (finalizer) |f| @ptrCast(f) else null;
            return c.hermes_new_external(ctx, ptr, fin_c);
        },
    }
}

/// Extract the pointer from a previously-created External value. Returns `null` if `value` is not an External (including when it was created for a different engine instance — External values are not portable across engines because the class registration is per-process but the backing object lives in a specific runtime).
pub fn getExternal(instance_id: i32, value: ActiveEngine.Value) ?*anyopaque {
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        // QuickJS class id is process-wide; no ctx needed. We still require the instance to exist so callers can't query after destroy().
        _ = engine.getContext(instance_id) orelse return null;
        const qjs_mod = @import("../backend.zig").ActiveEngineModule;
        return qjs_mod.qjsGetExternal(value);
    } else if (comptime backend.isJscApiBackend(backend.active_backend)) {
        const ctx = engine.getContext(instance_id) orelse return null;
        const jsc_mod = @import("../backend/jsc.zig");
        return jsc_mod.jscGetExternal(@ptrCast(ctx), value);
    } else if (comptime backend.active_backend == .escargot) {
        const ctx = engine.getContext(instance_id) orelse return null;
        const c = @import("../backend/escargot/c_api.zig");
        return c.escargot_get_external(ctx, value);
    } else if (comptime backend.active_backend == .hermes) {
        const ctx = engine.getContext(instance_id) orelse return null;
        const c = @import("../backend/hermes/c_api.zig");
        return c.hermes_get_external(ctx, value);
    } else {
        _ = .{ instance_id, value };
        return null;
    }
}

/// Type predicate: true iff `value` was produced by `newExternal`.
pub fn isExternal(instance_id: i32, value: ActiveEngine.Value) bool {
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        _ = engine.getContext(instance_id) orelse return false;
        const qjs_mod = @import("../backend.zig").ActiveEngineModule;
        return qjs_mod.qjsIsExternal(value);
    } else if (comptime backend.isJscApiBackend(backend.active_backend)) {
        const ctx = engine.getContext(instance_id) orelse return false;
        const jsc_mod = @import("../backend/jsc.zig");
        return jsc_mod.jscIsExternal(@ptrCast(ctx), value);
    } else if (comptime backend.active_backend == .escargot) {
        const ctx = engine.getContext(instance_id) orelse return false;
        const c = @import("../backend/escargot/c_api.zig");
        return c.escargot_is_external(ctx, value);
    } else if (comptime backend.active_backend == .hermes) {
        const ctx = engine.getContext(instance_id) orelse return false;
        const c = @import("../backend/hermes/c_api.zig");
        return c.hermes_is_external(ctx, value);
    } else {
        _ = .{ instance_id, value };
        return false;
    }
}
