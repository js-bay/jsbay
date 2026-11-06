//! Invalid output pointers and backend selection at the public Promise boundary.

const std = @import("std");
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");

test "async boundary: invalid output pointers clear every provided output" {
    const id = helpers.nextInstanceId();
    var request: u64 = 99;
    var value: u64 = 98;
    var exception: u64 = 97;
    try std.testing.expectEqual(@as(c_int, 2), c_api.jsbay_promise_create(id, null, &value, &exception));
    try std.testing.expectEqual(@as(u64, 0), value);
    try std.testing.expectEqual(@as(u64, 0), exception);
    value = 98;
    exception = 97;
    try std.testing.expectEqual(@as(c_int, 2), c_api.jsbay_promise_create(id, &request, null, &exception));
    try std.testing.expectEqual(@as(u64, 0), request);
    try std.testing.expectEqual(@as(u64, 0), exception);
    request = 99;
    try std.testing.expectEqual(@as(c_int, 2), c_api.jsbay_promise_create(id, &request, &value, null));
    try std.testing.expectEqual(@as(u64, 0), request);
    try std.testing.expectEqual(@as(u64, 0), value);
}

test "async boundary: packed alternate instances report unsupported and clear outputs" {
    var backends: [5]c_api.BackendC = undefined;
    const count = c_api.jsbay_available_backends(&backends, backends.len);
    const primary = c_api.jsbay_library_backend();
    var tested = false;
    for (backends[0..@min(count, backends.len)]) |selected| {
        if (@backingInt(selected) == primary) continue;
        tested = true;
        const id = helpers.nextInstanceId();
        var options = c_api.EngineCreateOptionsC{ .struct_size = @sizeOf(c_api.EngineCreateOptionsC), .backend = selected };
        try std.testing.expect(c_api.jsbay_engine_create_with_options(id, &options));
        defer c_api.jsbay_engine_destroy(id);
        var request: u64 = 99;
        var value: u64 = 98;
        var exception: u64 = 97;
        try std.testing.expectEqual(@as(c_int, 7), c_api.jsbay_promise_create(id, &request, &value, &exception));
        try std.testing.expectEqual(@as(u64, 0), request);
        try std.testing.expectEqual(@as(u64, 0), value);
        try std.testing.expectEqual(@as(u64, 0), exception);
    }
    if (!tested) return error.SkipZigTest;
}

test "async boundary: a packed alternate value cannot settle a primary promise" {
    var backends: [5]c_api.BackendC = undefined;
    const count = c_api.jsbay_available_backends(&backends, backends.len);
    const primary = c_api.jsbay_library_backend();
    for (backends[0..@min(count, backends.len)]) |selected| {
        if (@backingInt(selected) == primary) continue;
        const primary_id = helpers.nextInstanceId();
        const alternate_id = helpers.nextInstanceId();
        try std.testing.expect(c_api.jsbay_engine_create(primary_id, null, null));
        defer c_api.jsbay_engine_destroy(primary_id);
        var options = c_api.EngineCreateOptionsC{ .struct_size = @sizeOf(c_api.EngineCreateOptionsC), .backend = selected };
        try std.testing.expect(c_api.jsbay_engine_create_with_options(alternate_id, &options));
        defer c_api.jsbay_engine_destroy(alternate_id);
        var request: u64 = 0;
        var promise: u64 = 0;
        var exception: u64 = 0;
        try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_promise_create(primary_id, &request, &promise, &exception));
        defer _ = c_api.jsbay_value_release(promise);
        var foreign: u64 = 0;
        try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_new_number(alternate_id, 7, &foreign));
        defer _ = c_api.jsbay_value_release(foreign);
        try std.testing.expectEqual(@as(c_int, 2), c_api.jsbay_promise_settle(request, 0, foreign));
        var local: u64 = 0;
        try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_new_number(primary_id, 7, &local));
        defer _ = c_api.jsbay_value_release(local);
        try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_promise_settle(request, 0, local));
        return;
    }
    return error.SkipZigTest;
}
