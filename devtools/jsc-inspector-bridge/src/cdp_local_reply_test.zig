const std = @import("std");
const test_support = @import("cdp_test.zig");

test "local replies preserve request ids and fixed result values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var harness = try test_support.Harness.create(arena.allocator());
    defer harness.deinit();
    harness.bridge.openSession(1);

    harness.bridge.onMessage(1, "{\"id\":\"local\\\"id\",\"method\":\"Schema.getDomains\"}");
    harness.bridge.onMessage(1, "{\"id\":12.5,\"method\":\"Target.setAutoAttach\"}");
    harness.bridge.onMessage(1, "{\"id\":-8,\"method\":\"Runtime.getHeapUsage\"}");

    try std.testing.expectEqual(@as(usize, 3), harness.frontend.count());
    for (harness.frontend.sent.items, 0..) |entry, index| {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), entry.json, .{});
        const object = parsed.value.object;
        const id = object.get("id").?;
        const result = object.get("result").?.object;
        switch (index) {
            0 => {
                try std.testing.expectEqualStrings("local\"id", id.string);
                const domains = result.get("domains").?.array;
                try std.testing.expectEqual(@as(usize, 0), domains.items.len);
            },
            1 => {
                try std.testing.expectEqual(@as(f64, 12.5), id.float);
                try std.testing.expectEqual(@as(usize, 0), result.count());
            },
            2 => {
                try std.testing.expectEqual(@as(i64, -8), id.integer);
                try std.testing.expectEqual(@as(i64, 0), result.get("usedSize").?.integer);
                try std.testing.expectEqual(@as(i64, 0), result.get("totalSize").?.integer);
            },
            else => unreachable,
        }
    }
}
