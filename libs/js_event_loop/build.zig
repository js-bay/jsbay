const std = @import("std");
const zev_build = @import("zev");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ohos_sysroot = b.option([]const u8, "ohos-sysroot", "OpenHarmony native sysroot (the native/sysroot directory from the SDK)");
    const zev_dep = b.dependency("zev", .{ .target = target, .optimize = optimize });
    const zev = zev_dep.module("zev");
    if (b.isRoot()) zev_build.build_support_api.configureOhosMutex(b, zev, target, ohos_sysroot);
    const js_event_loop = b.addModule("js_event_loop", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zev", .module = zev }},
    });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .link_libc = true,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "js_event_loop", .module = js_event_loop },
            .{ .name = "zev", .module = zev },
        },
    }) });
    b.step("test", "Run JS event-loop package tests").dependOn(&b.addRunArtifact(tests).step);

    const fmt_step = b.step("fmt", "Run zig fmt on js_event_loop package source files");
    const fmt = b.addFmt(.{
        .paths = &.{
            b.path("src"),
            b.path("build.zig"),
            b.path("build.zig.zon"),
        },
        .check = false,
    });
    fmt_step.dependOn(&fmt.step);

    const test_fmt_step = b.step("test-fmt", "Check formatting of js_event_loop package source files");
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
