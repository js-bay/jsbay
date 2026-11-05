//! Host object with arbitrary get / set / enumerate traps.
//!
//! Host-object traps for arbitrary property names: unknown gets are `undefined`, a missing set trap throws a plain Error whose message starts with "TypeError: " (the error name is not "TypeError"), enumeration is only the names from `get_property_names` with canonical integer indices ascending first, and `in` / `hasOwnProperty` are true for every name. There is no decorator chain.
//!
//! Callback signatures are structural and must stay identical to the copies in `backend/quickjs/host_object.zig` and `backend/jsc/host_object.zig`.
//!
//! String bytes written by `get` must outlive the callback (static storage, `user_data`, or the heap). The engine copies them immediately after the callback returns. String bytes received by `set` are valid only for that call. `get_property_names` must point `out_names` at storage that outlives the call. `finalize` may run during GC and must not call engine APIs.

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const host_value = @import("../abi/host_value.zig");

const ActiveEngine = backend.ActiveEngine;

/// Null means success and `out` is filled. A non-null sentinel is an error message that becomes a JS exception. The pointer must stay valid.
pub const GetFn = *const fn (instance_id: i32, user_data: ?*anyopaque, name: []const u8, out: *host_value.HostValue) ?[*:0]const u8;

/// Null means the value was stored. A non-null sentinel becomes a JS exception.
pub const SetFn = *const fn (instance_id: i32, user_data: ?*anyopaque, name: []const u8, value: host_value.HostValue) ?[*:0]const u8;

/// Write the enumerable own names. An empty slice enumerates nothing.
pub const NamesFn = *const fn (instance_id: i32, user_data: ?*anyopaque, out_names: *[]const []const u8) void;

/// Runs from GC or engine teardown. Must not call back into the engine.
pub const FinalizeFn = *const fn (user_data: ?*anyopaque) void;

pub const Callbacks = struct {
    get: ?GetFn = null,
    set: ?SetFn = null,
    get_property_names: ?NamesFn = null,
    finalize: ?FinalizeFn = null,
};

/// Create a host object bound to `instance_id`. Callbacks receive that id. The caller owns the returned value (`freeValue`, or `setPropertyStr` which consumes it). Returns null if the instance is gone or allocation fails.
pub fn create(instance_id: i32, user_data: ?*anyopaque, callbacks: Callbacks) ?ActiveEngine.Value {
    const ctx = engine.getContext(instance_id) orelse return null;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const val = qjs_mod.qjsHostObjectCreate(
                ctx,
                instance_id,
                user_data,
                callbacks.get,
                callbacks.set,
                callbacks.get_property_names,
                callbacks.finalize,
            );
            if (qjs_mod.Backend.jsIsException(val)) {
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
            const obj = jsc_mod.jscHostObjectCreate(
                @ptrCast(ctx),
                instance_id,
                user_data,
                callbacks.get,
                callbacks.set,
                callbacks.get_property_names,
                callbacks.finalize,
            );
            if (obj == null) return null;
            const v: ActiveEngine.Value = @ptrCast(obj);
            _ = jsc_mod.jsc.JSValueProtect(@ptrCast(ctx), v);
            return v;
        },
        .escargot => {
            const esc = @import("../backend/escargot/host_object.zig");
            return esc.create(ctx, instance_id, user_data, callbacks.get, callbacks.set, callbacks.get_property_names, callbacks.finalize);
        },
        .hermes => {
            const her = @import("../backend/hermes/host_object.zig");
            return her.create(ctx, instance_id, user_data, callbacks.get, callbacks.set, callbacks.get_property_names, callbacks.finalize);
        },
    }
}
