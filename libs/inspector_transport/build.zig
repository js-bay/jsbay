const std = @import("std");
const zev_build = @import("zev");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ohos_sysroot = b.option([]const u8, "ohos-sysroot", "OpenHarmony native sysroot (the native/sysroot directory from the SDK)");
    const zev = b.dependency("zev", .{
        .target = target,
        .optimize = optimize,
    }).module("zev");
    if (b.isRoot()) zev_build.build_support_api.configureOhosMutex(b, zev, target, ohos_sysroot);
    const inspector = b.dependency("inspector", .{
        .target = target,
        .optimize = optimize,
    }).module("inspector");
    const transport = b.addModule("inspector_transport", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zev", .module = zev },
            .{ .name = "inspector", .module = inspector },
        },
    });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zev", .module = zev },
                .{ .name = "inspector_transport", .module = transport },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run inspector HTTP/WebSocket transport tests").dependOn(&run_tests.step);

    const fmt_step = b.step("fmt", "Run zig fmt on inspector_transport package source files");
    const fmt = b.addFmt(.{
        .paths = &.{
            b.path("src"),
            b.path("build.zig"),
            b.path("build.zig.zon"),
        },
        .check = false,
    });
    fmt_step.dependOn(&fmt.step);

    const test_fmt_step = b.step("test-fmt", "Check formatting of inspector_transport package source files");
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
