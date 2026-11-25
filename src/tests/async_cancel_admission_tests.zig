//! Async cancellation admission retry contract tests.

const std = @import("std");
const testing = std.testing;
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");
const dispatch = @import("../runtime/dispatch.zig");

fn createPromise(id: i32) !struct { request: u64, promise: u64 } {
    var request: u64 = 0;
    var promise: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_promise_create(id, &request, &promise, &exception));
    try testing.expect(request != 0 and promise != 0 and exception == 0);
    return .{ .request = request, .promise = promise };
}

fn installPromise(id: i32, promise: u64, name: []const u8) !void {
    var global: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_global(id, &global));
    defer _ = c_api.jsbay_value_release(global);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_set(global, .{ .data = name.ptr, .len = name.len }, promise, &exception));
    try testing.expectEqual(@as(u64, 0), exception);
}

fn advance(id: i32) void {
    _ = c_api.test_only.advance(id, 0);
}

test "async promise: failed cancellation admission leaves the request retryable" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var usage: c_api.ResourceUsageC = undefined;
    usage.struct_size = @sizeOf(c_api.ResourceUsageC);
    try testing.expect(c_api.jsbay_engine_get_resource_usage(id, &usage));
    const pending_calls_baseline = usage.pending_calls;
    const created = try createPromise(id);
    defer _ = c_api.jsbay_value_release(created.promise);
    try installPromise(id, created.promise, "asyncCancelRetry");
    try helpers.evalOk(id, "globalThis.asyncCancelRetryCount=0; asyncCancelRetry.catch(()=>asyncCancelRetryCount++);");

    usage = undefined;
    usage.struct_size = @sizeOf(c_api.ResourceUsageC);
    try testing.expect(c_api.jsbay_engine_get_resource_usage(id, &usage));
    try testing.expectEqual(pending_calls_baseline + 1, usage.pending_calls);

    dispatch.failNextQueueAllocationForTesting();
    try testing.expectEqual(@as(c_int, 6), c_api.jsbay_async_cancel(created.request));
    usage = undefined;
    usage.struct_size = @sizeOf(c_api.ResourceUsageC);
    try testing.expect(c_api.jsbay_engine_get_resource_usage(id, &usage));
    try testing.expectEqual(pending_calls_baseline + 1, usage.pending_calls);

    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_cancel(created.request));
    try testing.expectEqual(@as(c_int, 5), c_api.jsbay_async_cancel(created.request));
    advance(id);
    try helpers.expectEvalEquals(id, "String(asyncCancelRetryCount)", "1");
    usage = undefined;
    usage.struct_size = @sizeOf(c_api.ResourceUsageC);
    try testing.expect(c_api.jsbay_engine_get_resource_usage(id, &usage));
    try testing.expectEqual(pending_calls_baseline, usage.pending_calls);
}
