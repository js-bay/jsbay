const std = @import("std");
const lifecycle = @import("../backend/jsc/lifecycle.zig");
const values = @import("../backend/jsc/value.zig");
const datatypes = @import("../backend/jsc/datatypes.zig");
const common = @import("../backend/jsc/common.zig");
const jsc = common.jsc;

test "JSC BigInt fallback matches native modulo for negative and wide integers" {
    const runtime = lifecycle.newRuntime() orelse return error.OutOfMemory;
    defer lifecycle.freeRuntime(runtime);
    const ctx = lifecycle.newContext(runtime) orelse return error.OutOfMemory;
    defer lifecycle.freeContext(ctx);
    defer datatypes.setForceBigIntFallbackForTesting(false);
    const cases = [_]struct { expression: [:0]const u8, bits: u64 }{
        .{ .expression = "0n", .bits = 0 },
        .{ .expression = "-1n", .bits = std.math.maxInt(u64) },
        .{ .expression = "-9223372036854775808n", .bits = 1 << 63 },
        .{ .expression = "9223372036854775807n", .bits = std.math.maxInt(i64) },
        .{ .expression = "18446744073709551615n", .bits = std.math.maxInt(u64) },
        .{ .expression = "18446744073709551616n", .bits = 0 },
        .{ .expression = "1208925819614629174706177n", .bits = 1 },
        .{ .expression = "-1208925819614629174706177n", .bits = std.math.maxInt(u64) },
    };
    for (cases) |case| {
        const source = common.jsStringFromSlice(case.expression) orelse return error.OutOfMemory;
        defer jsc.JSStringRelease(source);
        var exception: jsc.JSValueRef = null;
        const value = jsc.JSEvaluateScript(ctx, source, null, null, 1, &exception);
        try std.testing.expect(exception == null);
        jsc.JSValueProtect(ctx, value);
        defer jsc.JSValueUnprotect(ctx, value);
        datatypes.setForceBigIntFallbackForTesting(false);
        const native_unsigned = datatypes.jscToBigIntU64(ctx, value);
        const native_signed = datatypes.jscToBigIntI64(ctx, value);
        datatypes.setForceBigIntFallbackForTesting(true);
        try std.testing.expectEqual(@as(?u64, case.bits), datatypes.jscToBigIntU64(ctx, value));
        try std.testing.expectEqual(@as(?i64, @bitCast(case.bits)), datatypes.jscToBigIntI64(ctx, value));
        try std.testing.expectEqual(native_unsigned, datatypes.jscToBigIntU64(ctx, value));
        try std.testing.expectEqual(native_signed, datatypes.jscToBigIntI64(ctx, value));
    }
}

test "JSC BigInt absence permits full intrinsic capture and ordinary evaluation" {
    const runtime = lifecycle.newRuntime() orelse return error.OutOfMemory;
    defer lifecycle.freeRuntime(runtime);
    const ctx = jsc.JSGlobalContextCreateInGroup(runtime, null);
    try std.testing.expect(ctx != null);
    defer jsc.JSGlobalContextRelease(ctx);
    const remove = common.jsStringFromSlice("delete globalThis.BigInt") orelse return error.OutOfMemory;
    defer jsc.JSStringRelease(remove);
    var exception: jsc.JSValueRef = null;
    _ = jsc.JSEvaluateScript(ctx, remove, null, null, 1, &exception);
    try std.testing.expect(exception == null);
    try std.testing.expect(values.captureFunctionApply(ctx));
    defer values.releaseFunctionApply(ctx);
    try std.testing.expect(values.bigIntConstructor(ctx) == null);
    try std.testing.expect(values.isBigIntFunction(ctx) == null);
    datatypes.setForceBigIntFallbackForTesting(true);
    defer datatypes.setForceBigIntFallbackForTesting(false);
    const unavailable = datatypes.jscNewBigIntI64(ctx, 1);
    try std.testing.expect(jsc.JSValueIsUndefined(ctx, unavailable));
    const source = common.jsStringFromSlice("40 + 2") orelse return error.OutOfMemory;
    defer jsc.JSStringRelease(source);
    const result = jsc.JSEvaluateScript(ctx, source, null, null, 1, &exception);
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 42), jsc.JSValueToNumber(ctx, result, &exception));
    try std.testing.expect(exception == null);
}
