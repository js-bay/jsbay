pub fn run(comptime Host: type, comptime TestApi: type) !void {
    // Includes bounded admission and cross-thread session discard/drain behavior.
    const std = @import("std");
    const testing = std.testing;
    const queue_mod = TestApi.state(Host).TestCases.CommandQueue;

    var count_queue = queue_mod.Queue{};
    defer queue_mod.deinit(&count_queue, testing.allocator);
    try testing.expect(try queue_mod.admit(&count_queue, testing.allocator, 9, "active"));
    for (0..queue_mod.message_count_cap) |_| {
        try testing.expect(!(try queue_mod.admit(&count_queue, testing.allocator, 9, "x")));
    }
    try testing.expectError(error.QueueFull, queue_mod.admit(&count_queue, testing.allocator, 9, "x"));
    try testing.expectEqual(queue_mod.message_count_cap, count_queue.messages.items.len);
    queue_mod.clear(&count_queue, testing.allocator);

    var byte_queue = queue_mod.Queue{};
    defer queue_mod.deinit(&byte_queue, testing.allocator);
    const large = try testing.allocator.alloc(u8, queue_mod.message_bytes_cap / 2);
    defer testing.allocator.free(large);
    @memset(large, 'b');
    try testing.expect(try queue_mod.admit(&byte_queue, testing.allocator, 9, "active"));
    try testing.expect(!(try queue_mod.admit(&byte_queue, testing.allocator, 9, large)));
    try testing.expect(!(try queue_mod.admit(&byte_queue, testing.allocator, 9, large)));
    try testing.expectError(error.QueueFull, queue_mod.admit(&byte_queue, testing.allocator, 9, "x"));
    try testing.expectEqual(queue_mod.message_bytes_cap, byte_queue.bytes);

    var concurrent = queue_mod.Queue{};
    defer queue_mod.deinit(&concurrent, testing.allocator);
    try testing.expect(try queue_mod.admit(&concurrent, testing.allocator, 99, "active"));
    const Worker = struct {
        queue: *queue_mod.Queue,
        session_id: u64,
        start: *std.atomic.Value(bool),
        done: *std.atomic.Value(bool),
        admitted: *std.atomic.Value(usize),
        failed: *std.atomic.Value(bool),

        fn run(worker: *@This()) void {
            while (!worker.start.load(.acquire)) std.Thread.yield() catch {};
            for (0..80) |_| {
                const result = queue_mod.admit(worker.queue, testing.allocator, worker.session_id, "x") catch {
                    worker.failed.store(true, .release);
                    continue;
                };
                if (result) worker.failed.store(true, .release);
                _ = worker.admitted.fetchAdd(1, .acq_rel);
            }
            worker.done.store(true, .release);
        }
    };

    var start = std.atomic.Value(bool).init(false);
    var done_one = std.atomic.Value(bool).init(false);
    var done_two = std.atomic.Value(bool).init(false);
    var admitted_one = std.atomic.Value(usize).init(0);
    var admitted_two = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(bool).init(false);
    var first = Worker{ .queue = &concurrent, .session_id = 1, .start = &start, .done = &done_one, .admitted = &admitted_one, .failed = &failed };
    var second = Worker{ .queue = &concurrent, .session_id = 2, .start = &start, .done = &done_two, .admitted = &admitted_two, .failed = &failed };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
    start.store(true, .release);
    while (admitted_one.load(.acquire) < 20 or admitted_two.load(.acquire) < 20) std.Thread.yield() catch {};
    queue_mod.discardSession(&concurrent, testing.allocator, 1);
    first_thread.join();
    second_thread.join();
    try testing.expect(done_one.load(.acquire) and done_two.load(.acquire));
    try testing.expect(!failed.load(.acquire));
    try testing.expectEqual(@as(usize, 160), admitted_one.load(.acquire) + admitted_two.load(.acquire));

    var drained: usize = 0;
    while (queue_mod.next(&concurrent)) |message| {
        try testing.expect(message.session_id == 1 or message.session_id == 2);
        try testing.expectEqualStrings("x", message.payload);
        testing.allocator.free(message.payload);
        drained += 1;
    }
    try testing.expect(drained > 0);
    try testing.expectEqual(@as(usize, 0), concurrent.bytes);
}
