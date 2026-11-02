const std = @import("std");
const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const dispatch = @import("../runtime/dispatch.zig");
const submission = @import("../runtime/submission.zig");
const helpers = @import("test_helpers.zig");

test "submission: cancelled work does not invoke its host side effect" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    const token = dispatch.captureInstanceToken(id) orelse return error.MissingToken;
    var side_effects: usize = 0;
    const SideEffect = struct {
        fn call(_: i32, user_data: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
            const count: *usize = @ptrCast(@alignCast(user_data orelse unreachable));
            count.* += 1;
            out_value.* = 0;
            out_exception.* = 0;
            return 0;
        }
    };
    var binding: u64 = 0;
    var exception: u64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = "submissionSideEffect", .len = 20 }, SideEffect.call, @ptrCast(&side_effects), null, &binding, &exception));
    defer _ = c_api.jsbay_value_release(binding);
    var probe = struct {
        calls: usize = 0,
        status: submission.Status = .completed,

        fn record(_: i32, _: u64, status: submission.Status, _: ?[*]const u8, _: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data orelse unreachable));
            self.calls += 1;
            self.status = status;
        }
    }{};
    try std.testing.expect(submission.postScript(id, token.generation, "submissionSideEffect()", "<cancelled-submission>", @TypeOf(probe).record, @ptrCast(&probe)));
    try std.testing.expect(c_api.jsbay_engine_cancel(id, token.generation));
    try std.testing.expect(dispatch.tickInstance(id) >= 1);
    try std.testing.expectEqual(@as(usize, 0), side_effects);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(submission.Status.cancelled, probe.status);
}

test "submission: packed-alt script and fence complete after its promise checkpoint" {
    var backends: [4]c_api.BackendC = undefined;
    const n = c_api.jsbay_available_backends(&backends, backends.len);
    const primary = c_api.jsbay_library_backend();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (@backingInt(backends[i]) == primary) continue;
        const id = helpers.nextInstanceId();
        var options = c_api.EngineCreateOptionsC{ .struct_size = @sizeOf(c_api.EngineCreateOptionsC), .backend = backends[i] };
        try std.testing.expect(c_api.jsbay_engine_create_with_options(id, &options));
        defer c_api.jsbay_engine_destroy(id);
        const token = dispatch.captureInstanceToken(id) orelse return error.MissingToken;
        var probe = struct {
            calls: usize = 0,
            statuses: [2]submission.Status = undefined,

            fn record(_: i32, _: u64, status: submission.Status, _: ?[*]const u8, _: usize, user_data: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(user_data orelse unreachable));
                self.statuses[self.calls] = status;
                self.calls += 1;
            }
        }{};
        const script = "globalThis.__packedSubmission = 0; Promise.resolve().then(() => { globalThis.__packedSubmission = 42; });";
        try std.testing.expect(submission.postScript(id, token.generation, script, "<packed-submission>", @TypeOf(probe).record, @ptrCast(&probe)));
        try std.testing.expect(submission.postFence(id, token.generation, false, @TypeOf(probe).record, @ptrCast(&probe)));
        try std.testing.expect(dispatch.tickInstance(id) >= 1);
        try std.testing.expect(dispatch.tickInstance(id) >= 1);
        try std.testing.expectEqual(@as(usize, 2), probe.calls);
        try std.testing.expectEqual(submission.Status.completed, probe.statuses[0]);
        try std.testing.expectEqual(submission.Status.completed, probe.statuses[1]);
        var value: u64 = 0;
        var exception: u64 = 0;
        const name = "globalThis.__packedSubmission";
        const filename = "<packed-submission-check>";
        try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_evaluate(id, .{ .data = name.ptr, .len = name.len }, .{ .data = filename.ptr, .len = filename.len }, null, &value, &exception));
        defer _ = c_api.jsbay_value_release(value);
        try std.testing.expectEqual(@as(u64, 0), exception);
        var number: f64 = 0;
        try std.testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_to_number(value, &number));
        try std.testing.expectEqual(@as(f64, 42), number);
    }
}
