//! Unified argument accessor for native function callbacks.
//!
//! A NativeArgs is a borrowed view of the backend's argv array plus the handler's instance id and JS context. All `getXxxString` / `jsonStringify` / `mapToJson` methods return heap-allocated slices that the caller must release with `freeString`.

const std = @import("std");
const backend = @import("../backend.zig");
const types = @import("types.zig");
const dispatch = @import("dispatch.zig");

const ActiveEngine = backend.ActiveEngine;

const TypedArrayView = types.TypedArrayView;
const DataViewPayload = types.DataViewPayload;

/// Unified argument accessor for native function callbacks. All returned strings are heap-allocated via c_allocator and must be freed by the caller.
pub const NativeArgs = struct {
    instance_id: i32,
    _count: usize,
    _ctx: ActiveEngine.Context,
    // Store raw pointer + stride to access backend-specific values
    _argv_raw: *const anyopaque,
    /// Borrowed `this` for the duration of the callback. Do not free it and do not keep it after the handler returns.
    ///
    /// QuickJS passes `undefined` for a bare call (`fn()`). JSC's C callback is sloppy, so a bare call arrives as the global object. A method call (`obj.fn()`) is that object on both backends.
    _this: ActiveEngine.Value,

    pub fn count(self: NativeArgs) usize {
        return self._count;
    }

    /// Serialize argument at index to JSON string. Caller must free with freeString().
    pub fn jsonStringify(self: NativeArgs, idx: usize) ?[]const u8 {
        if (idx >= self._count) return null;
        const val = self.getVal(idx);
        return ActiveEngine.jsonStringifyVal(self._ctx, val);
    }

    /// Convert argument at index to string. Caller must free with freeString().
    pub fn toString(self: NativeArgs, idx: usize) ?[]const u8 {
        if (idx >= self._count) return null;
        const val = self.getVal(idx);
        return ActiveEngine.valueToStringVal(self._ctx, val);
    }

    // ---- Type predicates ----

    pub fn isUndefined(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return true;
        return ActiveEngine.isUndefined(self._ctx, self.getVal(idx));
    }

    pub fn isNull(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return ActiveEngine.isNull(self._ctx, self.getVal(idx));
    }

    pub fn isBool(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return ActiveEngine.isBool(self._ctx, self.getVal(idx));
    }

    pub fn isNumber(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return ActiveEngine.isNumber(self._ctx, self.getVal(idx));
    }

    pub fn isString(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return ActiveEngine.isString(self._ctx, self.getVal(idx));
    }

    pub fn isObject(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return ActiveEngine.isObjectVal(self._ctx, self.getVal(idx));
    }

    pub fn isArray(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return ActiveEngine.isArray(self._ctx, self.getVal(idx));
    }

    // ---- Direct extraction ----

    pub fn toBool(self: NativeArgs, idx: usize) ?bool {
        if (idx >= self._count) return null;
        const val = self.getVal(idx);
        if (!ActiveEngine.isBool(self._ctx, val)) return null;
        return ActiveEngine.toBool(self._ctx, val);
    }

    pub fn toInt32(self: NativeArgs, idx: usize) ?i32 {
        if (idx >= self._count) return null;
        const val = self.getVal(idx);
        if (!ActiveEngine.isNumber(self._ctx, val)) return null;
        return ActiveEngine.toInt32(self._ctx, val);
    }

    pub fn toFloat64(self: NativeArgs, idx: usize) ?f64 {
        if (idx >= self._count) return null;
        const val = self.getVal(idx);
        if (!ActiveEngine.isNumber(self._ctx, val)) return null;
        return ActiveEngine.toFloat64(self._ctx, val);
    }

    // ---- Object property shortcuts ----

    /// Get a string property from arg[idx]. Caller must free with freeString().
    pub fn getPropertyString(self: NativeArgs, idx: usize, key: [*:0]const u8) ?[]const u8 {
        if (idx >= self._count) return null;
        const prop = ActiveEngine.getPropertyVal(self._ctx, self.getVal(idx), key) orelse return null;
        defer ActiveEngine.freeValue(self._ctx, prop);
        return ActiveEngine.valueToStringVal(self._ctx, prop);
    }

    pub fn getPropertyNumber(self: NativeArgs, idx: usize, key: [*:0]const u8) ?f64 {
        if (idx >= self._count) return null;
        const prop = ActiveEngine.getPropertyVal(self._ctx, self.getVal(idx), key) orelse return null;
        defer ActiveEngine.freeValue(self._ctx, prop);
        return ActiveEngine.toFloat64(self._ctx, prop);
    }

    pub fn getPropertyBool(self: NativeArgs, idx: usize, key: [*:0]const u8) ?bool {
        if (idx >= self._count) return null;
        const prop = ActiveEngine.getPropertyVal(self._ctx, self.getVal(idx), key) orelse return null;
        defer ActiveEngine.freeValue(self._ctx, prop);
        return ActiveEngine.toBool(self._ctx, prop);
    }

    // ---- Array access ----

    pub fn getLength(self: NativeArgs, idx: usize) ?u32 {
        if (idx >= self._count) return null;
        return ActiveEngine.getLength(self._ctx, self.getVal(idx));
    }

    /// Get a string element from array arg[idx]. Caller must free with freeString().
    pub fn getElementString(self: NativeArgs, idx: usize, array_index: u32) ?[]const u8 {
        if (idx >= self._count) return null;
        const elem = ActiveEngine.getIndex(self._ctx, self.getVal(idx), array_index) orelse return null;
        defer ActiveEngine.freeValue(self._ctx, elem);
        return ActiveEngine.valueToStringVal(self._ctx, elem);
    }

    // ---- ArrayBuffer / TypedArray ----

    /// True when arg[idx] is an ArrayBuffer (not a TypedArray / DataView).
    pub fn isArrayBuffer(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return ActiveEngine.isArrayBufferVal(self._ctx, self.getVal(idx));
    }

    /// True when arg[idx] is any TypedArray (Uint8Array, Int32Array, ...).
    pub fn isTypedArray(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return ActiveEngine.isTypedArrayVal(self._ctx, self.getVal(idx));
    }

    /// Borrow the byte slice of arg[idx] (must be an ArrayBuffer). The returned slice is backed by JS-owned memory and is only valid until the handler returns or the ArrayBuffer is detached. Returns null if arg[idx] is not an ArrayBuffer.
    pub fn getArrayBufferBytes(self: NativeArgs, idx: usize) ?[]const u8 {
        if (idx >= self._count) return null;
        const slice = ActiveEngine.getArrayBufferSliceVal(self._ctx, self.getVal(idx)) orelse return null;
        return slice;
    }

    /// Get a TypedArrayView for arg[idx] (must be a TypedArray). The returned view borrows JS-owned memory; do not hold it past the handler return. Returns null for non-TypedArray values.
    pub fn getTypedArray(self: NativeArgs, idx: usize) ?TypedArrayView {
        if (idx >= self._count) return null;
        const info = ActiveEngine.getTypedArrayBytesVal(self._ctx, self.getVal(idx)) orelse return null;
        const kind = types.kindFromBackend(info.kind) orelse return null;
        return .{ .kind = kind, .bytes = info.bytes };
    }

    // ---- DataView ----

    /// True when arg[idx] is a DataView.
    pub fn isDataView(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return dispatch.isDataViewVal(self._ctx, self.getVal(idx));
    }

    /// Get a DataViewPayload for arg[idx] (must be a DataView). The returned payload borrows JS-owned memory; do not hold it past the handler return. Returns null for non-DataView values.
    pub fn getDataView(self: NativeArgs, idx: usize) ?DataViewPayload {
        if (idx >= self._count) return null;
        const val = self.getVal(idx);
        if (!dispatch.isDataViewVal(self._ctx, val)) return null;
        const info = dispatch.dataViewInfoVal(self._ctx, val) orelse return null;
        return .{
            .buffer = .{ .bytes = info.bytes },
            .byte_offset = info.byte_offset,
            .byte_length = info.byte_length,
            ._ctx = self._ctx,
        };
    }

    // ---- Date ----

    /// True when arg[idx] is a Date object.
    pub fn isDate(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return dispatch.isDateVal(self._ctx, self.getVal(idx));
    }

    /// Read arg[idx] as a Date. Returns the value of `getTime()` as i64 (milliseconds since epoch). Returns null if arg[idx] is not a Date.
    pub fn toDateMs(self: NativeArgs, idx: usize) ?i64 {
        if (idx >= self._count) return null;
        return dispatch.toDateMsVal(self._ctx, self.getVal(idx));
    }

    // ---- BigInt ----

    /// True when arg[idx] is a BigInt value.
    pub fn isBigInt(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return dispatch.isBigIntVal(self._ctx, self.getVal(idx));
    }

    /// Read arg[idx] as a signed 64-bit BigInt. Returns null if arg[idx] is not a BigInt or the value overflows i64.
    pub fn toBigIntI64(self: NativeArgs, idx: usize) ?i64 {
        if (idx >= self._count) return null;
        return dispatch.toBigIntI64Val(self._ctx, self.getVal(idx));
    }

    /// Read arg[idx] as an unsigned 64-bit BigInt. Use for values that may exceed i64::MAX. Returns null if arg[idx] is not a BigInt.
    pub fn toBigIntU64(self: NativeArgs, idx: usize) ?u64 {
        if (idx >= self._count) return null;
        return dispatch.toBigIntU64Val(self._ctx, self.getVal(idx));
    }

    // ---- Map / Set ----

    /// True when arg[idx] is a Map instance (checked via `instanceof Map`).
    pub fn isMap(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return dispatch.isMapVal(self._ctx, self.getVal(idx));
    }

    /// True when arg[idx] is a Set instance (checked via `instanceof Set`).
    pub fn isSet(self: NativeArgs, idx: usize) bool {
        if (idx >= self._count) return false;
        return dispatch.isSetVal(self._ctx, self.getVal(idx));
    }

    /// Serialize a Map arg as `JSON.stringify(Array.from(map))`, yielding `[[k,v],...]`. Caller must free with freeString(). Returns null on non-Map input or JSON failure.
    pub fn mapToJson(self: NativeArgs, idx: usize) ?[]const u8 {
        if (idx >= self._count) return null;
        if (!self.isMap(idx)) return null;
        return dispatch.mapSetToJsonVal(self._ctx, self.getVal(idx));
    }

    /// Serialize a Set arg as `JSON.stringify(Array.from(set))`, yielding `[v,...]`. Caller must free with freeString(). Returns null on non-Set input or JSON failure.
    pub fn setToJson(self: NativeArgs, idx: usize) ?[]const u8 {
        if (idx >= self._count) return null;
        if (!self.isSet(idx)) return null;
        return dispatch.mapSetToJsonVal(self._ctx, self.getVal(idx));
    }

    /// Read the `.size` numeric property of a Map/Set arg.
    pub fn mapOrSetSize(self: NativeArgs, idx: usize) ?u32 {
        if (idx >= self._count) return null;
        const val = self.getVal(idx);
        const prop = ActiveEngine.getPropertyVal(self._ctx, val, "size") orelse return null;
        defer ActiveEngine.freeValue(self._ctx, prop);
        const d = ActiveEngine.toFloat64(self._ctx, prop) orelse return null;
        if (!std.math.isFinite(d) or d < 0) return null;
        return @intFromFloat(d);
    }

    /// Native Map iteration. For each `[key, value]` pair in the map (in insertion order), invokes `cb(ctx, cb_ctx, key, value)`. The callback receives *borrowed* backend Values that are fully faithful (no JSON flattening) — read properties directly via `getPropertyVal`, etc.
    ///
    /// Callback returns true to continue iteration, false to stop early. Returns true on clean completion (exhaustion or early-exit), false if arg[idx] is not a Map or iteration raised an exception.
    ///
    /// WeakMap is NOT supported (not iterable in JS). Use `isMap` to narrow if accepting mixed inputs.
    pub fn mapForEach(
        self: NativeArgs,
        idx: usize,
        cb_ctx: ?*anyopaque,
        cb: *const dispatch.MapForEachFn,
    ) bool {
        if (idx >= self._count) return false;
        return dispatch.mapForEachVal(self._ctx, self.getVal(idx), cb_ctx, cb);
    }

    /// Native Set iteration. Counterpart of `mapForEach` for Set values.
    pub fn setForEach(
        self: NativeArgs,
        idx: usize,
        cb_ctx: ?*anyopaque,
        cb: *const dispatch.SetForEachFn,
    ) bool {
        if (idx >= self._count) return false;
        return dispatch.setForEachVal(self._ctx, self.getVal(idx), cb_ctx, cb);
    }

    /// Typed Map size. Returns null if arg[idx] is not a Map.
    pub fn mapSize(self: NativeArgs, idx: usize) ?usize {
        if (idx >= self._count) return null;
        return dispatch.mapSizeVal(self._ctx, self.getVal(idx));
    }

    /// Typed Set size. Returns null if arg[idx] is not a Set.
    pub fn setSize(self: NativeArgs, idx: usize) ?usize {
        if (idx >= self._count) return null;
        return dispatch.setSizeVal(self._ctx, self.getVal(idx));
    }

    // ---- Raw value access ----

    /// Get the raw backend value at index. For advanced usage only.
    pub fn getValue(self: NativeArgs, idx: usize) ?ActiveEngine.Value {
        if (idx >= self._count) return null;
        return self.getVal(idx);
    }

    /// Borrowed receiver (`this`) of this call. See `_this` for which value a bare call actually carries on each backend.
    pub fn thisValue(self: NativeArgs) ActiveEngine.Value {
        return self._this;
    }

    /// Whether a receiver is present. QuickJS: `this` is an object (bare call is `undefined`, so false). JSC: `thisObject != null`. A bare call is the global object, so this is still true; compare `thisValue()` with that object to tell a method call from a bare call.
    pub fn hasReceiver(self: NativeArgs) bool {
        if (comptime backend.active_backend == .jsc) {
            return self._this != null;
        }
        return ActiveEngine.isObjectVal(self._ctx, self._this);
    }

    fn getVal(self: NativeArgs, idx: usize) ActiveEngine.Value {
        const typed: [*c]const ActiveEngine.Value = @ptrCast(@alignCast(self._argv_raw));
        return typed[idx];
    }
};

/// Free a string returned by NativeArgs methods.
pub fn freeString(s: []const u8) void {
    std.heap.c_allocator.free(@constCast(s));
}
