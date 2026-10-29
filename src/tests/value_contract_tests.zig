//! Host strict equality. JavaScript `===`: NaN is not equal to NaN, +0 equals -0, true is not 1, equal string contents match, distinct objects do not.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const value = @import("../value/root.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

test "strictEquals: NaN does not equal NaN" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const a = ActiveEngine.newFloat64Val(ctx, std.math.nan(f64));
            defer ActiveEngine.freeValue(ctx, a);
            const b = ActiveEngine.newFloat64Val(ctx, std.math.nan(f64));
            defer ActiveEngine.freeValue(ctx, b);
            try testing.expect(!value.strictEquals(id, a, b));
        }
    }.run);
}

test "strictEquals: +0 equals -0" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const pos = ActiveEngine.newFloat64Val(ctx, 0.0);
            defer ActiveEngine.freeValue(ctx, pos);
            const neg = ActiveEngine.newFloat64Val(ctx, -0.0);
            defer ActiveEngine.freeValue(ctx, neg);
            try testing.expect(value.strictEquals(id, pos, neg));
            try testing.expect(value.strictEquals(id, neg, pos));
        }
    }.run);
}

test "strictEquals: true does not equal 1" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const flag = ActiveEngine.newBoolVal(ctx, true);
            defer ActiveEngine.freeValue(ctx, flag);
            const one = ActiveEngine.newInt32Val(ctx, 1);
            defer ActiveEngine.freeValue(ctx, one);
            try testing.expect(!value.strictEquals(id, flag, one));
        }
    }.run);
}

test "strictEquals: same string content is equal" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const a = ActiveEngine.newStringVal(ctx, "rick");
            defer ActiveEngine.freeValue(ctx, a);
            const b = ActiveEngine.newStringVal(ctx, "rick");
            defer ActiveEngine.freeValue(ctx, b);
            const other = ActiveEngine.newStringVal(ctx, "morty");
            defer ActiveEngine.freeValue(ctx, other);
            try testing.expect(value.strictEquals(id, a, b));
            try testing.expect(value.strictEquals(id, b, a));
            try testing.expect(!value.strictEquals(id, a, other));
        }
    }.run);
}

test "strictEquals: two new objects are not equal" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const a = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, a);
            const b = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, b);
            try testing.expect(value.strictEquals(id, a, a));
            try testing.expect(!value.strictEquals(id, a, b));
        }
    }.run);
}
