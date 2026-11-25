const std = @import("std");

pub fn compactTail(comptime T: type, queue: *std.ArrayList(T), start: usize, allocator: std.mem.Allocator) void {
    const tail_len = queue.items.len - start;
    if (tail_len > queue.capacity / 2) {
        std.mem.copyForwards(T, queue.items[0..tail_len], queue.items[start..]);
        queue.items.len = tail_len;
        return;
    }
    const compacted = allocator.alloc(T, tail_len) catch {
        std.mem.copyForwards(T, queue.items[0..tail_len], queue.items[start..]);
        queue.items.len = tail_len;
        return;
    };
    @memcpy(compacted, queue.items[start..]);
    allocator.free(queue.allocatedSlice());
    queue.items = compacted;
    queue.capacity = compacted.len;
}

test "rejection queue compaction releases mostly unused capacity" {
    var tracked = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = tracked.allocator();
    var queue: std.ArrayList(u64) = .empty;
    defer queue.deinit(allocator);
    try queue.ensureTotalCapacityPrecise(allocator, 64);
    for (0..64) |index| try queue.append(allocator, index);
    const old_allocation_bytes = queue.capacity * @sizeOf(u64);

    compactTail(u64, &queue, 63, allocator);

    try std.testing.expectEqual(@as(usize, 1), queue.capacity);
    try std.testing.expectEqual(@as(u64, 63), queue.items[0]);
    try std.testing.expectEqual(old_allocation_bytes, tracked.freed_bytes);
}

test "rejection queue compaction retains capacity when most entries remain" {
    var tracked = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = tracked.allocator();
    var queue: std.ArrayList(u64) = .empty;
    defer queue.deinit(allocator);
    try queue.ensureTotalCapacityPrecise(allocator, 8);
    for (0..8) |index| try queue.append(allocator, index);
    const allocations = tracked.allocations;

    compactTail(u64, &queue, 2, allocator);

    try std.testing.expectEqual(@as(usize, 8), queue.capacity);
    try std.testing.expectEqual(@as(usize, 6), queue.items.len);
    try std.testing.expectEqual(allocations, tracked.allocations);
    for (queue.items, 2..) |item, index| try std.testing.expectEqual(@as(u64, @intCast(index)), item);
}

test "rejection queue compaction preserves tail when shrinking runs out of memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var queue: std.ArrayList(u64) = .empty;
    defer queue.deinit(allocator);
    try queue.ensureTotalCapacityPrecise(allocator, 64);
    for (0..64) |index| try queue.append(allocator, index);
    failing.fail_index = failing.alloc_index;

    compactTail(u64, &queue, 63, allocator);

    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing.freed_bytes);
    try std.testing.expectEqual(@as(usize, 64), queue.capacity);
    try std.testing.expectEqual(@as(usize, 1), queue.items.len);
    try std.testing.expectEqual(@as(u64, 63), queue.items[0]);
}
