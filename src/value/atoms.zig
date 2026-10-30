//! Pre-interned property keys for fast repeated property access.
//!
//! An `Atom` is an opaque, backend-specific handle to a pre-hashed property key. Use it on hot paths where the same string key is read or written many times (event dispatch, render loops, observer tables) — an atom skips the per-access string hash + lookup that `getPropertyStr` pays.
//!
//! Backend mapping:
//! - QuickJS: carries a `JSAtom` (u32 slot into the runtime's global atom table). Equal strings always intern to the same JSAtom.
//! - JavaScriptCore: carries a retained `JSStringRef`. JSC's engine-level string pool gives us the same "pre-hashed" lookup property; two separate `newAtom("foo")` calls may return different JSStringRefs but both map to the same underlying property slot inside JSC.
//!
//! Atoms are ref-counted on both backends. Pair every `newAtom` with a `freeAtom`. Leaking one is not a safety issue but will grow the runtime atom table over time on QuickJS.
//!
//! Safety contract: like every other engine API, an atom created on `instance_id` MUST only be used on that instance's owning thread, and MUST NOT be used after the instance has been destroyed.

const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");

const ActiveEngine = backend.ActiveEngine;

/// Opaque pre-interned property key. Treat the layout as private.
pub const Atom = extern struct {
    /// Backend-specific id:
    ///   - QuickJS: low 32 bits hold a JSAtom, high bits unused.
    ///   - JSC: holds a JSStringRef cast to usize.
    repr: u64,
};

/// Intern `name` as a property key in the given engine's atom table.
///
/// Returns `null` if `instance_id` is not live or the backend failed to allocate. The returned atom MUST be released with `freeAtom` when done.
pub fn newAtom(instance_id: i32, name: []const u8) ?Atom {
    const ctx = engine.getContext(instance_id) orelse return null;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const atom_id = qjs_mod.qjs.JS_NewAtomLen(ctx, name.ptr, name.len);
            // QuickJS uses JS_ATOM_NULL == 0 to signal allocation failure.
            if (atom_id == 0) return null;
            return Atom{ .repr = @as(u64, atom_id) };
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const str_ref = jsc_mod.JscBackend.jsStringFromSlice(name);
            if (str_ref == null) return null;
            return Atom{ .repr = @as(u64, @intFromPtr(str_ref)) };
        },
        .escargot => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            const handle = c_api.escargot_atom_new(ctx, name.ptr, name.len) orelse return null;
            return Atom{ .repr = @intFromPtr(handle) };
        },
        .hermes => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            const handle = c_api.hermes_atom_new(ctx, name.ptr, name.len) orelse return null;
            return Atom{ .repr = @intFromPtr(handle) };
        }, 
    }
}

/// Decode an atom back into an owned UTF-8 string. Caller frees via `allocator.free`. Returns `null` on failure (dead instance, decode error).
pub fn atomToString(allocator: std.mem.Allocator, instance_id: i32, atom: Atom) ?[]u8 {
    const ctx = engine.getContext(instance_id) orelse return null;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const atom_id: qjs_mod.qjs.JSAtom = @truncate(atom.repr);
            var len: usize = 0;
            const cstr = qjs_mod.qjs.JS_AtomToCStringLen(ctx, &len, atom_id);
            if (cstr == null) return null;
            defer qjs_mod.qjs.JS_FreeCString(ctx, cstr);
            const out = allocator.alloc(u8, len) catch return null;
            @memcpy(out, cstr[0..len]);
            return out;
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const str_ref: jsc_mod.jsc.JSStringRef = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            if (str_ref == null) return null;
            const common = @import("../backend/jsc/common.zig");
            return common.jsStringToOwnedAlloc(allocator, str_ref);
        },
        .escargot => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            const handle: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            const p = c_api.escargot_atom_to_utf8(ctx, handle) orelse return null;
            const s = std.mem.span(p);
            const out = allocator.dupe(u8, s) catch {
                _ = std.c.free(p);
                return null;
            };
            _ = std.c.free(p);
            return out;
        },
        .hermes => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            const handle: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            const p = c_api.hermes_atom_to_utf8(ctx, handle) orelse return null;
            const s = std.mem.span(p);
            const out = allocator.dupe(u8, s) catch {
                _ = std.c.free(p);
                return null;
            };
            _ = std.c.free(p);
            return out;
        },
    }
}

/// Release an atom. Safe to call once per `newAtom`. After `freeAtom` the atom value must not be used again.
pub fn freeAtom(instance_id: i32, atom: Atom) void {
    const ctx = engine.getContext(instance_id) orelse return;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const atom_id: qjs_mod.qjs.JSAtom = @truncate(atom.repr);
            qjs_mod.qjs.JS_FreeAtom(ctx, atom_id);
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const str_ref: jsc_mod.jsc.JSStringRef = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            if (str_ref != null) jsc_mod.jsc.JSStringRelease(str_ref);
        },
        .escargot => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            const a: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            c_api.escargot_atom_free(a);
        },
        .hermes => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            const a: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            c_api.hermes_atom_free(a);
        },
    }
}

/// Atom-keyed property read. Semantics match `getPropertyVal`: returns `null` on exception or if the property is missing/undefined.
///
/// Ownership mirrors `ActiveEngine.getPropertyVal` — the caller owns the returned Value and must eventually call `ActiveEngine.freeValue`.
pub fn getProperty(instance_id: i32, object: ActiveEngine.Value, atom: Atom) ?ActiveEngine.Value {
    const ctx = engine.getContext(instance_id) orelse return null;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const atom_id: qjs_mod.qjs.JSAtom = @truncate(atom.repr);
            const val = qjs_mod.qjs.JS_GetProperty(ctx, object, atom_id);
            if (qjs_mod.Backend.jsIsException(val)) {
                // Drain the pending exception so we don't poison subsequent evals.
                const pending = qjs_mod.qjs.JS_GetException(ctx);
                if (!qjs_mod.Backend.jsIsNull(pending)) {
                    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
                }
                qjs_mod.jsbay_qjs_JS_FreeValue(ctx, val);
                return null;
            }
            if (qjs_mod.Backend.jsIsUndefined(val)) return null;
            return val;
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            if (object == null) return null;
            const ctx_ref: jsc_mod.jsc.JSContextRef = @ptrCast(ctx);
            const str_ref: jsc_mod.jsc.JSStringRef = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            if (str_ref == null) return null;
            var exc: jsc_mod.jsc.JSValueRef = null;
            const val = jsc_mod.jsc.JSObjectGetProperty(ctx_ref, @constCast(object), str_ref, &exc);
            if (exc != null) return null;
            if (val == null or jsc_mod.jsc.JSValueIsUndefined(ctx_ref, val)) return null;
            // Protect so the caller can freeValue symmetrically with other Values.
            jsc_mod.jsc.JSValueProtect(ctx_ref, val);
            return val;
        },
        .escargot => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            const a: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            const val = c_api.escargot_get_property_atom(ctx, object, a);
            if (val == null or c_api.escargot_is_undefined(val)) {
                if (val != null) c_api.escargot_free_value(ctx, val);
                return null;
            }
            return val;
        },
        .hermes => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            const a: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            const val = c_api.hermes_get_property_atom(ctx, object, a);
            if (val == null or c_api.hermes_is_undefined(val)) {
                if (val != null) c_api.hermes_free_value(ctx, val);
                return null;
            }
            return val;
        },
    }
}

/// Atom-keyed property write. Returns `true` on success, `false` if the instance is dead or the engine threw.
///
/// CONSUMES `value` on both backends (symmetric with `setPropertyStr`): after the call the caller must NOT use or free `value`. Consumption happens even on failure, so no error-path free is ever needed.
pub fn setProperty(
    instance_id: i32,
    object: ActiveEngine.Value,
    atom: Atom,
    value: ActiveEngine.Value,
) bool {
    const ctx = engine.getContext(instance_id) orelse return false;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const atom_id: qjs_mod.qjs.JSAtom = @truncate(atom.repr);
            // JS_SetProperty steals `value`'s reference on both success AND failure paths, matching the rest of the QJS property API.
            const rc = qjs_mod.qjs.JS_SetProperty(ctx, object, atom_id, value);
            return rc >= 0;
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const ctx_ref: jsc_mod.jsc.JSContextRef = @ptrCast(ctx);
            // Unconditionally unprotect `value` on return to match QJS consume semantics, even on the null-object / null-atom error paths.
            defer if (value != null) jsc_mod.jsc.JSValueUnprotect(ctx_ref, value);
            if (object == null) return false;
            const str_ref: jsc_mod.jsc.JSStringRef = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            if (str_ref == null) return false;
            var exc: jsc_mod.jsc.JSValueRef = null;
            jsc_mod.jsc.JSObjectSetProperty(ctx_ref, @constCast(object), str_ref, value, 0, &exc);
            return exc == null;
        },
        .escargot => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            defer c_api.escargot_free_value(ctx, value);
            const a: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            return c_api.escargot_set_property_atom(ctx, object, a, value);
        },
        .hermes => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            defer c_api.hermes_free_value(ctx, value);
            const a: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            return c_api.hermes_set_property_atom(ctx, object, a, value);
        },
    }
}

/// True iff `object` has a property under the atom key. "Has" matches JS `in` semantics — inherited properties count.
pub fn hasProperty(instance_id: i32, object: ActiveEngine.Value, atom: Atom) bool {
    const ctx = engine.getContext(instance_id) orelse return false;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const atom_id: qjs_mod.qjs.JSAtom = @truncate(atom.repr);
            const rc = qjs_mod.qjs.JS_HasProperty(ctx, object, atom_id);
            if (rc < 0) {
                // Drain any pending exception — hasProperty must never leak one.
                const pending = qjs_mod.qjs.JS_GetException(ctx);
                if (!qjs_mod.Backend.jsIsNull(pending)) {
                    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
                }
                return false;
            }
            return rc != 0;
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            if (object == null) return false;
            const ctx_ref: jsc_mod.jsc.JSContextRef = @ptrCast(ctx);
            const str_ref: jsc_mod.jsc.JSStringRef = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            if (str_ref == null) return false;
            return jsc_mod.jsc.JSObjectHasProperty(ctx_ref, @constCast(object), str_ref);
        },
        .escargot => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            const a: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            return c_api.escargot_has_property_atom(ctx, object, a);
        },
        .hermes => {
            const c_api = @import("../backend.zig").ActiveEngineModule.c_api_mod;
            const a: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(atom.repr)));
            return c_api.hermes_has_property_atom(ctx, object, a);
        },
    }
}
