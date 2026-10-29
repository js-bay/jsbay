//! ArrayBuffer byte length is the backing store, not a shadowed JS property.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const buffers = @import("../value/buffers.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

test "getBufferView length ignores a redefined ArrayBuffer byteLength" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            try helpers.evalOk(id, "globalThis.__ab__ = new ArrayBuffer(10);");

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const ab = ActiveEngine.getPropertyVal(ctx, global, "__ab__") orelse
                return error.NoBuffer;
            defer ActiveEngine.freeValue(ctx, ab);

            const created = buffers.getBufferView(id, ab) orelse return error.NoView;
            try testing.expectEqual(@as(usize, 10), created.len);

            try helpers.evalOk(id, "Object.defineProperty(globalThis.__ab__, 'byteLength', { value: 20 });");
            try helpers.expectEvalEquals(id, "String(globalThis.__ab__.byteLength)", "20");

            const after = buffers.getBufferView(id, ab) orelse return error.NoView;
            try testing.expectEqual(@as(usize, 10), after.len);
        }
    }.run);
}
