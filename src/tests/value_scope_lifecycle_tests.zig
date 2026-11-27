const std = @import("std");
const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");

const API_OK: c_int = 0;
const API_INSTANCE_NOT_FOUND: c_int = 4;

const ValueScopeDestroyProbe = struct {
    instance_id: c_int,
    context_alive_in_callback: bool = false,
    post_destroy_status: c_int = -1,

    fn callback(user_data: ?*anyopaque) callconv(.c) void {
        const self: *ValueScopeDestroyProbe = @ptrCast(@alignCast(user_data.?));
        c_api.jsbay_engine_destroy(self.instance_id);
        self.context_alive_in_callback = engine.getContext(self.instance_id) != null;
        var value: u64 = 0;
        self.post_destroy_status = c_api.jsbay_value_undefined(self.instance_id, &value);
    }
};

test "c_api: value scope holds destruction until callback returns" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    var probe = ValueScopeDestroyProbe{ .instance_id = id };
    try std.testing.expectEqual(API_OK, c_api.jsbay_engine_with_value_scope(id, ValueScopeDestroyProbe.callback, &probe));
    try std.testing.expect(probe.context_alive_in_callback);
    try std.testing.expectEqual(API_INSTANCE_NOT_FOUND, probe.post_destroy_status);
    try std.testing.expect(engine.getContext(id) == null);
}
