//! Tests for Map + Set marshaling through NativeArgs / NativeResult.
//!
//! Content fidelity is checked through `JSON.stringify(Array.from(val))`.
//!

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const value = @import("../value/root.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

// ========================================================================
// Globals so handlers can surface observations to tests.
// ========================================================================
var g_size: ?u32 = null;
var g_is_map: ?bool = null;
var g_is_set: ?bool = null;
var g_json: ?[]const u8 = null;

fn resetGlobals() void {
    g_size = null;
    g_is_map = null;
    g_is_set = null;
    if (g_json) |j| {
        std.heap.c_allocator.free(@constCast(j));
        g_json = null;
    }
}

// ========================================================================
// Handlers.
// ========================================================================

fn hReadMap(_: i32, args: value.NativeArgs) value.NativeResult {
    g_is_map = args.isMap(0);
    g_size = args.mapOrSetSize(0);
    if (args.mapToJson(0)) |json| {
        // Dupe into a long-lived buffer so the test can inspect it after the handler returns. The handler's NativeArgs-owned copy is freed here.
        const owned = std.heap.c_allocator.dupe(u8, json) catch {
            value.freeString(json);
            return .null_val;
        };
        value.freeString(json);
        if (g_json) |old| std.heap.c_allocator.free(@constCast(old));
        g_json = owned;
        // Return the JSON string so JS can also see it.
        const out = std.heap.c_allocator.dupe(u8, owned) catch return .null_val;
        return .{ .string = out };
    }
    return .null_val;
}

fn hReadSet(_: i32, args: value.NativeArgs) value.NativeResult {
    g_is_set = args.isSet(0);
    g_size = args.mapOrSetSize(0);
    if (args.setToJson(0)) |json| {
        const owned = std.heap.c_allocator.dupe(u8, json) catch {
            value.freeString(json);
            return .null_val;
        };
        value.freeString(json);
        if (g_json) |old| std.heap.c_allocator.free(@constCast(old));
        g_json = owned;
        const out = std.heap.c_allocator.dupe(u8, owned) catch return .null_val;
        return .{ .string = out };
    }
    return .null_val;
}

fn hProbeMap(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.isMap(0) };
}

fn hProbeSet(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.isSet(0) };
}

fn hReturnMap(_: i32, _: value.NativeArgs) value.NativeResult {
    const json = std.heap.c_allocator.dupe(u8, "[[\"a\",1],[\"b\",2]]") catch return .null_val;
    return .{ .map_json = json };
}

fn hReturnSet(_: i32, _: value.NativeArgs) value.NativeResult {
    const json = std.heap.c_allocator.dupe(u8, "[10,20,30]") catch return .null_val;
    return .{ .set_json = json };
}

// ========================================================================
// Map tests.
// ========================================================================

test "map: JS passes Map; native reads size + JSON-serialized entries" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readMap", &hReadMap);
            try helpers.expectEvalEquals(
                inst,
                "readMap(new Map([['a',1],['b',2]]))",
                "[[\"a\",1],[\"b\",2]]",
            );
            try testing.expectEqual(@as(?bool, true), g_is_map);
            try testing.expectEqual(@as(?u32, 2), g_size);
            try testing.expect(g_json != null);
            if (g_json) |j| try testing.expectEqualStrings("[[\"a\",1],[\"b\",2]]", j);
            resetGlobals();
        }
    }.run);
}

test "map: empty Map round-trips with size=0 and JSON '[]'" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readMap", &hReadMap);
            try helpers.expectEvalEquals(inst, "readMap(new Map())", "[]");
            try testing.expectEqual(@as(?bool, true), g_is_map);
            try testing.expectEqual(@as(?u32, 0), g_size);
            resetGlobals();
        }
    }.run);
}

test "map: native returns Map; JS observes size + entries" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkMap", &hReturnMap);
            try helpers.expectEvalEquals(inst, "String(mkMap() instanceof Map)", "true");
            try helpers.expectEvalEquals(inst, "String(mkMap().size)", "2");
            try helpers.expectEvalEquals(inst, "String(mkMap().get('a'))", "1");
            try helpers.expectEvalEquals(inst, "String(mkMap().get('b'))", "2");
        }
    }.run);
}

test "map: isMap rejects plain objects, arrays, Sets" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "probe", &hProbeMap);
            try helpers.expectEvalEquals(inst, "String(probe({}))", "false");
            try helpers.expectEvalEquals(inst, "String(probe([]))", "false");
            try helpers.expectEvalEquals(inst, "String(probe(new Set([1])))", "false");
            try helpers.expectEvalEquals(inst, "String(probe(new Map()))", "true");
        }
    }.run);
}

// ========================================================================
// Set tests.
// ========================================================================

test "set: JS passes Set; native reads size + JSON-serialized elements" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readSet", &hReadSet);
            try helpers.expectEvalEquals(inst, "readSet(new Set([1,2,3]))", "[1,2,3]");
            try testing.expectEqual(@as(?bool, true), g_is_set);
            try testing.expectEqual(@as(?u32, 3), g_size);
            try testing.expect(g_json != null);
            if (g_json) |j| try testing.expectEqualStrings("[1,2,3]", j);
            resetGlobals();
        }
    }.run);
}

test "set: empty Set round-trips with size=0 and JSON '[]'" {
    resetGlobals();
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "readSet", &hReadSet);
            try helpers.expectEvalEquals(inst, "readSet(new Set())", "[]");
            try testing.expectEqual(@as(?bool, true), g_is_set);
            try testing.expectEqual(@as(?u32, 0), g_size);
            resetGlobals();
        }
    }.run);
}

test "set: native returns Set; JS observes size + has()" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkSet", &hReturnSet);
            try helpers.expectEvalEquals(inst, "String(mkSet() instanceof Set)", "true");
            try helpers.expectEvalEquals(inst, "String(mkSet().size)", "3");
            try helpers.expectEvalEquals(inst, "String(mkSet().has(20))", "true");
            try helpers.expectEvalEquals(inst, "String(mkSet().has(999))", "false");
        }
    }.run);
}

test "set: isSet rejects arrays, Maps, plain objects" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "probe", &hProbeSet);
            try helpers.expectEvalEquals(inst, "String(probe([]))", "false");
            try helpers.expectEvalEquals(inst, "String(probe(new Map()))", "false");
            try helpers.expectEvalEquals(inst, "String(probe({}))", "false");
            try helpers.expectEvalEquals(inst, "String(probe(new Set()))", "true");
        }
    }.run);
}

// ========================================================================
// Native iteration API tests (mapForEach / setForEach / newMap / newSet / ...)
//
// These exercise the *faithful* traversal path that bypasses JSON. Each test uses a callback context struct with a self-pointer wedged into an `*anyopaque`, the same pattern consumers will use.
// ========================================================================

const MapSumCtx = extern struct {
    // Accumulator for nested object properties (.x sums).
    x_total: i64 = 0,
    // How many entries the callback actually saw.
    entries_seen: u32 = 0,
    // Stop after this many iterations (0 = never stop).
    stop_after: u32 = 0,
};

fn mapSumXCallback(
    ctx: backend.ActiveEngine.Context,
    cb_ctx: ?*anyopaque,
    key: backend.ActiveEngine.Value,
    val: backend.ActiveEngine.Value,
) callconv(.c) bool {
    _ = key;
    const self: *MapSumCtx = @ptrCast(@alignCast(cb_ctx.?));
    // Read val.x as a number.
    if (ActiveEngine.getPropertyVal(ctx, val, "x")) |prop| {
        defer ActiveEngine.freeValue(ctx, prop);
        if (ActiveEngine.toFloat64(ctx, prop)) |d| {
            self.x_total += @intFromFloat(d);
        }
    }
    self.entries_seen += 1;
    if (self.stop_after != 0 and self.entries_seen >= self.stop_after) return false;
    return true;
}

const g_map_sum_state = struct {
    var data: MapSumCtx = .{};
};

fn hIterateMapXSum(_: i32, args: value.NativeArgs) value.NativeResult {
    g_map_sum_state.data = .{};
    const ok = args.mapForEach(0, @ptrCast(&g_map_sum_state.data), &mapSumXCallback);
    if (!ok) return .{ .err = std.heap.c_allocator.dupe(u8, "mapForEach failed") catch return .null_val };
    return .{ .number = @floatFromInt(g_map_sum_state.data.x_total) };
}

test "iteration: mapForEach reads nested object properties (JSON would flatten)" {
    g_map_sum_state.data = .{};
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "xsum", &hIterateMapXSum);
            // Map holds objects — JSON.stringify(Array.from()) flattens them but `mapForEach` exposes the objects directly so we can read .x.
            try helpers.expectEvalEquals(
                inst,
                "String(xsum(new Map([['a',{x:1}],['b',{x:2}]])))",
                "3",
            );
            try testing.expectEqual(@as(u32, 2), g_map_sum_state.data.entries_seen);
            try testing.expectEqual(@as(i64, 3), g_map_sum_state.data.x_total);
        }
    }.run);
}

const SetMixCtx = extern struct {
    number_total: i64 = 0,
    string_count: u32 = 0,
    object_x_total: i64 = 0,
    entries_seen: u32 = 0,
    stop_after: u32 = 0,
};

fn setMixCallback(
    ctx: backend.ActiveEngine.Context,
    cb_ctx: ?*anyopaque,
    val: backend.ActiveEngine.Value,
) callconv(.c) bool {
    const self: *SetMixCtx = @ptrCast(@alignCast(cb_ctx.?));
    self.entries_seen += 1;
    if (ActiveEngine.isNumber(ctx, val)) {
        if (ActiveEngine.toFloat64(ctx, val)) |d| self.number_total += @intFromFloat(d);
    } else if (ActiveEngine.isString(ctx, val)) {
        self.string_count += 1;
    } else if (ActiveEngine.isObjectVal(ctx, val)) {
        if (ActiveEngine.getPropertyVal(ctx, val, "x")) |prop| {
            defer ActiveEngine.freeValue(ctx, prop);
            if (ActiveEngine.toFloat64(ctx, prop)) |d| self.object_x_total += @intFromFloat(d);
        }
    }
    if (self.stop_after != 0 and self.entries_seen >= self.stop_after) return false;
    return true;
}

const g_set_mix_state = struct {
    var data: SetMixCtx = .{};
};

fn hIterateSetMix(_: i32, args: value.NativeArgs) value.NativeResult {
    g_set_mix_state.data = .{};
    const ok = args.setForEach(0, @ptrCast(&g_set_mix_state.data), &setMixCallback);
    if (!ok) return .{ .err = std.heap.c_allocator.dupe(u8, "setForEach failed") catch return .null_val };
    return .{ .number = @floatFromInt(g_set_mix_state.data.number_total + g_set_mix_state.data.object_x_total) };
}

test "iteration: setForEach visits mixed-type values (number, string, object)" {
    g_set_mix_state.data = .{};
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mix", &hIterateSetMix);
            try helpers.expectEvalEquals(
                inst,
                "String(mix(new Set([1, 'hi', {x:40}, 2])))",
                "43",
            );
            try testing.expectEqual(@as(u32, 4), g_set_mix_state.data.entries_seen);
            try testing.expectEqual(@as(i64, 3), g_set_mix_state.data.number_total);
            try testing.expectEqual(@as(u32, 1), g_set_mix_state.data.string_count);
            try testing.expectEqual(@as(i64, 40), g_set_mix_state.data.object_x_total);
        }
    }.run);
}

fn hEarlyExitMap(_: i32, args: value.NativeArgs) value.NativeResult {
    g_map_sum_state.data = .{ .stop_after = 2 };
    _ = args.mapForEach(0, @ptrCast(&g_map_sum_state.data), &mapSumXCallback);
    return .{ .number = @floatFromInt(g_map_sum_state.data.entries_seen) };
}

test "iteration: callback returning false stops Map iteration after 2 entries" {
    g_map_sum_state.data = .{};
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "first2", &hEarlyExitMap);
            try helpers.expectEvalEquals(
                inst,
                "String(first2(new Map([['a',{x:1}],['b',{x:2}],['c',{x:3}],['d',{x:4}]])))",
                "2",
            );
            try testing.expectEqual(@as(u32, 2), g_map_sum_state.data.entries_seen);
            // First two entries only → 1 + 2 = 3.
            try testing.expectEqual(@as(i64, 3), g_map_sum_state.data.x_total);
        }
    }.run);
}

fn hEmptyMapIter(_: i32, args: value.NativeArgs) value.NativeResult {
    g_map_sum_state.data = .{};
    const ok = args.mapForEach(0, @ptrCast(&g_map_sum_state.data), &mapSumXCallback);
    if (!ok) return .{ .err = std.heap.c_allocator.dupe(u8, "empty mapForEach failed") catch return .null_val };
    // Pack observed size and entries_seen so JS can assert both.
    return .{ .number = @floatFromInt(@as(i64, g_map_sum_state.data.entries_seen)) };
}

test "iteration: empty Map iteration invokes callback zero times" {
    g_map_sum_state.data = .{};
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "emptyIter", &hEmptyMapIter);
            try helpers.expectEvalEquals(inst, "String(emptyIter(new Map()))", "0");
            try testing.expectEqual(@as(u32, 0), g_map_sum_state.data.entries_seen);
        }
    }.run);
}

fn hEmptySetIter(_: i32, args: value.NativeArgs) value.NativeResult {
    g_set_mix_state.data = .{};
    _ = args.setForEach(0, @ptrCast(&g_set_mix_state.data), &setMixCallback);
    return .{ .number = @floatFromInt(@as(i64, g_set_mix_state.data.entries_seen)) };
}

test "iteration: empty Set iteration invokes callback zero times" {
    g_set_mix_state.data = .{};
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "emptySetIter", &hEmptySetIter);
            try helpers.expectEvalEquals(inst, "String(emptySetIter(new Set()))", "0");
            try testing.expectEqual(@as(u32, 0), g_set_mix_state.data.entries_seen);
        }
    }.run);
}

fn hForEachOnNonMap(_: i32, args: value.NativeArgs) value.NativeResult {
    g_map_sum_state.data = .{};
    const ok = args.mapForEach(0, @ptrCast(&g_map_sum_state.data), &mapSumXCallback);
    // Policy: non-Map input → returns false, callback not invoked, no panic.
    return .{ .boolean = ok };
}

test "iteration: mapForEach on non-Map returns false without invoking callback" {
    g_map_sum_state.data = .{};
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "tryIter", &hForEachOnNonMap);
            // Plain array — not a Map.
            try helpers.expectEvalEquals(inst, "String(tryIter([['a',1]]))", "false");
            try testing.expectEqual(@as(u32, 0), g_map_sum_state.data.entries_seen);
            // Plain object.
            g_map_sum_state.data = .{};
            try helpers.expectEvalEquals(inst, "String(tryIter({a:1}))", "false");
            try testing.expectEqual(@as(u32, 0), g_map_sum_state.data.entries_seen);
            // Set — still not a Map.
            g_map_sum_state.data = .{};
            try helpers.expectEvalEquals(inst, "String(tryIter(new Set([1,2])))", "false");
            try testing.expectEqual(@as(u32, 0), g_map_sum_state.data.entries_seen);
        }
    }.run);
}

// ---- Builder API (newMap + mapSet with object values) ----

fn hBuildMapWithObjects(_: i32, args: value.NativeArgs) value.NativeResult {
    _ = args;
    const ctx = currentCtx() orelse return .null_val;
    const map = value.newMap(ctx);
    // key1 = "a"; value1 = { x: 10 }
    const k1 = ActiveEngine.newStringVal(ctx, "a");
    defer ActiveEngine.freeValue(ctx, k1);
    const v1 = ActiveEngine.newObject(ctx);
    defer ActiveEngine.freeValue(ctx, v1);
    ActiveEngine.setPropertyStr(ctx, v1, "x", ActiveEngine.newInt32Val(ctx, 10));
    _ = value.mapSet(ctx, map, k1, v1);

    const k2 = ActiveEngine.newStringVal(ctx, "b");
    defer ActiveEngine.freeValue(ctx, k2);
    const v2 = ActiveEngine.newObject(ctx);
    defer ActiveEngine.freeValue(ctx, v2);
    ActiveEngine.setPropertyStr(ctx, v2, "x", ActiveEngine.newInt32Val(ctx, 20));
    _ = value.mapSet(ctx, map, k2, v2);

    return .{ .value = map };
}

fn currentCtx() ?backend.ActiveEngine.Context {
    // Best-effort lookup: if any engine exists, grab its ctx. The test only ever has one live engine at a time so picking the first is deterministic.
    const instance_map = @import("../runtime/instance_map.zig");
    var id: i32 = 10_000;
    while (id < 20_000) : (id += 1) {
        const maybe = instance_map.withInstanceReturn(id, struct {
            pub fn call(_: @This(), inst: *instance_map.EngineInstance) ?backend.ActiveEngine.Context {
                return inst.monoCtx();
            }
        }{});
        if (maybe) |c| return c;
    }
    return null;
}

test "builder: newMap + mapSet with object values survives round-trip to JS" {
    // Windows CI currently crashes inside QuickJS while materializing Map object values
    // (null JSShape). Keep coverage on POSIX hosts until the builder path is hardened.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkMapWithObjs", &hBuildMapWithObjects);
            try helpers.expectEvalEquals(inst, "String(mkMapWithObjs() instanceof Map)", "true");
            try helpers.expectEvalEquals(inst, "String(mkMapWithObjs().size)", "2");
            try helpers.expectEvalEquals(inst, "String(mkMapWithObjs().get('a').x)", "10");
            try helpers.expectEvalEquals(inst, "String(mkMapWithObjs().get('b').x)", "20");
            // Crucially: the value is the real object, not a JSON snapshot.
            try helpers.expectEvalEquals(
                inst,
                "(() => { const m = mkMapWithObjs(); const o = m.get('a'); o.mutated = 42; return String(m.get('a').mutated); })()",
                "42",
            );
        }
    }.run);
}

fn hBuildSetWithMixed(_: i32, args: value.NativeArgs) value.NativeResult {
    _ = args;
    const ctx = currentCtx() orelse return .null_val;
    const set = value.newSet(ctx);
    const n = ActiveEngine.newInt32Val(ctx, 7);
    defer ActiveEngine.freeValue(ctx, n);
    _ = value.setAdd(ctx, set, n);
    const s = ActiveEngine.newStringVal(ctx, "hi");
    defer ActiveEngine.freeValue(ctx, s);
    _ = value.setAdd(ctx, set, s);
    return .{ .value = set };
}

test "builder: newSet + setAdd produces a real Set round-trip" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "mkSetMix", &hBuildSetWithMixed);
            try helpers.expectEvalEquals(inst, "String(mkSetMix() instanceof Set)", "true");
            try helpers.expectEvalEquals(inst, "String(mkSetMix().size)", "2");
            try helpers.expectEvalEquals(inst, "String(mkSetMix().has(7))", "true");
            try helpers.expectEvalEquals(inst, "String(mkSetMix().has('hi'))", "true");
            try helpers.expectEvalEquals(inst, "String(mkSetMix().has(99))", "false");
        }
    }.run);
}

// ---- mapSize / setSize typed helpers ----

fn hMapSize(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.mapSize(0) orelse return .{ .number = -1 };
    return .{ .number = @floatFromInt(@as(i64, @intCast(s))) };
}

fn hSetSize(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.setSize(0) orelse return .{ .number = -1 };
    return .{ .number = @floatFromInt(@as(i64, @intCast(s))) };
}

test "typed size: mapSize returns size for Map, null for non-Map" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "ms", &hMapSize);
            try helpers.expectEvalEquals(inst, "String(ms(new Map([[1,2],[3,4]])))", "2");
            try helpers.expectEvalEquals(inst, "String(ms(new Map()))", "0");
            // Not a Map → sentinel -1.
            try helpers.expectEvalEquals(inst, "String(ms([1,2,3]))", "-1");
            try helpers.expectEvalEquals(inst, "String(ms(new Set([1,2])))", "-1");
        }
    }.run);
}

test "typed size: setSize returns size for Set, null for non-Set" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            value.registerFunction(inst, null, "ss", &hSetSize);
            try helpers.expectEvalEquals(inst, "String(ss(new Set([1,2,3])))", "3");
            try helpers.expectEvalEquals(inst, "String(ss(new Set()))", "0");
            try helpers.expectEvalEquals(inst, "String(ss(new Map([[1,2]])))", "-1");
            try helpers.expectEvalEquals(inst, "String(ss([1,2,3]))", "-1");
        }
    }.run);
}
