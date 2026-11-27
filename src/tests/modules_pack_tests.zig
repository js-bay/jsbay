//! Tests for packed secondary module operations.

const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");

const testing = std.testing;

fn secondaryPackedBackend() ?backend.BackendType {
    if (!backend.multi_pack) return null;
    var available: [8]backend.BackendType = undefined;
    const count = @import("../multi_pack.zig").availableBackends(&available);
    for (available[0..count]) |tag| {
        if (tag != backend.active_backend) return tag;
    }
    return null;
}

test "modules: packed secondary module entry is rejected" {
    const tag = secondaryPackedBackend() orelse return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try engine.createWithBackend(id, .{}, tag);
    defer engine.destroy(id);

    const result = engine.evalModule(id, "globalThis.__secondary_module__ = true;", "<secondary-module>");
    defer helpers.freeEvalResult(result);
    try testing.expectEqualStrings("ES module operations are not supported for packed secondary instances", result.err.?);
    try testing.expect(!result.err_is_heap);
    try testing.expect(result.result == null);
}

test "modules: packed secondary import entry is rejected" {
    const tag = secondaryPackedBackend() orelse return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try engine.createWithBackend(id, .{}, tag);
    defer engine.destroy(id);

    const result = engine.importModule(id, "missing");
    defer helpers.freeEvalResult(result);
    try testing.expectEqualStrings("ES module operations are not supported for packed secondary instances", result.err.?);
    try testing.expect(!result.err_is_heap);
    try testing.expect(result.result == null);
}
