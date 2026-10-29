const std = @import("std");
const testing = std.testing;
const console_format = @import("../backend/console_format.zig");

test "finishMessage transfers the formatted buffer and adds one sentinel" {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(std.heap.c_allocator, "hello world");

    const msg = try console_format.finishMessage(std.heap.c_allocator, &buf);
    defer std.heap.c_allocator.free(msg);

    try testing.expectEqualStrings("hello world", msg);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
    try testing.expectEqual(@as(usize, 0), buf.capacity);
}

test "finishMessage handles an empty console message" {
    var buf: std.ArrayList(u8) = .empty;

    const msg = try console_format.finishMessage(std.heap.c_allocator, &buf);
    defer std.heap.c_allocator.free(msg);

    try testing.expectEqual(@as(usize, 0), msg.len);
    try testing.expectEqual(@as(u8, 0), msg[0]);
}
