//! Tests for Date + BigInt marshaling through NativeArgs / NativeResult and the dispatch helpers in src/value/root.zig.
//!
//! Only the public surface is exercised, so these tests behave identically under QuickJS and JSC.
//!

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const value = @import("../value/root.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

// ========================================================================
// Globals used by handlers to smuggle observations out of JS into tests.
// ========================================================================
var g_ms: ?i64 = null;
var g_is_date: ?bool = null;
var g_bi_i64: ?i64 = null;
var g_bi_u64: ?u64 = null;
var g_is_bigint: ?bool = null;

fn resetGlobals() void {
    g_ms = null;
    g_is_date = null;
    g_bi_i64 = null;
    g_bi_u64 = null;
    g_is_bigint = null;
}

// ========================================================================
// Handlers.
// ========================================================================

fn hReturnDate(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .date_ms = 1_700_000_000_000 };
}

fn hReadDate(_: i32, args: value.NativeArgs) value.NativeResult {
    g_is_date = args.isDate(0);
    if (args.toDateMs(0)) |ms| {
        g_ms = ms;
        return .{ .number = @floatFromInt(ms) };
    }
    return .null_val;
}

fn hReturnBigIntI64(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .big_int_i64 = -123_456_789_012 };
}

fn hReturnBigIntU64Max(_: i32, _: value.NativeArgs) value.NativeResult {
    // 18446744073709551615 — bigger than i64::MAX.
    return .{ .big_int_u64 = std.math.maxInt(u64) };
}

fn hReadBigIntI64(_: i32, args: value.NativeArgs) value.NativeResult {
    g_is_bigint = args.isBigInt(0);
    if (args.toBigIntI64(0)) |v| {
        g_bi_i64 = v;
        // Return as string to avoid lossy number conversion.
        const s = std.fmt.allocPrint(std.heap.c_allocator, "{d}", .{v}) catch return .null_val;
        return .{ .string = s };
    }
    return .null_val;
}

fn hReadBigIntU64(_: i32, args: value.NativeArgs) value.NativeResult {
    g_is_bigint = args.isBigInt(0);
    if (args.toBigIntU64(0)) |v| {
        g_bi_u64 = v;
        const s = std.fmt.allocPrint(std.heap.c_allocator, "{d}", .{v}) catch return .null_val;
        return .{ .string = s };
    }
    return .null_val;
}

fn hProbeBigInt(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.isBigInt(0) };
}

fn hProbeDate(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.isDate(0) };
}

// ========================================================================
// Date tests.
// ========================================================================

test "date: native returns Date; JS verifies instanceof + getTime" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkDate", &hReturnDate);
            try helpers.expectEvalEquals(inst, "String(mkDate() instanceof Date)", "true");
            try helpers.expectEvalEquals(inst, "String(mkDate().getTime())", "1700000000000");
        }
    }.run);
}

test "date: JS passes Date; native reads epoch ms via toDateMs" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readDate", &hReadDate);
            try helpers.expectEvalEquals(inst, "String(readDate(new Date(1700000000000)))", "1700000000000");
            try testing.expectEqual(@as(?bool, true), g_is_date);
            try testing.expectEqual(@as(?i64, 1_700_000_000_000), g_ms);
        }
    }.run);
}

test "date: isDate rejects non-Date values" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "probe", &hProbeDate);
            try helpers.expectEvalEquals(inst, "String(probe(42))", "false");
            try helpers.expectEvalEquals(inst, "String(probe('2024-01-01'))", "false");
            try helpers.expectEvalEquals(inst, "String(probe({}))", "false");
            try helpers.expectEvalEquals(inst, "String(probe([]))", "false");
            try helpers.expectEvalEquals(inst, "String(probe(new Date()))", "true");
        }
    }.run);
}

// ========================================================================
// BigInt tests.
// ========================================================================

test "bigint: JS passes BigInt; native reads positive i64" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readBI", &hReadBigIntI64);
            try helpers.expectEvalEquals(inst, "readBI(123n)", "123");
            try testing.expectEqual(@as(?bool, true), g_is_bigint);
            try testing.expectEqual(@as(?i64, 123), g_bi_i64);
        }
    }.run);
}

test "bigint: JS passes negative BigInt; sign is preserved" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readBI", &hReadBigIntI64);
            try helpers.expectEvalEquals(inst, "readBI(-9007199254740993n)", "-9007199254740993");
            try testing.expectEqual(@as(?i64, -9_007_199_254_740_993), g_bi_i64);
        }
    }.run);
}

test "bigint: native returns i64 BigInt; JS observes value" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkBI", &hReturnBigIntI64);
            try helpers.expectEvalEquals(inst, "String(typeof mkBI())", "bigint");
            try helpers.expectEvalEquals(inst, "String(mkBI())", "-123456789012");
            try helpers.expectEvalEquals(inst, "String(mkBI() === -123456789012n)", "true");
        }
    }.run);
}

test "bigint: u64 > i64::MAX round-trips via big_int_u64 + toBigIntU64" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkMax", &hReturnBigIntU64Max);
            value.registerFunction(inst, null, "readU64", &hReadBigIntU64);
            try helpers.expectEvalEquals(inst, "String(mkMax())", "18446744073709551615");
            try helpers.expectEvalEquals(inst, "readU64(mkMax())", "18446744073709551615");
            try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), g_bi_u64);
        }
    }.run);
}

test "bigint: isBigInt rejects non-BigInt values" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "probe", &hProbeBigInt);
            try helpers.expectEvalEquals(inst, "String(probe(42))", "false");
            try helpers.expectEvalEquals(inst, "String(probe('123'))", "false");
            try helpers.expectEvalEquals(inst, "String(probe(123n))", "true");
            try helpers.expectEvalEquals(inst, "String(probe(0n))", "true");
        }
    }.run);
}

// ========================================================================
// Low-level: exercise the dispatch helpers directly (bypass NativeArgs).
// ========================================================================

test "date: dispatch helpers newDate/toDateMs round-trip without a handler" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = value.newDateVal(ctx, 42_000);
            defer ActiveEngine.freeValue(ctx, v);
            try testing.expect(value.isDateVal(ctx, v));
            const ms = value.toDateMsVal(ctx, v) orelse return error.NoMs;
            try testing.expectEqual(@as(i64, 42_000), ms);
        }
    }.run);
}

test "bigint: dispatch helpers newBigIntI64/toBigIntI64 round-trip" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = value.newBigIntI64Val(ctx, -7_777_777_777);
            defer ActiveEngine.freeValue(ctx, v);
            try testing.expect(value.isBigIntVal(ctx, v));
            const out = value.toBigIntI64Val(ctx, v) orelse return error.NoVal;
            try testing.expectEqual(@as(i64, -7_777_777_777), out);
        }
    }.run);
}

test "bigint: (1n + 2n) === 3n" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            try helpers.expectEvalEquals(inst, "(1n + 2n) === 3n", "true");
        }
    }.run);
}
