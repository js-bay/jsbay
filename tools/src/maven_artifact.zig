const std = @import("std");

pub fn resolve(backend: []const u8, requested: ?[]const u8) ?[]const u8 {
    const quickjs = std.mem.eql(u8, backend, "quickjs");
    const quickjs_ng = std.mem.eql(u8, backend, "quickjs_ng");
    if (!quickjs and !quickjs_ng) return null;
    const artifact = requested orelse if (quickjs) "jsbay-quickjs" else "jsbay-quickjs-ng";
    const matches = if (quickjs)
        std.mem.eql(u8, artifact, "jsbay-quickjs") or std.mem.eql(u8, artifact, "jsbayquickjs")
    else
        std.mem.eql(u8, artifact, "jsbay-quickjs-ng") or std.mem.eql(u8, artifact, "jsbayquickjsng");
    return if (matches) artifact else null;
}

test "Maven artifact names preserve legacy and current coordinates" {
    const cases = .{
        .{ "quickjs", null, "jsbay-quickjs" },
        .{ "quickjs", "jsbay-quickjs", "jsbay-quickjs" },
        .{ "quickjs", "jsbayquickjs", "jsbayquickjs" },
        .{ "quickjs_ng", null, "jsbay-quickjs-ng" },
        .{ "quickjs_ng", "jsbay-quickjs-ng", "jsbay-quickjs-ng" },
        .{ "quickjs_ng", "jsbayquickjsng", "jsbayquickjsng" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[2], resolve(case[0], case[1]).?);
    try std.testing.expect(resolve("unknown", null) == null);
    try std.testing.expect(resolve("quickjs", "jsbay-quickjs-ng") == null);
    try std.testing.expect(resolve("quickjs_ng", "jsbay-quickjs") == null);
}
