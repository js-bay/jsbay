const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
const io = @import("../platform/io.zig");
const console_tests = @import("cdp_console_tests.zig");

test "cdp: console.log during Runtime.enable is replayed after context" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try console_tests.openSession(alloc, "cdp-console-enable-window");
    defer session.deinit();
    errdefer std.debug.print("cdp console bytes:\n{s}\n", .{session.conn.got.items});

    var barrier = inspector.RuntimeEnableBarrierForTesting{};
    inspector.setRuntimeEnableBarrierForTesting(&barrier);
    var replay_barrier = inspector.RuntimeReplayBarrierForTesting{};
    inspector.setRuntimeReplayBarrierForTesting(&replay_barrier);
    defer {
        barrier.continue_after_context.store(true, .release);
        inspector.setRuntimeEnableBarrierForTesting(null);
        replay_barrier.continue_before_delivery.store(true, .release);
        inspector.setRuntimeReplayBarrierForTesting(null);
    }

    const start = session.conn.got.items.len;
    const id = try session.conn.command("Runtime.enable", "");
    const marker = try console_tests.idMarker(alloc, id);
    defer alloc.free(marker);
    try session.conn.expect(try session.conn.waitFrom(start, marker, 40));
    try session.conn.expect(try session.conn.waitFrom(start, "Runtime.executionContextCreated", 40));

    const deadline = io.milliTimestamp() + 5_000;
    while (!barrier.reached.load(.acquire) and io.milliTimestamp() < deadline) {
        std.Thread.yield() catch {};
    }
    try testing.expect(barrier.reached.load(.acquire));

    const live = engine.evalScript(session.id, "console.log('enable-window-token')", "console-enable-window.js");
    defer console_tests.discardEval(live);
    try testing.expect(live.err == null);
    _ = dispatch.tickInstance(session.id);
    barrier.continue_after_context.store(true, .release);

    const replay_deadline = io.milliTimestamp() + 5_000;
    while (!replay_barrier.reached.load(.acquire) and io.milliTimestamp() < replay_deadline) {
        std.Thread.yield() catch {};
    }
    try testing.expect(replay_barrier.reached.load(.acquire));

    const queued = engine.evalScript(session.id, "console.log('replay-window-token')", "console-replay-window.js");
    defer console_tests.discardEval(queued);
    try testing.expect(queued.err == null);
    _ = dispatch.tickInstance(session.id);
    const disable_id = try session.conn.command("Runtime.disable", "");
    const disable_marker = try console_tests.idMarker(alloc, disable_id);
    defer alloc.free(disable_marker);
    replay_barrier.continue_before_delivery.store(true, .release);

    try session.conn.expect(try session.conn.waitFrom(start, "enable-window-token", 40));
    try session.conn.expect(try session.conn.waitFrom(start, "replay-window-token", 40));
    try session.conn.expect(try session.conn.waitFrom(start, disable_marker, 40));
    const response_at = std.mem.indexOf(u8, session.conn.got.items[start..], marker) orelse return error.TestUnexpectedResult;
    const context_at = std.mem.indexOf(u8, session.conn.got.items[start..], "Runtime.executionContextCreated") orelse return error.TestUnexpectedResult;
    const snapshot_event_at = std.mem.indexOf(u8, session.conn.got.items[start..], "enable-window-token") orelse return error.TestUnexpectedResult;
    const queued_event_at = std.mem.indexOf(u8, session.conn.got.items[start..], "replay-window-token") orelse return error.TestUnexpectedResult;
    const disable_at = std.mem.indexOf(u8, session.conn.got.items[start..], disable_marker) orelse return error.TestUnexpectedResult;
    try testing.expect(response_at < context_at);
    try testing.expect(context_at < snapshot_event_at);
    try testing.expect(snapshot_event_at < queued_event_at);
    try testing.expect(queued_event_at < disable_at);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, session.conn.got.items[start..], "enable-window-token"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, session.conn.got.items[start..], "replay-window-token"));
}
