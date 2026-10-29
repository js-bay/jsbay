//! A non-writable data property throws on strict assignment. This is [[Writable]]: false, not a getter with no setter.

const testing = @import("std").testing;
const helpers = @import("test_helpers.zig");
const value = @import("../value/root.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

fn publish(id: i32, name: [*:0]const u8, obj: ActiveEngine.Value) !void {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    ActiveEngine.setPropertyStr(ctx, global, name, ActiveEngine.dupValue(ctx, obj));
}

test "defineDataProperty writable false throws in strict mode and keeps the value" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const obj = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, obj);
            const original = ActiveEngine.newStringVal(ctx, "str");
            defer ActiveEngine.freeValue(ctx, original);
            try testing.expect(value.defineDataProperty(id, obj, "key", original, false));
            try publish(id, "__ro", obj);

            try helpers.evalErr(id, "\"use strict\"; __ro.key = 1;");

            const got = ActiveEngine.getPropertyVal(ctx, obj, "key") orelse return error.Missing;
            defer ActiveEngine.freeValue(ctx, got);
            try testing.expect(value.strictEquals(id, got, original));

            // Data descriptor: `value` is present, `writable` is false, no getter.
            try helpers.evalOk(id,
                \\var d = Object.getOwnPropertyDescriptor(__ro, "key");
                \\if (!d || d.writable !== false) throw new Error("writable");
                \\if (!Object.prototype.hasOwnProperty.call(d, "value")) throw new Error("not a data property");
                \\if (d.get !== undefined || d.set !== undefined) throw new Error("accessor");
                \\if (d.value !== "str") throw new Error("value");
            );
        }
    }.run);
}

test "defineDataProperty writable true accepts a strict assignment" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const obj = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, obj);
            const original = ActiveEngine.newStringVal(ctx, "str");
            defer ActiveEngine.freeValue(ctx, original);
            try testing.expect(value.defineDataProperty(id, obj, "key", original, true));
            try publish(id, "__rw", obj);

            try helpers.evalOk(id, "\"use strict\"; __rw.key = 1;");
            const got = ActiveEngine.getPropertyVal(ctx, obj, "key") orelse return error.Missing;
            defer ActiveEngine.freeValue(ctx, got);
            const one = ActiveEngine.newInt32Val(ctx, 1);
            defer ActiveEngine.freeValue(ctx, one);
            try testing.expect(value.strictEquals(id, got, one));
        }
    }.run);
}
