//! Completion admission must report an expired generation even when its numeric ID is reused.

const std = @import("std");
const c_api = @import("../c_api.zig");
const api_async = @import("../abi/api_async.zig");
const helpers = @import("test_helpers.zig");

test "async promise: generation replacement during admission reports stale for completion and cancellation" {
    const Probe = struct {
        id: i32,
        recreated: bool = false,
        fn replace(_: u64, context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse unreachable));
            api_async.setAfterClaimHookForTesting(null, null);
            c_api.jsbay_engine_destroy(self.id);
            self.recreated = c_api.jsbay_engine_create(self.id, null, null);
        }
    };
    for ([_]bool{ false, true }) |cancel| {
        const id = helpers.nextInstanceId();
        try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
        defer c_api.jsbay_engine_destroy(id);
        var request: u64 = 0;
        var value: u64 = 0;
        var exception: u64 = 0;
        try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_promise_create(id, &request, &value, &exception));
        var probe = Probe{ .id = id };
        api_async.setAfterClaimHookForTesting(Probe.replace, &probe);
        defer api_async.setAfterClaimHookForTesting(null, null);
        const status = if (cancel)
            c_api.jsbay_async_cancel(request)
        else
            c_api.jsbay_async_complete(request, 0, 0, .{ .data = "late".ptr, .len = 4 });
        try std.testing.expect(probe.recreated);
        try std.testing.expectEqual(@as(c_int, 5), status);
        try helpers.expectEvalEquals(id, "String(6 * 7)", "42");
        try std.testing.expectEqual(@as(c_int, 5), c_api.jsbay_async_cancel(request));
    }
}
