//! Black-box distribution regressions.
const std = @import("std");
const sdk = @import("sdk.zig");

const testing = std.testing;
const Dir = std.Io.Dir;

fn root(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return std.process.currentPathAlloc(io, allocator);
}

fn temp(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) ![]u8 {
    var random: [12]u8 = undefined;
    io.random(&random);
    const directory = try std.fmt.allocPrint(allocator, "/tmp/{s}-{s}", .{ prefix, std.fmt.bytesToHex(random, .lower) });
    try Dir.cwd().createDir(io, directory, .default_dir);
    return directory;
}

fn join(allocator: std.mem.Allocator, base: []const u8, parts: []const []const u8) ![]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(allocator);
    try all.append(allocator, base);
    try all.appendSlice(allocator, parts);
    return std.fs.path.join(allocator, all.items);
}

fn write(io: std.Io, name: []const u8, contents: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = name, .data = contents });
}

fn read(allocator: std.mem.Allocator, io: std.Io, base: []const u8, parts: []const []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(io, try join(allocator, base, parts), allocator, .limited(16 * 1024 * 1024));
}

fn contains(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn notContains(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn mustRun(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8) !sdk.Output {
    var output = try sdk.run(allocator, io, argv, cwd);
    if (!output.succeeded()) {
        std.debug.print("command failed: {s}\n{s}", .{ output.result.stdout, output.result.stderr });
        output.deinit();
        return error.CommandFailed;
    }
    return output;
}

fn executable(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, name: []const u8, contents: []const u8) !void {
    try write(io, name, contents);
    var output = try mustRun(allocator, io, cwd, &.{ "chmod", "+x", name });
    output.deinit();
}

fn pathEnv(allocator: std.mem.Allocator, tools: []const u8) ![]u8 {
    // Keep this libc-free: `zig build test-tools` does not link libc on CI.
    // tools/ must stay first so fixture stubs win over host binaries.
    return std.fmt.allocPrint(allocator, "PATH={s}:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin", .{tools});
}

fn androidFixture(allocator: std.mem.Allocator, io: std.Io, fixture: []const u8) ![]u8 {
    const tools = try join(allocator, fixture, &.{"tools"});
    const bin = try join(allocator, fixture, &.{ "ndk", "toolchains", "llvm", "prebuilt", "test", "bin" });
    var output = try mustRun(allocator, io, fixture, &.{ "mkdir", "-p", tools, bin, try join(allocator, fixture, &.{ "ndk", "toolchains", "llvm", "prebuilt", "test", "sysroot" }) });
    output.deinit();
    const clang =
        \\#!/bin/sh
        \\out=""; previous=""
        \\for arg in "$@"; do [ "$previous" = -o ] && out="$arg"; previous="$arg"; done
        \\[ -n "$out" ] && { mkdir -p "$(dirname "$out")"; printf object > "$out"; }
        \\
    ;
    try executable(allocator, io, fixture, try join(allocator, bin, &.{"aarch64-linux-android24-clang"}), clang);
    try executable(allocator, io, fixture, try join(allocator, bin, &.{"x86_64-linux-android24-clang"}), clang);
    try executable(allocator, io, fixture, try join(allocator, bin, &.{"llvm-ar"}), "#!/bin/sh\nif [ \"$1\" = x ]; then printf object > unit.o; fi\nexit 0\n");
    try executable(allocator, io, fixture, try join(allocator, bin, &.{"llvm-nm"}), "#!/bin/sh\nexit 0\n");
    try executable(allocator, io, fixture, try join(allocator, bin, &.{"llvm-objcopy"}), "#!/bin/sh\nexit 0\n");
    try executable(allocator, io, fixture, try join(allocator, tools, &.{"zig"}),
        \\#!/bin/sh
        \\[ "$1" = build ] && [ "$2" = tool ] && exit 0
        \\target=""; prefix=""; previous=""
        \\for arg in "$@"; do case "$arg" in -Dtarget=*) target="${arg#-Dtarget=}" ;; esac; [ "$previous" = --prefix ] && prefix="$arg"; previous="$arg"; done
        \\if [ "${FAIL_X64:-}" = 1 ] && [ "${target#x86_64}" != "$target" ]; then exit 42; fi
        \\mkdir -p "$prefix/lib"; printf archive > "$prefix/lib/libjsbay.a"
        \\
    );
    return tools;
}

test "test_android_failed_second_arch_keeps_existing_output_unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const fixture = try temp(a, io, "jsbay-android-atomic");
    defer Dir.cwd().deleteTree(io, fixture) catch {};
    const output_dir = try join(a, fixture, &.{"jniLibs"});
    var setup = try mustRun(a, io, fixture, &.{ "mkdir", "-p", try join(a, output_dir, &.{"arm64-v8a"}), try join(a, output_dir, &.{"x86_64"}) });
    defer setup.deinit();
    try write(io, try join(a, output_dir, &.{ "arm64-v8a", "libjsbay.so" }), "old-arm64-v8a");
    try write(io, try join(a, output_dir, &.{ "x86_64", "libjsbay.so" }), "old-x86_64");
    const tools = try androidFixture(a, io, fixture);
    const env_path = try pathEnv(a, tools);
    var result = try sdk.run(a, io, &.{ "env", env_path, try std.fmt.allocPrint(a, "ANDROID_NDK_HOME={s}/ndk", .{fixture}), "FAIL_X64=1", try join(a, cwd, &.{"build-android.sh"}), output_dir }, cwd);
    defer result.deinit();
    try testing.expect(!result.succeeded());
    try contains(result.result.stdout, "Building Android x86_64");
    try testing.expectEqualStrings("old-arm64-v8a", try read(a, io, output_dir, &.{ "arm64-v8a", "libjsbay.so" }));
    try testing.expectEqualStrings("old-x86_64", try read(a, io, output_dir, &.{ "x86_64", "libjsbay.so" }));
}

test "test_android_rejects_stale_unsupported_abi_without_removing_it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const fixture = try temp(a, io, "jsbay-android-stale");
    defer Dir.cwd().deleteTree(io, fixture) catch {};
    const stale = try join(a, fixture, &.{ "jniLibs", "armeabi-v7a", "libjsbay.so" });
    var setup = try mustRun(a, io, fixture, &.{ "mkdir", "-p", try join(a, fixture, &.{ "jniLibs", "armeabi-v7a" }) });
    defer setup.deinit();
    try write(io, stale, "old-arm");
    const tools = try androidFixture(a, io, fixture);
    const env_path = try pathEnv(a, tools);
    var result = try sdk.run(a, io, &.{ "env", env_path, try std.fmt.allocPrint(a, "ANDROID_NDK_HOME={s}/ndk", .{fixture}), try join(a, cwd, &.{"build-android.sh"}), try join(a, fixture, &.{"jniLibs"}) }, cwd);
    defer result.deinit();
    try testing.expect(!result.succeeded());
    try contains(result.result.stderr, "unsupported ABI");
    try testing.expectEqualStrings("old-arm", try read(a, io, fixture, &.{ "jniLibs", "armeabi-v7a", "libjsbay.so" }));
}

fn appleFixture(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, fixture: []const u8) ![]u8 {
    const repo = try join(allocator, fixture, &.{"repo"});
    const tools = try join(allocator, fixture, &.{"tools"});
    var setup = try mustRun(allocator, io, fixture, &.{ "mkdir", "-p", tools, try join(allocator, repo, &.{"scripts"}), try join(allocator, repo, &.{"include"}), try join(allocator, repo, &.{ "tests", "zig-consumer" }) });
    defer setup.deinit();
    for ([_][]const []const u8{ &.{ try join(allocator, cwd, &.{"build-apple.sh"}), try join(allocator, repo, &.{"build-apple.sh"}) }, &.{ try join(allocator, cwd, &.{ "scripts", "apple_consumer_probe.c" }), try join(allocator, repo, &.{ "scripts", "apple_consumer_probe.c" }) }, &.{ try join(allocator, cwd, &.{ "scripts", "apple_consumer_ios_main.m" }), try join(allocator, repo, &.{ "scripts", "apple_consumer_ios_main.m" }) }, &.{ try join(allocator, cwd, &.{ "scripts", "apple_consumer_ios_Info.plist" }), try join(allocator, repo, &.{ "scripts", "apple_consumer_ios_Info.plist" }) } }) |copy| {
        var out = try mustRun(allocator, io, fixture, &.{ "cp", copy[0], copy[1] });
        out.deinit();
    }
    try write(io, try join(allocator, repo, &.{ "include", "jsbay.h" }), "\n");
    try write(io, try join(allocator, repo, &.{ "include", "module.modulemap" }), "\n");
    try write(io, try join(allocator, repo, &.{ "tests", "zig-consumer", "build.zig" }), "\n");
    try executable(allocator, io, fixture, try join(allocator, tools, &.{"zig"}),
        \\#!/bin/sh
        \\if [ "$1" = build ] && [ "$2" = --build-file ]; then mkdir -p zig-out/bin; { echo '#!/bin/sh'; echo 'exit 0'; } > zig-out/bin/jsbay-tool; chmod +x zig-out/bin/jsbay-tool; exit 0; fi
        \\[ "$1" = build ] && [ "$2" = tool ] && exit 0
        \\prefix=""; previous=""; for arg in "$@"; do [ "$previous" = --prefix ] && prefix="$arg"; previous="$arg"; done
        \\[ -n "$prefix" ] || exit 0
        \\mkdir -p "$prefix/lib"; printf archive > "$prefix/lib/libjsbay.a"
        \\
    );
    try executable(allocator, io, fixture, try join(allocator, tools, &.{"xcrun"}),
        \\#!/bin/sh
        \\if [ "$3" = --show-sdk-path ]; then printf /sdk; exit 0; fi
        \\if [ "$1" = otool ] && [ "$2" = -l ]; then case "$3" in *macos*) minos=11.0 ;; *ios-sim-arm64*) minos=14.0 ;; *) minos=13.0 ;; esac; printf '      cmd LC_BUILD_VERSION\n    minos %s\n' "$minos"; exit 0; fi
        \\if [ "$1" = simctl ] && [ "$2" = list ]; then if [ "$3" = devicetypes ]; then printf '{"devicetypes": []}'; else printf '{"runtimes": []}'; fi; exit 0; fi
        \\if [ "$1" = lipo ] && [ "$2" = -create ]; then source="$3"; out=""; previous=""; for arg in "$@"; do [ "$previous" = -output ] && out="$arg"; previous="$arg"; done; cp "$source" "$out"; exit 0; fi
        \\if [ "$1" = lipo ] && [ "$2" = -verify_arch ]; then exit 2; fi
        \\if [ "$3" = clang ]; then out=""; previous=""; for arg in "$@"; do [ "$previous" = -o ] && out="$arg"; previous="$arg"; done; mkdir -p "$(dirname "$out")"; { echo '#!/bin/sh'; echo 'echo JSBAY_APPLE_CONSUMER_PASS'; } > "$out"; chmod +x "$out"; exit 0; fi
        \\if [ "$2" = codesign ]; then exit 0; fi
        \\exit 0
        \\
    );
    try executable(allocator, io, fixture, try join(allocator, tools, &.{"nm"}),
        \\#!/bin/sh
        \\[ "${FAKE_NM_FAILURE:-}" = 1 ] && exit 42
        \\[ "${FAKE_JSC_IOS18_IMPORT:-}" = 1 ] && printf ' _JSValueIsBigInt\n'
        \\[ "${FAKE_IOS13_VECTORED_IMPORT:-}" = 1 ] && printf '                 (undefined) external _preadv\n'
        \\[ "${FAKE_IOS13_WEAK_IMPORT:-}" = 1 ] && printf '                 (undefined) weak external _preadv\n'
        \\exit 0
        \\
    );
    try executable(allocator, io, fixture, try join(allocator, tools, &.{"codesign"}), "#!/bin/sh\nexit 0\n");
    try executable(allocator, io, fixture, try join(allocator, tools, &.{"xcodebuild"}), "#!/bin/sh\nout=\"\"; previous=\"\"; for arg in \"$@\"; do [ \"$previous\" = -output ] && out=\"$arg\"; previous=\"$arg\"; done\nfor platform in macos-arm64 ios-arm64 ios-arm64_x86_64-simulator; do mkdir -p \"$out/$platform/Headers\"; src=\"$PWD\"/build/libjsbay-macos-arm64.a; [ -f \"$src\" ] || { mkdir -p \"$PWD\"/build; printf archive > \"$src\"; }; cp \"$src\" \"$out/$platform/libjsbay.a\"; done\n");
    return repo;
}

test "test_apple_missing_simulator_runtime_fails_the_script" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const fixture = try temp(a, io, "jsbay-apple-distribution");
    defer Dir.cwd().deleteTree(io, fixture) catch {};
    const repo = try appleFixture(a, io, cwd, fixture);
    const tools = try join(a, fixture, &.{"tools"});
    const env_path = try pathEnv(a, tools);
    const build_dir = try join(a, repo, &.{"build"});
    const script = try join(a, repo, &.{"build-apple.sh"});
    const base = [_][]const u8{ "env", env_path, try std.fmt.allocPrint(a, "BUILD_DIR={s}", .{build_dir}), script };
    var unavailable = try sdk.run(a, io, &base, repo);
    defer unavailable.deinit();
    try testing.expect(!unavailable.succeeded());
    const unavailable_out = try std.fmt.allocPrint(a, "{s}{s}", .{ unavailable.result.stderr, unavailable.result.stdout });
    const status = read(a, io, build_dir, &.{ "consumer-probes", "ios-simulator-consumer.status" }) catch null;
    const has_msg = std.mem.indexOf(u8, unavailable_out, "Simulator runtime unavailable") != null;
    if (status == null and !has_msg) {
        std.debug.print("apple missing-sim probe failed without status/msg\nstdout:\n{s}\nstderr:\n{s}\n", .{ unavailable.result.stdout, unavailable.result.stderr });
    }
    try testing.expect(status != null or has_msg);
    if (status) |s| {
        try testing.expectEqualStrings("FAIL: iOS Simulator runtime unavailable\n", s);
    }
    var bigint = try sdk.run(a, io, &.{ "env", env_path, try std.fmt.allocPrint(a, "BUILD_DIR={s}", .{build_dir}), "FAKE_JSC_IOS18_IMPORT=1", script, "jsc" }, repo);
    defer bigint.deinit();
    try testing.expect(!bigint.succeeded());
    try contains(bigint.result.stderr, "JSValueIsBigInt");
    try notContains(bigint.result.stderr, "Simulator runtime unavailable");
    var vector = try sdk.run(a, io, &.{ "env", env_path, try std.fmt.allocPrint(a, "BUILD_DIR={s}", .{build_dir}), "FAKE_IOS13_VECTORED_IMPORT=1", script }, repo);
    defer vector.deinit();
    try testing.expect(!vector.succeeded());
    try contains(vector.result.stderr, "preadv");
    try notContains(vector.result.stderr, "Simulator runtime unavailable");
    var nm_fail = try sdk.run(a, io, &.{ "env", env_path, try std.fmt.allocPrint(a, "BUILD_DIR={s}", .{build_dir}), "FAKE_NM_FAILURE=1", script }, repo);
    defer nm_fail.deinit();
    try testing.expect(!nm_fail.succeeded());
    try contains(nm_fail.result.stderr, "cannot inspect undefined imports");
    try notContains(nm_fail.result.stderr, "Simulator runtime unavailable");
    var weak = try sdk.run(a, io, &.{ "env", env_path, try std.fmt.allocPrint(a, "BUILD_DIR={s}", .{build_dir}), "FAKE_IOS13_WEAK_IMPORT=1", script }, repo);
    defer weak.deinit();
    try testing.expect(!weak.succeeded());
    try contains(weak.result.stderr, "Simulator runtime unavailable");
    try notContains(weak.result.stderr, "strongly imports preadv");
}

test "test_release_builds_and_uploads_verified_android_aar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const release = try read(a, io, cwd, &.{ ".github", "workflows", "release.yml" });
    for ([_][]const u8{ "jni/arm64-v8a/libjsbay_android.so", "jni/x86_64/libjsbay_android.so", "proguard.txt", "jsbay-${{ steps.ver.outputs.label }}-android-${{ matrix.backend }}.aar", "jsbay-*.aar" }) |needle| try contains(release, needle);
}

test "test_android_release_includes_maven_metadata_and_transitive_kotlin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const release = try read(a, io, cwd, &.{ ".github", "workflows", "release.yml" });
    const gradle = try read(a, io, cwd, &.{ "sdk", "android", "jsbay", "build.gradle.kts" });
    for ([_][]const u8{ "maven-publish", "implementation(\"org.jetbrains.kotlin:kotlin-stdlib" }) |needle| try contains(gradle, needle);
    for ([_][]const u8{ ":jsbay:publishReleasePublicationToStagingRepository", "-PjsbayVersion=", "-PjsbayMavenRepo=", "archive=\"jsbay-${ver}-android-${backend}-maven.zip\"", "tests/android-sdk/maven-consumer.sh", "env -u ANDROID_HOME ANDROID_SDK_ROOT=\"$ANDROID_SDK_ROOT\"", "-PjsbayVersion=\"${{ steps.ver.outputs.label }}\"", "tool -- check-maven" }) |needle| try contains(release, needle);
}

test "test_library_build_accepts_empty_and_explicit_targets_with_runner_bash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const fixture = try temp(a, io, "jsbay-release-runner");
    defer Dir.cwd().deleteTree(io, fixture) catch {};
    const cases = [_]struct { job: []const u8, step: []const u8, target: []const u8, apple: bool }{
        .{ .job = "build-libs-linux", .step = "Build library quickjs_ng (linux-x86_64)", .target = "x86_64-linux-gnu", .apple = false },
        .{ .job = "build-libs-macos", .step = "Build library quickjs_ng (macos-aarch64)", .target = "aarch64-macos.11.0", .apple = true },
        .{ .job = "build-libs-macos", .step = "Build library quickjs (macos-aarch64)", .target = "aarch64-macos.11.0", .apple = true },
    };
    const zig = try join(a, fixture, &.{"zig"});
    const xcrun = try join(a, fixture, &.{"xcrun"});
    const args = try join(a, fixture, &.{"args.txt"});
    try executable(a, io, fixture, zig, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ZIG_ARGS_FILE\"\n");
    try executable(a, io, fixture, xcrun, "#!/bin/sh\nprintf '%s\\n' \"$FAKE_APPLE_SDK\"\n");
    const env_path = try pathEnv(a, fixture);
    for (cases) |case| {
        const script_extract = try std.fmt.allocPrint(a, "require 'yaml'; steps = YAML.load_file(ARGV.fetch(0)).fetch('jobs').fetch('{s}').fetch('steps'); puts steps.find {{ |step| step['name'] == '{s}' }}.fetch('run')", .{ case.job, case.step });
        var extracted = try mustRun(a, io, cwd, &.{ "ruby", "-e", script_extract, ".github/workflows/release.yml" });
        defer extracted.deinit();
        var out = try sdk.run(a, io, &.{ "env", env_path, try std.fmt.allocPrint(a, "ZIG_ARGS_FILE={s}", .{args}), try std.fmt.allocPrint(a, "FAKE_APPLE_SDK={s}", .{fixture}), "bash", "-euo", "pipefail", "-c", extracted.result.stdout }, cwd);
        defer out.deinit();
        try testing.expect(out.succeeded());
        const recorded = try read(a, io, fixture, &.{"args.txt"});
        try contains(recorded, try std.fmt.allocPrint(a, "-Dtarget={s}", .{case.target}));
        if (case.apple) try contains(recorded, try std.fmt.allocPrint(a, "-Dapple-sysroot={s}", .{fixture})) else try notContains(recorded, "-Dapple-sysroot=");
        if (std.mem.indexOf(u8, case.step, "quickjs (") != null) try contains(recorded, "-Dbackend=quickjs") else try contains(recorded, "-Dbackend=quickjs_ng");
    }
}

test "test_android_sdk_distribution_uses_tracked_source_only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const release = try read(a, io, cwd, &.{ ".github", "workflows", "release.yml" });
    try contains(release, "git archive --format=tar HEAD -- sdk/android");
    try notContains(release, "cp -R sdk/android \"$stage/android-sdk\"");
    try contains(release, "android-sdk/(.*/)?(\\.gradle|build|local\\.properties)(/|$)");
}

test "test_android_sdk_archive_excludes_generated_and_local_files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const fixture = try temp(a, io, "jsbay-android-archive");
    defer Dir.cwd().deleteTree(io, fixture) catch {};
    const repo = try join(a, fixture, &.{"repo"});
    var setup = try mustRun(a, io, fixture, &.{ "mkdir", "-p", try join(a, repo, &.{ "sdk", "android", "jsbay", ".gradle", "cache" }), try join(a, repo, &.{ "sdk", "android", "jsbay", "build", "reports" }) });
    defer setup.deinit();
    try write(io, try join(a, repo, &.{ "sdk", "android", "settings.gradle.kts" }), "rootProject.name = \"fixture\"\n");
    try write(io, try join(a, repo, &.{ "sdk", "android", "jsbay", "build.gradle.kts" }), "plugins {}\n");
    try write(io, try join(a, repo, &.{ "sdk", "android", "jsbay", ".gradle", "cache", "state.bin" }), "generated\n");
    try write(io, try join(a, repo, &.{ "sdk", "android", "jsbay", "build", "reports", "lint.txt" }), "generated\n");
    try write(io, try join(a, repo, &.{ "sdk", "android", "local.properties" }), "sdk.dir=/example/sdk\n");
    for ([_][]const []const u8{ &.{ "git", "init", "-q" }, &.{ "git", "config", "user.name", "Release Test" }, &.{ "git", "config", "user.email", "release@example.invalid" }, &.{ "git", "add", "sdk/android/settings.gradle.kts", "sdk/android/jsbay/build.gradle.kts" }, &.{ "git", "commit", "-qm", "tracked Android SDK" } }) |argv| {
        var out = try mustRun(a, io, repo, argv);
        out.deinit();
    }
    var archive_out = try mustRun(a, io, repo, &.{ "bash", "-euc", "git archive --format=tar HEAD -- sdk/android > sdk.tar; mkdir stage; tar -xf sdk.tar -C stage; mv stage/sdk/android stage/android-sdk; rmdir stage/sdk; tar -C stage -czf android-sdk.tar.gz android-sdk" });
    defer archive_out.deinit();
    var members = try mustRun(a, io, repo, &.{ "tar", "-tzf", "android-sdk.tar.gz" });
    defer members.deinit();
    try contains(members.result.stdout, "android-sdk/settings.gradle.kts");
    try contains(members.result.stdout, "android-sdk/jsbay/build.gradle.kts");
    try notContains(members.result.stdout, ".gradle/");
    try notContains(members.result.stdout, "/build/");
    try notContains(members.result.stdout, "local.properties");
}

test "test_release_artifacts_include_project_and_engine_notices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const license = try read(a, io, cwd, &.{"LICENSE"});
    const notices = try read(a, io, cwd, &.{"THIRD_PARTY_NOTICES.md"});
    const release = try read(a, io, cwd, &.{ ".github", "workflows", "release.yml" });
    try contains(license, "MIT License");
    try contains(notices, "e2dc3ebbd874385fbcd48243acad5c8e98c4d451");
    try contains(notices, "6d46d07d04041b40f4f49eaa7fdebe44c314c699");
    for ([_][]const u8{ "cp LICENSE THIRD_PARTY_NOTICES.md \"$stage/\"", "META-INF/THIRD_PARTY_NOTICES.md", "tar -tzf \"$archive\" | grep -Fx \"$name/LICENSE\"", "unzip -Z1 \"$archive\" | grep -Fx \"$name/LICENSE\"" }) |needle| try contains(release, needle);
}

test "test_apple_archive_is_a_git_ready_swift_package" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const build = try read(a, io, cwd, &.{"build-apple.sh"});
    const release = try read(a, io, cwd, &.{ ".github", "workflows", "release.yml" });
    for ([_][]const u8{ "cp \"$SCRIPT_DIR/LICENSE\" \"$BUILD_DIR/SwiftPackage/\"", "cp \"$SCRIPT_DIR/THIRD_PARTY_NOTICES.md\" \"$BUILD_DIR/SwiftPackage/\"" }) |needle| try contains(build, needle);
    for ([_][]const u8{ "tool -- package-apple-release", "Test Apple Git package consumer", "tests/apple-sdk/git-package-consumer.sh", "\"$name/Package.swift", "\"$name/Sources/JsBaySDK/", "\"$name/Frameworks/JsBay.xcframework/", "\"$name/LICENSE", "\"$name/THIRD_PARTY_NOTICES.md" }) |needle| try contains(release, needle);
}

test "test_package_apple_release_archives_swift_package_and_preserves_output_on_missing_input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const fixture = try temp(a, io, "jsbay-swift-package");
    defer Dir.cwd().deleteTree(io, fixture) catch {};
    const name = "jsbay-0.1.0-apple-quickjs_ng";
    const source = try join(a, fixture, &.{ "build-apple", "SwiftPackage" });
    const framework = try join(a, source, &.{ "Frameworks", "JsBay.xcframework" });
    var setup = try mustRun(a, io, fixture, &.{ "mkdir", "-p", try join(a, source, &.{ "Sources", "JsBaySDK" }), try join(a, source, &.{ "Sources", "JsBayObjC" }), framework });
    defer setup.deinit();
    const license = "fixture license\n";
    const notices = "fixture notices\n";
    try write(io, try join(a, source, &.{"Package.swift"}), "// fixture\n");
    try write(io, try join(a, source, &.{ "Sources", "JsBaySDK", "JsBaySDK.swift" }), "public struct JsBaySDK {}\n");
    try write(io, try join(a, source, &.{ "Sources", "JsBayObjC", "JSBay.m" }), "void jsbay_fixture(void) {}\n");
    try write(io, try join(a, framework, &.{"Info.plist"}), "<plist/>\n");
    try write(io, try join(a, source, &.{"LICENSE"}), license);
    try write(io, try join(a, source, &.{"THIRD_PARTY_NOTICES.md"}), notices);
    const tool = try sdk.toolPath(a, io);
    const archive = try join(a, fixture, &.{"package.zip"});
    var packaged = try sdk.run(a, io, &.{ tool, "package-apple-release", "0.1.0", "quickjs_ng", "abc123", archive }, fixture);
    defer packaged.deinit();
    try testing.expect(packaged.succeeded());
    var members = try mustRun(a, io, fixture, &.{ "unzip", "-Z1", archive });
    defer members.deinit();
    for ([_][]const u8{ "Package.swift", "Sources/JsBaySDK/JsBaySDK.swift", "Sources/JsBayObjC/JSBay.m", "Frameworks/JsBay.xcframework/Info.plist", "LICENSE", "THIRD_PARTY_NOTICES.md", "VERSION", "COMMIT", "backend" }) |path| try contains(members.result.stdout, try std.fmt.allocPrint(a, "{s}/{s}", .{ name, path }));
    for ([_]struct { path: []const u8, contents: []const u8 }{ .{ .path = "LICENSE", .contents = license }, .{ .path = "THIRD_PARTY_NOTICES.md", .contents = notices }, .{ .path = "VERSION", .contents = "0.1.0\n" }, .{ .path = "COMMIT", .contents = "abc123\n" }, .{ .path = "backend", .contents = "quickjs_ng\n" } }) |expected| {
        var member = try mustRun(a, io, fixture, &.{ "unzip", "-p", archive, try std.fmt.allocPrint(a, "{s}/{s}", .{ name, expected.path }) });
        defer member.deinit();
        try testing.expectEqualStrings(expected.contents, member.result.stdout);
    }
    try write(io, archive, "existing output");
    try Dir.cwd().deleteFile(io, try join(a, source, &.{"LICENSE"}));
    var rejected = try sdk.run(a, io, &.{ tool, "package-apple-release", "0.1.0", "quickjs_ng", "abc123", archive }, fixture);
    defer rejected.deinit();
    try testing.expect(!rejected.succeeded());
    try testing.expectEqualStrings("existing output", try read(a, io, fixture, &.{"package.zip"}));
}

test "test_release_exports_a_history_free_source_snapshot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const release = try read(a, io, cwd, &.{ ".github", "workflows", "release.yml" });
    for ([_][]const u8{ "Checkout reviewed source snapshot", "zig build tool -- export-public-source", "zig build tool -- release-version", "cp \"${{ steps.source.outputs.archive }}\" release-assets/", "contains no Git metadata or repository history", "for f in jsbay-*.tar.gz jsbay-*.zip jsbay-*.aar" }) |needle| try contains(release, needle);
    try testing.expect((std.mem.indexOf(u8, release, "cp \"${{ steps.source.outputs.archive }}\" release-assets/") orelse return error.MissingSourceCopy) < (std.mem.indexOf(u8, release, ": > SHA256SUMS") orelse return error.MissingChecksums));
}

test "test_release_asset_inventory_rejects_missing_and_extra_archives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const directory = try temp(a, io, "jsbay-assets-missing");
    defer Dir.cwd().deleteTree(io, directory) catch {};
    const tool = try sdk.toolPath(a, io);
    const names = [_][]const u8{ "linux-x86_64-quickjs_ng.tar.gz", "linux-x86_64-quickjs.tar.gz", "linux-aarch64-quickjs_ng.tar.gz", "linux-aarch64-quickjs.tar.gz", "macos-aarch64-quickjs_ng.tar.gz", "macos-aarch64-quickjs.tar.gz", "macos-aarch64-jsc.tar.gz", "macos-x86_64-quickjs_ng.tar.gz", "macos-x86_64-quickjs.tar.gz", "macos-x86_64-jsc.tar.gz", "source.tar.gz" };
    for (names) |name| try write(io, try std.fmt.allocPrint(a, "{s}/jsbay-0.1.0-{s}", .{ directory, name }), "");
    var complete = try sdk.run(a, io, &.{ tool, "check-release-assets", directory, "0.1.0", "false", "false" }, cwd);
    defer complete.deinit();
    try testing.expect(complete.succeeded());
    try Dir.cwd().deleteFile(io, try std.fmt.allocPrint(a, "{s}/jsbay-0.1.0-source.tar.gz", .{directory}));
    var missing = try sdk.run(a, io, &.{ tool, "check-release-assets", directory, "0.1.0", "false", "false" }, cwd);
    defer missing.deinit();
    try testing.expect(!missing.succeeded());
    try contains(try std.mem.concat(a, u8, &.{ missing.result.stdout, missing.result.stderr }), "source.tar.gz");
    try write(io, try std.fmt.allocPrint(a, "{s}/jsbay-0.1.0-source.tar.gz", .{directory}), "");
    try write(io, try std.fmt.allocPrint(a, "{s}/jsbay-0.1.0-extra.tar.gz", .{directory}), "");
    var extra = try sdk.run(a, io, &.{ tool, "check-release-assets", directory, "0.1.0", "false", "false" }, cwd);
    defer extra.deinit();
    try testing.expect(!extra.succeeded());
    try contains(try std.mem.concat(a, u8, &.{ extra.result.stdout, extra.result.stderr }), "extra");
}
test "test_release_asset_inventory_accepts_full_tag_set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const directory = try temp(a, io, "jsbay-assets-full");
    defer Dir.cwd().deleteTree(io, directory) catch {};
    const tool = try sdk.toolPath(a, io);
    const names = [_][]const u8{ "linux-x86_64-quickjs_ng.tar.gz", "linux-x86_64-quickjs.tar.gz", "linux-aarch64-quickjs_ng.tar.gz", "linux-aarch64-quickjs.tar.gz", "macos-aarch64-quickjs_ng.tar.gz", "macos-aarch64-quickjs.tar.gz", "macos-aarch64-jsc.tar.gz", "macos-x86_64-quickjs_ng.tar.gz", "macos-x86_64-quickjs.tar.gz", "macos-x86_64-jsc.tar.gz", "apple-quickjs_ng-JsBay.xcframework.zip", "apple-quickjs-JsBay.xcframework.zip", "apple-jsc-JsBay.xcframework.zip", "android-quickjs_ng.aar", "android-quickjs_ng-maven.zip", "android-jniLibs-quickjs_ng.tar.gz", "android-quickjs.aar", "android-quickjs-maven.zip", "android-jniLibs-quickjs.tar.gz", "source.tar.gz" };
    for (names) |name| try write(io, try std.fmt.allocPrint(a, "{s}/jsbay-0.1.0-{s}", .{ directory, name }), "");
    var out = try sdk.run(a, io, &.{ tool, "check-release-assets", directory, "0.1.0", "true", "true" }, cwd);
    defer out.deinit();
    try testing.expect(out.succeeded());
}

test "test_release_l1_matrix_pins_all_targets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const release = try read(a, io, cwd, &.{ ".github", "workflows", "release.yml" });
    for ([_][]const u8{ "x86_64-linux-gnu", "aarch64-linux-gnu", "aarch64-macos.11.0", "x86_64-macos.11.0" }) |target| try contains(release, try std.fmt.allocPrint(a, "-Dtarget={s}", .{target}));
    for ([_][]const u8{ "Build library quickjs (macos-aarch64)", "Build library quickjs (macos-x86_64)", "./build-apple.sh quickjs", "backend: [quickjs_ng, quickjs]" }) |needle| try contains(release, needle);
}

test "test_dispatch_cannot_create_a_release_or_receive_write_permission" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const release = try read(a, io, cwd, &.{ ".github", "workflows", "release.yml" });
    const publish = release[std.mem.indexOf(u8, release, "  publish:\n") orelse return error.MissingPublish ..];
    for ([_][]const u8{ "permissions:\n  contents: read", "github.event_name == 'push'", "startsWith(github.ref, 'refs/tags/v')", "permissions:\n      contents: write", "if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}" }) |needle| try contains(if (std.mem.eql(u8, needle, "permissions:\n  contents: read")) release else publish, needle);
}

test "test_harmony_device_acceptance_uses_sdk12_target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const workflow = try read(a, io, cwd, &.{ ".github", "workflows", "device-tests.yml" });
    try contains(workflow, "runs-on: [self-hosted, jsbay-harmony-sdk12]");
    try contains(workflow, "HARMONY_TARGET_SDK_VERSION: '5.0.0(12)'");
}

test "test_local_harmony_staging_accepts_tar_and_zip_and_rejects_fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = try root(a, io);
    const fixture = try temp(a, io, "jsbay-harmony-stage");
    defer Dir.cwd().deleteTree(io, fixture) catch {};
    const repo = try join(a, fixture, &.{"repo"});
    var setup = try mustRun(a, io, fixture, &.{ "mkdir", "-p", try join(a, repo, &.{"scripts"}), try join(a, repo, &.{ "tests", "harmony-sdk", "fixture" }), try join(a, repo, &.{ "sdk", "harmony", "src", "main", "ets" }), try join(a, repo, &.{ "sdk", "harmony", "examples" }), try join(a, repo, &.{ "sdk", "harmony", ".cxx" }), try join(a, repo, &.{ "sdk", "harmony", "oh_modules" }), try join(a, repo, &.{ "packages", "@ohos", "hvigor" }), try join(a, repo, &.{ "packages", "@ohos", "hvigor-ohos-plugin" }) });
    defer setup.deinit();
    for ([_][]const []const u8{ &.{ try join(a, cwd, &.{ "scripts", "stage-harmony-har.sh" }), try join(a, repo, &.{ "scripts", "stage-harmony-har.sh" }) }, &.{ try join(a, cwd, &.{ "tests", "harmony-sdk", "build_har.sh" }), try join(a, repo, &.{ "tests", "harmony-sdk", "build_har.sh" }) } }) |copy| {
        var out = try mustRun(a, io, fixture, &.{ "cp", copy[0], copy[1] });
        defer out.deinit();
    }
    try write(io, try join(a, repo, &.{ "tests", "harmony-sdk", "conformance.ets" }), "export {}\n");
    try write(io, try join(a, repo, &.{ "tests", "harmony-sdk", "recursive_callback.ets" }), "export {}\n");
    try write(io, try join(a, repo, &.{ "tests", "harmony-sdk", "CrashIsolation.ets" }), "export {}\n");
    try write(io, try join(a, repo, &.{ "tests", "harmony-sdk", "CrashIsolationWorker.ets" }), "export {}\n");
    try write(io, try join(a, repo, &.{ "sdk", "harmony", "examples", "Worker.ets" }), "export {}\n");
    try write(io, try join(a, repo, &.{ "sdk", "harmony", ".cxx", "stale" }), "stale archive cache\n");
    try write(io, try join(a, repo, &.{ "sdk", "harmony", "oh_modules", "stale" }), "stale dependency cache\n");
    try write(io, try join(a, repo, &.{ "packages", "@ohos", "hvigor", "package.json" }), "{}\n");
    try write(io, try join(a, repo, &.{ "packages", "@ohos", "hvigor-ohos-plugin", "package.json" }), "{}\n");
    try write(io, try join(a, repo, &.{ "tests", "harmony-sdk", "fixture", "build-profile.json5" }), "{ \"app\": { \"products\": [] }, \"modules\": [{ \"srcPath\": \"../../../sdk/harmony\" }] }\n");
    const original_builder = try read(a, io, cwd, &.{ "tests", "harmony-sdk", "build_har.sh" });
    const core = try join(a, repo, &.{"libjsbay.a"});
    const object = try join(a, repo, &.{"core.o"});
    try write(io, object, "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\xb7\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    var ar = try mustRun(a, io, repo, &.{ "zig", "ar", "rcs", core, object });
    defer ar.deinit();
    try executable(a, io, repo, try join(a, repo, &.{"tool"}), "#!/bin/sh\nset -eu\nroot=$(cd \"$(dirname \"$0\")\" && pwd)\ncase \"$*\" in\n  *assembleHar*)\n    for package in hvigor hvigor-ohos-plugin; do\n      test -L \"$root/sdk/harmony/node_modules/@ohos/$package\"\n      test -L \"$root/tests/harmony-sdk/fixture/node_modules/@ohos/$package\"\n    done\n    work=$(mktemp -d); trap 'rm -rf \"$work\"' EXIT\n    mkdir -p \"$work/package/libs/arm64-v8a\" \"$work/package/ets\" \"$work/package/src/main/ets\"\n    : > \"$work/package/libs/arm64-v8a/libjsbay_harmony.so\"; : > \"$work/package/ets/modules.abc\"; : > \"$work/package/src/main/ets/JsBay.d.ets\"; : > \"$work/package/src/main/ets/index.d.ets\"\n    [ \"${HAR_FIXTURE:-}\" = 1 ] && : > \"$work/package/src/main/ets/ConformanceFixture.ets\"\n    har=\"$root/sdk/harmony/build/default/outputs/default/jsbay_harmony.har\"; mkdir -p \"$(dirname \"$har\")\"; rm -f \"$har\"\n    if [ \"${HAR_FORMAT:-tar}\" = zip ]; then (cd \"$work\" && zip -qr \"$har\" package); else tar -czf \"$har\" -C \"$work\" package; fi\n    ;;\n  *clean*) rm -f \"$root/sdk/harmony/build/default/outputs/default/jsbay_harmony.har\" ;;\nesac\n");
    try executable(a, io, repo, try join(a, repo, &.{"node"}), "#!/bin/sh\ncase \"$*\" in\n  *hvigor-ohos-plugin*) printf '%s\\n' \"$FAKE_PACKAGE_ROOT/@ohos/hvigor-ohos-plugin/package.json\" ;;\n  *) printf '%s\\n' \"$FAKE_PACKAGE_ROOT/@ohos/hvigor/package.json\" ;;\nesac\n");
    try executable(a, io, repo, try join(a, repo, &.{"link-check"}), "#!/bin/sh\nset -eu\nroot=$(cd \"$(dirname \"$0\")\" && pwd)\nfor package in hvigor hvigor-ohos-plugin; do\n  test -L \"$root/sdk/harmony/node_modules/@ohos/$package\"\n  test -L \"$root/tests/harmony-sdk/fixture/node_modules/@ohos/$package\"\ndone\n");
    try executable(a, io, repo, try join(a, repo, &.{"zig-ar"}), "#!/bin/sh\nexec zig ar \"$@\"\n");
    const script = try join(a, repo, &.{ "scripts", "stage-harmony-har.sh" });
    const env = [_][]const u8{ "env", try std.fmt.allocPrint(a, "DEVECO_SDK_HOME={s}", .{repo}), try std.fmt.allocPrint(a, "HVIGORW={s}/tool", .{repo}), try std.fmt.allocPrint(a, "OHPM={s}/link-check", .{repo}), try std.fmt.allocPrint(a, "NODE_BIN={s}/node", .{repo}), try std.fmt.allocPrint(a, "NODE_PATH={s}/packages", .{repo}), try std.fmt.allocPrint(a, "FAKE_PACKAGE_ROOT={s}/packages", .{repo}), try std.fmt.allocPrint(a, "JSBAY_LIBRARY={s}", .{core}), try std.fmt.allocPrint(a, "AR={s}/zig-ar", .{repo}), "JSBAY_BACKEND=quickjs_ng", script };
    var tar = try sdk.run(a, io, &.{ env[0], env[1], env[2], env[3], env[4], env[5], env[6], env[7], env[8], env[9], env[10], try join(a, repo, &.{"tar-stage"}), "1.2.3" }, repo);
    defer tar.deinit();
    try testing.expect(tar.succeeded());
    Dir.cwd().access(io, try join(a, repo, &.{ "tar-stage", "jsbay-1.2.3-harmony-quickjs_ng-arm64-v8a.har" }), .{}) catch return error.MissingTarAsset;
    Dir.cwd().access(io, try join(a, repo, &.{ "tar-stage", "SHA256SUMS" }), .{}) catch return error.MissingSums;
    try testing.expectError(error.FileNotFound, Dir.cwd().access(io, try join(a, repo, &.{ "sdk", "harmony", ".cxx", "stale" }), .{}));
    try testing.expectError(error.FileNotFound, Dir.cwd().access(io, try join(a, repo, &.{ "sdk", "harmony", "oh_modules", "stale" }), .{}));
    try testing.expectError(error.FileNotFound, Dir.cwd().access(io, try join(a, repo, &.{ "sdk", "harmony", "node_modules" }), .{}));
    try testing.expectError(error.FileNotFound, Dir.cwd().access(io, try join(a, repo, &.{ "tests", "harmony-sdk", "fixture", "node_modules" }), .{}));
    var zip = try sdk.run(a, io, &.{ env[0], env[1], env[2], env[3], env[4], env[5], env[6], env[7], "HAR_FORMAT=zip", env[8], env[9], env[10], try join(a, repo, &.{"zip-stage"}), "1.2.3" }, repo);
    defer zip.deinit();
    try testing.expect(zip.succeeded());
    var bad = try sdk.run(a, io, &.{ env[0], env[1], env[2], env[3], env[4], env[5], env[6], env[7], "HAR_FIXTURE=1", env[8], env[9], env[10], try join(a, repo, &.{"fixture-stage"}), "1.2.3" }, repo);
    defer bad.deinit();
    try testing.expect(!bad.succeeded());
    try contains(bad.result.stderr, "ConformanceFixture");
    for ([_][]const u8{ "sdk/harmony", "tests/harmony-sdk/fixture" }) |project| {
        const scope = try join(a, repo, &.{ project, "node_modules", "@ohos" });
        var mkdir = try mustRun(a, io, repo, &.{ "mkdir", "-p", scope });
        defer mkdir.deinit();
        for ([_][]const u8{ "hvigor", "hvigor-ohos-plugin" }) |package| {
            var link = try mustRun(a, io, repo, &.{ "ln", "-s", try join(a, repo, &.{ "packages", "@ohos", package }), try join(a, scope, &.{package}) });
            defer link.deinit();
        }
    }
    var existing = try sdk.run(a, io, &.{ env[0], env[1], env[2], env[3], env[4], env[5], env[6], env[7], env[8], env[9], env[10], try join(a, repo, &.{"existing-stage"}), "1.2.3" }, repo);
    defer existing.deinit();
    try testing.expect(existing.succeeded());
    for ([_][]const u8{ "sdk/harmony", "tests/harmony-sdk/fixture" }) |project| {
        for ([_][]const u8{ "hvigor", "hvigor-ohos-plugin" }) |package| {
            try Dir.cwd().access(io, try join(a, repo, &.{ project, "node_modules", "@ohos", package, "package.json" }), .{});
        }
    }
    try testing.expectEqualStrings(original_builder, try read(a, io, cwd, &.{ "tests", "harmony-sdk", "build_har.sh" }));
}
