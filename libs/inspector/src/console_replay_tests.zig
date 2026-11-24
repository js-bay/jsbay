pub fn run(comptime Host: type) !void {
    const std = @import("std");
    const transport_mod = @import("transport.zig");
    const state_mod = @import("state.zig").Module(Host);
    const replay = @import("console_replay.zig").Module;
    const testing = std.testing;

    const Probe = struct {
        closed: std.ArrayList(transport_mod.SessionId) = .empty,
        const vtable: transport_mod.Transport.VTable = .{
            .start = start,
            .deinit = deinit,
            .send_text = sendText,
            .broadcast_text = broadcastText,
            .close_session = closeSession,
        };
        fn start(_: *anyopaque, _: ?*anyopaque, _: transport_mod.EventHandler) !void {}
        fn deinit(_: *anyopaque) void {}
        fn sendText(_: *anyopaque, _: transport_mod.SessionId, _: []const u8) bool {
            return true;
        }
        fn broadcastText(_: *anyopaque, _: []const u8) void {}
        fn closeSession(ctx: *anyopaque, session_id: transport_mod.SessionId) void {
            const probe: *@This() = @ptrCast(@alignCast(ctx));
            probe.closed.append(testing.allocator, session_id) catch unreachable;
        }
    };

    var probe = Probe{};
    defer probe.closed.deinit(testing.allocator);
    var transport = transport_mod.Transport{ .ctx = &probe, .vtable = &Probe.vtable };
    var state = state_mod.InspectorState{
        .instance_id = -1,
        .allocator = testing.allocator,
        .transport = &transport,
        .title = &.{},
        .url = &.{},
        .target_id = &.{},
        .sessions = .empty,
        .object_table = state_mod.ObjectTable.init(testing.allocator),
    };
    defer {
        for (state.sessions.items) |*session| replay.deinitQueue(&state, session);
        state.sessions.deinit(testing.allocator);
        state.object_table.deinit(null);
        state_mod.deinitConsoleBuffer(&state);
        state.deinitSynchronization();
    }

    try testing.expect(state_mod.addSession(&state, 1));
    try testing.expect(state_mod.addSession(&state, 2));
    try testing.expect(replay.beginEnable(&state, 1));
    try testing.expect(replay.beginEnable(&state, 2));
    var live: std.ArrayList(transport_mod.SessionId) = .empty;
    defer live.deinit(testing.allocator);
    try state_mod.bufferConsoleEvent(&state, "before-snapshot", null, &.{}, &live);
    const first = replay.beginReplay(&state, 1);
    defer replay.freeBuffered(&state, first);
    const second = replay.beginReplay(&state, 2);
    defer replay.freeBuffered(&state, second);
    try testing.expect(first.started and second.started);
    try testing.expectEqualStrings("before-snapshot", first.entries[0]);
    try state_mod.bufferConsoleEvent(&state, "during-replay", null, &.{}, &live);
    switch (replay.nextEntry(&state, 1, first.generation)) {
        .entry => |entry| {
            defer replay.freeEntry(&state, entry);
            try testing.expectEqualStrings("during-replay", entry);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (replay.nextEntry(&state, 1, first.generation)) {
        .done => {},
        else => return error.TestUnexpectedResult,
    }
    switch (replay.nextEntry(&state, 2, second.generation)) {
        .entry => |entry| {
            defer replay.freeEntry(&state, entry);
            try testing.expectEqualStrings("during-replay", entry);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (replay.nextEntry(&state, 2, second.generation)) {
        .done => {},
        else => return error.TestUnexpectedResult,
    }
    replay.setEnabled(&state, 1, false);
    switch (replay.nextEntry(&state, 1, first.generation)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }

    try testing.expect(state_mod.addSession(&state, 3));
    try testing.expect(replay.beginEnable(&state, 3));
    const canceled = replay.beginReplay(&state, 3);
    defer replay.freeBuffered(&state, canceled);
    replay.failReplay(&state, 3, canceled.generation);
    switch (replay.nextEntry(&state, 3, canceled.generation)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }

    try testing.expect(state_mod.addSession(&state, 4));
    try testing.expect(replay.beginEnable(&state, 4));
    const bounded = replay.beginReplay(&state, 4);
    defer replay.freeBuffered(&state, bounded);
    for (0..replay.console_buffer_cap + 1) |i| {
        const event = try std.fmt.allocPrint(testing.allocator, "queued-{d}", .{i});
        defer testing.allocator.free(event);
        try state_mod.bufferConsoleEvent(&state, event, null, &.{}, &live);
    }
    try testing.expectEqual(@as(usize, 1), probe.closed.items.len);
    try testing.expectEqual(@as(transport_mod.SessionId, 4), probe.closed.items[0]);
    switch (replay.nextEntry(&state, 4, bounded.generation)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }

    try testing.expect(state_mod.addSession(&state, 5));
    try testing.expect(replay.beginEnable(&state, 5));
    const removed = replay.beginReplay(&state, 5);
    defer replay.freeBuffered(&state, removed);
    try testing.expect(state_mod.removeSession(&state, 5));
    switch (replay.nextEntry(&state, 5, removed.generation)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }

    try testing.expect(state_mod.addSession(&state, 6));
    try testing.expect(replay.beginEnable(&state, 6));
    const byte_bounded = replay.beginReplay(&state, 6);
    defer replay.freeBuffered(&state, byte_bounded);
    const huge_event = try testing.allocator.alloc(u8, replay.delivery_bytes_cap + 1);
    defer testing.allocator.free(huge_event);
    @memset(huge_event, 'x');
    try state_mod.bufferConsoleEvent(&state, huge_event, null, &.{}, &live);
    try testing.expectEqual(@as(usize, 2), probe.closed.items.len);
    try testing.expectEqual(@as(transport_mod.SessionId, 6), probe.closed.items[1]);
    switch (replay.nextEntry(&state, 6, byte_bounded.generation)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }
}
