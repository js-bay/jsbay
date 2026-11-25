const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const types = @import("../types.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const c_api = @import("../c_api.zig");

const InterruptAfterFirstError = struct {
    count: u32 = 0,

    fn handler(event: *const types.ErrorEvent, userdata: ?*anyopaque) callconv(.c) void {
        const self: *InterruptAfterFirstError = @ptrCast(@alignCast(userdata orelse return));
        self.count += 1;
        if (self.count == 1) _ = c_api.jsbay_engine_request_interrupt(event.instance_id);
    }
};

test "error observer: interrupted object rejections survive recovery" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var log = InterruptAfterFirstError{};
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
}
