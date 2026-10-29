//! Black-box contracts for repository commands. These tests invoke the installed `jsbay-tool`; unit tests alone do not establish CLI behavior.
const std = @import("std");
const sdk = @import("sdk.zig");

const testing = std.testing;
const Dir = std.Io.Dir;

fn makeTemp(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) ![]u8 {
    var random: [12]u8 = undefined;
    io.random(&random);
    const path = try std.fmt.allocPrint(allocator, "/tmp/{s}-{s}", .{ prefix, std.fmt.bytesToHex(random, .lower) });
    try Dir.cwd().createDir(io, path, .default_dir);
    return path;
}

fn toolPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return sdk.toolPath(allocator, io);
}

fn runTool(allocator: std.mem.Allocator, io: std.Io, tool: []const u8, cwd: []const u8, args: []const []const u8) !sdk.Output {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, tool);
    try argv.appendSlice(allocator, args);
    return sdk.run(allocator, io, argv.items, cwd);
}

fn runGit(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);
    var output = try sdk.run(allocator, io, argv.items, cwd);
    defer output.deinit();
    if (!output.succeeded()) {
        std.debug.print("git failed: {s}\n{s}", .{ output.result.stdout, output.result.stderr });
        return error.GitFailed;
    }
}

fn runExternal(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) !sdk.Output {
    return sdk.run(allocator, io, args, cwd);
}

fn writeFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
}

fn contains(output: sdk.Output, needle: []const u8) bool {
    return std.mem.indexOf(u8, output.result.stdout, needle) != null or std.mem.indexOf(u8, output.result.stderr, needle) != null;
}

fn privateMarker() []const u8 {
    return "No" ++ "ok";
}

fn installPrivacyDenylist(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) !void {
    const denylist = try std.fs.path.join(allocator, &.{ repo, ".git", "info", "privacy-denylist" });
    defer allocator.free(denylist);
    // Markers stay out of tools/src/repository.zig; contract fixtures load them via denylist.
    try writeFile(io, denylist, try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n", .{
        privateMarker(),
        "z" ++ "je_public",
        "z" ++ "jse_public",
    }));
}

test "release-version CLI accepts matching labels and rejects unsafe labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const fixture = try makeTemp(allocator, io, "jsbay-release-contract");
    defer {
        Dir.cwd().deleteTree(io, fixture) catch {};
        allocator.free(fixture);
    }
    try writeFile(io, try std.fs.path.join(allocator, &.{ fixture, "build.zig.zon" }), ".{ .name = .fixture, .version = \"0.1.0\" }\n");
    const tool = try toolPath(allocator, io);
    defer allocator.free(tool);

    const cases = [_]struct { args: []const []const u8, expected: []const u8 }{
        .{ .args = &.{ "release-version", "", "refs/tags/v0.1.0", "12345" }, .expected = "0.1.0\n" },
        .{ .args = &.{ "release-version", "0.1.0", "refs/heads/main", "12345" }, .expected = "0.1.0\n" },
        .{ .args = &.{ "release-version", "", "refs/heads/main", "12345" }, .expected = "12345\n" },
    };
    for (cases) |case| {
        var output = try runTool(allocator, io, tool, fixture, case.args);
        defer output.deinit();
        try testing.expect(output.succeeded());
        try testing.expectEqualStrings(case.expected, output.result.stdout);
    }
    for ([_][]const []const u8{
        &.{ "release-version", "9.9.9", "refs/heads/main", "12345" },
        &.{ "release-version", "", "refs/tags/v9.9.9", "12345" },
        &.{ "release-version", "", "refs/heads/main", "../unsafe" },
    }) |args| {
        var output = try runTool(allocator, io, tool, fixture, args);
        defer output.deinit();
        try testing.expect(!output.succeeded());
    }
}

test "privacy CLI rejects untracked, staged, and committed private input without echoing it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const fixture = try makeTemp(allocator, io, "jsbay-privacy-contract");
    defer {
        Dir.cwd().deleteTree(io, fixture) catch {};
        allocator.free(fixture);
    }
    const tool = try toolPath(allocator, io);
    defer allocator.free(tool);
    try runGit(allocator, io, fixture, &.{ "init", "-q" });
    try installPrivacyDenylist(allocator, io, fixture);
    try writeFile(io, try std.fs.path.join(allocator, &.{ fixture, "safe.txt" }), "public source\n");
    try runGit(allocator, io, fixture, &.{ "add", "safe.txt" });
    {
        var output = try runTool(allocator, io, tool, fixture, &.{"privacy"});
        defer output.deinit();
        try testing.expect(output.succeeded());
    }

    const candidate = try std.fs.path.join(allocator, &.{ fixture, "candidate.txt" });
    defer allocator.free(candidate);
    const marker = privateMarker();
    try writeFile(io, candidate, try std.fmt.allocPrint(allocator, "{s}\n", .{marker}));
    {
        var output = try runTool(allocator, io, tool, fixture, &.{"privacy"});
        defer output.deinit();
        try testing.expect(!output.succeeded());
        try testing.expect(contains(output, "candidate.txt"));
        try testing.expect(!contains(output, marker));
    }
    try runGit(allocator, io, fixture, &.{ "add", "candidate.txt" });
    {
        var output = try runTool(allocator, io, tool, fixture, &.{"privacy"});
        defer output.deinit();
        try testing.expect(!output.succeeded());
    }
    try Dir.cwd().deleteFile(io, candidate);
    {
        var output = try runTool(allocator, io, tool, fixture, &.{"privacy"});
        defer output.deinit();
        try testing.expect(output.succeeded());
    }
    try runGit(allocator, io, fixture, &.{ "rm", "-q", "--cached", "candidate.txt" });
    for ([_][]const u8{ "z" ++ "je_public", "z" ++ "jse_public" }) |legacy| {
        try writeFile(io, candidate, try std.fmt.allocPrint(allocator, "{s}\n", .{legacy}));
        var output = try runTool(allocator, io, tool, fixture, &.{"privacy"});
        defer output.deinit();
        try testing.expect(!output.succeeded());
        try testing.expect(contains(output, "candidate.txt"));
        try testing.expect(!contains(output, legacy));
        try Dir.cwd().deleteFile(io, candidate);
    }

    try runGit(allocator, io, fixture, &.{ "config", "user.name", "Privacy Test" });
    try runGit(allocator, io, fixture, &.{ "config", "user.email", "privacy-test@example.invalid" });
    try runGit(allocator, io, fixture, &.{ "commit", "-qm", "public fixture" });
    {
        var output = try runTool(allocator, io, tool, fixture, &.{ "privacy", "--commits", "HEAD" });
        defer output.deinit();
        try testing.expect(output.succeeded());
    }
    try runGit(allocator, io, fixture, &.{ "commit", "--allow-empty", "-qm", marker });
    {
        var output = try runTool(allocator, io, tool, fixture, &.{ "privacy", "--commits", "HEAD" });
        defer output.deinit();
        try testing.expect(!output.succeeded());
        try testing.expect(!contains(output, marker));
    }
}

fn initSourceRepo(allocator: std.mem.Allocator, io: std.Io, path: []const u8, file_name: []const u8, contents: []const u8, include_modules: bool) !void {
    try Dir.cwd().createDirPath(io, path);
    try runGit(allocator, io, path, &.{ "init", "-q" });
    try runGit(allocator, io, path, &.{ "config", "user.name", "Source Export Test" });
    try runGit(allocator, io, path, &.{ "config", "user.email", "source-export@example.invalid" });
    try writeFile(io, try std.fs.path.join(allocator, &.{ path, file_name }), contents);
    if (include_modules) try writeFile(io, try std.fs.path.join(allocator, &.{ path, ".gitmodules" }), "[submodule \"test262\"]\n\tpath = test262\n\turl = https://example.invalid/test262.git\n");
    try runGit(allocator, io, path, if (include_modules) &.{ "add", file_name, ".gitmodules" } else &.{ "add", file_name });
    try runGit(allocator, io, path, &.{ "commit", "-qm", "fixture source" });
}

fn expectArchiveHas(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, archive: []const u8, expected: []const []const u8) !void {
    var output = try runExternal(allocator, io, cwd, &.{ "tar", "-tzf", archive });
    defer output.deinit();
    try testing.expect(output.succeeded());
    for (expected) |path| try testing.expect(std.mem.indexOf(u8, output.result.stdout, path) != null);
    try testing.expect(std.mem.indexOf(u8, output.result.stdout, ".git/") == null);
    try testing.expect(std.mem.indexOf(u8, output.result.stdout, ".gitmodules") == null);
    try testing.expect(std.mem.indexOf(u8, output.result.stdout, "private.txt") == null);
}

test "export-public-source CLI excludes history and rejects a dirty tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const fixture = try makeTemp(allocator, io, "jsbay-source-contract");
    defer {
        Dir.cwd().deleteTree(io, fixture) catch {};
        allocator.free(fixture);
    }
    const repo = try std.fs.path.join(allocator, &.{ fixture, "repo" });
    defer allocator.free(repo);
    const classic = try std.fs.path.join(allocator, &.{ fixture, "upstreams", "quickjs" });
    defer allocator.free(classic);
    const ng = try std.fs.path.join(allocator, &.{ fixture, "upstreams", "quickjs-ng" });
    defer allocator.free(ng);
    try initSourceRepo(allocator, io, classic, "quickjs.c", "classic quickjs fixture\n", false);
    try initSourceRepo(allocator, io, ng, "quickjs.h", "quickjs-ng fixture\n", true);

    try Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ repo, "scripts" }));
    try runGit(allocator, io, repo, &.{ "init", "-q" });
    try runGit(allocator, io, repo, &.{ "config", "user.name", "Source Export Test" });
    try runGit(allocator, io, repo, &.{ "config", "user.email", "source-export@example.invalid" });
    try writeFile(io, try std.fs.path.join(allocator, &.{ repo, "LICENSE" }), "MIT test fixture\n");
    try writeFile(io, try std.fs.path.join(allocator, &.{ repo, "THIRD_PARTY_NOTICES.md" }), "Third-party fixture\n");
    try writeFile(io, try std.fs.path.join(allocator, &.{ repo, "build.zig.zon" }), ".{ .name = .fixture, .version = \"0.1.0\" }\n");
    try runGit(allocator, io, repo, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", classic, "vendor/quickjs" });
    try runGit(allocator, io, repo, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", ng, "vendor/quickjs-ng" });
    const marker = privateMarker();
    try writeFile(io, try std.fs.path.join(allocator, &.{ repo, "private.txt" }), try std.fmt.allocPrint(allocator, "{s}\n", .{marker}));
    try runGit(allocator, io, repo, &.{ "add", "." });
    try runGit(allocator, io, repo, &.{ "commit", "-qm", "private predecessor" });
    try Dir.cwd().deleteFile(io, try std.fs.path.join(allocator, &.{ repo, "private.txt" }));
    try runGit(allocator, io, repo, &.{ "add", "-u" });
    try runGit(allocator, io, repo, &.{ "commit", "-qm", "reviewed public tree" });

    const tool = try toolPath(allocator, io);
    defer allocator.free(tool);
    const archive = try std.fs.path.join(allocator, &.{ fixture, "public.tar.gz" });
    defer allocator.free(archive);
    {
        var output = try runTool(allocator, io, tool, repo, &.{ "export-public-source", archive });
        defer output.deinit();
        try testing.expect(output.succeeded());
    }
    try expectArchiveHas(allocator, io, repo, archive, &.{ "js-bay-source/LICENSE", "js-bay-source/THIRD_PARTY_NOTICES.md", "js-bay-source/vendor/quickjs/quickjs.c", "js-bay-source/vendor/quickjs-ng/quickjs.h" });

    const public_repo = try std.fs.path.join(allocator, &.{ fixture, "public-repo" });
    defer allocator.free(public_repo);
    try Dir.cwd().createDirPath(io, public_repo);
    {
        var output = try runExternal(allocator, io, fixture, &.{ "tar", "-xzf", archive, "-C", public_repo, "--strip-components=1" });
        defer output.deinit();
        try testing.expect(output.succeeded());
    }
    try runGit(allocator, io, public_repo, &.{ "init", "-q" });
    try installPrivacyDenylist(allocator, io, public_repo);
    try runGit(allocator, io, public_repo, &.{ "config", "user.name", "Source Export Test" });
    try runGit(allocator, io, public_repo, &.{ "config", "user.email", "source-export@example.invalid" });
    try runGit(allocator, io, public_repo, &.{ "add", "." });
    try runGit(allocator, io, public_repo, &.{ "commit", "-qm", "initial public source" });
    const second_archive = try std.fs.path.join(allocator, &.{ fixture, "public-again.tar.gz" });
    defer allocator.free(second_archive);
    {
        var output = try runTool(allocator, io, tool, public_repo, &.{ "export-public-source", second_archive });
        defer output.deinit();
        try testing.expect(output.succeeded());
    }
    try expectArchiveHas(allocator, io, public_repo, second_archive, &.{ "js-bay-source/vendor/quickjs/quickjs.c", "js-bay-source/vendor/quickjs-ng/quickjs.h" });

    const vendor_marker = try std.fs.path.join(allocator, &.{ public_repo, "vendor", "quickjs", "private.txt" });
    defer allocator.free(vendor_marker);
    try writeFile(io, vendor_marker, try std.fmt.allocPrint(allocator, "{s}\n", .{marker}));
    {
        var output = try runTool(allocator, io, tool, public_repo, &.{"privacy"});
        defer output.deinit();
        try testing.expect(!output.succeeded());
    }
    try Dir.cwd().deleteFile(io, vendor_marker);
    try writeFile(io, try std.fs.path.join(allocator, &.{ repo, "untracked.txt" }), "unreviewed file\n");
    const dirty_archive = try std.fs.path.join(allocator, &.{ fixture, "dirty.tar.gz" });
    defer allocator.free(dirty_archive);
    {
        var output = try runTool(allocator, io, tool, repo, &.{ "export-public-source", dirty_archive });
        defer output.deinit();
        try testing.expect(!output.succeeded());
    }
    try testing.expectError(error.FileNotFound, Dir.cwd().access(io, dirty_archive, .{}));
}
