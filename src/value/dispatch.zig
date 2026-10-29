//! Backend-neutral dispatch helpers wrapping the Date / BigInt / Map / Set / DataView / TypedArray surfaces declared on each backend struct.
//!
//! These give NativeArgs + NativeResult a uniform call site without adding methods to the backend structs. They are organised by concern (predicates, getters, builders, native iteration).

const std = @import("std");
const backend = @import("../backend.zig");
const types = @import("types.zig");

const ActiveEngine = backend.ActiveEngine;

const TypedArrayKind = types.TypedArrayKind;
const ArrayBufferPayload = types.ArrayBufferPayload;

/// Create a JS TypedArray of the given kind, copying `bytes` into a fresh JS-owned ArrayBuffer. Backend-specific under the hood.
pub fn newTypedArrayFromBytes(ctx: ActiveEngine.Context, kind: TypedArrayKind, bytes: []const u8) ActiveEngine.Value {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = backend.ActiveEngineModule;
            const code: c_int = switch (kind) {
                .uint8 => qjs_mod.QJS_TYPED_ARRAY_UINT8,
                .int8 => qjs_mod.QJS_TYPED_ARRAY_INT8,
                .int16 => qjs_mod.QJS_TYPED_ARRAY_INT16,
                .uint16 => qjs_mod.QJS_TYPED_ARRAY_UINT16,
                .int32 => qjs_mod.QJS_TYPED_ARRAY_INT32,
                .uint32 => qjs_mod.QJS_TYPED_ARRAY_UINT32,
                .big_int64 => qjs_mod.QJS_TYPED_ARRAY_BIG_INT64,
                .big_uint64 => qjs_mod.QJS_TYPED_ARRAY_BIG_UINT64,
                .float32 => qjs_mod.QJS_TYPED_ARRAY_FLOAT32,
                .float64 => qjs_mod.QJS_TYPED_ARRAY_FLOAT64,
            };
            const ab = ActiveEngine.newArrayBufferCopyVal(ctx, bytes);
            defer ActiveEngine.freeValue(ctx, ab);
            return ActiveEngine.newTypedArrayFromBufferVal(ctx, code, ab);
        },
        .jsc => {
            const jsc_mod = backend.EngineModule(.jsc);
            const code: c_int = switch (kind) {
                .uint8 => jsc_mod.JSC_TA_UINT8,
                .int8 => jsc_mod.JSC_TA_INT8,
                .int16 => jsc_mod.JSC_TA_INT16,
                .uint16 => jsc_mod.JSC_TA_UINT16,
                .int32 => jsc_mod.JSC_TA_INT32,
                .uint32 => jsc_mod.JSC_TA_UINT32,
                .big_int64 => jsc_mod.JSC_TA_BIG_INT64,
                .big_uint64 => jsc_mod.JSC_TA_BIG_UINT64,
                .float32 => jsc_mod.JSC_TA_FLOAT32,
                .float64 => jsc_mod.JSC_TA_FLOAT64,
            };
            const ab = ActiveEngine.newArrayBufferCopyVal(ctx, bytes);
            defer ActiveEngine.freeValue(ctx, ab);
            return ActiveEngine.newTypedArrayFromBufferVal(ctx, code, ab);
        },
    }
}

// ---- Date / BigInt / Map / Set dispatch helpers ----
//
// These wrap the backend-specific implementations declared at the end of src/backend/quickjs.zig and src/backend/jsc.zig. They give NativeArgs + NativeResult a uniform surface without adding methods to the backend structs.

pub fn isDateVal(ctx: ActiveEngine.Context, val: ActiveEngine.Value) bool {
    return ActiveEngine.isDate(ctx, val);
}

pub fn toDateMsVal(ctx: ActiveEngine.Context, val: ActiveEngine.Value) ?i64 {
    return ActiveEngine.toDateMs(ctx, val);
}

pub fn newDateVal(ctx: ActiveEngine.Context, ms: i64) ActiveEngine.Value {
    return ActiveEngine.newDate(ctx, ms);
}

pub fn isBigIntVal(ctx: ActiveEngine.Context, val: ActiveEngine.Value) bool {
    return ActiveEngine.isBigInt(ctx, val);
}

pub fn toBigIntI64Val(ctx: ActiveEngine.Context, val: ActiveEngine.Value) ?i64 {
    return ActiveEngine.toBigIntI64(ctx, val);
}

pub fn toBigIntU64Val(ctx: ActiveEngine.Context, val: ActiveEngine.Value) ?u64 {
    return ActiveEngine.toBigIntU64(ctx, val);
}

pub fn newBigIntI64Val(ctx: ActiveEngine.Context, v: i64) ActiveEngine.Value {
    return ActiveEngine.newBigIntI64(ctx, v);
}

pub fn newBigIntU64Val(ctx: ActiveEngine.Context, v: u64) ActiveEngine.Value {
    return ActiveEngine.newBigIntU64(ctx, v);
}

pub fn isMapVal(ctx: ActiveEngine.Context, val: ActiveEngine.Value) bool {
    return ActiveEngine.isMap(ctx, val);
}

pub fn isSetVal(ctx: ActiveEngine.Context, val: ActiveEngine.Value) bool {
    return ActiveEngine.isSet(ctx, val);
}

pub fn mapSetToJsonVal(ctx: ActiveEngine.Context, val: ActiveEngine.Value) ?[]const u8 {
    return ActiveEngine.mapSetToJson(ctx, val);
}

pub fn newMapFromJsonVal(ctx: ActiveEngine.Context, json: []const u8) ActiveEngine.Value {
    return ActiveEngine.newMapFromJson(ctx, json);
}

pub fn newSetFromJsonVal(ctx: ActiveEngine.Context, json: []const u8) ActiveEngine.Value {
    return ActiveEngine.newSetFromJson(ctx, json);
}

// ---- Native iteration + builder API for Map / Set ----
//
// These expose backend-neutral helpers for traversing a Map/Set entry-by-entry and for building a fresh Map/Set from native code. Unlike the JSON fast path (`mapToJson` / `setToJson` / `newMap{Set}FromJson`) they preserve full value fidelity — functions, objects, Dates, cyclic graphs, etc. all survive.
//
// Callback protocol: the driver calls `cb(ctx, cb_ctx, ...)` once per entry. Returning `false` stops iteration cleanly; returning `true` keeps going. Callback arguments are *borrowed* backend Values that only live for the duration of the call. To keep one past the callback, dup it via `ActiveEngine.dupValue` and free with `ActiveEngine.freeValue` later.
//
// Limitations:
// - WeakMap / WeakSet are NOT iterable per ECMAScript spec; `isMap`/`isSet` only match the strong Map/Set constructors, so Weak variants fall out naturally.
// - Iteration constructs a fresh iterator every call (via `val.entries()` / `val.values()`); there's no cached Iter state. Cost is one JS call + N next() calls per traversal.

/// Callback signature for `NativeArgs.mapForEach` / `mapForEachVal`. The `callconv(.c)` marker lets the backend-neutral dispatch trampoline forward directly into the per-backend `*.zig` iterator drivers without an extra thunk.
pub const MapForEachFn = fn (
    ctx: ActiveEngine.Context,
    cb_ctx: ?*anyopaque,
    key: ActiveEngine.Value,
    value: ActiveEngine.Value,
) callconv(.c) bool;

/// Callback signature for `NativeArgs.setForEach` / `setForEachVal`.
pub const SetForEachFn = fn (
    ctx: ActiveEngine.Context,
    cb_ctx: ?*anyopaque,
    value: ActiveEngine.Value,
) callconv(.c) bool;

pub fn mapForEachVal(
    ctx: ActiveEngine.Context,
    val: ActiveEngine.Value,
    cb_ctx: ?*anyopaque,
    cb: *const MapForEachFn,
) bool {
    // MapForEachFn (backend-neutral) and ActiveEngine.MapForEachFn share the same ABI shape once Context/Value are resolved — the backend struct's `mapForEach` does the final bitcast internally.
    const inner: *const ActiveEngine.MapForEachFn = @ptrCast(cb);
    return ActiveEngine.mapForEach(ctx, val, cb_ctx, inner);
}

pub fn setForEachVal(
    ctx: ActiveEngine.Context,
    val: ActiveEngine.Value,
    cb_ctx: ?*anyopaque,
    cb: *const SetForEachFn,
) bool {
    const inner: *const ActiveEngine.SetForEachFn = @ptrCast(cb);
    return ActiveEngine.setForEach(ctx, val, cb_ctx, inner);
}

pub fn mapSizeVal(ctx: ActiveEngine.Context, val: ActiveEngine.Value) ?usize {
    return ActiveEngine.mapSize(ctx, val);
}

pub fn setSizeVal(ctx: ActiveEngine.Context, val: ActiveEngine.Value) ?usize {
    return ActiveEngine.setSize(ctx, val);
}

/// Allocate a fresh empty `new Map()`. Engine takes ownership of the value; if you return it through NativeResult.value, do NOT free it yourself. If you use it transiently, free with `ActiveEngine.freeValue`.
pub fn newMap(ctx: ActiveEngine.Context) ActiveEngine.Value {
    return ActiveEngine.newMap(ctx);
}

/// Allocate a fresh empty `new Set()`. See `newMap` for ownership notes.
pub fn newSet(ctx: ActiveEngine.Context) ActiveEngine.Value {
    return ActiveEngine.newSet(ctx);
}

/// Call `map.set(key, value)`. The Map takes its own retention; the caller retains ownership of the `key` and `value` Values it passed in. Returns true on success, false if `map` rejected the call.
pub fn mapSet(ctx: ActiveEngine.Context, map: ActiveEngine.Value, key: ActiveEngine.Value, value: ActiveEngine.Value) bool {
    return ActiveEngine.mapSet(ctx, map, key, value);
}

/// Call `set.add(value)`. Same ownership semantics as `mapSet`.
pub fn setAdd(ctx: ActiveEngine.Context, set: ActiveEngine.Value, value: ActiveEngine.Value) bool {
    return ActiveEngine.setAdd(ctx, set, value);
}

/// Create a TypedArray from a typed slice (`[]const T`). Convenience wrapper around `newTypedArrayFromBytes` that infers the kind from `T`.
pub fn newTypedArray(ctx: ActiveEngine.Context, comptime T: type, elements: []const T) ActiveEngine.Value {
    const kind: TypedArrayKind = switch (T) {
        u8 => .uint8,
        i8 => .int8,
        i16 => .int16,
        u16 => .uint16,
        i32 => .int32,
        u32 => .uint32,
        f32 => .float32,
        f64 => .float64,
        i64 => .big_int64,
        u64 => .big_uint64,
        else => @compileError("newTypedArray: unsupported element type " ++ @typeName(T)),
    };
    const byte_ptr: [*]const u8 = @ptrCast(elements.ptr);
    return newTypedArrayFromBytes(ctx, kind, byte_ptr[0 .. elements.len * @sizeOf(T)]);
}

/// Create a JS DataView that views `buffer.bytes` with the given offset and length. `buffer.bytes` is copied into a fresh JS ArrayBuffer, then wrapped with `new DataView(ab, byte_offset, byte_length)`.
pub fn newDataView(
    ctx: ActiveEngine.Context,
    buffer: ArrayBufferPayload,
    byte_offset: usize,
    byte_length: usize,
) ActiveEngine.Value {
    const ab = ActiveEngine.newArrayBufferCopyVal(ctx, buffer.bytes);
    // ab ownership passes into the DataView. We free our local handle; the DataView retains a separate reference to the buffer internally.
    defer ActiveEngine.freeValue(ctx, ab);
    return newDataViewFromBufferVal(ctx, ab, byte_offset, byte_length);
}

fn newDataViewFromBufferVal(
    ctx: ActiveEngine.Context,
    ab: ActiveEngine.Value,
    byte_offset: usize,
    byte_length: usize,
) ActiveEngine.Value {
    return ActiveEngine.newDataViewFromBuffer(ctx, ab, byte_offset, byte_length);
}

// ---- DataView dispatch helpers ----

pub fn isDataViewVal(ctx: ActiveEngine.Context, val: ActiveEngine.Value) bool {
    return ActiveEngine.isDataView(ctx, val);
}

pub const DataViewInfo = struct {
    bytes: []u8,
    byte_offset: usize,
    byte_length: usize,
};

pub fn dataViewInfoVal(ctx: ActiveEngine.Context, val: ActiveEngine.Value) ?DataViewInfo {
    const info = ActiveEngine.dataViewInfo(ctx, val) orelse return null;
    return .{ .bytes = info.bytes, .byte_offset = info.byte_offset, .byte_length = info.byte_length };
}

/// Host strict equality for two values on `instance_id`.
///
/// JavaScript `===`: `NaN` is not equal to `NaN`, `+0` equals `-0`, `true` is not `1`, equal string contents match, and two distinct objects do not. QuickJS uses `JS_IsStrictEqual`; JSC uses `JSValueIsStrictEqual`. Returns false when the instance is gone.
pub fn strictEquals(instance_id: i32, a: ActiveEngine.Value, b: ActiveEngine.Value) bool {
    const engine = @import("../engine.zig");
    const ctx = engine.getContext(instance_id) orelse return false;
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.weak.jsbay_qjsStrictEqual(ctx, a, b),
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const ctx_ref: jsc_mod.jsc.JSContextRef = @ptrCast(ctx);
            return @import("../backend/jsc/weak.zig").jsbay_qjsStrictEqual(ctx_ref, a, b);
        },
    };
}

fn contextOf(instance_id: i32) ?ActiveEngine.Context {
    return @import("../engine.zig").getContext(instance_id);
}

/// ES IsConstructor. `class` and ordinary `function` are true. `Math`, `Reflect`, ordinary objects, generators, async functions, and arrows are false. Both backends read the engine's constructor bit; neither tries `new` and catches.
pub fn isConstructor(instance_id: i32, v: ActiveEngine.Value) bool {
    const ctx = contextOf(instance_id) orelse return false;
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.value.isConstructor(ctx, v),
        .jsc => @import("../backend/jsc/value.zig").isConstructor(ctx, v),
    };
}

/// `new Array(len)`. Caller frees the array. Null when the instance is gone or the constructor throws.
pub fn newArray(instance_id: i32, len: u32) ?ActiveEngine.Value {
    const ctx = contextOf(instance_id) orelse return null;
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.value.newArray(ctx, len),
        .jsc => @import("../backend/jsc/value.zig").newArray(ctx, len),
    };
}

/// Element at `index`, or JS `undefined` for a hole. Null only on failure. Caller frees the value, including `undefined`.
pub fn arrayGet(instance_id: i32, arr: ActiveEngine.Value, index: u32) ?ActiveEngine.Value {
    const ctx = contextOf(instance_id) orelse return null;
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.value.arrayGet(ctx, arr, index),
        .jsc => @import("../backend/jsc/value.zig").arrayGet(ctx, arr, index),
    };
}

/// `arr[index] = val`. Does not consume `val`.
pub fn arraySet(instance_id: i32, arr: ActiveEngine.Value, index: u32, val: ActiveEngine.Value) bool {
    const ctx = contextOf(instance_id) orelse return false;
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.value.arraySet(ctx, arr, index, val),
        .jsc => @import("../backend/jsc/value.zig").arraySet(ctx, arr, index, val),
    };
}

/// `arr.length`, or null when it cannot be read.
pub fn arrayLength(instance_id: i32, arr: ActiveEngine.Value) ?u32 {
    const ctx = contextOf(instance_id) orelse return null;
    return ActiveEngine.getLength(ctx, arr);
}

/// Set `length` to 0.
pub fn arrayClear(instance_id: i32, arr: ActiveEngine.Value) bool {
    const ctx = contextOf(instance_id) orelse return false;
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.value.arrayClear(ctx, arr),
        .jsc => @import("../backend/jsc/value.zig").arrayClear(ctx, arr),
    };
}

/// Data property `key` with `val` and the given [[Writable]]. Enumerable and configurable. Does not consume `obj` or `val`. `writable == false` makes a strict-mode assignment throw; it is not a getter-only accessor.
pub fn defineDataProperty(
    instance_id: i32,
    obj: ActiveEngine.Value,
    key: [*:0]const u8,
    val: ActiveEngine.Value,
    writable: bool,
) bool {
    const ctx = contextOf(instance_id) orelse return false;
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.value.defineDataProperty(ctx, obj, key, val, writable),
        .jsc => @import("../backend/jsc/value.zig").defineDataProperty(ctx, obj, key, val, writable),
    };
}
