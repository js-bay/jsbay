//! Public ABI lifecycle boundaries for retained Values.

const std = @import("std");
const testing = std.testing;

const c_api = @import("../c_api.zig");
const dispatch = @import("../runtime/dispatch.zig");
const runtime_control = @import("../runtime/runtime_control.zig");
const submission = @import("../runtime/submission.zig");
const helpers = @import("test_helpers.zig");

const ok: c_int = 0;
const instance_not_found: c_int = 4;

fn utf8(text: []const u8) c_api.Utf8 {
    return .{ .data = text.ptr, .len = text.len };
}

fn evaluate(id: i32, source: []const u8) !u64 {
    var value: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_engine_evaluate(id, utf8(source), utf8("runtime-boundary.js"), null, &value, &exception));
    try testing.expectEqual(@as(u64, 0), exception);
    return value;
}

fn seal(id: i32) !void {
    const token = dispatch.captureInstanceToken(id) orelse return error.MissingToken;
    try testing.expect(c_api.jsbay_engine_begin_shutdown(id, token.generation, 60_000));
    try testing.expect(runtime_control.sealShutdown(id));
}

test "runtime boundary: sealed primary values reject call getter and JSON without executing" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var side_effects: usize = 0;
    const Probe = struct {
        fn callback(_: i32, user_data: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
            const count: *usize = @ptrCast(@alignCast(user_data orelse unreachable));
            count.* += 1;
            out_exception.* = 0;
            out_value.* = 0;
            return ok;
        }
    };
    var binding: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_engine_bind(id, utf8("boundaryMark"), Probe.callback, @ptrCast(&side_effects), null, &binding, &exception));
    defer _ = c_api.jsbay_value_release(binding);

    const function = try evaluate(id, "(() => { boundaryMark(); return 1; })");
    defer _ = c_api.jsbay_value_release(function);
    const object = try evaluate(id, "({ get blocked() { boundaryMark(); return 1; }, toJSON() { boundaryMark(); return 'x'; } })");
    defer _ = c_api.jsbay_value_release(object);
    try seal(id);

    var value: u64 = 0;
    const call_status = c_api.jsbay_value_call(function, function, null, 0, &value, &exception);
    try testing.expectEqual(@as(usize, 0), side_effects);
    try testing.expectEqual(instance_not_found, call_status);

    try testing.expectEqual(instance_not_found, c_api.jsbay_value_get(object, utf8("blocked"), &value, &exception));
    try testing.expectEqual(@as(u64, 0), value);
    try testing.expectEqual(@as(usize, 0), side_effects);

    var bytes: c_api.Bytes = .{ .data = null, .len = 0 };
    try testing.expectEqual(instance_not_found, c_api.jsbay_value_to_json(object, &bytes, &exception));
    try testing.expect(bytes.data == null);
    try testing.expectEqual(@as(usize, 0), side_effects);
}

test "runtime boundary: sealed packed values reject executable operations" {
    var backends: [4]c_api.BackendC = undefined;
    const backend_count = c_api.jsbay_available_backends(&backends, backends.len);
    const primary = c_api.jsbay_library_backend();
    var exercised = false;
    for (backends[0..@min(backend_count, backends.len)]) |selected| {
        if (@backingInt(selected) == primary) continue;
        exercised = true;
        const id = helpers.nextInstanceId();
        var options = c_api.EngineCreateOptionsC{ .struct_size = @sizeOf(c_api.EngineCreateOptionsC), .backend = selected };
        try testing.expect(c_api.jsbay_engine_create_with_options(id, &options));
        defer c_api.jsbay_engine_destroy(id);

        const function = try evaluate(id, "(() => { throw new Error('call entered'); })");
        defer _ = c_api.jsbay_value_release(function);
        const object = try evaluate(id, "({ get blocked() { throw new Error('get entered'); }, toJSON() { throw new Error('json entered'); } })");
        defer _ = c_api.jsbay_value_release(object);
        try seal(id);

        var value: u64 = 0;
        var exception: u64 = 0;
        try testing.expectEqual(instance_not_found, c_api.jsbay_value_call(function, function, null, 0, &value, &exception));
        try testing.expectEqual(@as(u64, 0), value);
        try testing.expectEqual(instance_not_found, c_api.jsbay_value_get(object, utf8("blocked"), &value, &exception));
        try testing.expectEqual(@as(u64, 0), value);
        var bytes: c_api.Bytes = .{ .data = null, .len = 0 };
        try testing.expectEqual(instance_not_found, c_api.jsbay_value_to_json(object, &bytes, &exception));
        try testing.expect(bytes.data == null);
    }
    if (!exercised) return error.SkipZigTest;
}

test "runtime boundary: sealed retained values retain and release" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    const value = try evaluate(id, "1");
    var retained: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_retain(value, &retained));
    try seal(id);
    var retained_after_seal: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_retain(value, &retained_after_seal));
    try testing.expectEqual(ok, c_api.jsbay_value_release(retained_after_seal));
    try testing.expectEqual(ok, c_api.jsbay_value_release(retained));
    try testing.expectEqual(ok, c_api.jsbay_value_release(value));
}

test "runtime boundary: API checkpoint retains the outer execution deadline" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try testing.expect(c_api.jsbay_engine_set_execution_budget(id, 10_000));

    const Probe = struct {
        instance_id: i32,
        deadlines: [2]u64 = .{ 0, 0 },
        calls: usize = 0,

        fn callback(_: i32, user_data: ?*anyopaque, this_value: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(user_data orelse unreachable));
            self.deadlines[self.calls] = runtime_control.effectiveExecutionDeadlineMillis(self.instance_id) orelse 0;
            self.calls += 1;
            if (self.calls == 1) _ = c_api.jsbay_engine_set_execution_budget(self.instance_id, 100_000);
            out_exception.* = 0;
            return c_api.jsbay_value_retain(this_value, out_value);
        }
    };
    var probe = Probe{ .instance_id = id };
    var binding: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_engine_bind(id, utf8("captureDeadline"), Probe.callback, @ptrCast(&probe), null, &binding, &exception));
    defer _ = c_api.jsbay_value_release(binding);

    const result = try evaluate(id, "captureDeadline(); Promise.resolve().then(captureDeadline);");
    defer _ = c_api.jsbay_value_release(result);
    try testing.expectEqual(@as(usize, 2), probe.calls);
    try testing.expect(probe.deadlines[0] != 0);
    try testing.expectEqual(probe.deadlines[0], probe.deadlines[1]);
}

test "runtime boundary: queued checkpoint retains the outer execution deadline" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try testing.expect(c_api.jsbay_engine_set_execution_budget(id, 10_000));
    const token = dispatch.captureInstanceToken(id) orelse return error.MissingToken;

    const Probe = struct {
        instance_id: i32,
        deadlines: [2]u64 = .{ 0, 0 },
        calls: usize = 0,

        fn callback(_: i32, user_data: ?*anyopaque, this_value: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(user_data orelse unreachable));
            self.deadlines[self.calls] = runtime_control.effectiveExecutionDeadlineMillis(self.instance_id) orelse 0;
            self.calls += 1;
            if (self.calls == 1) _ = c_api.jsbay_engine_set_execution_budget(self.instance_id, 100_000);
            out_exception.* = 0;
            return c_api.jsbay_value_retain(this_value, out_value);
        }
    };
    var probe = Probe{ .instance_id = id };
    var binding: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_engine_bind(id, utf8("captureQueuedDeadline"), Probe.callback, @ptrCast(&probe), null, &binding, &exception));
    defer _ = c_api.jsbay_value_release(binding);

    try testing.expect(submission.postScript(id, token.generation, "captureQueuedDeadline(); Promise.resolve().then(captureQueuedDeadline);", "runtime-boundary-queued.js", null, null));
    try testing.expect(dispatch.tickInstance(id) >= 1);
    try testing.expectEqual(@as(usize, 2), probe.calls);
    try testing.expect(probe.deadlines[0] != 0);
    try testing.expectEqual(probe.deadlines[0], probe.deadlines[1]);
}
