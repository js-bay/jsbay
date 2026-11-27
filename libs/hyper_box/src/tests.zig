//! Comprehensive Unit Tests for HyperBox Package.

const std = @import("std");
const hyper_box = @import("hyper_box");
const Value = hyper_box.Value;
const GenerationalSlotMap = hyper_box.GenerationalSlotMap;
const SplitBox32 = hyper_box.SplitBox32;

test "hyper_box Quiet-NaN bit 51 invariant for all boxed tags" {
    const quiet_bit: u64 = 1 << 51;
    try std.testing.expect((hyper_box.TAG_INT32 & quiet_bit) != 0);
    try std.testing.expect((hyper_box.TAG_BOOL & quiet_bit) != 0);
    try std.testing.expect((hyper_box.TAG_SPECIAL & quiet_bit) != 0);
    try std.testing.expect((hyper_box.TAG_HANDLE & quiet_bit) != 0);
    try std.testing.expect((hyper_box.TAG_HEAP_OBJ & quiet_bit) != 0);
    try std.testing.expect((hyper_box.TAG_EXTENDED & quiet_bit) != 0);
    try std.testing.expect((hyper_box.TAG_SSO_0_5 & quiet_bit) != 0);
    try std.testing.expect((hyper_box.TAG_SSO_6 & quiet_bit) != 0);

    try std.testing.expect(hyper_box.TAG_BASE >= 0xFFF8_0000_0000_0000);
}

test "hyper_box empty sentinel" {
    const empty_val = Value.empty();
    try std.testing.expect(!empty_val.isValid());
    try std.testing.expect(empty_val.isEmpty());
    try std.testing.expect(!empty_val.isNumber());
    try std.testing.expect(!empty_val.isDouble());
    try std.testing.expect(!empty_val.isInt32());
    try std.testing.expect(!empty_val.isBool());
    try std.testing.expect(!empty_val.isSpecial());
    try std.testing.expect(!empty_val.isSso());
}

test "hyper_box doubles, infinities, and sNaN canonicalization" {
    const val_pi = Value.fromFloat(3.141592653589793);
    try std.testing.expect(val_pi.isValid());
    try std.testing.expect(val_pi.isDouble());
    try std.testing.expect(val_pi.isNumber());
    try std.testing.expect(!val_pi.isInt32());
    try std.testing.expectEqual(3.141592653589793, val_pi.asFloat());

    const val_inf = Value.fromFloat(std.math.inf(f64));
    try std.testing.expect(val_inf.isDouble());
    try std.testing.expect(std.math.isInf(val_inf.asFloat()));

    const val_neg_inf = Value.fromFloat(-std.math.inf(f64));
    try std.testing.expect(val_neg_inf.isDouble());
    try std.testing.expect(std.math.isNegativeInf(val_neg_inf.asFloat()));

    const val_nan = Value.fromFloat(std.math.nan(f64));
    try std.testing.expect(val_nan.isDouble());
    try std.testing.expect(std.math.isNan(val_nan.asFloat()));
    try std.testing.expectEqual(hyper_box.CANONICAL_NAN, val_nan.raw);

    const pos_snan = Value{ .raw = 0x7FF0_0000_0000_0001 };
    try std.testing.expect(std.math.isNan(pos_snan.asFloat()));
    const pos_snan_bits: u64 = @bitCast(pos_snan.asFloat());
    try std.testing.expectEqual(hyper_box.CANONICAL_NAN, pos_snan_bits);

    const pos_snan_f: f64 = @bitCast(@as(u64, 0x7FF0_0000_0000_0001));
    const val_pos_snan = Value.fromFloat(pos_snan_f);
    try std.testing.expectEqual(hyper_box.CANONICAL_NAN, val_pos_snan.raw);

    const neg_snan = Value{ .raw = 0xFFF0_0000_0000_0001 };
    try std.testing.expect(std.math.isNan(neg_snan.asFloat()));
    const neg_snan_bits: u64 = @bitCast(neg_snan.asFloat());
    try std.testing.expectEqual(hyper_box.CANONICAL_NAN, neg_snan_bits);

    const neg_snan_f: f64 = @bitCast(@as(u64, 0xFFF0_0000_0000_0001));
    const val_neg_snan = Value.fromFloat(neg_snan_f);
    try std.testing.expectEqual(hyper_box.CANONICAL_NAN, val_neg_snan.raw);

    const val_neg_zero = Value.fromFloat(-0.0);
    try std.testing.expect(val_neg_zero.isDouble());
    try std.testing.expect(std.math.isNegativeZero(val_neg_zero.asFloat()));
    try std.testing.expectEqual(hyper_box.NEGATIVE_ZERO, val_neg_zero.raw);

    const val_pos_zero = Value.fromFloat(0.0);
    try std.testing.expect(val_pos_zero.isInt32());
    try std.testing.expect(val_pos_zero.isNumber());
    try std.testing.expectEqual(@as(f64, 0.0), val_pos_zero.asFloat());
}

test "hyper_box ABI golden vectors" {
    const builtin = @import("builtin");

    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), Value.fromFloat(-0.0).raw);
    try std.testing.expectEqual(@as(u64, 0x7FF0_0000_0000_0000), Value.fromFloat(std.math.inf(f64)).raw);
    try std.testing.expectEqual(@as(u64, 0xFFF0_0000_0000_0000), Value.fromFloat(-std.math.inf(f64)).raw);
    try std.testing.expectEqual(@as(u64, 0x0000_0000_0000_0001), Value.fromFloat(@as(f64, @bitCast(@as(u64, 1)))).raw);
    try std.testing.expectEqual(@as(u64, 0x7FF8_0000_0000_0000), Value.fromFloat(@as(f64, @bitCast(@as(u64, 0x7FF0_0000_0000_0001)))).raw);
    try std.testing.expectEqual(@as(u64, 0x7FF8_0000_0000_0000), Value.fromFloat(@as(f64, @bitCast(@as(u64, 0xFFF0_0000_0000_0001)))).raw);

    try std.testing.expectEqual(@as(u64, 0xFFF8_0000_7FFF_FFFF), Value.fromInt32(std.math.maxInt(i32)).raw);
    try std.testing.expectEqual(@as(u64, 0xFFF8_0000_8000_0000), Value.fromInt32(std.math.minInt(i32)).raw);
    try std.testing.expectEqual(@as(u64, 0xFFFA_0000_0000_0000), Value.undefinedValue().raw);
    try std.testing.expectEqual(@as(u64, 0xFFFA_0000_0000_0001), Value.nullValue().raw);

    const utf8 = Value.fromSso("é").?;
    const expected_utf8_raw: u64 = if (builtin.cpu.arch.endian() == .little)
        0xFFFE_0200_0000_A9C3
    else
        0xFFFE_02C3_A900_0000;
    try std.testing.expectEqual(expected_utf8_raw, utf8.raw);
    try std.testing.expectEqualStrings("é", utf8.asSsoBytes().slice());

    const negative_zero_bytes: [8]u8 = @bitCast(Value.fromFloat(-0.0).raw);
    const expected_negative_zero_bytes: [8]u8 = if (builtin.cpu.arch.endian() == .little)
        .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80 }
    else
        .{ 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectEqual(expected_negative_zero_bytes, negative_zero_bytes);
}

test "hyper_box int32 integers" {
    const val_zero = Value.fromInt32(0);
    try std.testing.expect(val_zero.isInt32());
    try std.testing.expect(val_zero.isNumber());
    try std.testing.expectEqual(@as(i32, 0), val_zero.asInt32());
    try std.testing.expectEqual(@as(f64, 0.0), val_zero.asFloat());

    const val_42 = Value.fromInt32(42);
    try std.testing.expect(val_42.isInt32());
    try std.testing.expectEqual(@as(i32, 42), val_42.asInt32());
    try std.testing.expectEqual(@as(f64, 42.0), val_42.asFloat());

    const val_neg = Value.fromInt32(-1024);
    try std.testing.expect(val_neg.isInt32());
    try std.testing.expectEqual(@as(i32, -1024), val_neg.asInt32());
    try std.testing.expectEqual(@as(f64, -1024.0), val_neg.asFloat());

    const val_max = Value.fromInt32(std.math.maxInt(i32));
    try std.testing.expect(val_max.isInt32());
    try std.testing.expectEqual(std.math.maxInt(i32), val_max.asInt32());

    const val_min = Value.fromInt32(std.math.minInt(i32));
    try std.testing.expect(val_min.isInt32());
    try std.testing.expectEqual(std.math.minInt(i32), val_min.asInt32());
}

test "hyper_box booleans and specials" {
    const t = Value.fromBool(true);
    const f = Value.fromBool(false);
    try std.testing.expect(t.isBool());
    try std.testing.expect(f.isBool());
    try std.testing.expect(t.asBool());
    try std.testing.expect(!f.asBool());

    const u = Value.undefinedValue();
    const n = Value.nullValue();
    try std.testing.expect(u.isUndefined());
    try std.testing.expect(!u.isNull());
    try std.testing.expect(n.isNull());
    try std.testing.expect(!n.isUndefined());
    try std.testing.expect(u.isSpecial());
    try std.testing.expect(n.isSpecial());
}

test "hyper_box sso strings lengths 0 to 6 and safe copy" {
    const empty_sso = Value.fromSso("").?;
    try std.testing.expect(empty_sso.isSso());
    try std.testing.expectEqual(@as(usize, 0), empty_sso.ssoLength());
    try std.testing.expectEqualStrings("", empty_sso.asSsoBytes().slice());

    const s1 = Value.fromSso("a").?;
    try std.testing.expect(s1.isSso());
    try std.testing.expectEqual(@as(usize, 1), s1.ssoLength());
    try std.testing.expectEqualStrings("a", s1.asSsoBytes().slice());

    const s2 = Value.fromSso("id").?;
    try std.testing.expect(s2.isSso());
    try std.testing.expectEqual(@as(usize, 2), s2.ssoLength());
    try std.testing.expectEqualStrings("id", s2.asSsoBytes().slice());

    const s3 = Value.fromSso("key").?;
    try std.testing.expect(s3.isSso());
    try std.testing.expectEqual(@as(usize, 3), s3.ssoLength());
    try std.testing.expectEqualStrings("key", s3.asSsoBytes().slice());

    const s4 = Value.fromSso("name").?;
    try std.testing.expect(s4.isSso());
    try std.testing.expectEqual(@as(usize, 4), s4.ssoLength());
    try std.testing.expectEqualStrings("name", s4.asSsoBytes().slice());

    const s5 = Value.fromSso("hello").?;
    try std.testing.expect(s5.isSso());
    try std.testing.expectEqual(@as(usize, 5), s5.ssoLength());
    try std.testing.expectEqualStrings("hello", s5.asSsoBytes().slice());

    const s6 = Value.fromSso("result").?;
    try std.testing.expect(s6.isSso());
    try std.testing.expectEqual(@as(usize, 6), s6.ssoLength());
    try std.testing.expectEqualStrings("result", s6.asSsoBytes().slice());

    try std.testing.expect(Value.fromSso("toolong") == null);

    const invalid_utf8: []const u8 = &.{0xC3};
    try std.testing.expect(Value.fromSso(invalid_utf8) == null);

    var dest: [16]u8 = undefined;
    const copied = s6.copySso(&dest);
    try std.testing.expectEqual(@as(usize, 6), copied);
    try std.testing.expectEqualStrings("result", dest[0..copied]);

    const s5_dup = Value.fromSso("hello").?;
    try std.testing.expect(s5.ssoEquals(s5_dup));
    try std.testing.expect(!s5.ssoEquals(s6));
    try std.testing.expect(s5.ssoEqualsSlice("hello"));
    try std.testing.expect(!s5.ssoEqualsSlice("world"));

    try std.testing.expect(!Value.fromInt32(0).ssoEqualsSlice(""));
    try std.testing.expect(!Value.fromInt32(42).ssoEqualsSlice(""));
    try std.testing.expect(!Value.nullValue().ssoEqualsSlice(""));
    try std.testing.expect(!Value.undefinedValue().ssoEqualsSlice(""));
    try std.testing.expect(!Value.empty().ssoEqualsSlice(""));
    try std.testing.expect(!Value.fromBool(false).ssoEqualsSlice(""));
}

test "hyper_box generational handles" {
    const handle = Value.fromHandle(12, 345, 6789);
    try std.testing.expect(handle.isHandle());
    try std.testing.expect(!handle.isPrimitive());
    try std.testing.expect(!handle.isNumber());

    const decoded = handle.decodeHandle();
    try std.testing.expectEqual(@as(u12, 12), decoded.instance_id);
    try std.testing.expectEqual(@as(u16, 345), decoded.generation);
    try std.testing.expectEqual(@as(u20, 6789), decoded.slot_index);
}

test "hyper_box split32 representation" {
    const val_int = Value.fromInt32(12345);
    const split = val_int.split32();
    try std.testing.expectEqual(@as(u32, 12345), split.payload);
    try std.testing.expectEqual(@as(u32, @truncate(hyper_box.TAG_INT32 >> 32)), split.tag);
    try std.testing.expectEqual(val_int.raw, split.toU64());
}

test "generational_slot_map FIFO slot cycling and ABA prevention" {
    const testing = std.testing;
    var map = GenerationalSlotMap(u32).init(testing.allocator);
    defer map.deinit();

    const h0 = try map.insert(1, 100, false);
    const h1 = try map.insert(1, 200, false);
    const h2 = try map.insert(1, 300, false);

    const val0 = (Value{ .raw = h0 }).decodeHandle();
    const val1 = (Value{ .raw = h1 }).decodeHandle();
    const val2 = (Value{ .raw = h2 }).decodeHandle();
    try testing.expectEqual(@as(u20, 0), val0.slot_index);
    try testing.expectEqual(@as(u20, 1), val1.slot_index);
    try testing.expectEqual(@as(u20, 2), val2.slot_index);

    _ = map.remove(h0);
    _ = map.remove(h1);

    const h3 = try map.insert(1, 400, false);
    const val3 = (Value{ .raw = h3 }).decodeHandle();
    try testing.expectEqual(@as(u20, 0), val3.slot_index);
    try testing.expectEqual(@as(u16, 2), val3.generation);

    const h4 = try map.insert(1, 500, false);
    const val4 = (Value{ .raw = h4 }).decodeHandle();
    try testing.expectEqual(@as(u20, 1), val4.slot_index);
    try testing.expectEqual(@as(u16, 2), val4.generation);

    _ = map.remove(h2);
    _ = map.remove(h3);
    _ = map.remove(h4);
    try testing.expectEqual(@as(usize, 0), map.active_count);
}

test "generational_slot_map preserves full instance IDs with matching low bits" {
    const testing = std.testing;
    var map = GenerationalSlotMap(u32).init(testing.allocator);
    defer map.deinit();

    const ids = [_]i32{ 0, 4096, -4096 };
    const values = [_]u32{ 10, 20, 30 };
    var handles: [ids.len]u64 = undefined;

    for (ids, values, 0..) |instance_id, value, index| {
        handles[index] = try map.insert(instance_id, value, false);
    }

    for (ids, values, handles) |instance_id, value, handle| {
        const entry = map.get(handle).?;
        try testing.expectEqual(instance_id, entry.instance_id);
        try testing.expectEqual(value, entry.value);
        try testing.expectEqual(instance_id, map.instanceFor(handle).?);
    }

    for (handles) |handle| {
        try testing.expect(map.remove(handle) != null);
        try testing.expect(map.get(handle) == null);
        try testing.expect(map.instanceFor(handle) == null);
    }
}

test "generational_slot_map allocates the last u20 slot index" {
    const testing = std.testing;
    var map = GenerationalSlotMap(u32).init(testing.allocator);
    defer map.deinit();

    const slot_count = @as(usize, 1) << 20;
    var last_handle: u64 = 0;
    for (0..slot_count) |value| {
        last_handle = try map.insert(1, @intCast(value), false);
    }

    const last = (Value{ .raw = last_handle }).decodeHandle();
    try testing.expectEqual(@as(u20, std.math.maxInt(u20)), last.slot_index);
    try testing.expectError(error.OutOfMemory, map.insert(1, 0, false));
}

test "generational_slot_map reservation, commit, and safe cancel" {
    const testing = std.testing;
    var map = GenerationalSlotMap(u32).init(testing.allocator);
    defer map.deinit();

    const reserved_handle = try map.reserve(2, 0);
    try testing.expect(map.isReserved(reserved_handle));
    try testing.expect(map.get(reserved_handle) == null);
    try testing.expect(map.instanceFor(reserved_handle) == null);

    try testing.expect(map.commit(reserved_handle, 42));
    try testing.expect(!map.isReserved(reserved_handle));

    const e = map.get(reserved_handle).?;
    try testing.expectEqual(@as(u32, 42), e.value);
    try testing.expectEqual(@as(i32, 2), e.instance_id);

    try testing.expect(!map.cancel(reserved_handle));
    try testing.expect(map.get(reserved_handle) != null);

    const reserved2 = try map.reserve(2, 0);
    try testing.expect(map.isReserved(reserved2));
    try testing.expect(map.cancel(reserved2));
    try testing.expect(!map.isReserved(reserved2));
    try testing.expect(map.get(reserved2) == null);
}

test "generational_slot_map retires slot on generation exhaustion" {
    const testing = std.testing;
    var map = GenerationalSlotMap(u32).init(testing.allocator);
    defer map.deinit();

    const h1 = try map.insert(1, 100, false);
    const decoded = (Value{ .raw = h1 }).decodeHandle();
    try testing.expectEqual(@as(u20, 0), decoded.slot_index);
    try testing.expectEqual(@as(u16, 1), decoded.generation);

    // Manually advance slot generation to maximum to simulate long-running wrap condition.
    map.slots.items[0].generation = std.math.maxInt(u16);
    const max_handle = Value.fromHandle(1, std.math.maxInt(u16), 0).raw;
    try testing.expect(map.get(max_handle) != null);

    // Removing the slot when generation is exhausted must permanently retire it.
    try testing.expect(map.remove(max_handle) != null);
    try testing.expectEqual(@as(u16, 0), map.slots.items[0].generation);
    try testing.expectEqual(hyper_box.SENTINEL_FREE, map.first_free);

    // Stale handle with generation 65535 must be permanently rejected.
    try testing.expect(map.get(max_handle) == null);
    try testing.expect(map.remove(max_handle) == null);

    // Next insertion must allocate a fresh slot (slot index 1) rather than recycling slot 0.
    const h2 = try map.insert(1, 200, false);
    const decoded2 = (Value{ .raw = h2 }).decodeHandle();
    try testing.expectEqual(@as(u20, 1), decoded2.slot_index);
    try testing.expectEqual(@as(u16, 1), decoded2.generation);
}

test "generational_slot_map retires detached slot on generation exhaustion" {
    const testing = std.testing;
    var map = GenerationalSlotMap(u32).init(testing.allocator);
    defer map.deinit();

    const handle = try map.insert(7, 99, false);
    map.slots.items[0].generation = std.math.maxInt(u16);
    const exhausted_handle = Value.fromHandle(7, std.math.maxInt(u16), 0).raw;
    try testing.expect(map.get(exhausted_handle) != null);

    const detached = map.detachFirstForInstance(7).?;
    try testing.expectEqual(@as(u32, 99), detached.value);
    try testing.expectEqual(@as(u16, 0), map.slots.items[0].generation);
    try testing.expectEqual(hyper_box.SENTINEL_FREE, map.first_free);
    try testing.expect(map.get(exhausted_handle) == null);
    try testing.expect(map.get(handle) == null);

    const replacement = Value{ .raw = try map.insert(7, 100, false) };
    try testing.expectEqual(@as(u20, 1), replacement.decodeHandle().slot_index);
}

test "hyper_box64 rejects out-of-range SSO length and corrupt inline tags" {
    const testing = std.testing;
    const corrupt_val = Value{ .raw = 0xFFFE_0700_0000_0000 };
    try testing.expect(!corrupt_val.isSso());
    try testing.expectEqual(@as(usize, 0), corrupt_val.ssoLength());
    try testing.expectEqual(@as(u8, 0), corrupt_val.asSsoBytes().len);
    try testing.expect(!corrupt_val.isPrimitive());

    var buf: [6]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), corrupt_val.copySso(&buf));
    try testing.expectEqualStrings("", corrupt_val.asSsoSlice());

    const valid_val = Value.fromSso("hello").?;
    try testing.expect(valid_val.isSso());
    try testing.expectEqual(@as(usize, 5), valid_val.ssoLength());
    try testing.expectEqual(@as(u8, 5), valid_val.asSsoBytes().len);
    try testing.expect(valid_val.isPrimitive());
}
