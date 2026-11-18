//! HyperBox64: IEEE-754 Negative Quiet-NaN Value Engine with Inline SSO Strings.
//!
//! Memory layout (64-bit IEEE-754 Negative Quiet-NaN):
//!   [63:48] Tag (16 bits, strictly >= 0xFFF8 to guarantee Bit 51 is 1: Quiet NaN)
//!   [47:0]  Payload (48 bits)
//!
//! Tag allocation (all boxed tags reside strictly in Quiet-NaN space 0xFFF8..0xFFFF):
//!   0x0000..0xFFF7 : Pure IEEE-754 Doubles, +/-inf, subnormals, Canonical Quiet NaN.
//!   0xFFF8         : Int32 (bits 31..0: signed 32-bit integer)
//!   0xFFF9         : Boolean (bit 0: 0 for false, 1 for true)
//!   0xFFFA         : Special (0 for undefined, 1 for null)
//!   0xFFFB         : Generational Handle (12b instance_id, 16b generation, 20b slot_index)
//!   0xFFFC         : Caged Heap Object (48-bit pointer / caged base-relative offset)
//!   0xFFFD         : Extended (bit 32 = 0 for Symbol ID, bit 32 = 1 for BigInt offset)
//!   0xFFFE         : Inline SSO Strings (lengths 0 to 5 bytes; length stored in bits 47..40)
//!   0xFFFF         : Inline SSO Strings (length 6 bytes; all 48 payload bits are characters)

const std = @import("std");
const builtin = @import("builtin");
const split_box32 = @import("split_box32.zig");

pub const SplitBox32 = split_box32.SplitBox32;

pub const TAG_BASE: u64 = 0xFFF8_0000_0000_0000;
pub const TAG_INT32: u64 = 0xFFF8_0000_0000_0000;
pub const TAG_BOOL: u64 = 0xFFF9_0000_0000_0000;
pub const TAG_SPECIAL: u64 = 0xFFFA_0000_0000_0000;
pub const TAG_HANDLE: u64 = 0xFFFB_0000_0000_0000;
pub const TAG_HEAP_OBJ: u64 = 0xFFFC_0000_0000_0000;
pub const TAG_EXTENDED: u64 = 0xFFFD_0000_0000_0000;
pub const TAG_SSO_BASE: u64 = 0xFFFE_0000_0000_0000;
pub const TAG_SSO_0_5: u64 = 0xFFFE_0000_0000_0000;
pub const TAG_SSO_6: u64 = 0xFFFF_0000_0000_0000;

pub const EXT_KIND_SYMBOL: u64 = 0x0000_0000_0000_0000;
pub const EXT_KIND_BIGINT: u64 = 0x0000_0001_0000_0000;

pub const TAG_MASK: u64 = 0xFFFF_0000_0000_0000;
pub const PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;

pub const EXPONENT_MASK: u64 = 0x7FF0_0000_0000_0000;
pub const MANTISSA_MASK: u64 = 0x000F_FFFF_FFFF_FFFF;

/// Canonical hardware Quiet NaN representation (positive quiet NaN).
pub const CANONICAL_NAN: u64 = 0x7FF8_0000_0000_0000;

/// Negative zero representation in IEEE-754.
pub const NEGATIVE_ZERO: u64 = 0x8000_0000_0000_0000;

/// Empty / uninitialized value handle marker (guarantees C ABI NULL compatibility).
pub const VAL_EMPTY: Value = .{ .raw = 0 };

/// Universal immutable Undefined value.
pub const VAL_UNDEFINED: Value = .{ .raw = TAG_SPECIAL | 0 };

/// Universal immutable Null value.
pub const VAL_NULL: Value = .{ .raw = TAG_SPECIAL | 1 };

/// Universal immutable True value.
pub const VAL_TRUE: Value = .{ .raw = TAG_BOOL | 1 };

/// Universal immutable False value.
pub const VAL_FALSE: Value = .{ .raw = TAG_BOOL | 0 };

/// Generational handle layout packed into the 48-bit payload.
pub const HandlePayload = struct {
    instance_id: u12,
    generation: u16,
    slot_index: u20,
};

/// Safe value container for small string data.
pub const SsoBuffer = struct {
    bytes: [6]u8,
    len: u8,

    pub inline fn slice(self: *const SsoBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Value = extern struct {
    raw: u64,

    // ---- Constructors ----

    pub inline fn empty() Value {
        return VAL_EMPTY;
    }

    pub inline fn undefinedValue() Value {
        return VAL_UNDEFINED;
    }

    pub inline fn nullValue() Value {
        return VAL_NULL;
    }

    pub inline fn fromBool(b: bool) Value {
        return if (b) VAL_TRUE else VAL_FALSE;
    }

    pub inline fn fromInt32(i: i32) Value {
        const u: u32 = @bitCast(i);
        return .{ .raw = TAG_INT32 | @as(u64, u) };
    }

    pub fn fromFloat(f: f64) Value {
        const bits: u64 = @bitCast(f);
        if (bits == 0) {
            // Normalize positive zero (+0.0) to Int32(0) so raw 0 is preserved as the invalid handle sentinel.
            return fromInt32(0);
        }
        if (std.math.isNan(f)) {
            return .{ .raw = CANONICAL_NAN };
        }
        return .{ .raw = bits };
    }

    pub fn fromSso(slice: []const u8) ?Value {
        if (slice.len > 6) return null;
        if (!std.unicode.utf8ValidateSlice(slice)) return null;
        if (slice.len == 6) {
            var bytes: [8]u8 = @splat(0);
            @memcpy(bytes[0..6], slice);
            const chars: u64 = if (builtin.cpu.arch.endian() == .little)
                std.mem.readInt(u64, &bytes, .little)
            else
                @as(u64, std.mem.readInt(u64, &bytes, .big)) >> 16;
            return .{ .raw = TAG_SSO_6 | (chars & PAYLOAD_MASK) };
        } else {
            var bytes: [8]u8 = @splat(0);
            @memcpy(bytes[0..slice.len], slice);
            const chars: u64 = if (builtin.cpu.arch.endian() == .little)
                std.mem.readInt(u64, &bytes, .little) & 0x0000_00FF_FFFF_FFFF
            else
                (@as(u64, std.mem.readInt(u64, &bytes, .big)) >> 24) & 0x0000_00FF_FFFF_FFFF;
            const tag: u64 = TAG_SSO_0_5 | (@as(u64, slice.len) << 40);
            return .{ .raw = tag | chars };
        }
    }

    pub fn fromHandle(instance_id: u12, generation: u16, slot_index: u20) Value {
        const payload: u64 = (@as(u64, instance_id) << 36) |
            (@as(u64, generation) << 20) |
            @as(u64, slot_index);
        return .{ .raw = TAG_HANDLE | payload };
    }

    pub fn fromSymbol(symbol_id: u32) Value {
        return .{ .raw = TAG_EXTENDED | EXT_KIND_SYMBOL | @as(u64, symbol_id) };
    }

    pub fn fromBigIntOffset(offset: u32) Value {
        return .{ .raw = TAG_EXTENDED | EXT_KIND_BIGINT | @as(u64, offset) };
    }

    // ---- Fast-path Predicates ----

    pub inline fn isValid(self: Value) bool {
        return self.raw != 0;
    }

    pub inline fn isEmpty(self: Value) bool {
        return self.raw == 0;
    }

    pub inline fn isDouble(self: Value) bool {
        return (self.raw -% 1) < (TAG_BASE - 1);
    }

    pub inline fn isInt32(self: Value) bool {
        return (self.raw & TAG_MASK) == TAG_INT32;
    }

    pub inline fn isNumber(self: Value) bool {
        return self.isInt32() or self.isDouble();
    }

    pub inline fn isBool(self: Value) bool {
        return (self.raw & TAG_MASK) == TAG_BOOL;
    }

    pub inline fn isUndefined(self: Value) bool {
        return self.raw == VAL_UNDEFINED.raw;
    }

    pub inline fn isNull(self: Value) bool {
        return self.raw == VAL_NULL.raw;
    }

    pub inline fn isSpecial(self: Value) bool {
        return (self.raw & TAG_MASK) == TAG_SPECIAL;
    }

    pub inline fn isHandle(self: Value) bool {
        return (self.raw & TAG_MASK) == TAG_HANDLE;
    }

    pub inline fn isGenerationalHandle(self: Value) bool {
        return (self.raw & TAG_MASK) == TAG_HANDLE;
    }

    pub inline fn isHeapObject(self: Value) bool {
        return (self.raw & TAG_MASK) == TAG_HEAP_OBJ;
    }

    pub inline fn isSymbol(self: Value) bool {
        return (self.raw & 0xFFFF_0001_0000_0000) == (TAG_EXTENDED | EXT_KIND_SYMBOL);
    }

    pub inline fn isBigInt(self: Value) bool {
        return (self.raw & 0xFFFF_0001_0000_0000) == (TAG_EXTENDED | EXT_KIND_BIGINT);
    }

    pub inline fn isSso(self: Value) bool {
        if (self.raw >= TAG_SSO_6) return true;
        if (self.raw >= TAG_SSO_0_5) {
            const len = (self.raw >> 40) & 0xFF;
            return len <= 5;
        }
        return false;
    }

    pub inline fn isPrimitive(self: Value) bool {
        return self.isNumber() or self.isBool() or self.isSpecial() or self.isSso();
    }

    // ---- Decoders ----

    pub inline fn asFloat(self: Value) f64 {
        if (self.isInt32()) {
            return @floatFromInt(self.asInt32());
        }
        const bits = self.raw;
        if ((bits & EXPONENT_MASK) == EXPONENT_MASK and (bits & MANTISSA_MASK) != 0) {
            return @bitCast(CANONICAL_NAN);
        }
        return @bitCast(bits);
    }

    pub inline fn asInt32(self: Value) i32 {
        return @bitCast(@as(u32, @truncate(self.raw)));
    }

    pub inline fn asBool(self: Value) bool {
        return (self.raw & 1) != 0;
    }

    pub inline fn ssoLength(self: Value) usize {
        if (self.raw >= TAG_SSO_6) return 6;
        if (self.raw >= TAG_SSO_0_5) {
            const len = (self.raw >> 40) & 0xFF;
            if (len <= 5) return @intCast(len);
            return 0;
        }
        return 0;
    }

    /// Return a safe by-value container with copied inline string bytes.
    pub inline fn asSsoBytes(self: Value) SsoBuffer {
        const len = self.ssoLength();
        var buf: [6]u8 = @splat(0);
        if (len > 0 and len <= 6) {
            if (builtin.cpu.arch.endian() == .little) {
                const raw_bytes: [8]u8 = @bitCast(self.raw);
                @memcpy(buf[0..len], raw_bytes[0..len]);
            } else {
                const raw_bytes: [8]u8 = @bitCast(self.raw);
                if (len == 6) {
                    @memcpy(buf[0..6], raw_bytes[2..8]);
                } else {
                    @memcpy(buf[0..len], raw_bytes[3 .. 3 + len]);
                }
            }
        }
        return .{ .bytes = buf, .len = @intCast(@min(len, 6)) };
    }

    /// Copy inline string bytes into a destination buffer.
    pub inline fn copySso(self: Value, dest: []u8) usize {
        const len = self.ssoLength();
        if (len == 0 or len > 6) return 0;
        const copy_len = @min(dest.len, len);
        if (copy_len == 0) return 0;
        const sso_buf = self.asSsoBytes();
        @memcpy(dest[0..copy_len], sso_buf.bytes[0..copy_len]);
        return copy_len;
    }

    /// Return a slice view pointing into self.raw. Ensure self outlives the slice, or use asSsoBytes().
    pub fn asSsoSlice(self: *const Value) []const u8 {
        const len = self.ssoLength();
        if (len == 0 or len > 6) return "";
        if (builtin.cpu.arch.endian() == .little) {
            const ptr: [*]const u8 = @ptrCast(&self.raw);
            return ptr[0..len];
        } else {
            const ptr: [*]const u8 = @ptrCast(&self.raw);
            if (len == 6) {
                return ptr[2..8];
            } else {
                return ptr[3 .. 3 + len];
            }
        }
    }

    pub inline fn ssoEquals(self: Value, other: Value) bool {
        return self.raw == other.raw;
    }

    pub fn ssoEqualsSlice(self: Value, slice: []const u8) bool {
        if (self.ssoLength() != slice.len) return false;
        const sso_buf = self.asSsoBytes();
        return std.mem.eql(u8, sso_buf.slice(), slice);
    }

    pub inline fn decodeHandle(self: Value) HandlePayload {
        const payload = self.raw & PAYLOAD_MASK;
        return .{
            .instance_id = @truncate(payload >> 36),
            .generation = @truncate(payload >> 20),
            .slot_index = @truncate(payload),
        };
    }

    pub inline fn decodeSymbol(self: Value) u32 {
        return @truncate(self.raw);
    }

    pub inline fn split32(self: Value) SplitBox32 {
        return SplitBox32.fromU64(self.raw);
    }
};
