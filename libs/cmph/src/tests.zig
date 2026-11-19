//! Unit tests for cmph package.

const std = @import("std");
const cmph = @import("cmph");
const ComptimeMinimalPerfectHash = cmph.ComptimeMinimalPerfectHash;

test "cmph: generic compile-time minimal perfect hash lookup" {
    const testing = std.testing;
    const dictionary = [_][]const u8{
        "apple",     "banana",    "cherry",   "date",  "elderberry",
        "fig",       "grape",     "honeydew", "kiwi",  "lemon",
        "mango",     "nectarine", "orange",   "peach", "quince",
        "raspberry",
    };
    const FruitMatcher = ComptimeMinimalPerfectHash(&dictionary);

    for (dictionary, 0..) |fruit, expected_idx| {
        try testing.expectEqual(expected_idx, FruitMatcher.match(fruit).?);
    }

    try testing.expect(FruitMatcher.match("unknownFruit") == null);
    try testing.expect(FruitMatcher.match("app") == null);
    try testing.expect(FruitMatcher.match("applepie") == null);
    try testing.expect(FruitMatcher.match("") == null);
}

test "cmph: matches dictionary containing empty string key" {
    const testing = std.testing;
    const keys = [_][]const u8{ "", "alpha", "beta" };
    const Matcher = ComptimeMinimalPerfectHash(&keys);

    try testing.expectEqual(@as(?usize, 0), Matcher.match(""));
    try testing.expectEqual(@as(?usize, 1), Matcher.match("alpha"));
    try testing.expectEqual(@as(?usize, 2), Matcher.match("beta"));
    try testing.expectEqual(@as(?usize, null), Matcher.match("gamma"));
}
