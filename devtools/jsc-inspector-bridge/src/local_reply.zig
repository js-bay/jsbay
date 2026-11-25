const std = @import("std");

pub const Result = enum {
    empty,
    domains_empty,
    heap_usage_zero,
};

fn resultJson(result: Result) []const u8 {
    return switch (result) {
        .empty => "{}",
        .domains_empty => "{\"domains\":[]}",
        .heap_usage_zero => "{\"usedSize\":0,\"totalSize\":0}",
    };
}

pub fn write(writer: *std.Io.Writer, id: std.json.Value, result: Result) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(id, .{}, writer);
    try writer.writeAll(",\"result\":");
    try writer.writeAll(resultJson(result));
    try writer.writeAll("}");
}
