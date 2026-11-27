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

test "submission: public C API rejects packed-alt submissions without callbacks" {
    var backends: [4]c_api.BackendC = undefined;
    const n = c_api.jsbay_available_backends(&backends, backends.len);
    if (n < 2) return error.SkipZigTest;
    const primary = c_api.jsbay_library_backend();
    var found_secondary_jsc = false;
    for (backends[0..n]) |tag| {
        if (tag != .jsc or @backingInt(tag) == primary) continue;
        found_secondary_jsc = true;
        const id = helpers.nextInstanceId();
        var options = c_api.EngineCreateOptionsC{ .struct_size = @sizeOf(c_api.EngineCreateOptionsC), .backend = tag };
        try std.testing.expect(c_api.jsbay_engine_create_with_options(id, &options));
        defer c_api.jsbay_engine_destroy(id);
        const token = dispatch.captureInstanceToken(id) orelse return error.MissingToken;
        var callbacks: usize = 0;
        const Callback = struct {
            fn record(_: i32, _: u64, _: submission.Status, _: ?[*]const u8, _: usize, user_data: ?*anyopaque) callconv(.c) void {
                const count: *usize = @ptrCast(@alignCast(user_data orelse unreachable));
                count.* += 1;
            }
            fn schedule(_: ?*anyopaque, _: u64, _: c_api.LoopTask, _: ?*anyopaque) callconv(.c) bool {
                return false;
            }
            fn cancel(_: ?*anyopaque) callconv(.c) void {}
        };
        const source = "globalThis.shouldNotRun = true";
        const filename = "packed-submit.js";
        try std.testing.expect(!c_api.jsbay_engine_post_script(id, token.generation, .{ .data = source.ptr, .len = source.len }, .{ .data = filename.ptr, .len = filename.len }, Callback.record, @ptrCast(&callbacks)));
        try std.testing.expect(!c_api.jsbay_engine_post_fence(id, token.generation, false, Callback.record, @ptrCast(&callbacks)));
        try std.testing.expectEqual(@as(usize, 0), callbacks);
        try std.testing.expectEqual(@as(c_int, 7), c_api.jsbay_engine_run_loop(id));
        try std.testing.expectEqual(@as(c_int, 7), c_api.jsbay_engine_attach_loop(id, Callback.schedule, Callback.cancel, null));
        c_api.jsbay_engine_destroy(id);
        try std.testing.expectEqual(@as(usize, 0), callbacks);
    }
    if (!found_secondary_jsc) return error.SkipZigTest;
}

test "submission: public C API accepts primary and rejects stale generation" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    var snapshot: c_api.InstanceSnapshotC = undefined;
    snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try std.testing.expect(c_api.jsbay_engine_snapshot(id, &snapshot));
    var callbacks: usize = 0;
    const Callback = struct {
        fn record(_: i32, _: u64, _: submission.Status, _: ?[*]const u8, _: usize, user_data: ?*anyopaque) callconv(.c) void {
            const count: *usize = @ptrCast(@alignCast(user_data orelse unreachable));
            count.* += 1;
        }
    };
    const source = "globalThis.publicSubmit = true";
    const filename = "public-submit.js";
    try std.testing.expect(c_api.jsbay_engine_post_script(id, snapshot.generation, .{ .data = source.ptr, .len = source.len }, .{ .data = filename.ptr, .len = filename.len }, Callback.record, @ptrCast(&callbacks)));
    try std.testing.expect(c_api.jsbay_engine_post_fence(id, snapshot.generation, false, Callback.record, @ptrCast(&callbacks)));
    try std.testing.expect(dispatch.tickInstance(id) >= 1);
    try std.testing.expect(dispatch.tickInstance(id) >= 1);
    try std.testing.expectEqual(@as(usize, 2), callbacks);
    c_api.jsbay_engine_destroy(id);

    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try std.testing.expect(!c_api.jsbay_engine_post_script(id, snapshot.generation, .{ .data = source.ptr, .len = source.len }, .{ .data = filename.ptr, .len = filename.len }, Callback.record, @ptrCast(&callbacks)));
    try std.testing.expect(!c_api.jsbay_engine_post_fence(id, snapshot.generation, false, Callback.record, @ptrCast(&callbacks)));
    try std.testing.expectEqual(@as(usize, 2), callbacks);
}

test "submission: destroy caller completes queued work on its own thread" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    const token = dispatch.captureInstanceToken(id) orelse return error.MissingToken;
    const Probe = struct {
        callbacks: usize = 0,
        callback_thread_id: u64 = 0,
        destroy_thread_id: u64 = 0,
        cancelled: usize = 0,

        fn complete(_: i32, _: u64, status: submission.Status, _: ?[*]const u8, _: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data orelse unreachable));
            self.callbacks += 1;
            self.callback_thread_id = @intCast(std.Thread.getCurrentId());
            if (status == .cancelled) self.cancelled += 1;
        }

        fn destroy(self: *@This(), instance_id: i32) void {
            self.destroy_thread_id = @intCast(std.Thread.getCurrentId());
            c_api.jsbay_engine_destroy(instance_id);
        }
    };
    var probe = Probe{};
    const source = "globalThis.mustNotRun = true";
    const filename = "destroy-cancel.js";
    try std.testing.expect(c_api.jsbay_engine_post_script(id, token.generation, .{ .data = source.ptr, .len = source.len }, .{ .data = filename.ptr, .len = filename.len }, Probe.complete, @ptrCast(&probe)));
    try std.testing.expect(c_api.jsbay_engine_post_fence(id, token.generation, false, Probe.complete, @ptrCast(&probe)));

    const owner_thread_id: u64 = @intCast(std.Thread.getCurrentId());
    const worker = try std.Thread.spawn(.{}, Probe.destroy, .{ &probe, id });
    worker.join();

    try std.testing.expectEqual(@as(usize, 2), probe.callbacks);
    try std.testing.expectEqual(@as(usize, 2), probe.cancelled);
    try std.testing.expectEqual(probe.destroy_thread_id, probe.callback_thread_id);
    try std.testing.expect(probe.destroy_thread_id != owner_thread_id);
}

test "submission: empty throws remain failures" {
    try expectThrowDiagnostic("throw ''");
}

test "submission: surrogate throws have UTF-8 diagnostics" {
    try expectThrowDiagnostic("throw '\\uD800'");
    try expectThrowDiagnostic("throw new Error('\\uD800')");
    try expectThrowDiagnostic("const failure = new Error('message'); failure.stack = '\\uD800'; throw failure;");
}

fn expectThrowDiagnostic(source: []const u8) !void {
    var backends: [4]c_api.BackendC = undefined;
    const count = c_api.jsbay_available_backends(&backends, backends.len);
    for (backends[0..count]) |backend_tag| {
        const id = helpers.nextInstanceId();
        var options = c_api.EngineCreateOptionsC{ .struct_size = @sizeOf(c_api.EngineCreateOptionsC), .backend = backend_tag };
        try std.testing.expect(c_api.jsbay_engine_create_with_options(id, &options));
        defer c_api.jsbay_engine_destroy(id);
        const token = dispatch.captureInstanceToken(id) orelse return error.MissingToken;
        var probe = struct {
            calls: usize = 0,
            status: submission.Status = .completed,
            valid_utf8: bool = false,
            has_message: bool = false,
            fn record(_: i32, _: u64, status: submission.Status, bytes: ?[*]const u8, length: usize, user_data: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(user_data orelse unreachable));
                self.calls += 1;
                self.status = status;
                self.has_message = length > 0;
                self.valid_utf8 = if (bytes) |ptr| std.unicode.utf8ValidateSlice(ptr[0..length]) else false;
            }
        }{};
        try std.testing.expect(submission.postScript(id, token.generation, source, "<throw-submission>", @TypeOf(probe).record, @ptrCast(&probe)));
        try std.testing.expect(dispatch.tickInstance(id) >= 1);
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expectEqual(submission.Status.exception, probe.status);
        try std.testing.expect(probe.has_message);
        try std.testing.expect(probe.valid_utf8);
    }
}
