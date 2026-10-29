//! Tagged-union return type for native function callbacks. The engine consumes this and produces the corresponding backend Value, freeing any caller-owned slices along the way (see field-level docs).

const backend = @import("../backend.zig");
const types = @import("types.zig");

const ActiveEngine = backend.ActiveEngine;

const ArrayBufferPayload = types.ArrayBufferPayload;
const TypedArrayPayload = types.TypedArrayPayload;
const DataViewPayload = types.DataViewPayload;

/// Unified result from a native function callback. All string fields are owned by the caller; the engine copies and frees them.
pub const NativeResult = union(enum) {
    null_val,
    undefined_val,
    boolean: bool,
    number: f64,
    /// Return a JS string. Caller owns the slice; engine frees after conversion.
    string: []const u8,
    /// Return a parsed JSON object. Caller owns the slice; engine parses and frees.
    json: []const u8,
    /// Throw a JS error with this message. Caller owns the slice; engine frees.
    err: []const u8,
    /// Return a raw JS value directly. Engine takes ownership (caller must not free).
    value: ActiveEngine.Value,
    /// Return a Promise (raw backend Value). Semantically identical to `.value` but documents intent: the handler has stashed the Deferred's resolve/reject callbacks elsewhere and will settle the promise later (e.g. from a timer callback). Engine takes ownership of the Value.
    promise: ActiveEngine.Value,
    /// Return an ArrayBuffer copied from native memory.
    array_buffer: ArrayBufferPayload,
    /// Return a TypedArray copied from native memory.
    typed_array: TypedArrayPayload,
    /// Return a Date object. Value is epoch milliseconds.
    date_ms: i64,
    /// Return a BigInt from a signed 64-bit integer.
    big_int_i64: i64,
    /// Return a BigInt from an unsigned 64-bit integer (for values > i64::MAX).
    big_int_u64: u64,
    /// Return a Map constructed from `JSON.parse(json)`. JSON must be an iterable of [key, value] pairs, e.g. `[["a",1],["b",2]]`. Caller owns the slice; engine parses and frees.
    map_json: []const u8,
    /// Return a Set constructed from `JSON.parse(json)`. JSON must be an iterable of values, e.g. `[1,2,3]`. Caller owns the slice; engine parses and frees.
    set_json: []const u8,
    /// Return a DataView over a freshly-copied ArrayBuffer. The engine creates the underlying AB from `buffer.bytes` (respecting `free_after_copy`) and wraps it with the given offset/length.
    data_view: DataViewPayload,
};
