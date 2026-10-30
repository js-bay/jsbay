//! Tests for the DataView marshaling path — construction (native -> JS), extraction (JS -> native) and the endian-aware get/set accessors on DataViewPayload. Both backends share the Zig-side bit reading / writing, so the same assertions hold under -Dbackend=quickjs_ng and -Dbackend=jsc.
//!
//! These tests exercise the public surface only: NativeResult.data_view / NativeArgs.getDataView / NativeArgs.isDataView plus DataViewPayload's getXxx / setXxx helpers. They deliberately avoid reaching into backend-specific helpers.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const value = @import("../value/root.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

fn globalValue(id: i32, name: [*:0]const u8) !ActiveEngine.Value {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    return ActiveEngine.getPropertyVal(ctx, global, name) orelse return error.MissingValue;
}

fn qjsHasNoPendingException(ctx: ActiveEngine.Context) bool {
    if (comptime backend.isJscApiBackend(backend.active_backend)) return true;
    const qjs_mod = backend.ActiveEngineModule;
    if (comptime backend.active_backend == .quickjs) {
        return qjs_mod.qjs.JS_HasException(ctx) == 0;
    }
    return !qjs_mod.qjs.JS_HasException(ctx);
}

// ========================================================================
// Globals used to smuggle observations out of handlers.
// ========================================================================

var g_i32_le: ?i32 = null;
var g_i32_be: ?i32 = null;
var g_u8: ?u8 = null;
var g_oob_was_null: ?bool = null;
var g_big_i64: ?i64 = null;
var g_f32_bits: ?u32 = null;
var g_f64_bits: ?u64 = null;
var g_is_dv: ?bool = null;

fn reset() void {
    g_i32_le = null;
    g_i32_be = null;
    g_u8 = null;
    g_oob_was_null = null;
    g_big_i64 = null;
    g_f32_bits = null;
    g_f64_bits = null;
    g_is_dv = null;
}

// ========================================================================
// Handlers
// ========================================================================

// Create a DataView over a 16-byte AB, offset 4 / length 8, with the first exposed i32 initialised to 0xDEADBEEF (little-endian) via setInt32.
fn hMakeDVWithI32(_: i32, _: value.NativeArgs) value.NativeResult {
    const buf = std.heap.c_allocator.alloc(u8, 16) catch return .null_val;
    @memset(buf, 0);
    // Fill the window with a recognisable pattern so JS can verify exactly the byteOffset/length hand-off.
    var payload: value.DataViewPayload = .{
        .buffer = .{ .bytes = buf, .free_after_copy = true },
        .byte_offset = 4,
        .byte_length = 8,
    };
    _ = payload.setInt32(0, @bitCast(@as(u32, 0xDEADBEEF)), true); // little-endian
    return .{ .data_view = payload };
}

// Read an Int32 from arg[0] at arg[1] with arg[2] endian flag, stash into g_i32_le/be.
fn hReadI32Le(_: i32, args: value.NativeArgs) value.NativeResult {
    const dv = args.getDataView(0) orelse return .null_val;
    const off_i: i32 = args.toInt32(1) orelse 0;
    const v = dv.getInt32(@intCast(off_i), true) orelse return .null_val;
    g_i32_le = v;
    return .{ .number = @floatFromInt(v) };
}

fn hReadI32Be(_: i32, args: value.NativeArgs) value.NativeResult {
    const dv = args.getDataView(0) orelse return .null_val;
    const off_i: i32 = args.toInt32(1) orelse 0;
    const v = dv.getInt32(@intCast(off_i), false) orelse return .null_val;
    g_i32_be = v;
    return .{ .number = @floatFromInt(v) };
}

// Write an Int32 big-endian into the DataView arg[0] at offset arg[1] with the value arg[2], then return the same DataView (by value).
fn hWriteI32Be(_: i32, args: value.NativeArgs) value.NativeResult {
    const dv = args.getDataView(0) orelse return .null_val;
    const off_i: i32 = args.toInt32(1) orelse 0;
    const v_i: i32 = args.toInt32(2) orelse 0;
    const ok = dv.setInt32(@intCast(off_i), v_i, false);
    return .{ .boolean = ok };
}

// Uint8 get / set — no endianness.
fn hReadU8(_: i32, args: value.NativeArgs) value.NativeResult {
    const dv = args.getDataView(0) orelse return .null_val;
    const off_i: i32 = args.toInt32(1) orelse 0;
    const v = dv.getUint8(@intCast(off_i)) orelse return .null_val;
    g_u8 = v;
    return .{ .number = @floatFromInt(v) };
}

fn hWriteU8(_: i32, args: value.NativeArgs) value.NativeResult {
    const dv = args.getDataView(0) orelse return .null_val;
    const off_i: i32 = args.toInt32(1) orelse 0;
    const v_i: i32 = args.toInt32(2) orelse 0;
    const v: u8 = @intCast(v_i & 0xFF);
    const ok = dv.setUint8(@intCast(off_i), v);
    return .{ .boolean = ok };
}

// Out-of-range read: returns null when the access would cross the window boundary. We surface that by stashing the flag and returning a boolean.
fn hOutOfRange(_: i32, args: value.NativeArgs) value.NativeResult {
    const dv = args.getDataView(0) orelse return .null_val;
    const off_i: i32 = args.toInt32(1) orelse 0;
    const got = dv.getInt32(@intCast(off_i), true);
    const was_null = got == null;
    g_oob_was_null = was_null;
    return .{ .boolean = was_null };
}

// BigInt64 round-trip: write then read back.
fn hWriteReadBigI64(_: i32, args: value.NativeArgs) value.NativeResult {
    const dv = args.getDataView(0) orelse return .null_val;
    const v = args.toBigIntI64(1) orelse return .null_val;
    _ = dv.setBigInt64(0, v, true);
    const read = dv.getBigInt64(0, true) orelse return .null_val;
    g_big_i64 = read;
    return .{ .big_int_i64 = read };
}

// Float32 round-trip via exact bit pattern.
fn hF32RoundTrip(_: i32, args: value.NativeArgs) value.NativeResult {
    const dv = args.getDataView(0) orelse return .null_val;
    // Interpret arg[1] as u32 bits; write those bits as a float, then read back and report both the float and the roundtripped bits.
    const bits_f = args.toFloat64(1) orelse return .null_val;
    const bits: u32 = @intFromFloat(bits_f);
    const f: f32 = @bitCast(bits);
    _ = dv.setFloat32(0, f, true);
    const read_f = dv.getFloat32(0, true) orelse return .null_val;
    const read_bits: u32 = @bitCast(read_f);
    g_f32_bits = read_bits;
    return .{ .number = @floatFromInt(read_bits) };
}

// Float64 round-trip via exact bit pattern (u64 -> f64 -> u64).
fn hF64RoundTrip(_: i32, args: value.NativeArgs) value.NativeResult {
    const dv = args.getDataView(0) orelse return .null_val;
    const bits = args.toBigIntU64(1) orelse return .null_val;
    const f: f64 = @bitCast(bits);
    _ = dv.setFloat64(0, f, true);
    const read_f = dv.getFloat64(0, true) orelse return .null_val;
    const read_bits: u64 = @bitCast(read_f);
    g_f64_bits = read_bits;
    return .{ .big_int_u64 = read_bits };
}

fn hIsDataView(_: i32, args: value.NativeArgs) value.NativeResult {
    const r = args.isDataView(0);
    g_is_dv = r;
    return .{ .boolean = r };
}

// ========================================================================
// 1) Native -> JS: construct a DataView, verify in JS
// ========================================================================

test "dataview: native constructs DataView at offset 4 / length 8; JS sees bytes" {
    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkDV", &hMakeDVWithI32);
            try helpers.expectEvalEquals(inst, "String(mkDV() instanceof DataView)", "true");
            try helpers.expectEvalEquals(inst, "String(mkDV().byteOffset)", "4");
            try helpers.expectEvalEquals(inst, "String(mkDV().byteLength)", "8");
            // The DataView was initialised with 0xDEADBEEF little-endian at offset 0.
            try helpers.expectEvalEquals(inst, "String(mkDV().getInt32(0, true))", "-559038737"); // 0xDEADBEEF as i32
            try helpers.expectEvalEquals(inst, "String(mkDV().buffer.byteLength)", "16");
        }
    }.run);
}

// ========================================================================
// 2) JS -> Native: read Int32 LE / BE at offset 4
// ========================================================================

test "dataview: read Int32 with both endianness settings at offset 4" {
    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readLE", &hReadI32Le);
            value.registerFunction(inst, null, "readBE", &hReadI32Be);
            // Build a DataView in JS with known bytes at offset 4. We use setInt32 with the same endianness for a sanity round-trip.
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const ab = new ArrayBuffer(16);
                \\  const dv = new DataView(ab);
                \\  dv.setInt32(4, 0x01020304, true);  // little-endian
                \\  return String(readLE(dv, 4));
                \\})()
            , "16909060"); // 0x01020304
            try testing.expectEqual(@as(?i32, 0x01020304), g_i32_le);

            // Same bytes interpreted big-endian => 0x04030201
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const ab = new ArrayBuffer(16);
                \\  const dv = new DataView(ab);
                \\  dv.setInt32(4, 0x01020304, true);  // bytes in LE order
                \\  return String(readBE(dv, 4));
                \\})()
            , "67305985"); // 0x04030201
            try testing.expectEqual(@as(?i32, 0x04030201), g_i32_be);
        }
    }.run);
}

test "dataview: native access ignores shadowed backing metadata" {
    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readU8", &hReadU8);
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const backing = new Uint8Array([10, 20, 30, 40]).buffer;
                \\  const dv = new DataView(backing, 1, 2);
                \\  let getterRuns = 0;
                \\  Object.defineProperties(dv, {
                \\    buffer: { get() { getterRuns++; return new Uint8Array([8, 7]).buffer; } },
                \\    byteOffset: { get() { getterRuns++; return 0; } },
                \\    byteLength: { get() { getterRuns++; return 2; } },
                \\  });
                \\  globalThis.DataView = function () {};
                \\  return String(readU8(dv, 0)) + ":" + getterRuns;
                \\})()
            , "20:0");
            try testing.expectEqual(@as(?u8, 20), g_u8);
        }
    }.run);
}

test "dataview: zero-length view stays attached" {
    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "oob", &hOutOfRange);
            try helpers.expectEvalEquals(inst, "String(oob(new DataView(new ArrayBuffer(0)), 0))", "true");
            try helpers.expectEvalEquals(inst, "String(6 * 7)", "42");
        }
    }.run);
}

test "dataview: detached and ordinary values leave the context usable" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;

    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readU8", &hReadU8);
            value.registerFunction(inst, null, "isDV", &hIsDataView);
            try helpers.evalOk(inst,
                \\globalThis.__dv__ = new DataView(new Uint8Array([10, 20]).buffer);
                \\globalThis.__dv_buffer__ = __dv__.buffer;
                \\globalThis.__plain__ = {};
            );

            const ctx = engine.getContext(inst) orelse return error.NoContext;
            const buffer = try globalValue(inst, "__dv_buffer__");
            defer ActiveEngine.freeValue(ctx, buffer);
            const view = try globalValue(inst, "__dv__");
            defer ActiveEngine.freeValue(ctx, view);
            const plain = try globalValue(inst, "__plain__");
            defer ActiveEngine.freeValue(ctx, plain);
            const qjs_mod = backend.ActiveEngineModule;
            qjs_mod.qjs.JS_DetachArrayBuffer(ctx, buffer);

            try testing.expect(ActiveEngine.dataViewInfo(ctx, view) == null);
            try testing.expect(qjsHasNoPendingException(ctx));
            try testing.expect(ActiveEngine.dataViewInfo(ctx, plain) == null);
            try testing.expect(qjsHasNoPendingException(ctx));
            try helpers.expectEvalEquals(inst, "String(isDV(__dv__))", "true");
            try helpers.expectEvalEquals(inst, "String(readU8(__dv__, 0))", "null");
            try helpers.expectEvalEquals(inst, "String(readU8({}, 0))", "null");
            try helpers.expectEvalEquals(inst, "String(6 * 7)", "42");
        }
    }.run);
}

test "dataview: length-tracking resizable buffer follows shrink and grow" {
    if (comptime backend.isJscApiBackend(backend.active_backend)) return;
    // Spikes: Hermes has no ArrayBuffer.resize; Escargot resizes but Public ArrayBufferView
    // zeros OOB length-tracking views (cannot match QuickJS dataViewInfo→null).
    if (comptime backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;

    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readU8", &hReadU8);
            value.registerFunction(inst, null, "oob", &hOutOfRange);
            try helpers.evalOk(inst,
                \\globalThis.__rab__ = new ArrayBuffer(4, { maxByteLength: 8 });
                \\new Uint8Array(__rab__).set([10, 20, 30, 40]);
                \\globalThis.__dv__ = new DataView(__rab__, 2);
            );
            try helpers.expectEvalEquals(inst, "String(readU8(__dv__, 0))", "30");
            try helpers.expectEvalEquals(inst, "String(oob(__dv__, 0))", "true");

            try helpers.evalOk(inst, "__rab__.resize(8);");
            try helpers.expectEvalEquals(inst, "String(oob(__dv__, 2))", "false");

            try helpers.evalOk(inst, "__rab__.resize(1);");
            try helpers.expectEvalEquals(inst, "String(oob(__dv__, 0))", "null");
            try helpers.expectEvalEquals(inst, "String(6 * 7)", "42");

            try helpers.evalOk(inst, "__rab__.resize(8);");
            try helpers.expectEvalEquals(inst, "String(oob(__dv__, 2))", "false");
        }
    }.run);
}

// ========================================================================
// 3) Native writes big-endian; JS reads back big-endian
// ========================================================================

test "dataview: endianness round-trip (write BE native / read BE from JS)" {
    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "writeBE", &hWriteI32Be);
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const dv = new DataView(new ArrayBuffer(16));
                \\  writeBE(dv, 0, 0x0A0B0C0D);
                \\  return String(dv.getInt32(0, false));  // read BE
                \\})()
            , "168496141"); // 0x0A0B0C0D
            // And mis-read with LE yields the byte-swapped value.
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const dv = new DataView(new ArrayBuffer(16));
                \\  writeBE(dv, 0, 0x0A0B0C0D);
                \\  return String(dv.getInt32(0, true));  // same bytes, LE
                \\})()
            , "218893066"); // 0x0D0C0B0A
        }
    }.run);
}

// ========================================================================
// 4) getUint8 / setUint8 — no endianness
// ========================================================================

test "dataview: getUint8 / setUint8 behave identically regardless of byte order" {
    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readU8", &hReadU8);
            value.registerFunction(inst, null, "writeU8", &hWriteU8);
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const dv = new DataView(new ArrayBuffer(4));
                \\  writeU8(dv, 1, 200);
                \\  return String(readU8(dv, 1));
                \\})()
            , "200");
            try testing.expectEqual(@as(?u8, 200), g_u8);
        }
    }.run);
}

// ========================================================================
// 5) Cross-boundary reads: out-of-range returns null
// ========================================================================

test "dataview: getInt32 at boundary returns null (policy: null, not thrown)" {
    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "oob", &hOutOfRange);
            // DataView window is 4 bytes; getInt32 at offset 1 needs 4 bytes => overruns
            try helpers.expectEvalEquals(inst,
                \\String(oob(new DataView(new ArrayBuffer(4)), 1))
            , "true");
            try testing.expectEqual(@as(?bool, true), g_oob_was_null);
            // In-range read returns false (not null).
            try helpers.expectEvalEquals(inst,
                \\String(oob(new DataView(new ArrayBuffer(4)), 0))
            , "false");
            try testing.expectEqual(@as(?bool, false), g_oob_was_null);
        }
    }.run);
}

// ========================================================================
// 6) getBigInt64 / setBigInt64 round-trip
// ========================================================================

test "dataview: BigInt64 round-trip survives large values" {
    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "bi64", &hWriteReadBigI64);
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const dv = new DataView(new ArrayBuffer(8));
                \\  return String(bi64(dv, 9007199254740993n));
                \\})()
            , "9007199254740993");
            try testing.expectEqual(@as(?i64, 9_007_199_254_740_993), g_big_i64);

            // Negative large value.
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const dv = new DataView(new ArrayBuffer(8));
                \\  return String(bi64(dv, -9007199254740993n));
                \\})()
            , "-9007199254740993");
            try testing.expectEqual(@as(?i64, -9_007_199_254_740_993), g_big_i64);
        }
    }.run);
}

// ========================================================================
// 7) Float32 / Float64 round-trip with exact bit patterns
// ========================================================================

test "dataview: Float32 round-trip preserves exact bit pattern" {
    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "f32rt", &hF32RoundTrip);
            // Use a representative bit pattern: 0x40490FDB ~= pi as f32.
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const dv = new DataView(new ArrayBuffer(4));
                \\  return String(f32rt(dv, 0x40490FDB));
                \\})()
            , "1078530011"); // 0x40490FDB
            try testing.expectEqual(@as(?u32, 0x40490FDB), g_f32_bits);
        }
    }.run);
}

test "dataview: Float64 round-trip preserves exact bit pattern" {
    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "f64rt", &hF64RoundTrip);
            // 0x400921FB54442D18 ~= pi as f64.
            try helpers.expectEvalEquals(inst,
                \\(function(){
                \\  const dv = new DataView(new ArrayBuffer(8));
                \\  return String(f64rt(dv, 0x400921FB54442D18n));
                \\})()
            , "4614256656552045848"); // 0x400921FB54442D18
            try testing.expectEqual(@as(?u64, 0x400921FB54442D18), g_f64_bits);
        }
    }.run);
}

// ========================================================================
// 8) isDataView discriminates correctly
// ========================================================================

test "dataview: isDataView is true only for DataView instances" {
    reset();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "isDV", &hIsDataView);
            try helpers.expectEvalEquals(inst, "String(isDV(new DataView(new ArrayBuffer(4))))", "true");
            try testing.expectEqual(@as(?bool, true), g_is_dv);
            try helpers.expectEvalEquals(inst, "String(isDV(new ArrayBuffer(4)))", "false");
            try helpers.expectEvalEquals(inst, "String(isDV(new Uint8Array([1])))", "false");
            try helpers.expectEvalEquals(inst, "String(isDV({}))", "false");
            try helpers.expectEvalEquals(inst, "String(isDV(42))", "false");
        }
    }.run);
}
