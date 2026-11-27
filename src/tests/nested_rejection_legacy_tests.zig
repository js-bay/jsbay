//! Cross-instance legacy rejection callback regression tests.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const promise = @import("../runtime/promise.zig");
const types = @import("../types.zig");

const NestedReject = struct {
    target_id: i32,

    fn callback(_: i32, _: bool, _: [*]const u8, _: usize, userdata: ?*anyopaque) callconv(.c) void {
        const self: *NestedReject = @ptrCast(@alignCast(userdata orelse return));
        helpers.evalOk(self.target_id, "Promise.reject('nested-legacy-rejection');") catch unreachable;
    }
};

const EventCount = struct {
    count: u32 = 0,

    fn callback(event: *const types.ErrorEvent, userdata: ?*anyopaque) callconv(.c) void {
        const self: *EventCount = @ptrCast(@alignCast(userdata orelse return));
        if (event.kind == .unhandled_rejection) self.count += 1;
    }
};

const LegacyCount = struct {
    count: u32 = 0,
    instance_id: i32 = 0,
    reason: [128]u8 = undefined,
    reason_len: usize = 0,

    fn callback(instance_id: i32, handled: bool, reason: [*]const u8, reason_len: usize, userdata: ?*anyopaque) callconv(.c) void {
        const self: *LegacyCount = @ptrCast(@alignCast(userdata orelse return));
        if (!handled) {
            self.count += 1;
            self.instance_id = instance_id;
            self.reason_len = @min(reason_len, self.reason.len);
            @memcpy(self.reason[0..self.reason_len], reason[0..self.reason_len]);
        }
    }
};

test "rejection: nested legacy callback reports the inner legacy tracker" {
    const outer_id = helpers.nextInstanceId();
    const inner_id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(outer_id, null, null));
    defer c_api.jsbay_engine_destroy(outer_id);
    try testing.expect(c_api.jsbay_engine_create(inner_id, null, null));
    defer c_api.jsbay_engine_destroy(inner_id);

    var events = LegacyCount{};
    const installed = promise.setRejectionTracker(inner_id, LegacyCount.callback, &events);
    if (backend.active_backend == .jsc) {
        try testing.expect(!installed);
        return;
    }
    try testing.expect(installed);
    defer _ = promise.setRejectionTracker(inner_id, null, null);

    var nested = NestedReject{ .target_id = inner_id };
    try testing.expect(promise.setRejectionTracker(outer_id, NestedReject.callback, &nested));
    defer _ = promise.setRejectionTracker(outer_id, null, null);
    try helpers.evalOk(outer_id, "Promise.reject('outer-legacy-rejection');");
    try testing.expectEqual(@as(u32, 1), events.count);
    try testing.expectEqual(inner_id, events.instance_id);
    try testing.expect(std.mem.indexOf(u8, events.reason[0..events.reason_len], "nested-legacy-rejection") != null);
}

test "rejection: nested legacy callback flushes the inner instance" {
    const outer_id = helpers.nextInstanceId();
    const inner_id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(outer_id, null, null));
    defer c_api.jsbay_engine_destroy(outer_id);
    try testing.expect(c_api.jsbay_engine_create(inner_id, null, null));
    defer c_api.jsbay_engine_destroy(inner_id);

    var events = EventCount{};
    const observer_status = c_api.jsbay_engine_set_error_observer(inner_id, EventCount.callback, &events);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), observer_status);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), observer_status);
    defer _ = c_api.jsbay_engine_set_error_observer(inner_id, null, null);

    var nested = NestedReject{ .target_id = inner_id };
    try testing.expect(promise.setRejectionTracker(outer_id, NestedReject.callback, &nested));
    defer _ = promise.setRejectionTracker(outer_id, null, null);

    try helpers.evalOk(outer_id, "Promise.reject('outer-legacy-rejection');");
    try testing.expectEqual(@as(u32, 1), events.count);
}
