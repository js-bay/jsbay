//! Tests for native function registration, dispatch, and all NativeResult variants.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const backend = @import("../backend.zig");
const value = @import("../value/root.zig");
const engine = @import("../engine.zig");

// ---- Module-level state used by handlers ----

var g_last_num: f64 = 0;
var g_counter: i64 = 0;
var g_call_count: usize = 0;
var g_arg_count_seen: usize = 0;
var g_marker_v1: i32 = 0;
var g_marker_v2: i32 = 0;

fn resetState() void {
    g_last_num = 0;
    g_counter = 0;
    g_call_count = 0;
    g_arg_count_seen = 0;
    g_marker_v1 = 0;
    g_marker_v2 = 0;
}

fn dupZ(s: []const u8) []const u8 {
    return std.heap.c_allocator.dupe(u8, s) catch @panic("oom");
}

// ---- Handlers (each must be a top-level fn to satisfy callconv) ----

fn retSeven(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .number = 7 };
}

fn retConstNum(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .number = 42 };
}

fn echoNum(_: i32, args: value.NativeArgs) value.NativeResult {
    const n = args.toFloat64(0) orelse return .null_val;
    g_last_num = n;
    return .{ .number = n };
}

fn echoString(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.toString(0) orelse return .null_val;
    defer value.freeString(s);
    return .{ .string = dupZ(s) };
}

fn addHandler(_: i32, args: value.NativeArgs) value.NativeResult {
    const a = args.toFloat64(0) orelse return .null_val;
    const b = args.toFloat64(1) orelse return .null_val;
    return .{ .number = a + b };
}

fn subHandler(_: i32, args: value.NativeArgs) value.NativeResult {
    const a = args.toFloat64(0) orelse return .null_val;
    const b = args.toFloat64(1) orelse return .null_val;
    return .{ .number = a - b };
}

fn mulHandler(_: i32, args: value.NativeArgs) value.NativeResult {
    const a = args.toFloat64(0) orelse return .null_val;
    const b = args.toFloat64(1) orelse return .null_val;
    return .{ .number = a * b };
}

fn sumFive(_: i32, args: value.NativeArgs) value.NativeResult {
    var total: f64 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        total += args.toFloat64(i) orelse 0;
    }
    return .{ .number = total };
}

fn sumObj(_: i32, args: value.NativeArgs) value.NativeResult {
    const a = args.getPropertyNumber(0, "a") orelse return .null_val;
    const b = args.getPropertyNumber(0, "b") orelse return .null_val;
    return .{ .number = a + b };
}

fn sumArray(_: i32, args: value.NativeArgs) value.NativeResult {
    const len = args.getLength(0) orelse return .null_val;
    var total: i64 = 0;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const s = args.getElementString(0, i) orelse continue;
        defer value.freeString(s);
        const n = std.fmt.parseInt(i64, s, 10) catch continue;
        total += n;
    }
    return .{ .number = @floatFromInt(total) };
}

fn mixedArgs(_: i32, args: value.NativeArgs) value.NativeResult {
    // args: number, string, object{a}, array
    const n = args.toFloat64(0) orelse 0;
    const s = args.toString(1) orelse dupZ("");
    defer value.freeString(s);
    const oa = args.getPropertyNumber(2, "a") orelse 0;
    const alen = args.getLength(3) orelse 0;

    var aw: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer aw.deinit();
    aw.writer.print("{{\"num\":{d},\"str\":\"{s}\",\"obj_a\":{d},\"arr_len\":{d}}}", .{ n, s, oa, alen }) catch return .null_val;
    return .{ .json = dupZ(aw.written()) };
}

fn countArgs(_: i32, args: value.NativeArgs) value.NativeResult {
    g_arg_count_seen = args.count();
    // Probe out-of-bounds access
    const beyond = args.toFloat64(args.count() + 5);
    if (beyond != null) {
        // Should never happen; signal via sentinel
        return .{ .number = -1 };
    }
    return .{ .number = @floatFromInt(args.count()) };
}

fn countArgs50(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .number = @floatFromInt(args.count()) };
}

fn retNull(_: i32, _: value.NativeArgs) value.NativeResult {
    return .null_val;
}

fn retUndefined(_: i32, _: value.NativeArgs) value.NativeResult {
    return .undefined_val;
}

fn retBoolTrue(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .boolean = true };
}

fn retBoolFalse(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .boolean = false };
}

fn retPi(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .number = 3.14 };
}

fn retNegZero(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .number = -0.0 };
}

fn retBig(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .number = 1e20 };
}

fn retNan(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .number = std.math.nan(f64) };
}

fn retInf(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .number = std.math.inf(f64) };
}

fn retAsciiString(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .string = dupZ("hello world") };
}

fn retUtf8String(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .string = dupZ("héllo 🎉") };
}

fn retEmptyString(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .string = dupZ("") };
}

fn retValidJson(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .json = dupZ("{\"a\":1,\"b\":[1,2]}") };
}

fn retInvalidJson(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .json = dupZ("not json") };
}

fn retErrBoom(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .err = dupZ("boom") };
}

fn retLargeString(_: i32, _: value.NativeArgs) value.NativeResult {
    const size: usize = 100 * 1024;
    const buf = std.heap.c_allocator.alloc(u8, size) catch @panic("oom");
    @memset(buf, 'A');
    return .{ .string = buf };
}

fn retErrInner(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .err = dupZ("inner-failure") };
}

fn retFirstReg(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .number = 1 };
}

fn retSecondReg(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .number = 2 };
}

fn bumpCounter(_: i32, _: value.NativeArgs) value.NativeResult {
    g_counter += 1;
    return .{ .number = @floatFromInt(g_counter) };
}

fn recurseEval(instance_id: i32, _: value.NativeArgs) value.NativeResult {
    helpers.evalOk(instance_id, "globalThis.__mark__ = (globalThis.__mark__ || 0) + 1;") catch {};
    return .{ .number = 1 };
}

fn readXProp(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.getPropertyString(0, "x") orelse return .null_val;
    defer value.freeString(s);
    g_call_count += 1;
    return .{ .number = @floatFromInt(s.len) };
}

fn jsonifyArg(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.jsonStringify(0) orelse return .null_val;
    defer value.freeString(s);
    g_call_count += 1;
    return .{ .number = @floatFromInt(s.len) };
}

// ---- Tests ----

test "native: register on globalThis and call with 0 args" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "retSeven", &retSeven);
            try helpers.expectEvalEquals(inst, "retSeven()", "7");
        }
    }.run);
}

test "native: register with non-existent parent name" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, "wx", "fn", &retConstNum);
            try helpers.expectEvalEquals(inst, "wx.fn()", "42");
        }
    }.run);
}

test "native: register with existing parent preserves existing props" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            try helpers.evalOk(inst, "globalThis.wx = { existing: 1 };");
            value.registerFunction(inst, "wx", "fn", &retConstNum);
            try helpers.expectEvalEquals(inst, "wx.existing", "1");
            try helpers.expectEvalEquals(inst, "wx.fn()", "42");
        }
    }.run);
}

test "native: registerObjectWithFunctions with multiple fns" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            const handlers = [_]value.FunctionEntry{
                .{ .name = "add", .handler = &addHandler },
                .{ .name = "sub", .handler = &subHandler },
                .{ .name = "mul", .handler = &mulHandler },
            };
            value.registerObjectWithFunctions(inst, "math", &handlers);
            try helpers.expectEvalEquals(inst, "math.add(2, 3)", "5");
            try helpers.expectEvalEquals(inst, "math.sub(10, 4)", "6");
            try helpers.expectEvalEquals(inst, "math.mul(6, 7)", "42");
        }
    }.run);
}

test "native: single number arg echoed" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "echoNum", &echoNum);
            try helpers.expectEvalEquals(inst, "echoNum(123.5)", "123.5");
            try testing.expectEqual(@as(f64, 123.5), g_last_num);
        }
    }.run);
}

test "native: single string arg echoed and freed" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "echoStr", &echoString);
            // Invoke many times to flush any leak/use-after-free
            try helpers.evalOk(inst,
                \\for (let i = 0; i < 200; i++) { echoStr("hello-" + i); }
            );
            try helpers.expectEvalEquals(inst, "echoStr('ok')", "ok");
        }
    }.run);
}

test "native: 5 numeric args summed" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "sum5", &sumFive);
            try helpers.expectEvalEquals(inst, "sum5(1, 2, 3, 4, 5)", "15");
        }
    }.run);
}

test "native: object arg — getPropertyNumber" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "sumObj", &sumObj);
            try helpers.expectEvalEquals(inst, "sumObj({ a: 10, b: 32 })", "42");
        }
    }.run);
}

test "native: array arg — getElementString + parseInt" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "sumArr", &sumArray);
            try helpers.expectEvalEquals(inst, "sumArr([1, 2, 3, 4])", "10");
        }
    }.run);
}

test "native: mixed arg types — number, string, object, array" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mix", &mixedArgs);
            try helpers.expectEvalEquals(
                inst,
                "JSON.stringify(mix(7, 'hi', { a: 3 }, [1,2,3,4,5]))",
                "{\"num\":7,\"str\":\"hi\",\"obj_a\":3,\"arr_len\":5}",
            );
        }
    }.run);
}

test "native: fewer args than expected — out-of-bounds returns null" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "cnt", &countArgs);
            try helpers.expectEvalEquals(inst, "cnt()", "0");
            try testing.expectEqual(@as(usize, 0), g_arg_count_seen);
            try helpers.expectEvalEquals(inst, "cnt(1, 2)", "2");
            try testing.expectEqual(@as(usize, 2), g_arg_count_seen);
        }
    }.run);
}

test "native: large arg count (50 args)" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "cnt50", &countArgs50);
            try helpers.expectEvalEquals(
                inst,
                "cnt50(" ++ "1,1,1,1,1,1,1,1,1,1," ++ "1,1,1,1,1,1,1,1,1,1," ++ "1,1,1,1,1,1,1,1,1,1," ++ "1,1,1,1,1,1,1,1,1,1," ++ "1,1,1,1,1,1,1,1,1,1" ++ ")",
                "50",
            );
        }
    }.run);
}

test "native: NativeResult.null_val" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "rn", &retNull);
            try helpers.expectEvalEquals(inst, "rn() === null", "true");
        }
    }.run);
}

test "native: NativeResult.undefined_val" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "ru", &retUndefined);
            try helpers.expectEvalEquals(inst, "ru() === undefined", "true");
        }
    }.run);
}

test "native: NativeResult.boolean true and false" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "bt", &retBoolTrue);
            value.registerFunction(inst, null, "bf", &retBoolFalse);
            try helpers.expectEvalEquals(inst, "bt()", "true");
            try helpers.expectEvalEquals(inst, "bf()", "false");
        }
    }.run);
}

test "native: NativeResult.number 3.14" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "pi", &retPi);
            // Hermes String(number) uses more digits; compare numerically.
            if (comptime backend.isHermesBackend(backend.active_backend)) {
                try helpers.expectEvalEquals(inst, "Number(pi()) === 3.14", "true");
            } else {
                try helpers.expectEvalEquals(inst, "pi()", "3.14");
            }
        }
    }.run);
}

test "native: NativeResult.number -0.0" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "nz", &retNegZero);
            // 1 / -0 === -Infinity confirms signed zero preserved
            try helpers.expectEvalEquals(inst, "(1 / nz()) === -Infinity", "true");
        }
    }.run);
}

test "native: NativeResult.number 1e20" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "big", &retBig);
            try helpers.expectEvalEquals(inst, "big() === 1e20", "true");
        }
    }.run);
}

test "native: NativeResult.number NaN" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "nn", &retNan);
            try helpers.expectEvalEquals(inst, "Number.isNaN(nn())", "true");
        }
    }.run);
}

test "native: NativeResult.number Infinity" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "ii", &retInf);
            try helpers.expectEvalEquals(inst, "ii() === Infinity", "true");
        }
    }.run);
}

test "native: NativeResult.string ASCII" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "sa", &retAsciiString);
            try helpers.expectEvalEquals(inst, "sa()", "hello world");
        }
    }.run);
}

test "native: NativeResult.string UTF-8 round-trip" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "su", &retUtf8String);
            try helpers.expectEvalEquals(inst, "su()", "héllo 🎉");
            // Round-trip equality in JS
            try helpers.expectEvalEquals(inst, "su() === 'héllo 🎉'", "true");
        }
    }.run);
}

test "native: NativeResult.string empty" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "se", &retEmptyString);
            try helpers.expectEvalEquals(inst, "se() === ''", "true");
            try helpers.expectEvalEquals(inst, "se().length", "0");
        }
    }.run);
}

test "native: NativeResult.json valid" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "vj", &retValidJson);
            try helpers.expectEvalEquals(inst, "JSON.stringify(vj())", "{\"a\":1,\"b\":[1,2]}");
        }
    }.run);
}

test "native: NativeResult.json invalid → null" {
        resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "ij", &retInvalidJson);
            try helpers.expectEvalEquals(inst, "ij() === null", "true");
        }
    }.run);
}

test "native: NativeResult.err thrown and caught" {
        resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "boom", &retErrBoom);
            try helpers.expectEvalEquals(
                inst,
                "(() => { try { boom(); return 'no-throw'; } catch(e) { return e.message; } })()",
                "boom",
            );
        }
    }.run);
}

test "native: large string result (100KB)" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "big", &retLargeString);
            try helpers.expectEvalEquals(inst, "big().length", "102400");
            try helpers.expectEvalEquals(inst, "big().charCodeAt(0) === 65", "true");
            try helpers.expectEvalEquals(inst, "big().charCodeAt(102399) === 65", "true");
        }
    }.run);
}

test "native: throw from native, subsequent evals still work" {
        resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "boom", &retErrBoom);
            try helpers.expectEvalEquals(
                inst,
                "(() => { try { boom(); } catch(e) { return 'caught'; } })()",
                "caught",
            );
            // subsequent eval must still succeed
            try helpers.expectEvalEquals(inst, "1 + 2", "3");
        }
    }.run);
}

test "native: throw from nested call chain caught at outer's caller" {
        resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "inner", &retErrInner);
            try helpers.evalOk(inst, "function outer() { return inner(); }");
            try helpers.expectEvalEquals(
                inst,
                "(() => { try { outer(); return 'no'; } catch(e) { return e.message; } })()",
                "inner-failure",
            );
        }
    }.run);
}

test "native: re-registering same name replaces handler" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "rr", &retFirstReg);
            try helpers.expectEvalEquals(inst, "rr()", "1");
            value.registerFunction(inst, null, "rr", &retSecondReg);
            try helpers.expectEvalEquals(inst, "rr()", "2");
        }
    }.run);
}

test "native: unregistered function triggers ReferenceError" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            try helpers.evalErr(inst, "notRegistered()");
        }
    }.run);
}

test "native: recursion — JS calls native which evals JS that mutates global" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "bump", &recurseEval);
            try helpers.expectEvalEquals(inst, "bump()", "1");
            try helpers.expectEvalEquals(inst, "globalThis.__mark__", "1");
            try helpers.expectEvalEquals(inst, "bump()", "1");
            try helpers.expectEvalEquals(inst, "globalThis.__mark__", "2");
        }
    }.run);
}

test "native: string ownership — getPropertyString + freeString in loop (1000)" {
    // Hermes: top-level `let` does not persist across evaluateJavaScript; use var.
    // getPropertyString+freeString in the hot loop is fine (was misdiagnosed as JSI lifetime).
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "rx", &readXProp);
            try helpers.evalOk(inst,
                \\var acc = 0;
                \\for (var i = 0; i < 1000; i++) { acc += rx({ x: "abcdef" }); }
            );
            try helpers.expectEvalEquals(inst, "acc", "6000");
            try testing.expectEqual(@as(usize, 1000), g_call_count);
        }
    }.run);
}

test "native: jsonStringify + freeString roundtrip from JS" {
    resetState();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "jz", &jsonifyArg);
            // Object: JSON has at least "{" and "}" so length > 2
            try helpers.evalOk(inst,
                \\let total = 0;
                \\for (let i = 0; i < 50; i++) { total += jz({ n: i }); }
            );
            try testing.expectEqual(@as(usize, 50), g_call_count);
        }
    }.run);
}
