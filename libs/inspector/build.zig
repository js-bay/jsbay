const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const inspector = b.addModule("inspector", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "inspector", .module = inspector }} }) });
    const run_tests = b.addRunArtifact(tests);
    const step = b.step("test", "Run inspector package tests");
    step.dependOn(&run_tests.step);

    const fmt_step = b.step("fmt", "Run zig fmt on inspector package source files");
    const fmt = b.addFmt(.{
        .paths = &.{
            b.path("src"),
            b.path("build.zig"),
            b.path("build.zig.zon"),
        },
        .check = false,
    });
    fmt_step.dependOn(&fmt.step);

    const test_fmt_step = b.step("test-fmt", "Check formatting of inspector package source files");
    const test_fmt = b.addFmt(.{
        .paths = &.{
            b.path("src"),
            b.path("build.zig"),
            b.path("build.zig.zon"),
        },
        .check = true,
    });
    test_fmt_step.dependOn(&test_fmt.step);

    const check_fmt_step = b.step("check-fmt", "Alias for test-fmt");
    check_fmt_step.dependOn(&test_fmt.step);
}
