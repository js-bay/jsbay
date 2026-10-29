//! QuickJS C-API surface: translated header, externs, type constants, sentinel JSValues, and tag-only predicates that every other submodule depends on.
//!
//! This is the ONLY place that imports the translated `quickjs.h`. Other quickjs/* submodules pull symbols through here.

const std = @import("std");
const sync = @import("zev");

// Translated from vendor/quickjs-ng/quickjs.h by the build script.
pub const qjs = @import("qjs");

// ---- Wrapper functions (inline functions exposed via qjs_wrapper.c) ----
pub extern fn jsbay_qjs_JS_NewString(ctx: ?*qjs.JSContext, str: [*:0]const u8) qjs.JSValue;
pub extern fn jsbay_qjs_JS_NewBool(ctx: ?*qjs.JSContext, val: c_int) qjs.JSValue;
pub extern fn jsbay_qjs_JS_NewInt32(ctx: ?*qjs.JSContext, val: i32) qjs.JSValue;
pub extern fn jsbay_qjs_JS_NewFloat64(ctx: ?*qjs.JSContext, val: f64) qjs.JSValue;
pub extern fn jsbay_qjs_JS_NewCFunction(ctx: ?*qjs.JSContext, func: ?*const fn (?*qjs.JSContext, qjs.JSValue, c_int, [*c]qjs.JSValue) callconv(.c) qjs.JSValue, name: [*:0]const u8, length: c_int) qjs.JSValue;
pub extern fn jsbay_qjs_JS_NewCFunctionMagic(ctx: ?*qjs.JSContext, func: ?*const fn (?*qjs.JSContext, qjs.JSValue, c_int, [*c]qjs.JSValue, c_int) callconv(.c) qjs.JSValue, name: [*:0]const u8, length: c_int, cproto: c_int, magic: c_int) qjs.JSValue;
pub extern fn jsbay_qjs_JS_NewCFunctionData(ctx: ?*qjs.JSContext, func: ?*const fn (?*qjs.JSContext, qjs.JSValue, c_int, [*c]qjs.JSValue, c_int, [*c]qjs.JSValue) callconv(.c) qjs.JSValue, name: [*:0]const u8, length: c_int, data: qjs.JSValue) qjs.JSValue;
pub extern fn jsbay_qjs_JS_IsFunction(ctx: ?*qjs.JSContext, val: qjs.JSValue) c_int;
pub extern fn jsbay_qjs_JS_ToCString(ctx: ?*qjs.JSContext, val: qjs.JSValue) ?[*:0]const u8;
pub extern fn jsbay_qjs_JS_DupValue(ctx: ?*qjs.JSContext, val: qjs.JSValue) qjs.JSValue;
pub extern fn jsbay_qjs_JS_FreeValue(ctx: ?*qjs.JSContext, val: qjs.JSValue) void;
pub extern fn jsbay_qjs_JS_FreeCString(ctx: ?*qjs.JSContext, ptr: ?[*:0]const u8) void;
pub extern fn jsbay_qjs_JS_IsBool(val: qjs.JSValue) c_int;
pub extern fn jsbay_qjs_JS_IsNumber(val: qjs.JSValue) c_int;
pub extern fn jsbay_qjs_JS_IsString(val: qjs.JSValue) c_int;
pub extern fn jsbay_qjs_JS_IsSymbol(val: qjs.JSValue) c_int;
pub extern fn jsbay_qjs_JS_IsObject(val: qjs.JSValue) c_int;

// ---- ArrayBuffer / TypedArray externs ----
// These are regular (non-inline) functions exported by quickjs.c, so they can be declared directly as extern without a wrapper. size == 0 frees ptr and returns null. A non-zero size asks for a resize; returning null leaves ptr valid and reports failure.
pub const JSReallocArrayBufferDataFunc = fn (rt: ?*qjs.JSRuntime, opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;

pub extern fn jsbay_qjs_JS_NewArrayBuffer(
    ctx: ?*qjs.JSContext,
    buf: [*c]u8,
    len: usize,
    max_len: usize,
    realloc_func: ?*const JSReallocArrayBufferDataFunc,
    opaque_ptr: ?*anyopaque,
    is_shared: c_int,
) qjs.JSValue;
pub fn JS_NewArrayBuffer(
    ctx: ?*qjs.JSContext,
    buf: [*c]u8,
    len: usize,
    max_len: usize,
    realloc_func: ?*const JSReallocArrayBufferDataFunc,
    opaque_ptr: ?*anyopaque,
    is_shared: bool,
) qjs.JSValue {
    return jsbay_qjs_JS_NewArrayBuffer(ctx, buf, len, max_len, realloc_func, opaque_ptr, @intFromBool(is_shared));
}
pub extern fn JS_NewArrayBufferCopy(ctx: ?*qjs.JSContext, buf: [*c]const u8, len: usize) qjs.JSValue;
pub extern fn JS_GetArrayBuffer(ctx: ?*qjs.JSContext, psize: *usize, obj: qjs.JSValue) [*c]u8;
pub extern fn jsbay_qjs_JS_IsArrayBuffer(ctx: ?*qjs.JSContext, obj: qjs.JSValue) c_int;
pub fn JS_IsArrayBuffer(ctx: ?*qjs.JSContext, obj: qjs.JSValue) bool {
    return jsbay_qjs_JS_IsArrayBuffer(ctx, obj) != 0;
}
pub extern fn jsbay_qjs_JS_IsProxy(ctx: ?*qjs.JSContext, val: qjs.JSValue) c_int;
pub fn JS_IsProxy(ctx: ?*qjs.JSContext, val: qjs.JSValue) bool {
    return jsbay_qjs_JS_IsProxy(ctx, val) != 0;
}
pub extern fn JS_NewTypedArray(
    ctx: ?*qjs.JSContext,
    argc: c_int,
    argv: [*c]qjs.JSValue,
    array_type: c_int,
) qjs.JSValue;
pub extern fn JS_GetTypedArrayBuffer(
    ctx: ?*qjs.JSContext,
    obj: qjs.JSValue,
    pbyte_offset: ?*usize,
    pbyte_length: ?*usize,
    pbytes_per_element: ?*usize,
) qjs.JSValue;
pub extern fn JS_GetDataViewBuffer(
    ctx: ?*qjs.JSContext,
    obj: qjs.JSValue,
    pbyte_offset: ?*usize,
    pbyte_length: ?*usize,
) qjs.JSValue;
pub extern fn JS_IsDataView(obj: qjs.JSValue) bool;
pub extern fn jsbay_qjs_JS_GetTypedArrayType(ctx: ?*qjs.JSContext, obj: qjs.JSValue) c_int;
pub fn JS_GetTypedArrayType(ctx: ?*qjs.JSContext, obj: qjs.JSValue) c_int {
    return jsbay_qjs_JS_GetTypedArrayType(ctx, obj);
}

// Matches JSTypedArrayEnum in quickjs.h
pub const QJS_TYPED_ARRAY_UINT8C: c_int = 0;
pub const QJS_TYPED_ARRAY_INT8: c_int = 1;
pub const QJS_TYPED_ARRAY_UINT8: c_int = 2;
pub const QJS_TYPED_ARRAY_INT16: c_int = 3;
pub const QJS_TYPED_ARRAY_UINT16: c_int = 4;
pub const QJS_TYPED_ARRAY_INT32: c_int = 5;
pub const QJS_TYPED_ARRAY_UINT32: c_int = 6;
pub const QJS_TYPED_ARRAY_BIG_INT64: c_int = 7;
pub const QJS_TYPED_ARRAY_BIG_UINT64: c_int = 8;
pub const QJS_TYPED_ARRAY_FLOAT16: c_int = 9;
pub const QJS_TYPED_ARRAY_FLOAT32: c_int = 10;
pub const QJS_TYPED_ARRAY_FLOAT64: c_int = 11;

// ---- Date / BigInt / instanceof externs (used by datetime + collections) ----
pub extern fn jsbay_qjs_JS_NewDate(ctx: ?*qjs.JSContext, epoch_ms: f64) qjs.JSValue;
pub const JS_NewDate = jsbay_qjs_JS_NewDate;
pub extern fn jsbay_qjs_JS_IsDate(ctx: ?*qjs.JSContext, val: qjs.JSValue) c_int;
pub fn JS_IsDate(ctx: ?*qjs.JSContext, val: qjs.JSValue) bool {
    return jsbay_qjs_JS_IsDate(ctx, val) != 0;
}
pub extern fn jsbay_qjs_JS_NewClassID(rt: ?*qjs.JSRuntime, pclass_id: *qjs.JSClassID) qjs.JSClassID;
extern fn jsbay_qjs_JS_IsRegisteredClass(rt: ?*qjs.JSRuntime, class_id: qjs.JSClassID) c_int;

var class_id_mutex: sync.Mutex = .{};
var class_id_next: qjs.JSClassID = 0;

/// quickjs-ng counts class ids per runtime, but every class here keeps its id in a process-wide cell. A cell therefore has to hold the same id in every runtime; otherwise two cells can land on one id in a runtime that registers both, and the second `JS_NewClass` is rejected. The first sight of a class in a runtime also moves that runtime's own counter past the shared ids.
pub fn JS_NewClassID(rt: ?*qjs.JSRuntime, pclass_id: *qjs.JSClassID) qjs.JSClassID {
    class_id_mutex.lock();
    defer class_id_mutex.unlock();
    if (pclass_id.* == 0) {
        if (class_id_next == 0) {
            _ = jsbay_qjs_JS_NewClassID(rt, pclass_id);
        } else {
            pclass_id.* = class_id_next;
        }
        class_id_next = pclass_id.* + 1;
    }
    if (jsbay_qjs_JS_IsRegisteredClass(rt, pclass_id.*) == 0) {
        var probe: qjs.JSClassID = 0;
        while (jsbay_qjs_JS_NewClassID(rt, &probe) < class_id_next) probe = 0;
    }
    return pclass_id.*;
}
pub extern fn jsbay_qjs_JS_IsPromise(ctx: ?*qjs.JSContext, val: qjs.JSValue) c_int;
pub extern fn jsbay_qjs_JS_NewSymbol(ctx: ?*qjs.JSContext, description: [*:0]const u8, is_global: c_int) qjs.JSValue;
pub extern fn jsbay_qjs_JS_GetPropertyValue(ctx: ?*qjs.JSContext, obj: qjs.JSValue, key: qjs.JSValue) qjs.JSValue;
pub extern fn jsbay_qjs_JS_SetPropertyValue(ctx: ?*qjs.JSContext, obj: qjs.JSValue, key: qjs.JSValue, val: qjs.JSValue, flags: c_int) c_int;
pub extern fn JS_NewBigInt64(ctx: ?*qjs.JSContext, v: i64) qjs.JSValue;
pub extern fn JS_NewBigUint64(ctx: ?*qjs.JSContext, v: u64) qjs.JSValue;
pub extern fn JS_ToBigInt64(ctx: ?*qjs.JSContext, pres: *i64, val: qjs.JSValue) c_int;
pub extern fn jsbay_qjs_JS_ToBigUint64(ctx: ?*qjs.JSContext, pres: *u64, val: qjs.JSValue) c_int;
pub const JS_ToBigUint64 = jsbay_qjs_JS_ToBigUint64;
pub extern fn JS_IsInstanceOf(ctx: ?*qjs.JSContext, val: qjs.JSValue, obj: qjs.JSValue) c_int;

// ---- Sentinel JSValue constants ----
// Manually define JS value constants since @cImport's zeroInit can't handle the union member.
pub fn mkval(tag: i64) qjs.JSValue {
    const u: qjs.JSValueUnion = .{ .int32 = 0 };
    return .{ .u = u, .tag = tag };
}
pub const JS_UNDEFINED = mkval(qjs.JS_TAG_UNDEFINED);
pub const JS_NULL = mkval(qjs.JS_TAG_NULL);
pub const JS_EXCEPTION = mkval(qjs.JS_TAG_EXCEPTION);

// ---- Tag-only predicates ----
// These do not call into QuickJS — they only inspect the JSValue tag — so we keep them on the C-API floor where every other submodule can grab them without acquiring a back-edge to QuickJsBackend.

pub fn jsIsException(val: qjs.JSValue) bool {
    return val.tag == qjs.JS_TAG_EXCEPTION;
}

pub fn jsIsUndefined(val: qjs.JSValue) bool {
    return val.tag == qjs.JS_TAG_UNDEFINED;
}

pub fn jsIsNull(val: qjs.JSValue) bool {
    return val.tag == qjs.JS_TAG_NULL;
}

pub fn jsIsObject(val: qjs.JSValue) bool {
    return val.tag == qjs.JS_TAG_OBJECT;
}
