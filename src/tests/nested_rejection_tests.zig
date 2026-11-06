//! Cross-instance nested microtask-drain regression tests.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const types = @import("../types.zig");

const NestedEval = struct {
    target_id: i32,
    calls: u32 = 0,

    fn callback(instance_id: i32, userdata: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
        const self: *NestedEval = @ptrCast(@alignCast(userdata orelse unreachable));
        self.calls += 1;
        const result = engine.evalScript(self.target_id, "Promise.reject(new Error('nested-rejection-marker'));", "nested-rejection.js");
        defer helpers.freeEvalResult(result);
        if (result.err != null) {
            out_value.* = 0;
            out_exception.* = 0;
            return 4;
        }
        out_exception.* = 0;
        return c_api.jsbay_value_undefined(instance_id, out_value);
    }
};

const ErrorLog = struct {
    count: u32 = 0,
    retained_value: u64 = 0,

    fn callback(event: *const types.ErrorEvent, userdata: ?*anyopaque) callconv(.c) void {
        const self: *ErrorLog = @ptrCast(@alignCast(userdata orelse return));
        if (event.kind != .unhandled_rejection) return;
        self.count += 1;
        if (self.retained_value == 0) _ = c_api.jsbay_value_retain(event.value, &self.retained_value);
    }
};

test "rejection: nested drain reports the inner instance" {
    const outer_id = helpers.nextInstanceId();
    const inner_id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(outer_id, null, null));
    defer c_api.jsbay_engine_destroy(outer_id);
    try testing.expect(c_api.jsbay_engine_create(inner_id, null, null));
    defer c_api.jsbay_engine_destroy(inner_id);

    var log = ErrorLog{};
    const observer_status = c_api.jsbay_engine_set_error_observer(inner_id, ErrorLog.callback, &log);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), observer_status);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), observer_status);
    defer _ = c_api.jsbay_engine_set_error_observer(inner_id, null, null);
    defer {
        if (log.retained_value != 0) _ = c_api.jsbay_value_release(log.retained_value);
    }

    var nested = NestedEval{ .target_id = inner_id };
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "nestedEvaluate";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(outer_id, .{ .data = name.ptr, .len = name.len }, NestedEval.callback, &nested, null, &function, &exception));
    defer _ = c_api.jsbay_value_release(function);

    try helpers.evalOk(outer_id, "Promise.resolve().then(function () { nestedEvaluate(); });");
    try testing.expectEqual(@as(u32, 1), nested.calls);
    try testing.expectEqual(@as(u32, 1), log.count);
    try testing.expect(log.retained_value != 0);
}
