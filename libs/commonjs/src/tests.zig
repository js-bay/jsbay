const std = @import("std");
const commonjs = @import("root.zig");
comptime {
    _ = @import("loader.zig");
    _ = @import("registry.zig");
}

test "public package exposes loader identity and registry without a VM" {
    const Host = struct {
        fn load(_: ?*anyopaque, _: [*:0]const u8, out: *commonjs.LoadResult) callconv(.c) bool {
            out.* = .{ .source = "source", .source_len = 6 };
            return true;
        }
    };
    const vtable = commonjs.LoaderVTable{ .load = Host.load };
    const loader = commonjs.Loader{ .vtable = &vtable };
    const resolved = try commonjs.resolveSpecifier(std.testing.allocator, &loader, "module", "parent");
    defer resolved.deinit();
    try std.testing.expectEqualStrings("module", resolved.id);
    try std.testing.expectEqualStrings("dir", commonjs.dirnameOf("dir/module"));
    try std.testing.expect(@hasDecl(commonjs, "Registry"));
}
