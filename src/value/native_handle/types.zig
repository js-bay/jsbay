//! engine/native_handle/types.zig — Shared type definitions for the NativeHandle subsystem.
//!
//! HandleData carries native state for a NativeHandle JS object. It is allocated by `handle.create*()` in QuickJS-managed memory so the runtime frees it together with the JS context.

const std = @import("std");
const backend = @import("../../backend.zig");
const c_api = backend.ActiveEngineModule;

/// Re-export of the canonical QuickJS cImport (backend/quickjs/c_api.zig). Must not declare a second @cImport of quickjs.h here: each @cImport call site produces its own structurally-distinct translate-c types, and this subsystem's HandleData/JSValue values cross into backend/quickjs.zig call sites that expect the canonical types.
pub const c = c_api.qjs;

/// Zero-initialized JSValue of the given tag. Used to fabricate the canonical `JS_UNDEFINED` since QuickJS exposes it as a macro.
pub fn mkval(tag: i64) c.JSValue {
    return c_api.mkval(tag);
}

pub const JS_UNDEFINED: c.JSValue = mkval(c.JS_TAG_UNDEFINED);

/// Length of a NUL-terminated C string (byte count, excluding the NUL).
pub fn zLen(code: [*:0]const u8) usize {
    return std.mem.sliceTo(code, 0).len;
}

/// Configuration for a new NativeHandle.  Passed to `create()`.
pub const HandleData = struct {
    /// Arbitrary native pointer carried by this handle.
    ptr: ?*anyopaque = null,

    /// Called when JS invokes the object directly: `handle(args…)`.
    call_fn: ?*const fn (
        ctx: ?*c.JSContext,
        ptr: ?*anyopaque,
        argc: c_int,
        argv: [*c]c.JSValue,
    ) callconv(.c) c.JSValue = null,

    /// Called when the JS object is garbage-collected.
    finalize_fn: ?*const fn (ptr: ?*anyopaque) void = null,

    /// Called during GC mark phase. If native code stores JSValues inside the opaque data, this callback MUST call JS_MarkValue() on each of them so the GC knows they are still reachable.
    gc_mark_fn: ?*const fn (
        rt: ?*c.JSRuntime,
        ptr: ?*anyopaque,
        mark_func: ?*const c.JS_MarkFunc,
    ) void = null,
};

/// Method function type — same as a standard QuickJS C function. `this` is always the NativeHandle object (guaranteed by the bound method trampoline). Use `getOpaque(ctx, this)` to get HandleData.
pub const MethodFn = *const fn (
    ctx: ?*c.JSContext,
    this: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue;
