//! Array holes are `undefined`, not `null`. `new Array(len)` leaves the slots empty; getting one must not collapse that to the null sentinel.

const testing = @import("std").testing;
const helpers = @import("test_helpers.zig");
const value = @import("../value/root.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

test "newArray holes are undefined, not null" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const arr = value.newArray(id, 4) orelse return error.NoArray;
            defer ActiveEngine.freeValue(ctx, arr);
            try testing.expectEqual(@as(u32, 4), value.arrayLength(id, arr) orelse return error.NoLength);

            const undef = ActiveEngine.newUndefinedVal(ctx);
            defer ActiveEngine.freeValue(ctx, undef);
            const nil = ActiveEngine.newNullVal(ctx);
            defer ActiveEngine.freeValue(ctx, nil);

            var index: u32 = 0;
            while (index < 4) : (index += 1) {
                const slot = value.arrayGet(id, arr, index) orelse return error.MissingSlot;
                defer ActiveEngine.freeValue(ctx, slot);
                try testing.expect(ActiveEngine.isUndefined(ctx, slot));
                try testing.expect(!ActiveEngine.isNull(ctx, slot));
                try testing.expect(value.strictEquals(id, slot, undef));
                try testing.expect(!value.strictEquals(id, slot, nil));
            }
        }
    }.run);
}

test "arraySet reads the string back and arrayClear sets length to 0" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const arr = value.newArray(id, 4) orelse return error.NoArray;
            defer ActiveEngine.freeValue(ctx, arr);

            const text = ActiveEngine.newStringVal(ctx, "slot0");
            defer ActiveEngine.freeValue(ctx, text);
            try testing.expect(value.arraySet(id, arr, 0, text));

            const got = value.arrayGet(id, arr, 0) orelse return error.MissingSlot;
            defer ActiveEngine.freeValue(ctx, got);
            try testing.expect(value.strictEquals(id, got, text));
            const rendered = ActiveEngine.valueToStringVal(ctx, got) orelse return error.NoString;
            defer value.freeString(rendered);
            try testing.expectEqualStrings("slot0", rendered);

            // The other holes stay undefined.
            const hole = value.arrayGet(id, arr, 1) orelse return error.MissingSlot;
            defer ActiveEngine.freeValue(ctx, hole);
            try testing.expect(ActiveEngine.isUndefined(ctx, hole));
            try testing.expect(!ActiveEngine.isNull(ctx, hole));

            try testing.expect(value.arrayClear(id, arr));
            try testing.expectEqual(@as(u32, 0), value.arrayLength(id, arr) orelse return error.NoLength);

            const after = value.arrayGet(id, arr, 0) orelse return error.MissingSlot;
            defer ActiveEngine.freeValue(ctx, after);
            try testing.expect(ActiveEngine.isUndefined(ctx, after));
            try testing.expect(!value.strictEquals(id, after, text));
        }
    }.run);
}
