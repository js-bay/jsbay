//! JSC NULL_SENTINEL coverage.
//!
//! `src/backend/jsc/common.zig` defines `NULL_SENTINEL = 0x1` so that the no-ctx `nullValue()` and `undefinedValue()` are distinguishable at the `ActiveEngine.Value` layer.
//!
//! These tests feed `ActiveEngine.nullValue()` (the sentinel on JSC, JS_NULL on QuickJS) into each entry point and require JavaScript `null` semantics without passing the sentinel into a JSC API.
//!
//! Each entry point must handle the sentinel as JavaScript `null` on JSC.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

// ============================================================================
// value.zig entries — type extraction
//
// `JSValueToBoolean(ctx, 0x1)` / `JSValueToNumber(ctx, 0x1, &exc)` deref the sentinel. JS spec for the corresponding coercions on `null`: Boolean(null) === false Number(null) === 0 (so toInt32 / toFloat64 → 0 / 0.0)
// ============================================================================

test "jsc-sentinel: toBool(nullValue()) returns false (Boolean(null))" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            const got = ActiveEngine.toBool(ctx, v);
            try testing.expectEqual(@as(?bool, false), got);
        }
    }.run);
}

test "jsc-sentinel: toInt32(nullValue()) returns 0 (Number(null) | 0)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            const got = ActiveEngine.toInt32(ctx, v);
            try testing.expectEqual(@as(?i32, 0), got);
        }
    }.run);
}

test "jsc-sentinel: toFloat64(nullValue()) returns 0.0 (Number(null))" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            const got = ActiveEngine.toFloat64(ctx, v);
            try testing.expect(got != null);
            try testing.expectEqual(@as(f64, 0.0), got.?);
        }
    }.run);
}

// ============================================================================
// value.zig entries — property / array / function access
//
// Property access on JS `null` throws TypeError. The Zig API represents an exception with optional `null` or false; callers must receive that result without a sentinel-pointer crash.
// ============================================================================

test "jsc-sentinel: getPropertyVal(nullValue(), \"foo\") does not crash and returns null" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const obj = ActiveEngine.nullValue();
            const got = ActiveEngine.getPropertyVal(ctx, obj, "foo");
            try testing.expect(got == null);
        }
    }.run);
}

test "jsc-sentinel: hasProperty(nullValue(), \"foo\") does not crash and returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const obj = ActiveEngine.nullValue();
            const got = ActiveEngine.hasProperty(ctx, obj, "foo");
            try testing.expectEqual(false, got);
        }
    }.run);
}

test "jsc-sentinel: getIndex(nullValue(), 0) does not crash and returns null" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const arr = ActiveEngine.nullValue();
            const got = ActiveEngine.getIndex(ctx, arr, 0);
            try testing.expect(got == null);
        }
    }.run);
}

test "jsc-sentinel: getLength(nullValue()) does not crash and returns null" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const obj = ActiveEngine.nullValue();
            const got = ActiveEngine.getLength(ctx, obj);
            try testing.expect(got == null);
        }
    }.run);
}

test "jsc-sentinel: callFunction(nullValue(), this, args) does not crash and returns null" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const func = ActiveEngine.nullValue();
            const this_v = ActiveEngine.undefinedValue();
            const args = [_]ActiveEngine.Value{};
            const got = ActiveEngine.callFunction(ctx, func, this_v, args[0..]);
            // null receiver / non-callable: must not crash. Both backends surface "no result" by returning the optional null.
            try testing.expect(got == null);
        }
    }.run);
}

// ============================================================================
// datatypes.zig entries — Date / BigInt / Map / Set / DataView predicates.
//
// All of these directly forward `val` into `JSValueIs*` / object-method dispatch without lifting the sentinel. Each must classify the no-ctx `nullValue()` as "not a Date / not a BigInt / …" — i.e. return `false`.
// ============================================================================

test "jsc-sentinel: isDate(nullValue()) returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expectEqual(false, ActiveEngine.isDate(ctx, v));
        }
    }.run);
}

test "jsc-sentinel: toDateMs(nullValue()) returns null (not a Date)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expect(ActiveEngine.toDateMs(ctx, v) == null);
        }
    }.run);
}

test "jsc-sentinel: isBigInt(nullValue()) returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expectEqual(false, ActiveEngine.isBigInt(ctx, v));
        }
    }.run);
}

test "jsc-sentinel: toBigIntI64(nullValue()) returns null (not a BigInt)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expect(ActiveEngine.toBigIntI64(ctx, v) == null);
        }
    }.run);
}

test "jsc-sentinel: toBigIntU64(nullValue()) returns null (not a BigInt)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expect(ActiveEngine.toBigIntU64(ctx, v) == null);
        }
    }.run);
}

test "jsc-sentinel: isMap(nullValue()) returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expectEqual(false, ActiveEngine.isMap(ctx, v));
        }
    }.run);
}

test "jsc-sentinel: isSet(nullValue()) returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expectEqual(false, ActiveEngine.isSet(ctx, v));
        }
    }.run);
}

test "jsc-sentinel: mapSize(nullValue()) returns null (not a Map)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expect(ActiveEngine.mapSize(ctx, v) == null);
        }
    }.run);
}

test "jsc-sentinel: setSize(nullValue()) returns null (not a Set)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expect(ActiveEngine.setSize(ctx, v) == null);
        }
    }.run);
}

test "jsc-sentinel: mapSetToJson(nullValue()) returns null (no crash on non-Map)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            // Forwards `val` into Array.from(val) — currently passes 0x1 straight to JSObjectCallAsFunction which derefs it.
            try testing.expect(ActiveEngine.mapSetToJson(ctx, v) == null);
        }
    }.run);
}

test "jsc-sentinel: mapSet(nullValue(), key, value) returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const map = ActiveEngine.nullValue();
            const key = ActiveEngine.newInt32Val(ctx, 1);
            defer ActiveEngine.freeValue(ctx, key);
            const value = ActiveEngine.newInt32Val(ctx, 2);
            defer ActiveEngine.freeValue(ctx, value);
            try testing.expectEqual(false, ActiveEngine.mapSet(ctx, map, key, value));
        }
    }.run);
}

test "jsc-sentinel: setAdd(nullValue(), value) returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const set = ActiveEngine.nullValue();
            const value = ActiveEngine.newInt32Val(ctx, 1);
            defer ActiveEngine.freeValue(ctx, value);
            try testing.expectEqual(false, ActiveEngine.setAdd(ctx, set, value));
        }
    }.run);
}

test "jsc-sentinel: isDataView(nullValue()) returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expectEqual(false, ActiveEngine.isDataView(ctx, v));
        }
    }.run);
}

test "jsc-sentinel: dataViewInfo(nullValue()) returns null (not a DataView)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expect(ActiveEngine.dataViewInfo(ctx, v) == null);
        }
    }.run);
}

// ============================================================================
// Map / Set iteration drivers — entries route through the unprotected `is*` predicates above, so they SEGV on the same deref-0x1 path.
// ============================================================================

fn neverReachedMapCb(
    _: ActiveEngine.Context,
    _: ?*anyopaque,
    _: ActiveEngine.Value,
    _: ActiveEngine.Value,
) callconv(.c) bool {
    return false;
}

fn neverReachedSetCb(
    _: ActiveEngine.Context,
    _: ?*anyopaque,
    _: ActiveEngine.Value,
) callconv(.c) bool {
    return false;
}

test "jsc-sentinel: mapForEach(nullValue(), …) returns false (not a Map)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expectEqual(false, ActiveEngine.mapForEach(ctx, v, null, &neverReachedMapCb));
        }
    }.run);
}

test "jsc-sentinel: setForEach(nullValue(), …) returns false (not a Set)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const v = ActiveEngine.nullValue();
            try testing.expectEqual(false, ActiveEngine.setForEach(ctx, v, null, &neverReachedSetCb));
        }
    }.run);
}
