//! VM-independent own-key ordering for QuickJS-family exotic host objects.

const std = @import("std");

/// Canonical array index: decimal form of an integer in `0 .. 2^32-2`.
fn canonicalArrayIndex(name: []const u8) ?u32 {
    if (name.len == 0 or name.len > 10) return null;
    if (name[0] == '0') return if (name.len == 1) 0 else null;
    var n: u64 = 0;
    for (name) |ch| {
        if (ch < '0' or ch > '9') return null;
        n = n * 10 + (ch - '0');
    }
    if (n >= 0xFFFF_FFFF) return null;
    return @intCast(n);
}

/// Integer indices ascending, then every other name in input order. QuickJS keeps exotic own-keys in callback order, so the sort has to happen here.
///
/// The caller supplies at least `names.len` slots in `order`; this operation does not allocate.
pub fn writeEnumerationOrder(names: []const []const u8, order: []usize) void {
    var n: usize = 0;
    for (names, 0..) |name, i| {
        if (canonicalArrayIndex(name) != null) {
            order[n] = i;
            n += 1;
        }
    }
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const key = order[i];
        const key_num = canonicalArrayIndex(names[key]).?;
        var j: usize = i;
        while (j > 0) {
            const prev = order[j - 1];
            const prev_num = canonicalArrayIndex(names[prev]).?;
            if (prev_num < key_num or (prev_num == key_num and prev < key)) break;
            order[j] = prev;
            j -= 1;
        }
        order[j] = key;
    }
    for (names, 0..) |name, idx| {
        if (canonicalArrayIndex(name) == null) {
            order[n] = idx;
            n += 1;
        }
    }
}

test "host keys: canonical indices exclude reserved and non-canonical spellings" {
    for ([_]struct { text: []const u8, index: u32 }{
        .{ .text = "0", .index = 0 },
        .{ .text = "1", .index = 1 },
        .{ .text = "4294967294", .index = 4294967294 },
    }) |item| try std.testing.expectEqual(item.index, canonicalArrayIndex(item.text).?);
    for ([_][]const u8{ "", "00", "02", "-1", "+1", "1.0", "1e0", " 1", "4294967295", "9999999999", "12345678901" }) |name| {
        try std.testing.expect(canonicalArrayIndex(name) == null);
    }
}

test "host keys: numeric indices sort stably before original-order strings" {
    const names = [_][]const u8{ "b", "02", "2", "0", "4294967294", "4294967295", "1", "a", "2" };
    var order: [names.len]usize = undefined;
    writeEnumerationOrder(&names, &order);
    try std.testing.expectEqualSlices(usize, &.{ 3, 6, 2, 8, 4, 0, 1, 5, 7 }, &order);
    var empty: [0]usize = .{};
    writeEnumerationOrder(&.{}, &empty);
}
