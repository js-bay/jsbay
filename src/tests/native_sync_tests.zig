//! C ABI synchronous native calls: completions are native data only.

const std = @import("std");
const testing = std.testing;
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");
const io = @import("../platform/io.zig");

const Probe = struct {
    id: i32,
    mode: enum { inline_ok, background_ok, exception, bad_json, never, interrupt, shorten_deadline, late_inline, close_late, race } = .inline_ok,
    request_id: std.atomic.Value(u64) = .init(0),
    completion_status: std.atomic.Value(c_int) = .init(-1),
    duplicate_status: std.atomic.Value(c_int) = .init(-1),
    thread: ?std.Thread = null,
    thread2: ?std.Thread = null,
};

fn completeLater(probe: *Probe) void {
    io.sleepMs(2);
    const id = probe.request_id.load(.seq_cst);
    const status = c_api.js_bay_sync_complete(id, 0, .{ .data = "41".ptr, .len = 2 });
    probe.completion_status.store(status, .seq_cst);
}

fn interruptLater(probe: *Probe) void {
    io.sleepMs(2);
    _ = c_api.js_bay_engine_request_interrupt(probe.id);
}

fn start(instance_id: i32, data: ?*anyopaque, request_id: u64, _: u64, _: usize, _: ?[*]const u64) callconv(.c) void {
    const probe: *Probe = @ptrCast(@alignCast(data orelse return));
    probe.request_id.store(request_id, .seq_cst);
    switch (probe.mode) {
        .inline_ok => {
            probe.completion_status.store(c_api.js_bay_sync_complete(request_id, 0, .{ .data = "41".ptr, .len = 2 }), .seq_cst);
            probe.duplicate_status.store(c_api.js_bay_sync_complete(request_id, 0, .{ .data = "42".ptr, .len = 2 }), .seq_cst);
        },
        .exception => probe.completion_status.store(c_api.js_bay_sync_complete(request_id, 1, .{ .data = "7".ptr, .len = 1 }), .seq_cst),
        .bad_json => probe.completion_status.store(c_api.js_bay_sync_complete(request_id, 0, .{ .data = "{".ptr, .len = 1 }), .seq_cst),
        .background_ok => probe.thread = std.Thread.spawn(.{}, completeLater, .{probe}) catch unreachable,
        .interrupt => probe.thread = std.Thread.spawn(.{}, interruptLater, .{probe}) catch unreachable,
        .never => {},
        .shorten_deadline => _ = c_api.js_bay_engine_set_execution_time_limit(instance_id, 5),
        .late_inline => {
            _ = c_api.js_bay_engine_set_execution_time_limit(instance_id, 5);
            io.sleepMs(10);
            probe.completion_status.store(c_api.js_bay_sync_complete(request_id, 0, .{ .data = "41".ptr, .len = 2 }), .seq_cst);
        },
        .close_late => {
            probe.thread = std.Thread.spawn(.{}, completeLater, .{probe}) catch unreachable;
            c_api.js_bay_engine_destroy(instance_id);
        },
        .race => {
            probe.thread = std.Thread.spawn(.{}, completeLater, .{probe}) catch unreachable;
            probe.thread2 = std.Thread.spawn(.{}, interruptLater, .{probe}) catch unreachable;
        },
    }
}

test "native sync: close inside start rejects late completion and old IDs cannot affect recreated engine" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.js_bay_engine_create(id, null, null));
    var probe = Probe{ .id = id, .mode = .close_late };
    var function: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_engine_bind_sync(id, .{ .data = "syncClose".ptr, .len = 9 }, &start, &probe, null, 500, &function, &exception));
    _ = c_api.js_bay_value_release(function);
    var value: u64 = 0;
    try testing.expectEqual(@as(c_int, 4), c_api.js_bay_engine_evaluate(id, .{ .data = "syncClose()".ptr, .len = 11 }, .{ .data = "native-sync.js".ptr, .len = 14 }, null, &value, &exception));
    const old_request = probe.request_id.load(.seq_cst);
    if (probe.thread) |thread| thread.join();
    try testing.expectEqual(@as(c_int, 5), probe.completion_status.load(.seq_cst));
    try testing.expectEqual(@as(c_int, 5), c_api.js_bay_sync_complete(old_request, 0, .{ .data = "41".ptr, .len = 2 }));

    try testing.expect(c_api.js_bay_engine_create(id, null, null));
    defer c_api.js_bay_engine_destroy(id);
    probe = .{ .id = id, .mode = .inline_ok };
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_engine_bind_sync(id, .{ .data = "syncNew".ptr, .len = 7 }, &start, &probe, null, 80, &function, &exception));
    defer _ = c_api.js_bay_value_release(function);
    try testing.expectEqual(@as(f64, 42), try evalNumber(id, "syncNew()+1"));
}

test "native sync: completion cancel and finish races keep the engine usable" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.js_bay_engine_create(id, null, null));
    defer c_api.js_bay_engine_destroy(id);
    var probe = Probe{ .id = id, .mode = .race };
    var function: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_engine_bind_sync(id, .{ .data = "syncRace".ptr, .len = 8 }, &start, &probe, null, 500, &function, &exception));
    defer _ = c_api.js_bay_value_release(function);
    var iteration: usize = 0;
    while (iteration < 24) : (iteration += 1) {
        probe.thread = null;
        probe.thread2 = null;
        probe.completion_status.store(-1, .seq_cst);
        var value: u64 = 0;
        exception = 0;
        const status = c_api.js_bay_engine_evaluate(id, .{ .data = "syncRace()".ptr, .len = 10 }, .{ .data = "native-sync.js".ptr, .len = 14 }, null, &value, &exception);
        try testing.expect(status == 0 or status == 1);
        if (value != 0) _ = c_api.js_bay_value_release(value);
        if (exception != 0) _ = c_api.js_bay_value_release(exception);
        if (probe.thread) |thread| thread.join();
        if (probe.thread2) |thread| thread.join();
        const completion = probe.completion_status.load(.seq_cst);
        try testing.expect(completion == 0 or completion == 5);
        try testing.expect(c_api.js_bay_engine_clear_interrupt(id));
    }
    try testing.expectEqual(@as(f64, 42), try evalNumber(id, "6*7"));
}

fn evalNumber(id: i32, source: []const u8) !f64 {
    var value: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_engine_evaluate(id, .{ .data = source.ptr, .len = source.len }, .{ .data = "native-sync.js".ptr, .len = 14 }, null, &value, &exception));
    defer _ = c_api.js_bay_value_release(value);
    var number: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_value_to_number(value, &number));
    return number;
}

fn evalException(id: i32, source: []const u8) !void {
    var value: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 1), c_api.js_bay_engine_evaluate(id, .{ .data = source.ptr, .len = source.len }, .{ .data = "native-sync.js".ptr, .len = 14 }, null, &value, &exception));
    try testing.expect(value == 0 and exception != 0);
    _ = c_api.js_bay_value_release(exception);
}

test "native sync: inline, background, exception, invalid JSON and timeout preserve owner results" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.js_bay_engine_create(id, null, null));
    defer c_api.js_bay_engine_destroy(id);
    var probe = Probe{ .id = id };
    var function: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_engine_bind_sync(id, .{ .data = "syncValue".ptr, .len = 9 }, &start, &probe, null, 80, &function, &exception));
    defer _ = c_api.js_bay_value_release(function);
    try testing.expectEqual(@as(f64, 42), try evalNumber(id, "const wx={test:syncValue}; const x=wx.test(); x+1"));
    try testing.expectEqual(@as(c_int, 0), probe.completion_status.load(.seq_cst));
    try testing.expectEqual(@as(c_int, 5), probe.duplicate_status.load(.seq_cst));

    probe.mode = .background_ok;
    try testing.expectEqual(@as(f64, 42), try evalNumber(id, "syncValue()+1"));
    if (probe.thread) |thread| thread.join();
    try testing.expectEqual(@as(c_int, 0), probe.completion_status.load(.seq_cst));

    probe.mode = .exception;
    try evalException(id, "syncValue()");
    probe.mode = .bad_json;
    try evalException(id, "syncValue()");
    probe.mode = .never;
    try evalException(id, "syncValue()");
    try testing.expectEqual(@as(f64, 42), try evalNumber(id, "6*7"));
    const stale = c_api.js_bay_sync_complete(probe.request_id.load(.seq_cst), 0, .{ .data = "42".ptr, .len = 2 });
    try testing.expectEqual(@as(c_int, 5), stale);
}

test "native sync: cross-thread interrupt wakes wait and recovery works" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.js_bay_engine_create(id, null, null));
    defer c_api.js_bay_engine_destroy(id);
    var probe = Probe{ .id = id, .mode = .interrupt };
    var function: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_engine_bind_sync(id, .{ .data = "syncInterrupt".ptr, .len = 13 }, &start, &probe, null, 500, &function, &exception));
    defer _ = c_api.js_bay_value_release(function);
    try evalException(id, "syncInterrupt()");
    if (probe.thread) |thread| thread.join();
    try testing.expect(c_api.js_bay_engine_clear_interrupt(id));
    try testing.expectEqual(@as(f64, 42), try evalNumber(id, "6*7"));
}

test "native sync: start-set execution deadline and completion after deadline cannot win" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.js_bay_engine_create(id, null, null));
    defer c_api.js_bay_engine_destroy(id);
    var probe = Probe{ .id = id, .mode = .shorten_deadline };
    var function: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_engine_bind_sync(id, .{ .data = "syncDeadline".ptr, .len = 12 }, &start, &probe, null, 80, &function, &exception));
    defer _ = c_api.js_bay_value_release(function);
    const before = io.monotonicMilliseconds();
    try evalException(id, "syncDeadline()");
    try testing.expect(io.monotonicMilliseconds() - before < 50);
    try testing.expect(c_api.js_bay_engine_clear_interrupt(id));
    try testing.expect(c_api.js_bay_engine_set_execution_time_limit(id, 0));
    try testing.expectEqual(@as(f64, 42), try evalNumber(id, "6*7"));

    probe.mode = .late_inline;
    try evalException(id, "syncDeadline()");
    try testing.expectEqual(@as(c_int, 5), probe.completion_status.load(.seq_cst));
}
