const std = @import("std");

/// Finish a formatted console message without copying the ArrayList a second time. The returned slice owns the allocation and is NUL terminated for the C ABI callbacks used by both backends.
pub fn finishMessage(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
) ![:0]u8 {
    return buf.toOwnedSliceSentinel(allocator, 0);
}
