const std = @import("std");

pub fn build(b: *std.Build) void {
    const core = b.dependency("jsbay", .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .backend = .quickjs_ng,
    });
    const options = core.module("jsbay").import_table.get("build_options").?;
    b.getInstallStep().dependOn(&b.addInstallFile(options.root_source_file.?, "options.zig").step);
}
