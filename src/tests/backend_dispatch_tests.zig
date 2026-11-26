const std = @import("std");
const backend_dispatch = @import("../backend_dispatch.zig");
const multi_pack = @import("../multi_pack.zig");
const Backend = backend_dispatch.Backend;

test "backend_dispatch: create/eval/destroy via erased handles for each packed tag" {
    const testing = std.testing;
    const tags = [_]Backend{ .quickjs_ng, .quickjs, .jsc };
    for (tags) |tag| {
        if (!multi_pack.isPacked(tag)) continue;
        const handles = backend_dispatch.createPacked(tag) orelse return error.CreatePackedFailed;
        backend_dispatch.finishCreate(tag, handles, 42, 256 * 1024);
        const res = backend_dispatch.evalPacked(tag, handles, "1+1", "<backend_dispatch>");
        defer {
            if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
            if (res.err_is_heap) {
                if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
            }
        }
        try testing.expect(res.err == null);
        try testing.expectEqualStrings("2", res.result.?);
        backend_dispatch.processPendingJobsPacked(tag, handles);
        backend_dispatch.destroyPacked(tag, handles);
    }
}

test "backend_dispatch: refused when tag not packed" {
    // On a single-pack Linux NG build, jsc is not packed.
    if (comptime multi_pack.isPacked(.jsc)) return error.SkipZigTest;
    try std.testing.expect(backend_dispatch.createPacked(.jsc) == null);
}
