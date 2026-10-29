//! Plain-data payload types shared across NativeArgs / NativeResult and the dispatch helpers. All types here are backend-agnostic; the only piece of backend-touching code is `kindFromBackend`, which maps a per-backend TypedArray code into the unified `TypedArrayKind` enum used by NativeArgs.getTypedArray.

const std = @import("std");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

/// Kind discriminator for TypedArray round-trips. Covers the element types marshalled directly by NativeArgs/NativeResult. Variants are strictly append-only; existing callers remain binary-compatible when new kinds are added at the end.
pub const TypedArrayKind = enum {
    uint8,
    int32,
    float32,
    float64,
    // Appended — see task notes.
    int8,
    int16,
    uint16,
    uint32,
    big_int64,
    big_uint64,

    pub fn elementSize(self: TypedArrayKind) usize {
        return switch (self) {
            .uint8, .int8 => 1,
            .int16, .uint16 => 2,
            .int32, .uint32, .float32 => 4,
            .float64, .big_int64, .big_uint64 => 8,
        };
    }
};

/// TypedArray view exposed to native handlers. `bytes` is the raw backing slice; use `asSlice` for typed element access. The slice is borrowed from the JS heap and must not outlive the handler invocation.
pub const TypedArrayView = struct {
    kind: TypedArrayKind,
    bytes: []const u8,

    pub fn elementCount(self: TypedArrayView) usize {
        const es = self.kind.elementSize();
        if (es == 0) return 0;
        return self.bytes.len / es;
    }

    /// Re-interpret the backing bytes as `[]const T`. Returns null if `T` does not match `self.kind`.
    pub fn asSlice(self: TypedArrayView, comptime T: type) ?[]const T {
        const expected: TypedArrayKind = switch (T) {
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
            else => return null,
        };
        if (expected != self.kind) return null;
        if (self.bytes.len == 0) return &[_]T{};
        const ptr: [*]const T = @ptrCast(@alignCast(self.bytes.ptr));
        return ptr[0 .. self.bytes.len / @sizeOf(T)];
    }
};

/// Payload describing a freshly-created ArrayBuffer to return to JS. `bytes` is copied into JS-managed memory; `free_after_copy` releases the native slice after copying.
pub const ArrayBufferPayload = struct {
    bytes: []const u8,
    free_after_copy: bool = false,
};

/// Payload describing a freshly-created TypedArray to return to JS. `bytes` is copied into a new JS ArrayBuffer and wrapped in the requested typed-array constructor.
pub const TypedArrayPayload = struct {
    kind: TypedArrayKind,
    bytes: []const u8,
    free_after_copy: bool = false,
};

/// Payload describing a freshly-created DataView or a DataView borrowed from a JS argument. `buffer.bytes` is the *full* backing byte range of the underlying ArrayBuffer; `byte_offset` and `byte_length` delimit the window the DataView exposes. When produced by `NativeArgs.getDataView` the slice is JS-owned and must not be retained past the handler return.
///
/// As a NativeResult it asks the engine to build `new DataView(new ArrayBuffer(buffer.bytes), byte_offset, byte_length)`; `buffer.free_after_copy` is honoured exactly as for `ArrayBufferPayload`.
///
/// Reads and writes operate directly on the window bytes via `std.mem.readInt`/`writeInt` with explicit endianness — no JS round-trip, same code path on both backends.
pub const DataViewPayload = struct {
    buffer: ArrayBufferPayload,
    byte_offset: usize = 0,
    byte_length: usize = 0,
    /// Only populated when this payload was obtained from NativeArgs; null when the payload is being built for return. Used only for the RangeError policy (see `rangeError`).
    _ctx: ?ActiveEngine.Context = null,

    fn viewBytes(self: DataViewPayload) []const u8 {
        const start = self.byte_offset;
        const end = start + self.byte_length;
        if (end > self.buffer.bytes.len) return &.{};
        return self.buffer.bytes[start..end];
    }

    fn viewBytesMut(self: DataViewPayload) []u8 {
        const start = self.byte_offset;
        const end = start + self.byte_length;
        const full: []u8 = @constCast(self.buffer.bytes);
        if (end > full.len) return full[0..0];
        return full[start..end];
    }

    fn inRange(self: DataViewPayload, off: usize, n: usize) bool {
        if (off > self.byte_length) return false;
        if (self.byte_length - off < n) return false;
        return true;
    }

    fn endianness(little: bool) std.builtin.Endian {
        return if (little) .little else .big;
    }

    // ---- getters ----

    pub fn getInt8(self: DataViewPayload, off: usize) ?i8 {
        if (!self.inRange(off, 1)) return null;
        const b = self.viewBytes();
        return @bitCast(b[off]);
    }

    pub fn getUint8(self: DataViewPayload, off: usize) ?u8 {
        if (!self.inRange(off, 1)) return null;
        const b = self.viewBytes();
        return b[off];
    }

    pub fn getInt16(self: DataViewPayload, off: usize, little_endian: bool) ?i16 {
        if (!self.inRange(off, 2)) return null;
        const b = self.viewBytes();
        return std.mem.readInt(i16, b[off..][0..2], endianness(little_endian));
    }

    pub fn getUint16(self: DataViewPayload, off: usize, little_endian: bool) ?u16 {
        if (!self.inRange(off, 2)) return null;
        const b = self.viewBytes();
        return std.mem.readInt(u16, b[off..][0..2], endianness(little_endian));
    }

    pub fn getInt32(self: DataViewPayload, off: usize, little_endian: bool) ?i32 {
        if (!self.inRange(off, 4)) return null;
        const b = self.viewBytes();
        return std.mem.readInt(i32, b[off..][0..4], endianness(little_endian));
    }

    pub fn getUint32(self: DataViewPayload, off: usize, little_endian: bool) ?u32 {
        if (!self.inRange(off, 4)) return null;
        const b = self.viewBytes();
        return std.mem.readInt(u32, b[off..][0..4], endianness(little_endian));
    }

    pub fn getFloat32(self: DataViewPayload, off: usize, little_endian: bool) ?f32 {
        if (!self.inRange(off, 4)) return null;
        const b = self.viewBytes();
        const bits = std.mem.readInt(u32, b[off..][0..4], endianness(little_endian));
        return @bitCast(bits);
    }

    pub fn getFloat64(self: DataViewPayload, off: usize, little_endian: bool) ?f64 {
        if (!self.inRange(off, 8)) return null;
        const b = self.viewBytes();
        const bits = std.mem.readInt(u64, b[off..][0..8], endianness(little_endian));
        return @bitCast(bits);
    }

    pub fn getBigInt64(self: DataViewPayload, off: usize, little_endian: bool) ?i64 {
        if (!self.inRange(off, 8)) return null;
        const b = self.viewBytes();
        return std.mem.readInt(i64, b[off..][0..8], endianness(little_endian));
    }

    pub fn getBigUint64(self: DataViewPayload, off: usize, little_endian: bool) ?u64 {
        if (!self.inRange(off, 8)) return null;
        const b = self.viewBytes();
        return std.mem.readInt(u64, b[off..][0..8], endianness(little_endian));
    }

    // ---- setters ----

    pub fn setInt8(self: DataViewPayload, off: usize, v: i8) bool {
        if (!self.inRange(off, 1)) return false;
        const b = self.viewBytesMut();
        b[off] = @bitCast(v);
        return true;
    }

    pub fn setUint8(self: DataViewPayload, off: usize, v: u8) bool {
        if (!self.inRange(off, 1)) return false;
        const b = self.viewBytesMut();
        b[off] = v;
        return true;
    }

    pub fn setInt16(self: DataViewPayload, off: usize, v: i16, little_endian: bool) bool {
        if (!self.inRange(off, 2)) return false;
        const b = self.viewBytesMut();
        std.mem.writeInt(i16, b[off..][0..2], v, endianness(little_endian));
        return true;
    }

    pub fn setUint16(self: DataViewPayload, off: usize, v: u16, little_endian: bool) bool {
        if (!self.inRange(off, 2)) return false;
        const b = self.viewBytesMut();
        std.mem.writeInt(u16, b[off..][0..2], v, endianness(little_endian));
        return true;
    }

    pub fn setInt32(self: DataViewPayload, off: usize, v: i32, little_endian: bool) bool {
        if (!self.inRange(off, 4)) return false;
        const b = self.viewBytesMut();
        std.mem.writeInt(i32, b[off..][0..4], v, endianness(little_endian));
        return true;
    }

    pub fn setUint32(self: DataViewPayload, off: usize, v: u32, little_endian: bool) bool {
        if (!self.inRange(off, 4)) return false;
        const b = self.viewBytesMut();
        std.mem.writeInt(u32, b[off..][0..4], v, endianness(little_endian));
        return true;
    }

    pub fn setFloat32(self: DataViewPayload, off: usize, v: f32, little_endian: bool) bool {
        if (!self.inRange(off, 4)) return false;
        const b = self.viewBytesMut();
        const bits: u32 = @bitCast(v);
        std.mem.writeInt(u32, b[off..][0..4], bits, endianness(little_endian));
        return true;
    }

    pub fn setFloat64(self: DataViewPayload, off: usize, v: f64, little_endian: bool) bool {
        if (!self.inRange(off, 8)) return false;
        const b = self.viewBytesMut();
        const bits: u64 = @bitCast(v);
        std.mem.writeInt(u64, b[off..][0..8], bits, endianness(little_endian));
        return true;
    }

    pub fn setBigInt64(self: DataViewPayload, off: usize, v: i64, little_endian: bool) bool {
        if (!self.inRange(off, 8)) return false;
        const b = self.viewBytesMut();
        std.mem.writeInt(i64, b[off..][0..8], v, endianness(little_endian));
        return true;
    }

    pub fn setBigUint64(self: DataViewPayload, off: usize, v: u64, little_endian: bool) bool {
        if (!self.inRange(off, 8)) return false;
        const b = self.viewBytesMut();
        std.mem.writeInt(u64, b[off..][0..8], v, endianness(little_endian));
        return true;
    }
};

/// Convert a backend-specific TypedArray kind code into a TypedArrayKind. Returns null for kinds we don't currently marshal (e.g. Float16Array).
pub fn kindFromBackend(code: c_int) ?TypedArrayKind {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = backend.ActiveEngineModule;
            if (code == qjs_mod.QJS_TYPED_ARRAY_UINT8 or code == qjs_mod.QJS_TYPED_ARRAY_UINT8C) return .uint8;
            if (code == qjs_mod.QJS_TYPED_ARRAY_INT8) return .int8;
            if (code == qjs_mod.QJS_TYPED_ARRAY_INT16) return .int16;
            if (code == qjs_mod.QJS_TYPED_ARRAY_UINT16) return .uint16;
            if (code == qjs_mod.QJS_TYPED_ARRAY_INT32) return .int32;
            if (code == qjs_mod.QJS_TYPED_ARRAY_UINT32) return .uint32;
            if (code == qjs_mod.QJS_TYPED_ARRAY_BIG_INT64) return .big_int64;
            if (code == qjs_mod.QJS_TYPED_ARRAY_BIG_UINT64) return .big_uint64;
            if (code == qjs_mod.QJS_TYPED_ARRAY_FLOAT32) return .float32;
            if (code == qjs_mod.QJS_TYPED_ARRAY_FLOAT64) return .float64;
            return null;
        },
        .jsc => {
            const jsc_mod = backend.EngineModule(.jsc);
            if (code == jsc_mod.JSC_TA_UINT8 or code == jsc_mod.JSC_TA_UINT8C) return .uint8;
            if (code == jsc_mod.JSC_TA_INT8) return .int8;
            if (code == jsc_mod.JSC_TA_INT16) return .int16;
            if (code == jsc_mod.JSC_TA_UINT16) return .uint16;
            if (code == jsc_mod.JSC_TA_INT32) return .int32;
            if (code == jsc_mod.JSC_TA_UINT32) return .uint32;
            if (code == jsc_mod.JSC_TA_FLOAT32) return .float32;
            if (code == jsc_mod.JSC_TA_FLOAT64) return .float64;
            if (code == jsc_mod.JSC_TA_BIG_INT64) return .big_int64;
            if (code == jsc_mod.JSC_TA_BIG_UINT64) return .big_uint64;
            return null;
        },
    };
}
