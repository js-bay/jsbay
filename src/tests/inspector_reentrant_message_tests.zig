const std = @import("std");
const testing = std.testing;
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
const helpers = @import("test_helpers.zig");
const options = @import("build_options");
const HostTransport = @import("host_transport_fixture.zig").HostTransport;

test "host transport can reenter a message callback from sendText" {
    if (!options.inspector) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var host = HostTransport{};
    host.init();
    defer host.freeFrames();
    const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
    defer inspector.stop(handle);
    host.emit(.session_opened, 7, "");
    host.reenter_message_on_method = "Runtime.executionContextCreated";
    host.reenter_message_payload = "{\"id\":72,\"method\":\"Runtime.disable\"}";

    host.emit(.message, 7, "{\"id\":71,\"method\":\"Runtime.enable\"}");

    var enabled = try host.reply(7, 71);
    defer enabled.deinit();
    try testing.expect(enabled.value.object.get("result") != null);
    var disabled = try host.reply(7, 72);
    defer disabled.deinit();
    try testing.expect(disabled.value.object.get("result") != null);
    const context_index = blk: {
        for (host.frames.items, 0..) |frame, index| {
            if (std.mem.indexOf(u8, frame.text, "Runtime.executionContextCreated") != null) break :blk index;
        }
        return error.MissingReply;
    };
    const disable_index = blk: {
        for (host.frames.items, 0..) |frame, index| {
            var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame.text, .{});
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const raw_id = parsed.value.object.get("id") orelse continue;
            if (raw_id == .integer and raw_id.integer == 72) break :blk index;
        }
        return error.MissingReply;
    };
    try testing.expect(context_index < disable_index);
}
