const std = @import("std");

pub const Error = error{BufferTooSmall};

pub fn formatCommas(buf: []u8, n: u64) Error![]u8 {
    var digits: usize = 1;
    var remaining = n;
    while (remaining >= 10) : (remaining /= 10) {
        digits += 1;
    }

    const separators = (digits - 1) / 3;
    const output_len = digits + separators;
    if (buf.len < output_len) return error.BufferTooSmall;

    var index = output_len;
    remaining = n;
    var group_digits: usize = 0;
    while (true) {
        index -= 1;
        buf[index] = @as(u8, '0') + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
        group_digits += 1;

        if (remaining == 0) break;
        if (group_digits == 3) {
            index -= 1;
            buf[index] = ',';
            group_digits = 0;
        }
    }
    return buf[0..output_len];
}

test "formats zero without a separator" {
    var buf: [4]u8 = undefined;
    const formatted = try formatCommas(&buf, 0);
    try std.testing.expectEqualStrings("0", formatted);
}

test "inserts thousands separators" {
    var buf: [32]u8 = undefined;
    const formatted = try formatCommas(&buf, 1_234_567_890);
    try std.testing.expectEqualStrings("1,234,567,890", formatted);
}

test "reports a buffer that cannot hold the formatted value" {
    var buf = [_]u8{ 'x', 'x', 'x' };
    try std.testing.expectError(error.BufferTooSmall, formatCommas(&buf, 1_000));
    try std.testing.expectEqualSlices(u8, "xxx", &buf);
}

test "formats the largest u64" {
    var buf: [32]u8 = undefined;
    const formatted = try formatCommas(&buf, std.math.maxInt(u64));
    try std.testing.expectEqualStrings("18,446,744,073,709,551,615", formatted);
}
