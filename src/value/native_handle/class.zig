//! engine/native_handle/class.zig — NativeHandle QuickJS class registration.
//!
//! Owns the singleton `class_id` shared by every NativeHandle instance and wires the QuickJS class callbacks (finalizer, GC mark, call). All other NativeHandle submodules depend on this one for the class id and for the HandleData opaque accessor.

const std = @import("std");
const sync = @import("zev");
const types = @import("types.zig");

const c = types.c;
const qjs_api = @import("../../backend.zig").ActiveEngineModule.c_api;

// ── Class ID (shared by all NativeHandle instances) ───────────────────────

var class_id: c.JSClassID = 0;
var class_id_mutex: sync.Mutex = .{};

// ── Class callbacks ───────────────────────────────────────────────────────

/// Invoked by QuickJS GC when a NativeHandle is collected.
fn classFinalizer(rt: ?*c.JSRuntime, val: c.JSValue) callconv(.c) void {
    const p = c.JS_GetOpaque(val, class_id) orelse return;
    const data: *types.HandleData = @ptrCast(@alignCast(p));
    if (data.finalize_fn) |fin| {
        fin(data.ptr);
    }
    c.js_free_rt(rt, p);
}

/// GC mark phase — lets the collector trace JSValues held by native code.
fn classGcMark(rt: ?*c.JSRuntime, val: c.JSValue, mark_func: ?*const c.JS_MarkFunc) callconv(.c) void {
    const p = c.JS_GetOpaque(val, class_id) orelse return;
    const data: *types.HandleData = @ptrCast(@alignCast(p));
    if (data.gc_mark_fn) |mark| {
        mark(rt, data.ptr, mark_func);
    }
}

/// Invoked when JS code calls the object as a function: `handle(args…)`.
fn classCall(
    ctx: ?*c.JSContext,
    func_obj: c.JSValue,
    _: c.JSValue, // this_val
    argc: c_int,
    argv: [*c]c.JSValue,
    _: c_int, // flags
) callconv(.c) c.JSValue {
    const p = c.JS_GetOpaque(func_obj, class_id) orelse
        return c.JS_ThrowTypeError(ctx, "NativeHandle: invalid object");
    const data: *types.HandleData = @ptrCast(@alignCast(p));
    if (data.call_fn) |call_fn| {
        return call_fn(ctx, data.ptr, argc, argv);
    }
    return c.JS_ThrowTypeError(ctx, "NativeHandle is not callable");
}

/// QuickJS class definition with callable + GC mark support.
const class_def = c.JSClassDef{
    .class_name = "NativeHandle",
    .finalizer = classFinalizer,
    .gc_mark = classGcMark,
    .call = classCall,
    .exotic = null,
};

// ── Public API ────────────────────────────────────────────────────────────

/// Register the NativeHandle class with the QuickJS runtime. Must be called once before creating any handles. Idempotent per runtime because `JS_NewClassID` only allocates a new id the first time it sees the zero-initialized output slot.
pub fn init(rt: ?*c.JSRuntime) void {
    class_id_mutex.lock();
    defer class_id_mutex.unlock();
    _ = qjs_api.JS_NewClassID(rt, &class_id);
    _ = c.JS_NewClass(rt, class_id, &class_def);
}

/// Get the class ID (for advanced interop).
pub fn getClassId() c.JSClassID {
    return class_id;
}

/// Internal accessor for sibling submodules — returns the live class id without taking the mutex (callers must guarantee `init` has run).
pub inline fn classIdRaw() c.JSClassID {
    return class_id;
}
