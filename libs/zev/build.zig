const std = @import("std");
const build_support = @import("build_support.zig");

pub const build_support_api = build_support;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const android_ndk_clang = b.option([]const u8, "android-ndk-clang", "API-specific Android NDK Clang for linking the stress executable");
    const ohos_clang = b.option([]const u8, "ohos-clang", "OpenHarmony SDK Clang (the aarch64-unknown-linux-ohos-clang wrapper) for linking the stress executable");
    const ohos_sysroot = b.option([]const u8, "ohos-sysroot", "OpenHarmony native sysroot (the native/sysroot directory from the SDK)");
    const thread_sanitizer = b.option(bool, "tsan", "Build the tests and stress executable with ThreadSanitizer") orelse false;
    const ios_zig_lib_dir = b.option([]const u8, "ios-zig-lib-dir", "Patched Zig standard-library directory for iOS targets");
    const ohos = target.result.abi == .ohos or target.result.abi == .ohoseabi;

    const zev = b.addModule("zev", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = if (thread_sanitizer) true else null,
    });
    if (ohos) {
        // A parent that imports this module adds its SDK paths to the shared module instance. The standalone package configures its own module.
        if (b.isRoot()) build_support.configureOhosMutex(b, zev, target, ohos_sysroot);
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = if (thread_sanitizer) true else null,
            .imports = &.{.{ .name = "zev", .module = zev }},
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run event loop behavior tests");
    test_step.dependOn(&run_tests.step);

    const stress_module = b.createModule(.{
        .root_source_file = b.path("src/stress.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = if (thread_sanitizer) true else null,
        // The SDK Clang links position-independent executables by default.
        .pic = if (ohos) true else null,
        .imports = &.{.{ .name = "zev", .module = zev }},
    });
    if (ohos and b.isRoot()) {
        // This compatibility symbol is only for the standalone stress executable. The parent project already provides its own copy.
        build_support.addOhosMutexIncludes(b, stress_module, target, ohos_sysroot);
        stress_module.addCSourceFile(.{ .file = b.path("src/ohos_stress_statx.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror", "-O2" } });
    }
    const stress = b.addExecutable(.{
        .name = "zev-stress",
        .root_module = stress_module,
        .zig_lib_dir = if (b.isRoot() and target.result.os.tag == .ios) iosZigLibDir(ios_zig_lib_dir) else null,
    });
    const stress_step = b.step("stress", "Run zev contention stress test");
    if (target.result.abi.isAndroid() or ohos) {
        // Zig's own linker output lacks the emulated-TLS runtime these targets need, so the toolchain's Clang does the final link.
        const external_clang = if (ohos) ohos_clang else android_ndk_clang;
        if (external_clang) |clang| {
            const stress_object = b.addObject(.{
                .name = "zev-stress",
                .root_module = stress_module,
            });
            if (target.result.abi.isAndroid()) stress_object.bundle_compiler_rt = true;
            const link = b.addSystemCommand(&.{clang});
            link.addArgs(&.{ "-O2", "-o" });
            const linked_stress = link.addOutputFileArg("zev-stress");
            link.addFileArg(stress_object.getEmittedBin());
            link.addArgs(&.{ "-lm", "-pthread" });
            const install_stress = b.addInstallBinFile(linked_stress, "zev-stress");
            b.getInstallStep().dependOn(&install_stress.step);
            stress_step.dependOn(&install_stress.step);
        } else if (b.isRoot()) {
            const missing_clang = b.addFail(if (ohos)
                "OpenHarmony stress builds require -Dohos-clang=<path-to-sdk-clang>"
            else
                "Android stress builds require -Dandroid-ndk-clang=<path-to-ndk-clang>");
            const platform_stress = b.step(if (ohos) "ohos-stress" else "android-stress", "Build the stress executable with the platform toolchain");
            platform_stress.dependOn(&missing_clang.step);
            stress_step.dependOn(&missing_clang.step);
            b.getInstallStep().dependOn(&missing_clang.step);
        }
    } else {
        b.installArtifact(stress);
        const run_stress = b.addRunArtifact(stress);
        stress_step.dependOn(&run_stress.step);
    }

    // This executable is deliberately owned by the zev package: applications may call it, but the reusable package never imports root-project tools.
    const platform_test = b.addExecutable(.{
        .name = "zev-platform-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform_test_main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_platform_test = b.addRunArtifact(platform_test);
    run_platform_test.addPassthruArgs();
    b.step("platform-test", "Run the host-only ZEV platform test runner").dependOn(&run_platform_test.step);

    const overlay = b.addExecutable(.{
        .name = "zev-ios-stdlib-overlay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ios_stdlib_overlay_main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_overlay = b.addRunArtifact(overlay);
    run_overlay.addPassthruArgs();
    b.step("prepare-ios-stdlib", "Create a private patched Zig iOS standard-library overlay").dependOn(&run_overlay.step);

    const platform_test_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(platform_test_tests).step);

    const overlay_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ios_stdlib_overlay.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(overlay_tests).step);

    const fmt_step = b.step("fmt", "Run zig fmt on zev package source files");
    const fmt = b.addFmt(.{
        .paths = &.{
            b.path("src"),
            b.path("platform-test"),
            b.path("build.zig"),
            b.path("build_support.zig"),
            b.path("build.zig.zon"),
        },
        .check = false,
    });
    fmt_step.dependOn(&fmt.step);

    const test_fmt_step = b.step("test-fmt", "Check formatting of zev package source files");
    const test_fmt = b.addFmt(.{
        .paths = &.{
            b.path("src"),
            b.path("build.zig"),
            b.path("build_support.zig"),
            b.path("build.zig.zon"),
        },
        .check = true,
    });
    test_fmt_step.dependOn(&test_fmt.step);

    const check_fmt_step = b.step("check-fmt", "Alias for test-fmt");
    check_fmt_step.dependOn(&test_fmt.step);
}

fn iosZigLibDir(path: ?[]const u8) ?std.Build.LazyPath {
    const dir = path orelse @panic("iOS stress builds require -Dios-zig-lib-dir=<prepared-zig-stdlib>");
    return .{ .cwd_relative = dir };
}
