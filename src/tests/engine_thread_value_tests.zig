const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const engine_thread_value = @import("../runtime/engine_thread_value.zig");
const helpers = @import("test_helpers.zig");

const ActiveEngine = backend.ActiveEngine;

test "adoptTypedValue adopts successful serialization" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const ctx = engine.getContext(id) orelse return error.ContextUnavailable;
    const num = ActiveEngine.newInt32Val(ctx, 123);
    const adopted = engine_thread_value.adoptTypedValue(ctx, num, engine_thread_value.status_ok);
    defer if (adopted.result) |res| std.heap.c_allocator.free(res);
    try std.testing.expectEqual(engine_thread_value.status_ok, adopted.status);
    try std.testing.expectEqualStrings("123", adopted.result.?);
}

test "adoptTypedValue reports an exception value as err text" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const ctx = engine.getContext(id) orelse return error.ContextUnavailable;
    const err_str = ActiveEngine.newStringVal(ctx, "manual-error");
    const adopted = engine_thread_value.adoptTypedValue(ctx, err_str, engine_thread_value.status_exception);
    defer if (adopted.err) |e| std.heap.c_allocator.free(e);
    try std.testing.expectEqual(engine_thread_value.status_exception, adopted.status);
    try std.testing.expectEqualStrings("manual-error", adopted.err.?);
}
