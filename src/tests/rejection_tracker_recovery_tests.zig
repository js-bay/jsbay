const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const types = @import("../types.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const c_api = @import("../c_api.zig");

const InterruptAfterFirstError = struct {
    count: u32 = 0,
    values: [3]u64 = @splat(0),

    fn handler(event: *const types.ErrorEvent, userdata: ?*anyopaque) callconv(.c) void {
        const self: *InterruptAfterFirstError = @ptrCast(@alignCast(userdata orelse return));
        if (self.count < self.values.len) _ = c_api.jsbay_value_retain(event.value, &self.values[self.count]);
        self.count += 1;
        if (self.count == 1) _ = c_api.jsbay_engine_request_interrupt(event.instance_id);
    }

    fn deinit(self: *InterruptAfterFirstError) void {
        for (self.values, 0..) |value, index| {
            if (value != 0) {
                _ = c_api.jsbay_value_release(value);
                self.values[index] = 0;
            }
        }
    }
};

test "error observer: interrupted object rejections survive recovery" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var log = InterruptAfterFirstError{};
    defer log.deinit();
    const registered = c_api.jsbay_engine_set_error_observer(id, InterruptAfterFirstError.handler, &log);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), registered);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), registered);
    defer _ = c_api.jsbay_engine_set_error_observer(id, null, null);

    try helpers.evalOk(id, "setTimeout(function () { Promise.reject(new Error('one')); Promise.reject(new Error('two')); Promise.reject(new Error('three')); }, 0);");
    engine.runEventLoopOnce(id);
    try testing.expectEqual(@as(u32, 1), log.count);
    try testing.expect(c_api.jsbay_engine_clear_interrupt(id));
    try helpers.evalOk(id, "void 0;");
    try testing.expectEqual(@as(u32, 3), log.count);
    for (log.values, [_][]const u8{ "one", "two", "three" }) |value, expected| {
        var message: u64 = 0;
        var exception: u64 = 0;
        try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_get(value, .{ .data = "message", .len = "message".len }, &message, &exception));
        defer _ = c_api.jsbay_value_release(message);
        var bytes: c_api.Bytes = .{ .data = null, .len = 0 };
        try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_to_utf8(message, &bytes, &exception));
        defer c_api.jsbay_free_bytes(bytes);
        const actual = if (bytes.data) |data| data[0..bytes.len] else "";
        try testing.expectEqualStrings(expected, actual);
    }
}
