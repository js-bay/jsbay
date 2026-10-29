//! Tests for ArrayBuffer + TypedArray marshaling through NativeArgs / NativeResult.
//!
//! These tests exercise only the public surface: NativeArgs helpers on the receiver side and NativeResult variants on the sender side. They behave identically across backends.
//!

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const value = @import("../value/root.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

// ========================================================================
// Globals for smuggling observations out of handlers.
// ========================================================================
var g_len: ?usize = null;
var g_sum_i32: ?i64 = null;
var g_sum_f32: ?f32 = null;
var g_sum_f64: ?f64 = null;
var g_first_byte: ?u8 = null;
var g_last_byte: ?u8 = null;
var g_is_ab: ?bool = null;
var g_is_ta: ?bool = null;
var g_kind_is_uint8: ?bool = null;

fn resetGlobals() void {
    g_len = null;
    g_sum_i32 = null;
    g_sum_f32 = null;
    g_sum_f64 = null;
    g_first_byte = null;
    g_last_byte = null;
    g_is_ab = null;
    g_is_ta = null;
    g_kind_is_uint8 = null;
}

// ========================================================================
// Handlers that return ArrayBuffer / TypedArray.
// ========================================================================

fn hReturnU8Array(_: i32, _: value.NativeArgs) value.NativeResult {
    // Static data referenced directly; free_after_copy=false.
    const static = [_]u8{ 1, 2, 3, 4, 5 };
    return .{ .typed_array = .{ .kind = .uint8, .bytes = static[0..] } };
}

fn hReturnI32Array(_: i32, _: value.NativeArgs) value.NativeResult {
    // Heap copy so we exercise free_after_copy=true.
    const src = [_]i32{ 10, 20, 30, 40 };
    const buf = std.heap.c_allocator.alloc(u8, src.len * @sizeOf(i32)) catch return .null_val;
    @memcpy(buf, std.mem.sliceAsBytes(&src));
    return .{ .typed_array = .{ .kind = .int32, .bytes = buf, .free_after_copy = true } };
}

fn hReturnF32Array(_: i32, _: value.NativeArgs) value.NativeResult {
    const src = [_]f32{ 1.5, 2.5, 3.5 };
    const byte_ptr: [*]const u8 = @ptrCast(&src);
    const bytes = byte_ptr[0 .. src.len * @sizeOf(f32)];
    return .{ .typed_array = .{ .kind = .float32, .bytes = bytes } };
}

fn hReturnF64Array(_: i32, _: value.NativeArgs) value.NativeResult {
    const src = [_]f64{ 0.25, 0.5, 0.75, 1.0 };
    const byte_ptr: [*]const u8 = @ptrCast(&src);
    const bytes = byte_ptr[0 .. src.len * @sizeOf(f64)];
    return .{ .typed_array = .{ .kind = .float64, .bytes = bytes } };
}

fn hReturnArrayBuffer(_: i32, _: value.NativeArgs) value.NativeResult {
    const src = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    return .{ .array_buffer = .{ .bytes = src[0..] } };
}

fn hReturnEmptyArrayBuffer(_: i32, _: value.NativeArgs) value.NativeResult {
    const empty: []const u8 = &[_]u8{};
    return .{ .array_buffer = .{ .bytes = empty } };
}

// ========================================================================
// Handlers that consume ArrayBuffer / TypedArray.
// ========================================================================

fn hReadU8Bytes(_: i32, args: value.NativeArgs) value.NativeResult {
    const view = args.getTypedArray(0) orelse return .null_val;
    const slice = view.asSlice(u8) orelse return .null_val;
    g_len = slice.len;
    if (slice.len > 0) {
        g_first_byte = slice[0];
        g_last_byte = slice[slice.len - 1];
    }
    return .{ .number = @floatFromInt(slice.len) };
}

fn hSumI32(_: i32, args: value.NativeArgs) value.NativeResult {
    const view = args.getTypedArray(0) orelse return .null_val;
    const slice = view.asSlice(i32) orelse return .null_val;
    var sum: i64 = 0;
    for (slice) |v| sum += v;
    g_sum_i32 = sum;
    return .{ .number = @floatFromInt(sum) };
}

fn hSumF32(_: i32, args: value.NativeArgs) value.NativeResult {
    const view = args.getTypedArray(0) orelse return .null_val;
    const slice = view.asSlice(f32) orelse return .null_val;
    var sum: f32 = 0.0;
    for (slice) |v| sum += v;
    g_sum_f32 = sum;
    return .{ .number = @floatCast(sum) };
}

fn hSumF64(_: i32, args: value.NativeArgs) value.NativeResult {
    const view = args.getTypedArray(0) orelse return .null_val;
    const slice = view.asSlice(f64) orelse return .null_val;
    var sum: f64 = 0.0;
    for (slice) |v| sum += v;
    g_sum_f64 = sum;
    return .{ .number = sum };
}

fn hReadArrayBufferLen(_: i32, args: value.NativeArgs) value.NativeResult {
    const bytes = args.getArrayBufferBytes(0) orelse return .null_val;
    g_len = bytes.len;
    return .{ .number = @floatFromInt(bytes.len) };
}

fn hSumAbBytes(_: i32, args: value.NativeArgs) value.NativeResult {
    const bytes = args.getArrayBufferBytes(0) orelse return .null_val;
    var sum: u64 = 0;
    for (bytes) |b| sum += b;
    return .{ .number = @floatFromInt(sum) };
}

fn hProbeKinds(_: i32, args: value.NativeArgs) value.NativeResult {
    g_is_ab = args.isArrayBuffer(0);
    g_is_ta = args.isTypedArray(0);
    if (args.getTypedArray(0)) |view| {
        g_kind_is_uint8 = view.kind == .uint8;
    } else {
        g_kind_is_uint8 = null;
    }
    return .undefined_val;
}

fn hRejectNonAb(_: i32, args: value.NativeArgs) value.NativeResult {
    if (args.getArrayBufferBytes(0)) |b| {
        _ = b;
        return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

fn hRejectNonTa(_: i32, args: value.NativeArgs) value.NativeResult {
    if (args.getTypedArray(0)) |_| return .{ .boolean = true };
    return .{ .boolean = false };
}

// ========================================================================
// 1) Native -> JS: Uint8Array round-trip
// ========================================================================

test "typedarray: native returns Uint8Array; JS observes length and elements" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "makeU8", &hReturnU8Array);
            try helpers.expectEvalEquals(inst, "String(makeU8() instanceof Uint8Array)", "true");
            try helpers.expectEvalEquals(inst, "String(makeU8().length)", "5");
            try helpers.expectEvalEquals(inst, "String(makeU8()[0])", "1");
            try helpers.expectEvalEquals(inst, "String(makeU8()[4])", "5");
            try helpers.expectEvalEquals(inst, "String(makeU8().byteLength)", "5");
        }
    }.run);
}

// ========================================================================
// 2) JS -> Native: Uint8Array read
// ========================================================================

test "typedarray: JS passes Uint8Array; native reads []const u8" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readU8", &hReadU8Bytes);
            try helpers.expectEvalEquals(inst, "String(readU8(new Uint8Array([10,20,30])))", "3");
            try testing.expectEqual(@as(?usize, 3), g_len);
            try testing.expectEqual(@as(?u8, 10), g_first_byte);
            try testing.expectEqual(@as(?u8, 30), g_last_byte);
        }
    }.run);
}

// ========================================================================
// 3) ArrayBuffer round-trip: native returns AB, JS verifies bytes
// ========================================================================

test "typedarray: native returns ArrayBuffer; JS reads through Uint8Array view" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkAB", &hReturnArrayBuffer);
            try helpers.expectEvalEquals(inst, "String(mkAB() instanceof ArrayBuffer)", "true");
            try helpers.expectEvalEquals(inst, "String(mkAB().byteLength)", "4");
            try helpers.expectEvalEquals(inst, "String(new Uint8Array(mkAB())[0])", "222"); // 0xDE
            try helpers.expectEvalEquals(inst, "String(new Uint8Array(mkAB())[3])", "239"); // 0xEF
        }
    }.run);
}

// ========================================================================
// 4) JS creates ArrayBuffer, native reads len + sum
// ========================================================================

test "typedarray: JS passes ArrayBuffer; native reads byte length and content" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "abLen", &hReadArrayBufferLen);
            value.registerFunction(inst, null, "abSum", &hSumAbBytes);
            try helpers.expectEvalEquals(inst, "(function(){const ab=new ArrayBuffer(16); return String(abLen(ab));})()", "16");
            try testing.expectEqual(@as(?usize, 16), g_len);
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const ab=new ArrayBuffer(4);
                \\  const v=new Uint8Array(ab);
                \\  v[0]=1; v[1]=2; v[2]=3; v[3]=4;
                \\  return String(abSum(ab));
                \\})()
            , "10");
        }
    }.run);
}

// ========================================================================
// 5) Int32Array round-trip
// ========================================================================

test "typedarray: native returns Int32Array; JS observes elements" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkI32", &hReturnI32Array);
            try helpers.expectEvalEquals(inst, "String(mkI32() instanceof Int32Array)", "true");
            try helpers.expectEvalEquals(inst, "String(mkI32().length)", "4");
            try helpers.expectEvalEquals(inst, "String(mkI32()[2])", "30");
        }
    }.run);
}

test "typedarray: JS passes Int32Array; native sums elements" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "sumI32", &hSumI32);
            try helpers.expectEvalEquals(inst, "String(sumI32(new Int32Array([1,2,3,4,5])))", "15");
            try testing.expectEqual(@as(?i64, 15), g_sum_i32);
        }
    }.run);
}

// ========================================================================
// 6) Float32Array round-trip
// ========================================================================

test "typedarray: native returns Float32Array; JS observes values" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkF32", &hReturnF32Array);
            try helpers.expectEvalEquals(inst, "String(mkF32() instanceof Float32Array)", "true");
            try helpers.expectEvalEquals(inst, "String(mkF32().length)", "3");
            try helpers.expectEvalEquals(inst, "String(mkF32()[1])", "2.5");
        }
    }.run);
}

test "typedarray: JS passes Float32Array; native sums elements" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "sumF32", &hSumF32);
            try helpers.expectEvalEquals(inst, "String(sumF32(new Float32Array([0.5, 1.5, 2.0])))", "4");
            try testing.expect(g_sum_f32 != null);
            if (g_sum_f32) |s| try testing.expect(@abs(s - 4.0) < 1e-6);
        }
    }.run);
}

// ========================================================================
// 7) Float64Array round-trip
// ========================================================================

test "typedarray: native returns Float64Array; JS observes values" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkF64", &hReturnF64Array);
            try helpers.expectEvalEquals(inst, "String(mkF64() instanceof Float64Array)", "true");
            try helpers.expectEvalEquals(inst, "String(mkF64().length)", "4");
            try helpers.expectEvalEquals(inst, "String(mkF64()[3])", "1");
        }
    }.run);
}

test "typedarray: JS passes Float64Array; native sums elements" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "sumF64", &hSumF64);
            try helpers.expectEvalEquals(inst, "String(sumF64(new Float64Array([1.1, 2.2, 3.3])))", "6.6");
            try testing.expect(g_sum_f64 != null);
            if (g_sum_f64) |s| try testing.expect(@abs(s - 6.6) < 1e-9);
        }
    }.run);
}

// ========================================================================
// 8) Subview: JS constructs TypedArray over ArrayBuffer with offset/len
// ========================================================================

test "typedarray: JS TypedArray with byteOffset/length; native sees only the sub-view" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readU8", &hReadU8Bytes);
            // ArrayBuffer of 10 bytes, view covers bytes [2..6].
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const ab=new ArrayBuffer(10);
                \\  const full=new Uint8Array(ab);
                \\  for(let i=0;i<10;i++) full[i]=i*10;
                \\  const sub=new Uint8Array(ab, 2, 4);
                \\  return String(readU8(sub));
                \\})()
            , "4");
            try testing.expectEqual(@as(?usize, 4), g_len);
            try testing.expectEqual(@as(?u8, 20), g_first_byte); // sub[0] = full[2]=20
            try testing.expectEqual(@as(?u8, 50), g_last_byte); // sub[3] = full[5]=50
        }
    }.run);
}

// ========================================================================
// 9) Wrong-type rejections
// ========================================================================

test "typedarray: getArrayBufferBytes returns null for non-ArrayBuffer values" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "isAb", &hRejectNonAb);
            try helpers.expectEvalEquals(inst, "String(isAb([1,2,3]))", "false");
            try helpers.expectEvalEquals(inst, "String(isAb('string'))", "false");
            try helpers.expectEvalEquals(inst, "String(isAb(42))", "false");
            try helpers.expectEvalEquals(inst, "String(isAb(new Uint8Array([1])))", "false"); // TypedArray is NOT an ArrayBuffer
            try helpers.expectEvalEquals(inst, "String(isAb(new ArrayBuffer(4)))", "true");
        }
    }.run);
}

test "typedarray: getTypedArray returns null for plain arrays and AB" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "isTa", &hRejectNonTa);
            try helpers.expectEvalEquals(inst, "String(isTa([1,2,3]))", "false");
            try helpers.expectEvalEquals(inst, "String(isTa(new ArrayBuffer(4)))", "false");
            try helpers.expectEvalEquals(inst, "String(isTa(new Uint8Array([1,2,3])))", "true");
        }
    }.run);
}

// ========================================================================
// 10) Predicates: isArrayBuffer / isTypedArray
// ========================================================================

test "typedarray: isArrayBuffer and isTypedArray discriminate correctly" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "probe", &hProbeKinds);

            // Uint8Array: TA=true, AB=false, kind=.uint8
            try helpers.evalOk(inst, "probe(new Uint8Array([9]))");
            try testing.expectEqual(@as(?bool, false), g_is_ab);
            try testing.expectEqual(@as(?bool, true), g_is_ta);
            try testing.expectEqual(@as(?bool, true), g_kind_is_uint8);

            // ArrayBuffer: AB=true, TA=false
            try helpers.evalOk(inst, "probe(new ArrayBuffer(2))");
            try testing.expectEqual(@as(?bool, true), g_is_ab);
            try testing.expectEqual(@as(?bool, false), g_is_ta);
            try testing.expectEqual(@as(?bool, null), g_kind_is_uint8);

            // Int32Array: TA=true, kind != uint8
            try helpers.evalOk(inst, "probe(new Int32Array([1]))");
            try testing.expectEqual(@as(?bool, true), g_is_ta);
            try testing.expectEqual(@as(?bool, false), g_kind_is_uint8);
        }
    }.run);
}

// ========================================================================
// 11) Empty ArrayBuffer — edge case
// ========================================================================

test "typedarray: empty ArrayBuffer round-trip gives zero byte length" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkEmpty", &hReturnEmptyArrayBuffer);
            value.registerFunction(inst, null, "abLen", &hReadArrayBufferLen);
            try helpers.expectEvalEquals(inst, "String(mkEmpty().byteLength)", "0");
            try helpers.expectEvalEquals(inst, "String(abLen(mkEmpty()))", "0");
            try testing.expectEqual(@as(?usize, 0), g_len);
        }
    }.run);
}

// ========================================================================
// 12) TypedArrayView.asSlice: wrong element type returns null
// ========================================================================

test "typedarray: TypedArrayView.asSlice rejects mismatched element type" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        const Inner = struct {
            fn handler(_: i32, args: value.NativeArgs) value.NativeResult {
                const view = args.getTypedArray(0) orelse return .null_val;
                // view is Uint8Array but caller asks for i32 — should be null.
                if (view.asSlice(i32)) |_| return .{ .boolean = true };
                return .{ .boolean = false };
            }
        };
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "check", &Inner.handler);
            try helpers.expectEvalEquals(inst, "String(check(new Uint8Array([1,2])))", "false");
        }
    }.run);
}

// ========================================================================
// 14) elementCount helper returns the expected number of elements
// ========================================================================

test "typedarray: elementCount reports the right count for Int32Array" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        const Inner = struct {
            fn handler(_: i32, args: value.NativeArgs) value.NativeResult {
                const view = args.getTypedArray(0) orelse return .null_val;
                return .{ .number = @floatFromInt(view.elementCount()) };
            }
        };
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "count", &Inner.handler);
            try helpers.expectEvalEquals(inst, "String(count(new Int32Array([1,2,3,4,5,6,7])))", "7");
        }
    }.run);
}

// ========================================================================
// Extended TypedArray coverage: Int8 / Int16 / Uint16 / Uint32 / BigInt64 / BigUint64 round-trips, non-zero byte offsets, and a shared rejection test for non-TA values. Globals below are private to this section so they don't collide with the earlier suite.
// ========================================================================

var g_sum_i8: ?i64 = null;
var g_sum_i16: ?i64 = null;
var g_sum_u16: ?u64 = null;
var g_sum_u32: ?u64 = null;
var g_sum_big_i64: ?i64 = null;
var g_sum_big_u64: ?u64 = null;
var g_first_i8: ?i8 = null;
var g_first_i16: ?i16 = null;
var g_first_u16: ?u16 = null;
var g_first_u32: ?u32 = null;
var g_first_big_i64: ?i64 = null;
var g_first_big_u64: ?u64 = null;
var g_reject_was_null: ?bool = null;

fn resetExtGlobals() void {
    g_sum_i8 = null;
    g_sum_i16 = null;
    g_sum_u16 = null;
    g_sum_u32 = null;
    g_sum_big_i64 = null;
    g_sum_big_u64 = null;
    g_first_i8 = null;
    g_first_i16 = null;
    g_first_u16 = null;
    g_first_u32 = null;
    g_first_big_i64 = null;
    g_first_big_u64 = null;
    g_reject_was_null = null;
}

// ---- Handlers for new TA types ----

fn hReturnI8Array(_: i32, _: value.NativeArgs) value.NativeResult {
    const src = [_]i8{ -1, -2, 127, -128, 0 };
    const byte_ptr: [*]const u8 = @ptrCast(&src);
    const bytes = byte_ptr[0 .. src.len * @sizeOf(i8)];
    return .{ .typed_array = .{ .kind = .int8, .bytes = bytes } };
}

fn hReturnI16Array(_: i32, _: value.NativeArgs) value.NativeResult {
    const src = [_]i16{ -32768, -1, 0, 1, 32767 };
    const byte_ptr: [*]const u8 = @ptrCast(&src);
    const bytes = byte_ptr[0 .. src.len * @sizeOf(i16)];
    return .{ .typed_array = .{ .kind = .int16, .bytes = bytes } };
}

fn hReturnU16Array(_: i32, _: value.NativeArgs) value.NativeResult {
    const src = [_]u16{ 0, 1, 65535, 42 };
    const byte_ptr: [*]const u8 = @ptrCast(&src);
    const bytes = byte_ptr[0 .. src.len * @sizeOf(u16)];
    return .{ .typed_array = .{ .kind = .uint16, .bytes = bytes } };
}

fn hReturnU32Array(_: i32, _: value.NativeArgs) value.NativeResult {
    const src = [_]u32{ 0, 1, 4_294_967_295, 12345 };
    const byte_ptr: [*]const u8 = @ptrCast(&src);
    const bytes = byte_ptr[0 .. src.len * @sizeOf(u32)];
    return .{ .typed_array = .{ .kind = .uint32, .bytes = bytes } };
}

fn hReturnBigI64Array(_: i32, _: value.NativeArgs) value.NativeResult {
    const src = [_]i64{ -9_000_000_000_000, 0, 1, 9_000_000_000_000 };
    const byte_ptr: [*]const u8 = @ptrCast(&src);
    const bytes = byte_ptr[0 .. src.len * @sizeOf(i64)];
    return .{ .typed_array = .{ .kind = .big_int64, .bytes = bytes } };
}

fn hReturnBigU64Array(_: i32, _: value.NativeArgs) value.NativeResult {
    const src = [_]u64{ 0, 1, 18_446_744_073_709_551_615, 9_000_000_000_000 };
    const byte_ptr: [*]const u8 = @ptrCast(&src);
    const bytes = byte_ptr[0 .. src.len * @sizeOf(u64)];
    return .{ .typed_array = .{ .kind = .big_uint64, .bytes = bytes } };
}

fn hSumI8(_: i32, args: value.NativeArgs) value.NativeResult {
    const view = args.getTypedArray(0) orelse return .null_val;
    const slice = view.asSlice(i8) orelse return .null_val;
    var sum: i64 = 0;
    for (slice) |v| sum += v;
    g_sum_i8 = sum;
    if (slice.len > 0) g_first_i8 = slice[0];
    return .{ .number = @floatFromInt(sum) };
}

fn hSumI16(_: i32, args: value.NativeArgs) value.NativeResult {
    const view = args.getTypedArray(0) orelse return .null_val;
    const slice = view.asSlice(i16) orelse return .null_val;
    var sum: i64 = 0;
    for (slice) |v| sum += v;
    g_sum_i16 = sum;
    if (slice.len > 0) g_first_i16 = slice[0];
    return .{ .number = @floatFromInt(sum) };
}

fn hSumU16(_: i32, args: value.NativeArgs) value.NativeResult {
    const view = args.getTypedArray(0) orelse return .null_val;
    const slice = view.asSlice(u16) orelse return .null_val;
    var sum: u64 = 0;
    for (slice) |v| sum += v;
    g_sum_u16 = sum;
    if (slice.len > 0) g_first_u16 = slice[0];
    return .{ .number = @floatFromInt(sum) };
}

fn hSumU32(_: i32, args: value.NativeArgs) value.NativeResult {
    const view = args.getTypedArray(0) orelse return .null_val;
    const slice = view.asSlice(u32) orelse return .null_val;
    var sum: u64 = 0;
    for (slice) |v| sum += v;
    g_sum_u32 = sum;
    if (slice.len > 0) g_first_u32 = slice[0];
    return .{ .number = @floatFromInt(sum) };
}

fn hSumBigI64(_: i32, args: value.NativeArgs) value.NativeResult {
    const view = args.getTypedArray(0) orelse return .null_val;
    const slice = view.asSlice(i64) orelse return .null_val;
    var sum: i64 = 0;
    for (slice) |v| sum +%= v;
    g_sum_big_i64 = sum;
    if (slice.len > 0) g_first_big_i64 = slice[0];
    return .{ .big_int_i64 = sum };
}

fn hSumBigU64(_: i32, args: value.NativeArgs) value.NativeResult {
    const view = args.getTypedArray(0) orelse return .null_val;
    const slice = view.asSlice(u64) orelse return .null_val;
    var sum: u64 = 0;
    for (slice) |v| sum +%= v;
    g_sum_big_u64 = sum;
    if (slice.len > 0) g_first_big_u64 = slice[0];
    return .{ .big_int_u64 = sum };
}

// Rejection handler shared across types: returns boolean indicating whether getTypedArray returned null.
fn hTypedArrayIsNull(_: i32, args: value.NativeArgs) value.NativeResult {
    const was_null = args.getTypedArray(0) == null;
    g_reject_was_null = was_null;
    return .{ .boolean = was_null };
}

// --- Int8Array ---

test "typedarray: Int8Array native->JS->native round-trip preserves negative values" {
    resetExtGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkI8", &hReturnI8Array);
            value.registerFunction(inst, null, "sumI8", &hSumI8);
            try helpers.expectEvalEquals(inst, "String(mkI8() instanceof Int8Array)", "true");
            try helpers.expectEvalEquals(inst, "String(mkI8().length)", "5");
            try helpers.expectEvalEquals(inst, "String(mkI8()[0])", "-1");
            try helpers.expectEvalEquals(inst, "String(mkI8()[3])", "-128");
            try helpers.expectEvalEquals(inst, "String(sumI8(mkI8()))", "-4");
            try testing.expectEqual(@as(?i64, -4), g_sum_i8);
            try testing.expectEqual(@as(?i8, -1), g_first_i8);
        }
    }.run);
}

// --- Int16Array ---

test "typedarray: Int16Array native->JS->native round-trip with boundary values" {
    resetExtGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkI16", &hReturnI16Array);
            value.registerFunction(inst, null, "sumI16", &hSumI16);
            try helpers.expectEvalEquals(inst, "String(mkI16() instanceof Int16Array)", "true");
            try helpers.expectEvalEquals(inst, "String(mkI16().length)", "5");
            try helpers.expectEvalEquals(inst, "String(mkI16()[0])", "-32768");
            try helpers.expectEvalEquals(inst, "String(mkI16()[4])", "32767");
            try helpers.expectEvalEquals(inst, "String(sumI16(mkI16()))", "-1");
            try testing.expectEqual(@as(?i64, -1), g_sum_i16);
            try testing.expectEqual(@as(?i16, -32768), g_first_i16);
        }
    }.run);
}

// --- Uint16Array ---

test "typedarray: Uint16Array round-trip reaches u16::MAX" {
    resetExtGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkU16", &hReturnU16Array);
            value.registerFunction(inst, null, "sumU16", &hSumU16);
            try helpers.expectEvalEquals(inst, "String(mkU16() instanceof Uint16Array)", "true");
            try helpers.expectEvalEquals(inst, "String(mkU16()[2])", "65535");
            try helpers.expectEvalEquals(inst, "String(sumU16(new Uint16Array([65535, 1])))", "65536");
            try testing.expectEqual(@as(?u64, 65536), g_sum_u16);
            try testing.expectEqual(@as(?u16, 65535), g_first_u16);
        }
    }.run);
}

// --- Uint32Array ---

test "typedarray: Uint32Array round-trip reaches u32::MAX" {
    resetExtGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkU32", &hReturnU32Array);
            value.registerFunction(inst, null, "sumU32", &hSumU32);
            try helpers.expectEvalEquals(inst, "String(mkU32() instanceof Uint32Array)", "true");
            try helpers.expectEvalEquals(inst, "String(mkU32()[2])", "4294967295");
            try helpers.expectEvalEquals(inst, "String(sumU32(new Uint32Array([1, 2, 4294967295])))", "4294967298");
            try testing.expectEqual(@as(?u64, 4_294_967_298), g_sum_u32);
            try testing.expectEqual(@as(?u32, 1), g_first_u32);
        }
    }.run);
}

// --- BigInt64Array ---

test "typedarray: BigInt64Array carries values beyond 2^53" {
    resetExtGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkBigI", &hReturnBigI64Array);
            value.registerFunction(inst, null, "sumBigI", &hSumBigI64);
            try helpers.expectEvalEquals(inst, "String(mkBigI() instanceof BigInt64Array)", "true");
            try helpers.expectEvalEquals(inst, "String(mkBigI().length)", "4");
            try helpers.expectEvalEquals(inst, "String(mkBigI()[0])", "-9000000000000");
            try helpers.expectEvalEquals(inst, "String(mkBigI()[3])", "9000000000000");
            // Sum should exercise an explicitly-built array.
            try helpers.expectEvalEquals(
                inst,
                "String(sumBigI(new BigInt64Array([1n, 2n, 9007199254740993n])))",
                "9007199254740996",
            );
            try testing.expectEqual(@as(?i64, 9_007_199_254_740_996), g_sum_big_i64);
            try testing.expectEqual(@as(?i64, 1), g_first_big_i64);
        }
    }.run);
}

// --- BigUint64Array ---

test "typedarray: BigUint64Array carries values near u64::MAX" {
    resetExtGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkBigU", &hReturnBigU64Array);
            value.registerFunction(inst, null, "sumBigU", &hSumBigU64);
            try helpers.expectEvalEquals(inst, "String(mkBigU() instanceof BigUint64Array)", "true");
            try helpers.expectEvalEquals(inst, "String(mkBigU()[2])", "18446744073709551615");
            // sum wraps modulo 2^64; feed two values with no overflow for a clean round-trip: 2^63 + (2^63 - 1) = 2^64 - 1 = u64::MAX.
            try helpers.expectEvalEquals(
                inst,
                "String(sumBigU(new BigUint64Array([9223372036854775808n, 9223372036854775807n])))",
                "18446744073709551615",
            );
            try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), g_sum_big_u64);
            try testing.expectEqual(@as(?u64, 9_223_372_036_854_775_808), g_first_big_u64);
        }
    }.run);
}

// --- Non-zero byteOffset across all new types ---

test "typedarray: non-zero byteOffset views deliver the sub-range for new TA kinds" {
    resetExtGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "sumI8", &hSumI8);
            value.registerFunction(inst, null, "sumU32", &hSumU32);
            value.registerFunction(inst, null, "sumBigI", &hSumBigI64);
            // Int8Array sub-view: full=[10,20,30,40,50,60]; sub[2..5]=[30,40,50] -> sum=120
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const full = new Int8Array([10,20,30,40,50,60]);
                \\  const sub  = new Int8Array(full.buffer, 2, 3);
                \\  return String(sumI8(sub));
                \\})()
            , "120");
            try testing.expectEqual(@as(?i64, 120), g_sum_i8);
            try testing.expectEqual(@as(?i8, 30), g_first_i8);

            // Uint32Array sub-view: [100,200,300,400]; sub[1..3]=[200,300] -> sum=500
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const full = new Uint32Array([100,200,300,400]);
                \\  const sub  = new Uint32Array(full.buffer, 4, 2);
                \\  return String(sumU32(sub));
                \\})()
            , "500");
            try testing.expectEqual(@as(?u64, 500), g_sum_u32);

            // BigInt64Array sub-view: [5n,6n,7n,8n]; sub[1..4]=[6,7,8] -> sum=21
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const full = new BigInt64Array([5n,6n,7n,8n]);
                \\  const sub  = new BigInt64Array(full.buffer, 8, 3);
                \\  return String(sumBigI(sub));
                \\})()
            , "21");
            try testing.expectEqual(@as(?i64, 21), g_sum_big_i64);
        }
    }.run);
}

// --- Non-TA inputs return null from getTypedArray ---

test "typedarray: getTypedArray returns null for non-TypedArray values across inputs" {
    resetExtGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "probe", &hTypedArrayIsNull);
            // A plain number, string, object, array, ArrayBuffer and a DataView should all be rejected. A Uint8Array should not.
            try helpers.expectEvalEquals(inst, "String(probe(42))", "true");
            try helpers.expectEvalEquals(inst, "String(probe('x'))", "true");
            try helpers.expectEvalEquals(inst, "String(probe({}))", "true");
            try helpers.expectEvalEquals(inst, "String(probe([1,2,3]))", "true");
            try helpers.expectEvalEquals(inst, "String(probe(new ArrayBuffer(4)))", "true");
            try helpers.expectEvalEquals(inst, "String(probe(new DataView(new ArrayBuffer(4))))", "true");
            try helpers.expectEvalEquals(inst, "String(probe(new Uint8Array([1])))", "false");
        }
    }.run);
}

// In-place reverse and sort must work on 64-bit element types backed by shared storage in the QuickJS family or plain storage in JSC. SharedArrayBuffer and growable shared buffers are not exercised on JSC.
test "typedarray: reverse and sort of 64-bit views work over a shared or plain buffer" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            const buffer_ctor = comptime if (backend.isQuickJsApiBackend(backend.active_backend)) "SharedArrayBuffer" else "ArrayBuffer";
            const script =
                "(function () {" ++
                "  var f = new Float64Array(new " ++ buffer_ctor ++ "(32));" ++
                "  f.set([3.5, -1, 2.25, 0]);" ++
                "  f.reverse();" ++
                "  var rev = Array.prototype.join.call(f, ',');" ++
                "  f.sort();" ++
                "  var sorted = Array.prototype.join.call(f, ',');" ++
                "  var b = new BigInt64Array(new " ++ buffer_ctor ++ "(32));" ++
                "  b.set([5n, -(2n ** 62n), 2n ** 62n, 0n]);" ++
                "  b.sort();" ++
                "  var bsorted = Array.prototype.map.call(b, String).join(',');" ++
                "  b.reverse();" ++
                "  var brev = Array.prototype.map.call(b, String).join(',');" ++
                "  var shared = f.buffer instanceof " ++ buffer_ctor ++ ";" ++
                "  return [rev, sorted, bsorted, brev, shared].join('|');" ++
                "})()";
            try helpers.expectEvalEquals(inst, script, "0,2.25,-1,3.5|-1,0,2.25,3.5|-4611686018427387904,0,5,4611686018427387904|4611686018427387904,5,0,-4611686018427387904|true");
        }
    }.run);
}
