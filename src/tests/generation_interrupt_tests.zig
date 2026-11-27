const std = @import("std");
const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");
const instance_map = @import("../runtime/instance_map.zig");
const runtime_control = @import("../runtime/runtime_control.zig");
const types = @import("../types.zig");

const EventCapture = struct {
    count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn handler(_: *const types.EngineEvent, user_data: ?*anyopaque) callconv(.c) void {
        const self: *EventCapture = @ptrCast(@alignCast(user_data.?));
        _ = self.count.fetchAdd(1, .seq_cst);
    }
};

test "c_api: generation interrupt rejects a replaced instance" {
    if (comptime backend.isSpikeBackend(backend.active_backend)) return;
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    const first_generation = instance_map.captureGeneration(id) orelse return error.MissingGeneration;
    c_api.jsbay_engine_destroy(id);

    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    const second_generation = instance_map.captureGeneration(id) orelse return error.MissingGeneration;
    try std.testing.expect(first_generation != second_generation);
    var capture: EventCapture = .{};
    try std.testing.expect(c_api.jsbay_engine_set_event_handler(id, EventCapture.handler, &capture));
    try std.testing.expect(!c_api.jsbay_engine_request_interrupt_for_generation(id, first_generation));
    try std.testing.expect(!runtime_control.isInterruptRequested(id));
    try std.testing.expectEqual(@as(u32, 0), capture.count.load(.seq_cst));
    try std.testing.expect(c_api.jsbay_engine_request_interrupt_for_generation(id, second_generation));
    try std.testing.expect(runtime_control.isInterruptRequested(id));
    try std.testing.expectEqual(@as(u32, 1), capture.count.load(.seq_cst));
    try std.testing.expect(c_api.jsbay_engine_clear_interrupt(id));
    try std.testing.expect(c_api.jsbay_engine_set_event_handler(id, null, null));
}
