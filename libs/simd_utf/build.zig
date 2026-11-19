const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const simd_utf = b.addModule("simd_utf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "simd_utf", .module = simd_utf }},
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run simd_utf package tests").dependOn(&run_tests.step);

    const fmt_step = b.step("fmt", "Run zig fmt on simd_utf package source files");
    const fmt = b.addFmt(.{
        .paths = &.{
            b.path("src"),
            b.path("build.zig"),
            b.path("build.zig.zon"),
        },
        .check = false,
    });
    fmt_step.dependOn(&fmt.step);

    const test_fmt_step = b.step("test-fmt", "Check formatting of simd_utf package source files");
    const test_fmt = b.addFmt(.{
        .paths = &.{
            b.path("src"),
            b.path("build.zig"),
            b.path("build.zig.zon"),
        },
        .check = true,
    });
    test_fmt_step.dependOn(&test_fmt.step);
}
