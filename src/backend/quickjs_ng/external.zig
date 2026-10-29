//! External value support (napi_create_external / v8::External parity).
//!
//! Wraps a raw native pointer as an opaque JS object. Uses a dedicated QuickJS class so JS_GetOpaque(val, class_id) returns null for anything that isn't one of ours — giving a clean isExternal / getExternal predicate.

const std = @import("std");
const sync = @import("zev");
const c = @import("c_api.zig");
const qjs = c.qjs;

pub const QjsExternalFinalizer = *const fn (*anyopaque) callconv(.c) void;

/// Internal storage for an External object. Allocated via js_mallocz so that QuickJS frees it automatically when the runtime tears down if the finalizer somehow doesn't run. The finalizer itself calls js_free_rt to release the box on normal collection.
const QjsExternalBox = extern struct {
    ptr: ?*anyopaque,
    finalizer: ?QjsExternalFinalizer,
};

var qjs_external_class_id: qjs.JSClassID = 0;
var qjs_external_class_mutex: sync.Mutex = .{};

fn qjsExternalFinalizer(rt: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const p = qjs.JS_GetOpaque(val, qjs_external_class_id) orelse return;
    const box: *QjsExternalBox = @ptrCast(@alignCast(p));
    if (box.finalizer) |fin| {
        if (box.ptr) |ptr| fin(ptr);
    }
    qjs.js_free_rt(rt, p);
}

const qjs_external_class_def = qjs.JSClassDef{
    .class_name = "JsBayQjsExternal",
    .finalizer = qjsExternalFinalizer,
    .gc_mark = null,
    .call = null,
    .exotic = null,
};

fn qjsEnsureExternalClass(rt: ?*qjs.JSRuntime) void {
    qjs_external_class_mutex.lock();
    defer qjs_external_class_mutex.unlock();
    // JS_NewClassID only allocates a fresh id the first time it sees a zero-initialised cell; subsequent calls are idempotent. JS_NewClass tolerates re-registration when the id is the same, so we unconditionally register — this is robust across tests that recycle JSRuntime pointers.
    _ = c.JS_NewClassID(rt, &qjs_external_class_id);
    _ = qjs.JS_NewClass(rt, qjs_external_class_id, &qjs_external_class_def);
}

/// Wrap `ptr` as an External JS object. Returns JS_EXCEPTION on allocation failure. `finalizer`, if non-null, is invoked with `ptr` when the returned JS value is garbage-collected.
pub fn qjsNewExternal(
    ctx: ?*qjs.JSContext,
    ptr: *anyopaque,
    finalizer: ?QjsExternalFinalizer,
) qjs.JSValue {
    const rt = qjs.JS_GetRuntime(ctx);
    qjsEnsureExternalClass(rt);

    const obj = qjs.JS_NewObjectClass(ctx, @intCast(qjs_external_class_id));
    if (c.jsIsException(obj)) return obj;

    const raw: ?*anyopaque = qjs.js_mallocz(ctx, @sizeOf(QjsExternalBox));
    if (raw == null) {
        c.jsbay_qjs_JS_FreeValue(ctx, obj);
        return qjs.JS_ThrowOutOfMemory(ctx);
    }
    const box: *QjsExternalBox = @ptrCast(@alignCast(raw.?));
    box.* = .{ .ptr = ptr, .finalizer = finalizer };
    _ = qjs.JS_SetOpaque(obj, raw);
    return obj;
}

/// Return the wrapped pointer if `val` is an External, else null. Uses the non-throwing JS_GetOpaque so this is safe to call speculatively on any JSValue.
pub fn qjsGetExternal(val: qjs.JSValue) ?*anyopaque {
    if (qjs_external_class_id == 0) return null;
    const p = qjs.JS_GetOpaque(val, qjs_external_class_id) orelse return null;
    const box: *QjsExternalBox = @ptrCast(@alignCast(p));
    return box.ptr;
}

/// True iff `val` is a JS object previously created by qjsNewExternal.
pub fn qjsIsExternal(val: qjs.JSValue) bool {
    if (qjs_external_class_id == 0) return false;
    return qjs.JS_GetOpaque(val, qjs_external_class_id) != null;
}
