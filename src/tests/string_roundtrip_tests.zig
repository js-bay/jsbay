//! JS string round-trip. Bytes written from a Zig slice must come back with the same length, including embedded 0x00. The caller frees the buffer with the allocator it passed in.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const helpers = @import("test_helpers.zig");

const ActiveEngine = backend.ActiveEngine;

fn expectRoundTrip(ctx: ActiveEngine.Context, input: []const u8) !void {
    const js = ActiveEngine.newStringVal(ctx, input);
    defer ActiveEngine.freeValue(ctx, js);
    const got = ActiveEngine.valueToStringAlloc(testing.allocator, ctx, js) orelse return error.MissingString;
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, input, got);
}

test "string roundtrip preserves embedded NUL, ASCII, and non-ASCII" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try expectRoundTrip(ctx, "a\x00b");
            try expectRoundTrip(ctx, "\x00");
            try expectRoundTrip(ctx, "a\x00b\x00");
            try expectRoundTrip(ctx, "");
            try expectRoundTrip(ctx, "ascii");
            try expectRoundTrip(ctx, "γειά");
            try expectRoundTrip(ctx, "a\x00Σ");
            try expectRoundTrip(ctx, "🙂");
        }
    }.run);
}
