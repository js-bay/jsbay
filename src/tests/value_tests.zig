//! Tests for the unified value layer (NativeArgs / NativeResult / valueInit / registerFunction / registerObjectWithFunctions).
//!
//! Each test registers a native handler that inspects its arguments (or returns a specific NativeResult), evaluates JS that calls it, and asserts on the observed result. The handlers are top-level `fn`s because the backend wrappers generate `callconv(.c)` trampolines at comptime that require the handler to be a comptime-known pointer. Cross-test state is held in module-level globals and reset in the corresponding test block.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const value = @import("../value/root.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

// ========================================================================
// Globals used to smuggle observations out of handlers into assertions.
// ========================================================================
var g_bool_a: bool = false;
var g_bool_b: bool = false;
var g_int: ?i32 = null;
var g_float: ?f64 = null;
var g_str: ?[]const u8 = null;
var g_count: usize = 0;

fn resetGlobals() void {
    g_bool_a = false;
    g_bool_b = false;
    g_int = null;
    g_float = null;
    if (g_str) |s| value.freeString(s);
    g_str = null;
    g_count = 0;
}

// ========================================================================
// Handlers — one per behavior, returning sentinel values that can be compared in JS via String() stringification.
// ========================================================================

fn hIsNumber(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.isNumber(0) };
}

fn hIsString(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.isString(0) };
}

fn hIsBool(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.isBool(0) };
}

fn hIsNull(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.isNull(0) };
}

fn hIsUndefined(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.isUndefined(0) };
}

fn hIsObject(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.isObject(0) };
}

fn hIsArray(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.isArray(0) };
}

fn hToInt32(_: i32, args: value.NativeArgs) value.NativeResult {
    const v = args.toInt32(0) orelse return .null_val;
    return .{ .number = @floatFromInt(v) };
}

fn hToFloat64(_: i32, args: value.NativeArgs) value.NativeResult {
    const v = args.toFloat64(0) orelse return .null_val;
    return .{ .number = v };
}

fn hToBool(_: i32, args: value.NativeArgs) value.NativeResult {
    const v = args.toBool(0) orelse return .null_val;
    return .{ .boolean = v };
}

fn hToString(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.toString(0) orelse return .null_val;
    // Return the string back to JS — the engine takes ownership.
    return .{ .string = s };
}

fn hJsonStringify(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.jsonStringify(0) orelse return .null_val;
    return .{ .string = s };
}

fn hGetPropString(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.getPropertyString(0, "name") orelse return .null_val;
    return .{ .string = s };
}

fn hGetPropStringMissing(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.getPropertyString(0, "missing") orelse return .{ .boolean = false };
    value.freeString(s);
    return .{ .boolean = true };
}

fn hGetPropNumber(_: i32, args: value.NativeArgs) value.NativeResult {
    const n = args.getPropertyNumber(0, "age") orelse return .null_val;
    return .{ .number = n };
}

fn hGetPropNumberMissing(_: i32, args: value.NativeArgs) value.NativeResult {
    if (args.getPropertyNumber(0, "missing")) |_| {
        return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

fn hGetPropBool(_: i32, args: value.NativeArgs) value.NativeResult {
    const b = args.getPropertyBool(0, "active") orelse return .null_val;
    return .{ .boolean = b };
}

fn hGetPropBoolMissing(_: i32, args: value.NativeArgs) value.NativeResult {
    if (args.getPropertyBool(0, "missing")) |_| {
        return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

fn hNestedJson(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.jsonStringify(0) orelse return .null_val;
    return .{ .string = s };
}

fn hGetLength(_: i32, args: value.NativeArgs) value.NativeResult {
    const len = args.getLength(0) orelse return .null_val;
    return .{ .number = @floatFromInt(len) };
}

fn hGetElementString(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.getElementString(0, 1) orelse return .null_val;
    return .{ .string = s };
}

fn hGetElementStringOob(_: i32, args: value.NativeArgs) value.NativeResult {
    if (args.getElementString(0, 999)) |s| {
        value.freeString(s);
        return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

fn hReturnNull(_: i32, _: value.NativeArgs) value.NativeResult {
    return .null_val;
}

fn hReturnUndefined(_: i32, _: value.NativeArgs) value.NativeResult {
    return .undefined_val;
}

fn hReturnBool(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .boolean = true };
}

fn hReturnNumber(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .number = 3.14 };
}

fn hReturnString(_: i32, _: value.NativeArgs) value.NativeResult {
    const owned = std.heap.c_allocator.dupe(u8, "hi") catch return .null_val;
    return .{ .string = owned };
}

fn hReturnJson(_: i32, _: value.NativeArgs) value.NativeResult {
    const owned = std.heap.c_allocator.dupe(u8, "{\"ok\":true}") catch return .null_val;
    return .{ .json = owned };
}

fn hReturnError(_: i32, _: value.NativeArgs) value.NativeResult {
    const owned = std.heap.c_allocator.dupe(u8, "boom") catch return .null_val;
    return .{ .err = owned };
}

fn hAdd(_: i32, args: value.NativeArgs) value.NativeResult {
    const a = args.toFloat64(0) orelse return .null_val;
    const b = args.toFloat64(1) orelse return .null_val;
    return .{ .number = a + b };
}

fn hSub(_: i32, args: value.NativeArgs) value.NativeResult {
    const a = args.toFloat64(0) orelse return .null_val;
    const b = args.toFloat64(1) orelse return .null_val;
    return .{ .number = a - b };
}

fn hZeroArgs(_: i32, args: value.NativeArgs) value.NativeResult {
    // Capture observations for the 0-arg test.
    g_count = args.count();
    g_bool_a = args.isUndefined(0);
    g_bool_b = args.isNumber(0) or args.isString(0) or args.isBool(0) or args.isNull(0) or args.isObject(0) or args.isArray(0);
    return .undefined_val;
}

fn hManyArgs(_: i32, args: value.NativeArgs) value.NativeResult {
    // Sum the first N numeric args, verifying all are accessible.
    var sum: f64 = 0;
    var i: usize = 0;
    while (i < args.count()) : (i += 1) {
        const v = args.toFloat64(i) orelse return .null_val;
        sum += v;
    }
    g_count = args.count();
    return .{ .number = sum };
}

// ========================================================================
// Type predicate tests
// ========================================================================

test "value: isNumber detects integers and rejects strings/bool/null/undefined" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "isNum", &hIsNumber);
            try helpers.expectEvalEquals(inst, "String(isNum(123))", "true");
            try helpers.expectEvalEquals(inst, "String(isNum('123'))", "false");
            try helpers.expectEvalEquals(inst, "String(isNum(true))", "false");
            try helpers.expectEvalEquals(inst, "String(isNum(null))", "false");
            try helpers.expectEvalEquals(inst, "String(isNum(undefined))", "false");
        }
    }.run);
}

test "value: isString true for string, false for number/object" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "isStr", &hIsString);
            try helpers.expectEvalEquals(inst, "String(isStr('x'))", "true");
            try helpers.expectEvalEquals(inst, "String(isStr(1))", "false");
            try helpers.expectEvalEquals(inst, "String(isStr({}))", "false");
        }
    }.run);
}

test "value: isBool true for true/false, false for numbers" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "isB", &hIsBool);
            try helpers.expectEvalEquals(inst, "String(isB(true))", "true");
            try helpers.expectEvalEquals(inst, "String(isB(false))", "true");
            try helpers.expectEvalEquals(inst, "String(isB(0))", "false");
            try helpers.expectEvalEquals(inst, "String(isB(1))", "false");
        }
    }.run);
}

test "value: isNull distinguishes null from undefined" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "isN", &hIsNull);
            try helpers.expectEvalEquals(inst, "String(isN(null))", "true");
            try helpers.expectEvalEquals(inst, "String(isN(undefined))", "false");
        }
    }.run);
}

test "value: isUndefined true for undefined and omitted args, false for null" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "isU", &hIsUndefined);
            try helpers.expectEvalEquals(inst, "String(isU(undefined))", "true");
            try helpers.expectEvalEquals(inst, "String(isU())", "true");
            try helpers.expectEvalEquals(inst, "String(isU(null))", "false");
        }
    }.run);
}

test "value: isObject true for objects and arrays, false for null/primitives" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "isO", &hIsObject);
            try helpers.expectEvalEquals(inst, "String(isO({}))", "true");
            try helpers.expectEvalEquals(inst, "String(isO([]))", "true");
            try helpers.expectEvalEquals(inst, "String(isO(null))", "false");
            try helpers.expectEvalEquals(inst, "String(isO(42))", "false");
            try helpers.expectEvalEquals(inst, "String(isO('s'))", "false");
        }
    }.run);
}

test "value: isArray true only for arrays" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "isA", &hIsArray);
            try helpers.expectEvalEquals(inst, "String(isA([]))", "true");
            try helpers.expectEvalEquals(inst, "String(isA({}))", "false");
            try helpers.expectEvalEquals(inst, "String(isA('abc'))", "false");
        }
    }.run);
}

// ========================================================================
// Direct extraction
// ========================================================================

test "value: toInt32 returns integer value, truncates floats, null on string" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "toI", &hToInt32);
            try helpers.expectEvalEquals(inst, "String(toI(42))", "42");
            // Float 42.9 should truncate to 42.
            try helpers.expectEvalEquals(inst, "String(toI(42.9))", "42");
            // Pure string "abc" should yield null from toInt32 (JS_ToInt32 fails).
            try helpers.expectEvalEquals(inst, "String(toI('abc'))", "null");
        }
    }.run);
}

test "value: toFloat64 handles number and int, null for non-numeric string" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "toF", &hToFloat64);
            try helpers.expectEvalEquals(inst, "String(toF(3.5))", "3.5");
            try helpers.expectEvalEquals(inst, "String(toF(7))", "7");
            // Non-numeric string "abc" should fail and yield null.
            try helpers.expectEvalEquals(inst, "String(toF('abc'))", "null");
            // NaN conversion path (NaN is a number, just float NaN).
            try helpers.expectEvalEquals(inst, "String(toF(NaN))", "NaN");
        }
    }.run);
}

test "value: toBool returns true/false for booleans" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "toB", &hToBool);
            try helpers.expectEvalEquals(inst, "String(toB(true))", "true");
            try helpers.expectEvalEquals(inst, "String(toB(false))", "false");
        }
    }.run);
}

// ========================================================================
// toString
// ========================================================================

test "value: toString of string returns content, of number returns decimal" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "ts", &hToString);
            try helpers.expectEvalEquals(inst, "ts('hello')", "hello");
            try helpers.expectEvalEquals(inst, "ts(42)", "42");
        }
    }.run);
}

test "value: toString of null returns 'null'" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "ts", &hToString);
            try helpers.expectEvalEquals(inst, "ts(null)", "null");
        }
    }.run);
}

test "value: toString of undefined returns 'undefined'" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "ts", &hToString);
            try helpers.expectEvalEquals(inst, "ts(undefined)", "undefined");
        }
    }.run);
}

test "value: toString of plain object yields '[object Object]'" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "ts", &hToString);
            try helpers.expectEvalEquals(inst, "ts({})", "[object Object]");
        }
    }.run);
}

// ========================================================================
// JSON stringify
// ========================================================================

test "value: jsonStringify serializes object with string/number fields" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "jstr", &hJsonStringify);
            // Parse back via std.json and verify.
            const alloc = std.testing.allocator;
            const s = try helpers.evalString(alloc, inst, "jstr({a:1, b:'x'})");
            defer alloc.free(s);

            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, s, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            const a = obj.get("a") orelse return error.MissingField;
            const b = obj.get("b") orelse return error.MissingField;
            try testing.expectEqual(@as(i64, 1), a.integer);
            try testing.expectEqualStrings("x", b.string);
        }
    }.run);
}

test "value: jsonStringify array returns '[1,2,3]'" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "jstr", &hJsonStringify);
            try helpers.expectEvalEquals(inst, "jstr([1,2,3])", "[1,2,3]");
        }
    }.run);
}

test "value: jsonStringify primitive number returns '42'" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "jstr", &hJsonStringify);
            try helpers.expectEvalEquals(inst, "jstr(42)", "42");
        }
    }.run);
}

// ========================================================================
// Property shortcuts
// ========================================================================

test "value: getPropertyString returns string when present" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "gps", &hGetPropString);
            try helpers.expectEvalEquals(inst, "gps({name:'alice'})", "alice");
        }
    }.run);
}

test "value: getPropertyString returns null for missing key" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "gpsm", &hGetPropStringMissing);
            // Handler returns false when property is absent.
            try helpers.expectEvalEquals(inst, "String(gpsm({}))", "false");
        }
    }.run);
}

test "value: getPropertyNumber returns number when present, null otherwise" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "gpn", &hGetPropNumber);
            value.registerFunction(inst, null, "gpnm", &hGetPropNumberMissing);
            try helpers.expectEvalEquals(inst, "String(gpn({age:30}))", "30");
            try helpers.expectEvalEquals(inst, "String(gpnm({}))", "false");
        }
    }.run);
}

test "value: getPropertyBool returns bool when present, null otherwise" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "gpb", &hGetPropBool);
            value.registerFunction(inst, null, "gpbm", &hGetPropBoolMissing);
            try helpers.expectEvalEquals(inst, "String(gpb({active:true}))", "true");
            try helpers.expectEvalEquals(inst, "String(gpb({active:false}))", "false");
            try helpers.expectEvalEquals(inst, "String(gpbm({}))", "false");
        }
    }.run);
}

test "value: jsonStringify roundtrips nested object" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "deep", &hNestedJson);
            const alloc = std.testing.allocator;
            const s = try helpers.evalString(alloc, inst, "deep({a:{b:'deep'}})");
            defer alloc.free(s);

            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, s, .{});
            defer parsed.deinit();
            const a = parsed.value.object.get("a") orelse return error.MissingA;
            const b = a.object.get("b") orelse return error.MissingB;
            try testing.expectEqualStrings("deep", b.string);
        }
    }.run);
}

// ========================================================================
// Array access
// ========================================================================

test "value: getLength returns length of array" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "glen", &hGetLength);
            try helpers.expectEvalEquals(inst, "String(glen([1,2,3,4]))", "4");
            try helpers.expectEvalEquals(inst, "String(glen([]))", "0");
        }
    }.run);
}

test "value: getLength on string returns string length" {
    // Strings in QuickJS expose a `length` property, so getLength returns it.
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "glen", &hGetLength);
            try helpers.expectEvalEquals(inst, "String(glen('hello'))", "5");
        }
    }.run);
}

test "value: getElementString returns element as string" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "gel", &hGetElementString);
            try helpers.expectEvalEquals(inst, "gel(['a','b','c'])", "b");
        }
    }.run);
}

test "value: getElementString out-of-bounds returns null" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "gelo", &hGetElementStringOob);
            try helpers.expectEvalEquals(inst, "String(gelo([1,2,3]))", "false");
        }
    }.run);
}

// ========================================================================
// NativeResult variants
// ========================================================================

test "value: returning .null_val produces JS null" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "rn", &hReturnNull);
            try helpers.expectEvalEquals(inst, "String(rn())", "null");
        }
    }.run);
}

test "value: returning .undefined_val produces JS undefined" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "ru", &hReturnUndefined);
            try helpers.expectEvalEquals(inst, "String(ru())", "undefined");
        }
    }.run);
}

test "value: returning .boolean produces JS boolean" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "rb", &hReturnBool);
            try helpers.expectEvalEquals(inst, "String(rb())", "true");
        }
    }.run);
}

test "value: returning .number produces JS number" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "rnum", &hReturnNumber);
            try helpers.expectEvalEquals(inst, "String(rnum())", "3.14");
        }
    }.run);
}

test "value: returning .string produces JS string" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "rs", &hReturnString);
            try helpers.expectEvalEquals(inst, "rs()", "hi");
        }
    }.run);
}

test "value: returning .json parses into JS object" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "rj", &hReturnJson);
            try helpers.expectEvalEquals(inst, "String(rj().ok)", "true");
        }
    }.run);
}

test "value: returning .err throws JS exception containing message" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "re", &hReturnError);
            // JS catches the thrown error and stringifies it — expect "boom" to appear in the message.
            const alloc = std.testing.allocator;
            const s = try helpers.evalString(alloc, inst,
                \\(function(){ try { re(); return 'no-throw'; } catch(e) { return String(e); } })()
            );
            defer alloc.free(s);
            if (std.mem.indexOf(u8, s, "boom") == null) {
                std.debug.print("expected 'boom' in exception message, got: {s}\n", .{s});
                return error.ExpectedBoomInError;
            }
        }
    }.run);
}

// ========================================================================
// valueInit (comptime constructor) — exercised via withBareContext. These don't go through engine.evalScript; instead they construct a value directly, then round-trip through the backend's extractors.
// ========================================================================

test "value: valueInit i32 produces an int32 value" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = value.valueInit(ctx, @as(i32, 42));
            defer ActiveEngine.freeValue(ctx, v);
            const got = ActiveEngine.toInt32(ctx, v) orelse return error.ExpectedInt;
            try testing.expectEqual(@as(i32, 42), got);
        }
    }.run);
}

test "value: valueInit f64 produces a float value" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = value.valueInit(ctx, @as(f64, 3.14));
            defer ActiveEngine.freeValue(ctx, v);
            const got = ActiveEngine.toFloat64(ctx, v) orelse return error.ExpectedFloat;
            try testing.expect(@abs(got - 3.14) < 1e-9);
        }
    }.run);
}

test "value: valueInit bool produces a bool value" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = value.valueInit(ctx, true);
            defer ActiveEngine.freeValue(ctx, v);
            try testing.expect(ActiveEngine.isBool(ctx, v));
            const got = ActiveEngine.toBool(ctx, v) orelse return error.ExpectedBool;
            try testing.expectEqual(true, got);
        }
    }.run);
}

test "value: valueInit string produces a string value" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = value.valueInit(ctx, @as([]const u8, "hello"));
            defer ActiveEngine.freeValue(ctx, v);
            try testing.expect(ActiveEngine.isString(ctx, v));
            const s = ActiveEngine.valueToStringVal(ctx, v) orelse return error.ExpectedStr;
            defer value.freeString(s);
            try testing.expectEqualStrings("hello", s);
        }
    }.run);
}

test "value: valueInit null optional produces null" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = value.valueInit(ctx, @as(?i32, null));
            defer ActiveEngine.freeValue(ctx, v);
            try testing.expect(ActiveEngine.isNull(ctx, v));
        }
    }.run);
}

// ========================================================================
// Tagged undefined vs null at the ActiveEngine.Value level.
//
// JS semantics: `null === undefined` is false. The Value layer must preserve that distinction across both backends, including round trips through `newNullVal` / `newUndefinedVal`, JSON, and native handler return values.
// ========================================================================

test "value: newNullVal is null and not undefined (Value-level distinction)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.newNullVal(ctx);
            defer ActiveEngine.freeValue(ctx, v);
            try testing.expect(ActiveEngine.isNull(ctx, v));
            try testing.expect(!ActiveEngine.isUndefined(ctx, v));
        }
    }.run);
}

test "value: newUndefinedVal is undefined and not null (Value-level distinction)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.newUndefinedVal(ctx);
            defer ActiveEngine.freeValue(ctx, v);
            try testing.expect(ActiveEngine.isUndefined(ctx, v));
            try testing.expect(!ActiveEngine.isNull(ctx, v));
        }
    }.run);
}

test "value: newNullVal serializes to JSON \"null\" (not omitted)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.newNullVal(ctx);
            defer ActiveEngine.freeValue(ctx, v);
            const s = ActiveEngine.jsonStringifyVal(ctx, v) orelse return error.ExpectedJson;
            defer value.freeString(s);
            try testing.expectEqualStrings("null", s);
        }
    }.run);
}

fn hReturnNullThenInspect(_: i32, _: value.NativeArgs) value.NativeResult {
    return .null_val;
}

fn hReturnUndefThenInspect(_: i32, _: value.NativeArgs) value.NativeResult {
    return .undefined_val;
}

test "value: NativeResult .null_val and .undefined_val are JS-distinguishable" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "retNull", &hReturnNullThenInspect);
            value.registerFunction(inst, null, "retUndef", &hReturnUndefThenInspect);
            // strict-equality probes: null !== undefined per spec.
            try helpers.expectEvalEquals(inst, "String(retNull() === null)", "true");
            try helpers.expectEvalEquals(inst, "String(retNull() === undefined)", "false");
            try helpers.expectEvalEquals(inst, "String(retUndef() === undefined)", "true");
            try helpers.expectEvalEquals(inst, "String(retUndef() === null)", "false");
            // typeof: null -> "object", undefined -> "undefined".
            try helpers.expectEvalEquals(inst, "typeof retNull()", "object");
            try helpers.expectEvalEquals(inst, "typeof retUndef()", "undefined");
        }
    }.run);
}

fn hClassifyArg(_: i32, args: value.NativeArgs) value.NativeResult {
    if (args.isNull(0)) {
        const owned = std.heap.c_allocator.dupe(u8, "null") catch return .null_val;
        return .{ .string = owned };
    }
    if (args.isUndefined(0)) {
        const owned = std.heap.c_allocator.dupe(u8, "undefined") catch return .null_val;
        return .{ .string = owned };
    }
    const owned = std.heap.c_allocator.dupe(u8, "other") catch return .null_val;
    return .{ .string = owned };
}

test "value: predicates classify JS-side null vs undefined arguments distinctly" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "classify", &hClassifyArg);
            try helpers.expectEvalEquals(inst, "classify(null)", "null");
            try helpers.expectEvalEquals(inst, "classify(undefined)", "undefined");
            try helpers.expectEvalEquals(inst, "classify()", "undefined");
            try helpers.expectEvalEquals(inst, "classify(0)", "other");
        }
    }.run);
}

test "value: no-ctx nullValue() and undefinedValue() are distinguishable across backends" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const u = ActiveEngine.undefinedValue();
            const n = ActiveEngine.nullValue();
            // The no-ctx variants are used as default-init slots. Whatever the representation, a Value produced by `nullValue()` must classify as null, and a Value produced by `undefinedValue()` as undefined.
            try testing.expect(ActiveEngine.isUndefined(ctx, u));
            try testing.expect(!ActiveEngine.isNull(ctx, u));
            try testing.expect(ActiveEngine.isNull(ctx, n));
            try testing.expect(!ActiveEngine.isUndefined(ctx, n));
        }
    }.run);
}

test "value: round-trip newNullVal as a property preserves null tag" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const obj = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, obj);
            const null_v = ActiveEngine.newNullVal(ctx);
            const undef_v = ActiveEngine.newUndefinedVal(ctx);
            // setPropertyStr takes ownership of the value
            ActiveEngine.setPropertyStr(ctx, obj, "n", null_v);
            ActiveEngine.setPropertyStr(ctx, obj, "u", undef_v);
            // JSON.stringify drops `undefined` props but keeps `null` ones. That observable difference is the whole point of the tag.
            const s = ActiveEngine.jsonStringifyVal(ctx, obj) orelse return error.ExpectedJson;
            defer value.freeString(s);
            try testing.expectEqualStrings("{\"n\":null}", s);
        }
    }.run);
}

// ========================================================================
// registerObjectWithFunctions
// ========================================================================

test "value: registerObjectWithFunctions registers multiple methods on an object" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            const handlers = [_]value.FunctionEntry{
                .{ .name = "add", .handler = &hAdd },
                .{ .name = "sub", .handler = &hSub },
            };
            value.registerObjectWithFunctions(inst, "myObj", &handlers);
            try helpers.expectEvalEquals(inst, "String(myObj.add(2,3))", "5");
            try helpers.expectEvalEquals(inst, "String(myObj.sub(10,4))", "6");
        }
    }.run);
}

// ========================================================================
// Edge cases
// ========================================================================

test "value: zero-arg call yields count()==0 and all predicates false except isUndefined" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "z", &hZeroArgs);
            try helpers.evalOk(inst, "z();");
            try testing.expectEqual(@as(usize, 0), g_count);
            try testing.expectEqual(true, g_bool_a); // isUndefined(0) -> true
            try testing.expectEqual(false, g_bool_b); // no other predicate true
        }
    }.run);
}

test "value: 10-arg call — all arguments accessible and summable" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "many", &hManyArgs);
            try helpers.expectEvalEquals(inst, "String(many(1,2,3,4,5,6,7,8,9,10))", "55");
            try testing.expectEqual(@as(usize, 10), g_count);
        }
    }.run);
}
