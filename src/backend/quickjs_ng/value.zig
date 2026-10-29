//! Uniform value methods exposed by `QuickJsBackend` (the parent struct forwards each declaration explicitly via `pub const foo = value_mixin.foo;`).
//!
//! Two layers live here:
//! 1. Type predicates / extractors / creators used by `value.zig`'s cross-backend abstraction (isUndefined / toInt32 / newStringVal / ...).
//! 2. ArrayBuffer / TypedArray helpers that wrap the QJS C-API extern surface declared in `c_api.zig`.
//!
//! The `Date / BigInt / Map / Set / DataView` dispatch shims that forward to file-level qjsXxx helpers also live here for the same reason.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

const exception = @import("exception.zig");
const datetime = @import("datetime.zig");
const collections = @import("collections.zig");
const dataview = @import("dataview.zig");
const lifecycle = @import("lifecycle.zig");

// File-private aliases so the function signatures stay tidy; `pub` would collide with `QuickJsBackend.Value` / `Context` once these declarations are forwarded from the struct.
const Value = qjs.JSValue;
const Context = ?*qjs.JSContext;

// ---- Sentinel value getters ----

pub fn undefinedValue() Value {
    return c.JS_UNDEFINED;
}

pub fn nullValue() Value {
    return c.JS_NULL;
}

pub fn dupValue(ctx: Context, val: Value) Value {
    return c.jsbay_qjs_JS_DupValue(ctx, val);
}

pub fn freeValue(ctx: Context, val: Value) void {
    c.jsbay_qjs_JS_FreeValue(ctx, val);
}

pub fn isFunction(ctx: Context, val: Value) bool {
    return c.jsbay_qjs_JS_IsFunction(ctx, val) != 0;
}

// ---- Type predicates ----
pub fn isUndefined(_: Context, val: Value) bool {
    return val.tag == qjs.JS_TAG_UNDEFINED;
}

pub fn isNull(_: Context, val: Value) bool {
    return val.tag == qjs.JS_TAG_NULL;
}

pub fn isBool(_: Context, val: Value) bool {
    return c.jsbay_qjs_JS_IsBool(val) != 0;
}

pub fn isNumber(_: Context, val: Value) bool {
    return c.jsbay_qjs_JS_IsNumber(val) != 0;
}

pub fn isString(_: Context, val: Value) bool {
    return c.jsbay_qjs_JS_IsString(val) != 0;
}

pub fn isSymbol(_: Context, val: Value) bool {
    return c.jsbay_qjs_JS_IsSymbol(val) != 0;
}

pub fn isObjectVal(_: Context, val: Value) bool {
    return c.jsbay_qjs_JS_IsObject(val) != 0;
}

pub fn isArray(ctx: Context, val: Value) bool {
    _ = ctx;
    return qjs.JS_IsArray(val);
}

// ---- Type extraction ----
pub fn toBool(ctx: Context, val: Value) ?bool {
    const r = qjs.JS_ToBool(ctx, val);
    if (r < 0) return null;
    return r != 0;
}

pub fn toInt32(ctx: Context, val: Value) ?i32 {
    var result: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &result, val) != 0) return null;
    return result;
}

pub fn toFloat64(ctx: Context, val: Value) ?f64 {
    var result: f64 = 0;
    if (qjs.JS_ToFloat64(ctx, &result, val) != 0) return null;
    return result;
}

// ---- Value creation ----
pub fn newBoolVal(ctx: Context, val: bool) Value {
    return c.jsbay_qjs_JS_NewBool(ctx, if (val) 1 else 0);
}

pub fn newInt32Val(ctx: Context, val: i32) Value {
    return c.jsbay_qjs_JS_NewInt32(ctx, val);
}

pub fn newFloat64Val(ctx: Context, val: f64) Value {
    return c.jsbay_qjs_JS_NewFloat64(ctx, val);
}

pub fn newStringVal(ctx: Context, str: []const u8) Value {
    // Length is part of the API, so an embedded 0x00 is payload. A zero length returns the empty string without reading the pointer.
    return qjs.JS_NewStringLen(ctx, str.ptr, str.len);
}

pub fn newNullVal(_: Context) Value {
    return c.JS_NULL;
}

pub fn newUndefinedVal(_: Context) Value {
    return c.JS_UNDEFINED;
}

// ---- Property access ----
pub fn getPropertyVal(ctx: Context, obj: Value, key: [*:0]const u8) ?Value {
    const val = qjs.JS_GetPropertyStr(ctx, obj, key);
    if (c.jsIsException(val)) {
        c.jsbay_qjs_JS_FreeValue(ctx, val);
        return null;
    }
    if (c.jsIsUndefined(val)) {
        return null;
    }
    return val;
}

pub fn hasProperty(ctx: Context, obj: Value, key: [*:0]const u8) bool {
    const val = qjs.JS_GetPropertyStr(ctx, obj, key);
    if (c.jsIsException(val)) {
        c.jsbay_qjs_JS_FreeValue(ctx, val);
        return false;
    }
    const has = !c.jsIsUndefined(val);
    c.jsbay_qjs_JS_FreeValue(ctx, val);
    return has;
}

// ---- Array access ----
pub fn getIndex(ctx: Context, arr: Value, idx: u32) ?Value {
    const val = qjs.JS_GetPropertyUint32(ctx, arr, idx);
    if (c.jsIsException(val)) {
        c.jsbay_qjs_JS_FreeValue(ctx, val);
        return null;
    }
    if (c.jsIsUndefined(val)) {
        return null;
    }
    return val;
}

pub fn getLength(ctx: Context, obj: Value) ?u32 {
    const len_val = qjs.JS_GetPropertyStr(ctx, obj, "length");
    if (c.jsIsException(len_val) or c.jsIsUndefined(len_val)) {
        c.jsbay_qjs_JS_FreeValue(ctx, len_val);
        return null;
    }
    var result: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &result, len_val) != 0) {
        c.jsbay_qjs_JS_FreeValue(ctx, len_val);
        return null;
    }
    c.jsbay_qjs_JS_FreeValue(ctx, len_val);
    if (result < 0) return null;
    return @intCast(result);
}

// ---- Function call ----
pub fn callFunction(ctx: Context, func: Value, this: Value, args: []const Value) ?Value {
    // Anchor the stack limit if this is the outermost entry (e.g. a host dispatch/tsfn call). A refusal (concurrent cross-thread entry) must NOT touch ctx: another thread is currently using this runtime. Return null; the caller is responsible for serializing access (this is diagnostic).
    if (!lifecycle.enterJs(ctx)) return null;
    defer lifecycle.leaveJs(ctx);
    lifecycle.syncStackTopForJs(ctx);
    const result = qjs.JS_Call(ctx, func, this, @intCast(args.len), @constCast(args.ptr));
    if (c.jsIsException(result)) {
        c.jsbay_qjs_JS_FreeValue(ctx, result);
        return null;
    }
    return result;
}

// ---- JSON ----
pub fn jsonParseVal(ctx: Context, json: []const u8) ?Value {
    // QuickJS JSON lexer reads one byte past buf_len (see qjsNewMapFromJson for the full rationale). Defensively NUL-terminate.
    const buf = std.heap.c_allocator.dupeSentinel(u8, json, 0) catch return null;
    defer std.heap.c_allocator.free(buf);
    const result = qjs.JS_ParseJSON(ctx, buf.ptr, buf.len, "<native>");
    if (c.jsIsException(result)) {
        c.jsbay_qjs_JS_FreeValue(ctx, result);
        // ParseJSON sets a pending exception that we're swallowing.
        const pending = qjs.JS_GetException(ctx);
        if (!c.jsIsNull(pending)) c.jsbay_qjs_JS_FreeValue(ctx, pending);
        return null;
    }
    return result;
}

pub fn jsonStringifyVal(ctx: Context, val: Value) ?[]const u8 {
    return exception.jsonStringify(ctx, val);
}

pub fn valueToStringAlloc(allocator: std.mem.Allocator, ctx: Context, val: Value) ?[]u8 {
    return exception.valueToStringAlloc(allocator, ctx, val);
}

pub fn valueToStringVal(ctx: Context, val: Value) ?[]const u8 {
    return valueToStringAlloc(std.heap.c_allocator, ctx, val);
}

// ---- ArrayBuffer / TypedArray (used by value.zig) ----

pub fn isArrayBufferVal(ctx: Context, val: Value) bool {
    return c.JS_IsArrayBuffer(ctx, val);
}

pub fn isTypedArrayVal(ctx: Context, val: Value) bool {
    return c.JS_GetTypedArrayType(ctx, val) >= 0;
}

/// Return the byte slice of an ArrayBuffer (not a TypedArray). Returns null if the value is not an ArrayBuffer. The pointer is valid until the ArrayBuffer is detached or freed.
pub fn getArrayBufferSliceVal(ctx: Context, val: Value) ?[]u8 {
    if (!c.JS_IsArrayBuffer(ctx, val)) return null;
    var size: usize = 0;
    const ptr = c.JS_GetArrayBuffer(ctx, &size, val);
    if (ptr == null) return null;
    if (size == 0) return ptr[0..0];
    return ptr[0..size];
}

/// For a TypedArray, return the underlying bytes (byte_offset..byte_length) into its backing ArrayBuffer as a slice. Returns null if not a TypedArray.
pub fn getTypedArrayBytesVal(ctx: Context, val: Value) ?struct { bytes: []u8, element_size: usize, kind: c_int } {
    const kind = c.JS_GetTypedArrayType(ctx, val);
    if (kind < 0) return null;
    var offset: usize = 0;
    var byte_len: usize = 0;
    var bpe: usize = 0;
    const ab = c.JS_GetTypedArrayBuffer(ctx, val, &offset, &byte_len, &bpe);
    if (c.jsIsException(ab)) {
        c.jsbay_qjs_JS_FreeValue(ctx, ab);
        return null;
    }
    defer c.jsbay_qjs_JS_FreeValue(ctx, ab);
    var size: usize = 0;
    const base = c.JS_GetArrayBuffer(ctx, &size, ab);
    if (base == null) return null;
    if (offset + byte_len > size) return null;
    return .{ .bytes = base[offset .. offset + byte_len], .element_size = bpe, .kind = kind };
}

/// Create a new ArrayBuffer by copying `data` into JS-owned memory.
pub fn newArrayBufferCopyVal(ctx: Context, data: []const u8) Value {
    return c.JS_NewArrayBufferCopy(ctx, data.ptr, data.len);
}

/// Create a fixed ArrayBuffer that views external memory. `realloc_func` is called with size 0 when QuickJS releases the buffer.
pub fn newArrayBufferNoCopyVal(
    ctx: Context,
    data: []u8,
    realloc_func: ?*const c.JSReallocArrayBufferDataFunc,
    opaque_ptr: ?*anyopaque,
) Value {
    return c.JS_NewArrayBuffer(ctx, data.ptr, data.len, 0, realloc_func, opaque_ptr, false);
}

/// Create a TypedArray of the given kind wrapping `ab` (an ArrayBuffer). JS_NewTypedArray forwards to the `new TypedArray(buffer, byteOffset, length)` constructor which reads three arguments; we pass UNDEFINED for byteOffset/length so the view spans the whole buffer.
pub fn newTypedArrayFromBufferVal(ctx: Context, kind: c_int, ab: Value) Value {
    var argv = [_]qjs.JSValue{ ab, c.JS_UNDEFINED, c.JS_UNDEFINED };
    return c.JS_NewTypedArray(ctx, 3, &argv, kind);
}

// ---- Public exception predicates re-exposed on the backend struct ----
//
// Submodules use the C helpers directly. The backend struct forwards these predicates as part of its current interface.

pub fn jsIsException(val: qjs.JSValue) bool {
    return c.jsIsException(val);
}

pub fn jsIsUndefined(val: qjs.JSValue) bool {
    return c.jsIsUndefined(val);
}

pub fn jsIsNull(val: qjs.JSValue) bool {
    return c.jsIsNull(val);
}

pub fn jsIsObject(val: qjs.JSValue) bool {
    return c.jsIsObject(val);
}

pub fn getAndFormatException(ctx: Context) ?[]const u8 {
    return exception.getAndFormatException(ctx);
}

pub fn jsonStringify(ctx: Context, val: qjs.JSValue) ?[]const u8 {
    return exception.jsonStringify(ctx, val);
}

pub fn valueToString(ctx: Context, val: qjs.JSValue) ?[]const u8 {
    return exception.valueToString(ctx, val);
}

// ---- Date / BigInt / Map / Set / DataView dispatch shims ----
//
// These thin methods forward to the file-level qjsXxx helpers in the neighbouring submodules. Hoisting them onto the struct lets value.zig dispatch through `ActiveEngine.xxx(...)` instead of a per-call-site `switch` on the active backend tag.

pub fn isDate(ctx: Context, val: Value) bool {
    return datetime.qjsIsDate(ctx, val);
}

pub fn toDateMs(ctx: Context, val: Value) ?i64 {
    return datetime.qjsToDateMs(ctx, val);
}

pub fn newDate(ctx: Context, ms: i64) Value {
    return datetime.qjsNewDate(ctx, ms);
}

pub fn isBigInt(ctx: Context, val: Value) bool {
    return datetime.qjsIsBigInt(ctx, val);
}

pub fn toBigIntI64(ctx: Context, val: Value) ?i64 {
    return datetime.qjsToBigIntI64(ctx, val);
}

pub fn toBigIntU64(ctx: Context, val: Value) ?u64 {
    return datetime.qjsToBigIntU64(ctx, val);
}

pub fn newBigIntI64(ctx: Context, v: i64) Value {
    return datetime.qjsNewBigIntI64(ctx, v);
}

pub fn newBigIntU64(ctx: Context, v: u64) Value {
    return datetime.qjsNewBigIntU64(ctx, v);
}

pub fn isMap(ctx: Context, val: Value) bool {
    return collections.qjsIsMap(ctx, val);
}

pub fn isSet(ctx: Context, val: Value) bool {
    return collections.qjsIsSet(ctx, val);
}

pub fn mapSetToJson(ctx: Context, val: Value) ?[]const u8 {
    return collections.qjsMapSetToJson(ctx, val);
}

pub fn newMapFromJson(ctx: Context, json: []const u8) Value {
    return collections.qjsNewMapFromJson(ctx, json);
}

pub fn newSetFromJson(ctx: Context, json: []const u8) Value {
    return collections.qjsNewSetFromJson(ctx, json);
}

pub fn mapSize(ctx: Context, val: Value) ?usize {
    return collections.qjsMapSize(ctx, val);
}

pub fn setSize(ctx: Context, val: Value) ?usize {
    return collections.qjsSetSize(ctx, val);
}

pub fn newMap(ctx: Context) Value {
    return collections.qjsNewMap(ctx);
}

pub fn newSet(ctx: Context) Value {
    return collections.qjsNewSet(ctx);
}

pub fn mapSet(ctx: Context, map: Value, key: Value, value: Value) bool {
    return collections.qjsMapSet(ctx, map, key, value);
}

pub fn setAdd(ctx: Context, set: Value, value: Value) bool {
    return collections.qjsSetAdd(ctx, set, value);
}

pub fn isDataView(ctx: Context, val: Value) bool {
    return dataview.qjsIsDataView(ctx, val);
}

pub const BackendDataViewInfo = struct {
    bytes: []u8,
    byte_offset: usize,
    byte_length: usize,
};

pub fn dataViewInfo(ctx: Context, val: Value) ?BackendDataViewInfo {
    const info = dataview.qjsDataViewInfo(ctx, val) orelse return null;
    return .{
        .bytes = info.bytes,
        .byte_offset = info.byte_offset,
        .byte_length = info.byte_length,
    };
}

pub fn newDataViewFromBuffer(
    ctx: Context,
    ab: Value,
    byte_offset: usize,
    byte_length: usize,
) Value {
    return dataview.qjsNewDataView(ctx, ab, byte_offset, byte_length);
}

// ---- Map/Set iteration shims ----

pub const MapForEachFn = fn (
    ctx: Context,
    cb_ctx: ?*anyopaque,
    key: Value,
    value: Value,
) callconv(.c) bool;

pub const SetForEachFn = fn (
    ctx: Context,
    cb_ctx: ?*anyopaque,
    value: Value,
) callconv(.c) bool;

pub fn mapForEach(
    ctx: Context,
    val: Value,
    cb_ctx: ?*anyopaque,
    cb: *const MapForEachFn,
) bool {
    // MapForEachFn and QjsMapForEachFn have identical ABI shape; bitcast so callers can use the struct-local signature.
    const inner: *const collections.QjsMapForEachFn = @ptrCast(cb);
    return collections.qjsMapForEach(ctx, val, cb_ctx, inner);
}

pub fn setForEach(
    ctx: Context,
    val: Value,
    cb_ctx: ?*anyopaque,
    cb: *const SetForEachFn,
) bool {
    const inner: *const collections.QjsSetForEachFn = @ptrCast(cb);
    return collections.qjsSetForEach(ctx, val, cb_ctx, inner);
}

fn dropPending(ctx: Context) void {
    const pending = qjs.JS_GetException(ctx);
    c.jsbay_qjs_JS_FreeValue(ctx, pending);
}

/// ES IsConstructor. Reads the function's constructor bit; does not call it.
pub fn isConstructor(ctx: Context, val: Value) bool {
    return qjs.JS_IsConstructor(ctx, val);
}

pub fn sameValue(ctx: Context, a: Value, b: Value) bool {
    return qjs.JS_IsSameValue(ctx, a, b);
}

/// `new Array(len)`. Index holes stay absent and read back as `undefined`. Caller owns the returned value. Null on exception.
pub fn newArray(ctx: Context, len: u32) ?Value {
    const arr = qjs.JS_NewArray(ctx);
    if (c.jsIsException(arr)) {
        c.jsbay_qjs_JS_FreeValue(ctx, arr);
        dropPending(ctx);
        return null;
    }
    if (len != 0) {
        // JS_NewArray is a native primitive; setting `length` keeps the slots as holes without consulting the user-mutable global Array.
        const length = c.jsbay_qjs_JS_NewFloat64(ctx, @floatFromInt(len));
        if (qjs.JS_SetPropertyStr(ctx, arr, "length", length) < 0) {
            c.jsbay_qjs_JS_FreeValue(ctx, arr);
            dropPending(ctx);
            return null;
        }
    }
    return arr;
}

/// Own element, or `undefined` for a hole. Never collapses a hole to `null`. Caller owns the returned value. Null only when the get throws.
pub fn arrayGet(ctx: Context, arr: Value, index: u32) ?Value {
    const val = qjs.JS_GetPropertyUint32(ctx, arr, index);
    if (c.jsIsException(val)) {
        c.jsbay_qjs_JS_FreeValue(ctx, val);
        dropPending(ctx);
        return null;
    }
    return val;
}

/// Set `arr[index] = val`. Does not consume `val`.
pub fn arraySet(ctx: Context, arr: Value, index: u32, val: Value) bool {
    const duped = c.jsbay_qjs_JS_DupValue(ctx, val);
    const rc = qjs.JS_SetPropertyUint32(ctx, arr, index, duped);
    if (rc < 0) {
        dropPending(ctx);
        return false;
    }
    return true;
}

/// `arr.length = 0`, which drops every element.
pub fn arrayClear(ctx: Context, arr: Value) bool {
    const n = c.jsbay_qjs_JS_NewInt32(ctx, 0);
    const rc = qjs.JS_SetPropertyStr(ctx, arr, "length", n);
    if (rc < 0) {
        dropPending(ctx);
        return false;
    }
    return true;
}

/// Data descriptor `{ value, writable, enumerable: true, configurable: true }`. `writable == false` is a real [[Writable]] false, not a getter-only accessor. Does not consume `val`.
pub fn defineDataProperty(ctx: Context, obj: Value, key: [*:0]const u8, val: Value, writable: bool) bool {
    const base = qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE;
    const flags = if (writable) base | qjs.JS_PROP_WRITABLE else base;
    const duped = c.jsbay_qjs_JS_DupValue(ctx, val);
    const rc = qjs.JS_DefinePropertyValueStr(ctx, obj, key, duped, flags);
    if (rc < 0) {
        dropPending(ctx);
        return false;
    }
    return rc > 0;
}
