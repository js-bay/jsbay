//! Regression tests for target-specific release build arguments.
const std = @import("std");
const sdk = @import("sdk.zig");
const support = @import("distribution_test_support.zig");

const testing = std.testing;
const Dir = std.Io.Dir;

test "test_library_build_accepts_empty_and_explicit_targets_with_runner_bash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try support.root(a, io);
    const fixture = try support.temp(a, io, "jsbay-release-runner");
    defer Dir.cwd().deleteTree(io, fixture) catch {};
    const cases = [_]struct { job: []const u8, step: []const u8, target: []const u8, apple: bool }{
        .{ .job = "build-libs-linux", .step = "Build library quickjs_ng (linux-x86_64)", .target = "x86_64-linux-gnu", .apple = false },
        .{ .job = "build-libs-macos", .step = "Build library quickjs_ng (macos-aarch64)", .target = "aarch64-macos.11.0", .apple = true },
        .{ .job = "build-libs-macos", .step = "Build library quickjs (macos-aarch64)", .target = "aarch64-macos.11.0", .apple = true },
    };
    const zig = try support.join(a, fixture, &.{"zig"});
    const xcrun = try support.join(a, fixture, &.{"xcrun"});
    const args = try support.join(a, fixture, &.{"args.txt"});
    try support.executable(a, io, fixture, zig, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ZIG_ARGS_FILE\"\n");
    try support.executable(a, io, fixture, xcrun, "#!/bin/sh\nprintf '%s\\n' \"$FAKE_APPLE_SDK\"\n");
    const env_path = try support.pathEnv(a, fixture);
    const zig_args_env = try std.fmt.allocPrint(a, "ZIG_ARGS_FILE={s}", .{args});
    const apple_sdk_env = try std.fmt.allocPrint(a, "FAKE_APPLE_SDK={s}", .{fixture});
    const apple_sysroot_arg = try std.fmt.allocPrint(a, "-Dapple-sysroot={s}", .{fixture});
    for (cases) |case| {
        const script_extract = try std.fmt.allocPrint(a, "require 'yaml'; steps = YAML.load_file(ARGV.fetch(0)).fetch('jobs').fetch('{s}').fetch('steps'); puts steps.find {{ |step| step['name'] == '{s}' }}.fetch('run')", .{ case.job, case.step });
        var extracted = try support.mustRun(a, io, cwd, &.{ "ruby", "-e", script_extract, ".github/workflows/release.yml" });
        defer extracted.deinit();
        var out = try sdk.run(a, io, &.{ "env", env_path, zig_args_env, apple_sdk_env, "bash", "-euo", "pipefail", "-c", extracted.result.stdout }, cwd);
        defer out.deinit();
        try testing.expect(out.succeeded());
        const recorded = try support.read(a, io, fixture, &.{"args.txt"});
        try support.contains(recorded, try std.fmt.allocPrint(a, "-Dtarget={s}", .{case.target}));
        if (case.apple) try support.contains(recorded, apple_sysroot_arg) else try support.notContains(recorded, "-Dapple-sysroot=");
        if (std.mem.indexOf(u8, case.step, "quickjs (") != null) try support.contains(recorded, "-Dbackend=quickjs") else try support.contains(recorded, "-Dbackend=quickjs_ng");
    }
}
