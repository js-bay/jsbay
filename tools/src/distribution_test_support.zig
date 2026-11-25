//! Shared helpers for black-box distribution tests.
const std = @import("std");
const sdk = @import("sdk.zig");

const testing = std.testing;
const Dir = std.Io.Dir;

pub fn root(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return std.process.currentPathAlloc(io, allocator);
}

pub fn temp(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) ![]u8 {
    var random: [12]u8 = undefined;
    io.random(&random);
    const directory = try std.fmt.allocPrint(allocator, "/tmp/{s}-{s}", .{ prefix, std.fmt.bytesToHex(random, .lower) });
    try Dir.cwd().createDir(io, directory, .default_dir);
    return directory;
}

pub fn join(allocator: std.mem.Allocator, base: []const u8, parts: []const []const u8) ![]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(allocator);
    try all.append(allocator, base);
    try all.appendSlice(allocator, parts);
    return std.fs.path.join(allocator, all.items);
}

pub fn write(io: std.Io, name: []const u8, contents: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = name, .data = contents });
}

pub fn read(allocator: std.mem.Allocator, io: std.Io, base: []const u8, parts: []const []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(io, try join(allocator, base, parts), allocator, .limited(16 * 1024 * 1024));
}

pub fn contains(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

pub fn notContains(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

pub fn mustRun(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8) !sdk.Output {
    var output = try sdk.run(allocator, io, argv, cwd);
    if (!output.succeeded()) {
        std.debug.print("command failed:", .{});
        for (argv) |arg| std.debug.print(" {s}", .{arg});
        std.debug.print("\n{s}{s}", .{ output.result.stdout, output.result.stderr });
        output.deinit();
        return error.CommandFailed;
    }
    return output;
}

pub fn expectSucceeded(output: sdk.Output, label: []const u8) !void {
    if (output.succeeded()) return;
    std.debug.print("{s} failed:\n{s}{s}\n", .{ label, output.result.stdout, output.result.stderr });
    return error.TestUnexpectedResult;
}

pub fn executable(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, name: []const u8, contents: []const u8) !void {
    try write(io, name, contents);
    var output = try mustRun(allocator, io, cwd, &.{ "chmod", "+x", name });
    output.deinit();
}

pub fn pathEnv(allocator: std.mem.Allocator, tools: []const u8) ![]u8 {
    // Keep this libc-free: `zig build test-tools` does not link libc on CI.
    //
    // tools/ must stay first so fixture stubs win over host binaries.
    return std.fmt.allocPrint(allocator, "PATH={s}:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin", .{tools});
}

pub fn androidFixture(allocator: std.mem.Allocator, io: std.Io, fixture: []const u8) ![]u8 {
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
