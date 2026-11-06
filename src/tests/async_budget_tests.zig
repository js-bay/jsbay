//! Payload reservations must be returned on both delivery and queued teardown.

const std = @import("std");
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");

fn createPromise(id: i32) !u64 {
    var request: u64 = 0;
    var value: u64 = 0;
    var exception: u64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_promise_create(id, &request, &value, &exception));
    try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_release(value));
    return request;
}

fn globalBytes() !usize {
    var usage: c_api.ResourceGlobalUsageC = undefined;
    usage.struct_size = @sizeOf(c_api.ResourceGlobalUsageC);
    try std.testing.expect(c_api.jsbay_resource_global_usage(&usage));
    return usage.pending_bytes;
}

test "async promise: delivered payload reservations are returned before the next request" {
    const before = try globalBytes();
    const id = helpers.nextInstanceId();
    var limits = c_api.ResourceLimitsC{
        .struct_size = @sizeOf(c_api.ResourceLimitsC),
        .max_timers = 0,
        .max_tsfn_handles = 0,
        .max_pending_calls = 1,
        .max_pending_bytes = 8,
        .max_pending_tasks = 1,
    };
    try std.testing.expect(c_api.jsbay_engine_create_with_limits(id, null, null, &limits));
    defer c_api.jsbay_engine_destroy(id);
    for (0..5) |_| {
        const request = try createPromise(id);
        try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(request, 0, 0, .{ .data = "done".ptr, .len = 4 }));
        _ = c_api.test_only.advance(id, 0);
        var usage: c_api.ResourceUsageC = undefined;
        usage.struct_size = @sizeOf(c_api.ResourceUsageC);
        try std.testing.expect(c_api.jsbay_engine_get_resource_usage(id, &usage));
        try std.testing.expectEqual(@as(usize, 0), usage.pending_bytes);
        try std.testing.expectEqual(before, try globalBytes());
    }
}

test "async promise: destroying queued payloads returns the process reservation" {
    const before = try globalBytes();
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    const request = try createPromise(id);
    try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(request, 0, 0, .{ .data = "done".ptr, .len = 4 }));
    c_api.jsbay_engine_destroy(id);
    try std.testing.expectEqual(before, try globalBytes());
}
