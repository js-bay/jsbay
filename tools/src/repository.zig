const std = @import("std");
const Dir = std.Io.Dir;

pub fn handles(command: []const u8) bool {
    inline for (.{ "privacy", "release-version", "check-release-assets", "package-apple-release", "export-public-source", "patch-quickjs", "patch-quickjs-ng", "check-docs", "check-tooling", "simulator-list", "harmony-facade", "check-maven" }) |name| {
        if (std.mem.eql(u8, command, name)) return true;
    }
    return false;
}

const Context = struct {
    init: std.process.Init,
    fn allocator(c: Context) std.mem.Allocator {
        return c.init.arena.allocator();
    }
    fn fmt(c: Context, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(c.allocator(), format, args);
    }
    fn read(c: Context, path: []const u8) ![]const u8 {
        return Dir.cwd().readFileAlloc(c.init.io, path, c.allocator(), .unlimited);
    }
    fn write(c: Context, path: []const u8, data: []const u8) !void {
        try Dir.cwd().writeFile(c.init.io, .{ .sub_path = path, .data = data });
    }
    fn output(c: Context, data: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(c.init.io, data);
    }
    fn capture(c: Context, argv: []const []const u8, cwd: ?[]const u8) !std.process.RunResult {
        return std.process.run(c.allocator(), c.init.io, .{ .argv = argv, .cwd = if (cwd) |path| .{ .path = path } else .inherit });
    }
    fn command(c: Context, argv: []const []const u8, cwd: ?[]const u8) ![]const u8 {
        const result = try c.capture(argv, cwd);
        if (!successful(result)) {
            try std.Io.File.stderr().writeStreamingAll(c.init.io, result.stderr);
            return error.ChildFailed;
        }
        return result.stdout;
    }
    fn temp(c: Context, parent: []const u8) ![]const u8 {
        var bytes: [16]u8 = undefined;
        c.init.io.random(&bytes);
        const path = try c.fmt("{s}/.jsbay-tool-{s}", .{ parent, std.fmt.bytesToHex(bytes, .lower) });
        try Dir.cwd().createDir(c.init.io, path, .default_dir);
        return path;
    }
    fn exists(c: Context, path: []const u8) !bool {
        Dir.cwd().access(c.init.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
};

fn successful(result: std.process.RunResult) bool {
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const c: Context = .{ .init = init };
    if (args.len == 0) return error.Usage;
    const command = args[0];
    const tail = args[1..];
    if (std.mem.eql(u8, command, "release-version")) return releaseVersion(c, tail);
    if (std.mem.eql(u8, command, "privacy")) return privacy(c, tail);
    if (std.mem.eql(u8, command, "check-release-assets")) return releaseAssets(c, tail);
    if (std.mem.eql(u8, command, "check-docs")) return checkDocs(c, tail);
    if (std.mem.eql(u8, command, "check-tooling")) return checkTooling(c, tail);
    if (std.mem.eql(u8, command, "simulator-list")) return simulatorList(c, tail);
    if (std.mem.eql(u8, command, "harmony-facade")) return harmonyFacade(c, tail);
    if (std.mem.eql(u8, command, "check-maven")) return checkMaven(c, tail);
    if (std.mem.eql(u8, command, "package-apple-release")) return packageApple(c, tail);
    if (std.mem.eql(u8, command, "export-public-source")) return exportSource(c, tail);
    if (std.mem.eql(u8, command, "patch-quickjs") or std.mem.eql(u8, command, "patch-quickjs-ng")) return patchEngine(c, tail, std.mem.endsWith(u8, command, "-ng"));
    return error.Usage;
}

fn safeLabel(label: []const u8) bool {
    if (label.len == 0 or !std.ascii.isAlphanumeric(label[0])) return false;
    for (label) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') return false;
    return true;
}

fn resolveVersion(allocator: std.mem.Allocator, manifest: []const u8, input: []const u8, ref: []const u8, run_id: []const u8) ![]const u8 {
    const parsed = try std.SemanticVersion.parse(manifest);
    _ = parsed;
    const label = if (std.mem.startsWith(u8, ref, "refs/tags/")) blk: {
        const expected = try std.fmt.allocPrint(allocator, "refs/tags/v{s}", .{manifest});
        if (!std.mem.eql(u8, expected, ref)) return error.VersionMismatch;
        break :blk manifest;
    } else if (input.len != 0) blk: {
        if (!std.mem.eql(u8, input, manifest)) return error.VersionMismatch;
        break :blk input;
    } else run_id;
    if (!safeLabel(label)) return error.UnsafeLabel;
    return label;
}

fn releaseVersion(c: Context, args: []const []const u8) !void {
    if (args.len > 3) return error.Usage;
    const text = try c.read("build.zig.zon");
    const version_start = std.mem.indexOf(u8, text, ".version") orelse return error.MissingVersion;
    const quote = version_start + (std.mem.indexOfScalar(u8, text[version_start..], '"') orelse return error.MissingVersion) + 1;
    const end = quote + (std.mem.indexOfScalar(u8, text[quote..], '"') orelse return error.MissingVersion);
    const label = try resolveVersion(c.allocator(), text[quote..end], if (args.len > 0) args[0] else "", if (args.len > 1) args[1] else "", if (args.len > 2) args[2] else "");
    try c.output(try c.fmt("{s}\n", .{label}));
}

const privacy_patterns =
    // Public-tree hygiene only. Personal names, private product labels, lab
    // device ids, and private network markers go in git `info/privacy-denylist`
    // (or PRIVACY_EXTRA_FILE) so they are not embedded in this source file.
    "(^|[^0-9.])100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9]+\\.[0-9]+\n/Use[r]s/[A-Za-z0-9._-]+\n/Volum[e]s/[A-Za-z0-9._-]+\n" ++
    // Comparison / inspiration engine product names — block attributions in-tree.
    "h[e]rmes\nr[e]act[-_ ]?native\n\\bj[s]i\\b\n";

fn privacy(c: Context, args: []const []const u8) !void {
    if (args.len != 0 and (args.len != 2 or !std.mem.eql(u8, args[0], "--commits"))) return error.Usage;
    const root = std.mem.trim(u8, try c.command(&.{ "git", "rev-parse", "--show-toplevel" }, null), "\r\n");
    const stage = try c.temp(c.init.environ_map.get("TMPDIR") orelse c.init.environ_map.get("TEMP") orelse "/tmp");
    defer Dir.cwd().deleteTree(c.init.io, stage) catch {};
    const pattern_file = try c.fmt("{s}/patterns", .{stage});
    var patterns: std.Io.Writer.Allocating = .init(c.allocator());
    try patterns.writer.writeAll(privacy_patterns);
    const extra_path = c.init.environ_map.get("PRIVACY_EXTRA_FILE") orelse std.mem.trim(u8, try c.command(&.{ "git", "rev-parse", "--git-path", "info/privacy-denylist" }, root), "\r\n");
    const extra = if (std.fs.path.isAbsolute(extra_path)) extra_path else try c.fmt("{s}/{s}", .{ root, extra_path });
    if (try c.exists(extra)) {
        var lines = std.mem.splitScalar(u8, try c.read(extra), '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0 and trimmed[0] != '#') try patterns.writer.print("{s}\n", .{line});
        }
    }
    try c.write(pattern_file, patterns.written());
    const files = try c.command(&.{ "git", "ls-files", "-co", "--exclude-standard", "-z" }, root);
    var names: std.Io.Writer.Allocating = .init(c.allocator());
    var candidates: std.ArrayList([]const u8) = .empty;
    try candidates.appendSlice(c.allocator(), &.{ "rg", "-l", "-i", "-f", pattern_file, "--" });
    var paths = std.mem.splitScalar(u8, files, 0);
    var failed = false;
    while (paths.next()) |path| {
        if (path.len == 0) continue;
        const absolute = try c.fmt("{s}/{s}", .{ root, path });
        const stat = Dir.cwd().statFile(c.init.io, absolute, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind != .file) continue;
        const upstream_hash: ?[]const u8 = if (std.mem.eql(u8, path, "vendor/quickjs/intl/locale-data.c")) "686b0ee52efcfd2e2d93b28d4d997b7ccc6ac9ef" else if (std.mem.eql(u8, path, "vendor/quickjs-ng/docs/package-lock.json")) "f13c2d8cc80c186b87d3f0b8071120c81b6dc7ac" else null;
        if (upstream_hash) |expected| {
            const hash = std.mem.trim(u8, try c.command(&.{ "git", "hash-object", "--", path }, root), "\r\n");
            if (std.mem.eql(u8, hash, expected)) continue;
        }
        try names.writer.print("{s}\n", .{path});
        try candidates.append(c.allocator(), path);
        if (candidates.items.len == 106) {
            failed = (try scanBatch(c, candidates.items, root)) or failed;
            candidates.shrinkRetainingCapacity(6);
        }
    }
    if (candidates.items.len > 6) failed = (try scanBatch(c, candidates.items, root)) or failed;
    const names_file = try c.fmt("{s}/names", .{stage});
    try c.write(names_file, names.written());
    const names_result = try c.capture(&.{ "rg", "-i", "-f", pattern_file, "--", names_file }, null);
    switch (names_result.term) {
        .exited => |code| {
            if (code == 0) {
                try std.Io.File.stderr().writeStreamingAll(c.init.io, names_result.stdout);
                failed = true;
            } else if (code != 1) return error.ScanFailed;
        },
        else => return error.ScanFailed,
    }
    if (args.len == 2) {
        const messages = try c.command(&.{ "git", "log", "--format=%h %B", args[1] }, root);
        const messages_file = try c.fmt("{s}/messages", .{stage});
        try c.write(messages_file, messages);
        const result = try c.capture(&.{ "rg", "-i", "-q", "-f", pattern_file, "--", messages_file }, null);
        switch (result.term) {
            .exited => |code| {
                if (code == 0) failed = true else if (code != 1) return error.ScanFailed;
            },
            else => return error.ScanFailed,
        }
    }
    if (failed) return error.PrivacyViolation;
    try c.output("privacy: candidate source is clear\n");
}

fn scanBatch(c: Context, argv: []const []const u8, root: []const u8) !bool {
    const result = try c.capture(argv, root);
    switch (result.term) {
        .exited => |code| {
            if (code == 1) return false;
            if (code != 0) return error.ScanFailed;
            try std.Io.File.stderr().writeStreamingAll(c.init.io, result.stdout);
            return true;
        },
        else => return error.ScanFailed,
    }
}

fn releaseAssets(c: Context, args: []const []const u8) !void {
    if (args.len != 4 or !safeLabel(args[1])) return error.Usage;
    for (args[2..]) |arg| if (!std.mem.eql(u8, arg, "true") and !std.mem.eql(u8, arg, "false")) return error.Usage;
    var expected: std.StringHashMap(void) = .init(c.allocator());
    const base = [_][]const u8{ "linux-x86_64-quickjs_ng.tar.gz", "linux-x86_64-quickjs.tar.gz", "linux-aarch64-quickjs_ng.tar.gz", "linux-aarch64-quickjs.tar.gz", "macos-aarch64-quickjs_ng.tar.gz", "macos-aarch64-quickjs.tar.gz", "macos-aarch64-jsc.tar.gz", "macos-x86_64-quickjs_ng.tar.gz", "macos-x86_64-quickjs.tar.gz", "macos-x86_64-jsc.tar.gz", "source.tar.gz" };
    for (base) |name| try expected.put(try c.fmt("jsbay-{s}-{s}", .{ args[1], name }), {});
    if (std.mem.eql(u8, args[2], "true")) for ([_][]const u8{ "apple-quickjs_ng-JsBay.xcframework.zip", "apple-quickjs-JsBay.xcframework.zip", "apple-jsc-JsBay.xcframework.zip" }) |name| {
        try expected.put(try c.fmt("jsbay-{s}-{s}", .{ args[1], name }), {});
    };
    if (std.mem.eql(u8, args[3], "true")) for ([_][]const u8{ "android-quickjs_ng.aar", "android-quickjs_ng-maven.zip", "android-jniLibs-quickjs_ng.tar.gz", "android-quickjs.aar", "android-quickjs-maven.zip", "android-jniLibs-quickjs.tar.gz" }) |name| {
        try expected.put(try c.fmt("jsbay-{s}-{s}", .{ args[1], name }), {});
    };
    var dir = try Dir.cwd().openDir(c.init.io, args[0], .{ .iterate = true });
    defer dir.close(c.init.io);
    var it = dir.iterate();
    while (try it.next(c.init.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!expected.remove(entry.name)) {
            try std.Io.File.stderr().writeStreamingAll(c.init.io, try c.fmt("unexpected release asset: {s}\n", .{entry.name}));
            return error.UnexpectedReleaseAsset;
        }
    }
    if (expected.count() != 0) {
        var missing = expected.keyIterator();
        while (missing.next()) |name| try std.Io.File.stderr().writeStreamingAll(c.init.io, try c.fmt("missing release asset: {s}\n", .{name.*}));
        return error.MissingReleaseAsset;
    }
}

fn copyTree(c: Context, source: []const u8, destination: []const u8, exclude_git: bool) !void {
    try Dir.cwd().createDirPath(c.init.io, destination);
    var source_dir = try Dir.cwd().openDir(c.init.io, source, .{ .iterate = true });
    defer source_dir.close(c.init.io);
    var walker = try source_dir.walk(c.allocator());
    defer walker.deinit();
    while (try walker.next(c.init.io)) |entry| {
        if (exclude_git and std.mem.eql(u8, entry.basename, ".git")) {
            if (entry.kind == .directory) walker.leave(c.init.io);
            continue;
        }
        const dst = try c.fmt("{s}/{s}", .{ destination, entry.path });
        switch (entry.kind) {
            .directory => try Dir.cwd().createDirPath(c.init.io, dst),
            .file => try entry.dir.copyFile(entry.basename, Dir.cwd(), dst, c.init.io, .{}),
            .sym_link => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const len = try entry.dir.readLink(c.init.io, entry.basename, &buffer);
                try Dir.cwd().symLink(c.init.io, buffer[0..len], dst, .{});
            },
            else => return error.UnsupportedFileKind,
        }
    }
}

fn patchEngine(c: Context, args: []const []const u8, ng: bool) !void {
    if (args.len != (if (ng) @as(usize, 10) else 12)) return error.Usage;
    if (!try c.exists(try c.fmt("{s}/{s}", .{ args[0], if (ng) "quickjs.h" else "quickjs.c" }))) return error.MissingUpstream;
    try copyTree(c, args[0], args[1], true);
    const cwd = try std.process.currentPathAlloc(c.init.io, c.allocator());
    if (ng) {
        const header = try c.read(try c.fmt("{s}/quickjs.h", .{args[1]}));
        if (std.mem.indexOf(u8, header, "JS_RequestLocationCallback") == null) try applyPatch(c, args[1], cwd, if (std.mem.indexOf(u8, header, "JS_SetDebuggerHandler") != null) args[3] else args[2]);
        for (args[4..]) |patch| try applyPatch(c, args[1], cwd, patch);
    } else for (args[2..]) |patch| try applyPatch(c, args[1], cwd, patch);
}

fn applyPatch(c: Context, destination: []const u8, cwd: []const u8, patch: []const u8) !void {
    const absolute = if (std.fs.path.isAbsolute(patch)) patch else try c.fmt("{s}/{s}", .{ cwd, patch });
    _ = try c.command(&.{ "patch", "-p1", "-i", absolute }, destination);
}

fn packageApple(c: Context, args: []const []const u8) !void {
    if (args.len != 4 or !safeLabel(args[0])) return error.Usage;
    if (!std.mem.eql(u8, args[1], "quickjs") and !std.mem.eql(u8, args[1], "quickjs_ng") and !std.mem.eql(u8, args[1], "jsc")) return error.Usage;
    const source = "build-apple/SwiftPackage";
    for ([_][]const u8{ "Package.swift", "Sources", "Frameworks/JsBay.xcframework", "LICENSE", "THIRD_PARTY_NOTICES.md" }) |path| if (!try c.exists(try c.fmt("{s}/{s}", .{ source, path }))) return error.MissingAppleInput;
    for ([_][]const u8{ ".git", ".build" }) |path| if (try c.exists(try c.fmt("{s}/{s}", .{ source, path }))) return error.ForbiddenAppleInput;
    const absolute = try std.fs.path.resolve(c.allocator(), &.{ try std.process.currentPathAlloc(c.init.io, c.allocator()), args[3] });
    const stage = try c.temp(std.fs.path.dirname(absolute) orelse return error.Usage);
    defer Dir.cwd().deleteTree(c.init.io, stage) catch {};
    const name = try c.fmt("jsbay-{s}-apple-{s}", .{ args[0], args[1] });
    const destination = try c.fmt("{s}/{s}", .{ stage, name });
    try copyTree(c, source, destination, false);
    for ([_][]const u8{ "VERSION", "COMMIT", "backend" }, [_][]const u8{ args[0], args[2], args[1] }) |name_part, value| try c.write(try c.fmt("{s}/{s}", .{ destination, name_part }), try c.fmt("{s}\n", .{value}));
    const staged_zip = try c.fmt("{s}/package.zip", .{stage});
    _ = try c.command(&.{ "zip", "-qry", staged_zip, name }, stage);
    const listing = try c.command(&.{ "unzip", "-Z1", staged_zip }, null);
    for ([_][]const u8{ "Package.swift", "Sources/JsBaySDK/JsBaySDK.swift", "Sources/JsBayObjC/JSBay.m", "Frameworks/JsBay.xcframework/Info.plist", "LICENSE", "THIRD_PARTY_NOTICES.md", "VERSION", "COMMIT", "backend" }) |path| {
        const expected = try c.fmt("{s}/{s}", .{ name, path });
        var lines = std.mem.splitScalar(u8, listing, '\n');
        var found = false;
        while (lines.next()) |line| if (std.mem.eql(u8, line, expected)) {
            found = true;
            break;
        };
        if (!found) return error.MissingArchiveMember;
    }
    try Dir.renameAbsolute(staged_zip, absolute, c.init.io);
}

fn exportSource(c: Context, args: []const []const u8) !void {
    if (args.len != 1) return error.Usage;
    const output = try std.fs.path.resolve(c.allocator(), &.{ try std.process.currentPathAlloc(c.init.io, c.allocator()), args[0] });
    const root = std.mem.trim(u8, try c.command(&.{ "git", "rev-parse", "--show-toplevel" }, null), "\r\n");
    if (std.mem.trim(u8, try c.command(&.{ "git", "status", "--porcelain", "--untracked-files=all" }, root), "\r\n").len != 0) return error.DirtySourceTree;
    for ([_][]const u8{ "LICENSE", "THIRD_PARTY_NOTICES.md", "build.zig.zon" }) |path| _ = try c.command(&.{ "git", "ls-files", "--error-unmatch", path }, root);
    try privacy(c, &.{});
    const stage = try c.temp(c.init.environ_map.get("TMPDIR") orelse c.init.environ_map.get("TEMP") orelse "/tmp");
    defer Dir.cwd().deleteTree(c.init.io, stage) catch {};
    const archive = try c.fmt("{s}/source.tar", .{stage});
    _ = try c.command(&.{ "git", "archive", "--format=tar", "--prefix=js-bay-source/", "-o", archive, "HEAD" }, root);
    _ = try c.command(&.{ "tar", "-xf", archive, "-C", stage }, null);
    const tree_root = try c.fmt("{s}/js-bay-source", .{stage});
    for ([_][]const u8{ "vendor/quickjs", "vendor/quickjs-ng" }) |submodule| {
        const spec = std.mem.trim(u8, try c.command(&.{ "git", "ls-tree", "-d", "--format=%(objectmode) %(objecttype) %(objectname)", "HEAD", "--", submodule }, root), "\r\n");
        if (std.mem.startsWith(u8, spec, "160000 commit ")) {
            const revision = spec[14..];
            const source = try c.fmt("{s}/{s}", .{ root, submodule });
            const current = std.mem.trim(u8, try c.command(&.{ "git", "rev-parse", "HEAD" }, source), "\r\n");
            if (!std.mem.eql(u8, current, revision)) return error.SubmoduleRevisionMismatch;
            _ = try c.command(&.{ "git", "cat-file", "-e", try c.fmt("{s}^{{commit}}", .{revision}) }, source);
            const destination = try c.fmt("{s}/{s}", .{ tree_root, submodule });
            try Dir.cwd().createDirPath(c.init.io, destination);
            _ = try c.command(&.{ "git", "archive", "--format=tar", "-o", archive, revision }, source);
            _ = try c.command(&.{ "tar", "-xf", archive, "-C", destination }, null);
        } else if (!std.mem.startsWith(u8, spec, "040000 tree ") or !try c.exists(try c.fmt("{s}/{s}", .{ tree_root, submodule }))) return error.MissingCommittedSources;
    }
    var dir = try Dir.cwd().openDir(c.init.io, tree_root, .{ .iterate = true });
    defer dir.close(c.init.io);
    var walker = try dir.walk(c.allocator());
    defer walker.deinit();
    while (try walker.next(c.init.io)) |entry| {
        if (std.mem.eql(u8, entry.basename, ".git")) return error.GitMetadataInExport;
        if (std.mem.eql(u8, entry.basename, ".gitmodules")) {
            if (entry.kind != .file) return error.GitMetadataInExport;
            try entry.dir.deleteFile(c.init.io, entry.basename);
        }
    }
    for ([_][]const u8{ "LICENSE", "THIRD_PARTY_NOTICES.md", "build.zig.zon" }) |path| if (!try c.exists(try c.fmt("{s}/{s}", .{ tree_root, path }))) return error.MissingSourceInput;
    _ = try c.command(&.{ "tar", "-C", stage, "-czf", output, "js-bay-source" }, null);
    try c.output(try c.fmt("source snapshot: {s}\n", .{output}));
}

fn checkDocs(c: Context, args: []const []const u8) !void {
    if (args.len != 0) return error.Usage;
    var dir = try Dir.cwd().openDir(c.init.io, "docs", .{ .iterate = true });
    defer dir.close(c.init.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(c.init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) return error.InvalidDocumentationLayout;
        for (entry.name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '.')) return error.InvalidDocumentationLayout;
        const content = try dir.readFileAlloc(c.init.io, entry.name, c.allocator(), .unlimited);
        var view = try std.unicode.Utf8View.init(content);
        var codepoints = view.iterator();
        while (codepoints.nextCodepoint()) |cp| if (cp >= 0x3400 and cp <= 0x9fff) return error.NonEnglishDocumentation;
        count += 1;
    }
    if (count == 0) return error.MissingDocumentation;
    try c.output("docs: flat lowercase English documentation\n");
}

fn checkTooling(c: Context, args: []const []const u8) !void {
    if (args.len != 0) return error.Usage;
    // Git lists a submodule as one directory entry. Its upstream files are
    // outside this repository's tooling policy, as are ignored build caches.
    const files = try c.command(&.{ "git", "ls-files", "-co", "--exclude-standard", "-z" }, null);
    var paths = std.mem.splitScalar(u8, files, 0);
    var failed = false;
    while (paths.next()) |path| {
        if (path.len == 0) continue;
        const stat = Dir.cwd().statFile(c.init.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind != .file) continue;
        const script = std.mem.endsWith(u8, path, ".py") or std.mem.endsWith(u8, path, ".pyw") or std.mem.endsWith(u8, path, ".pyc");
        const content = try c.read(path);
        const invocation = containsInterpreter(content);
        if (script or invocation) {
            failed = true;
            try std.Io.File.stderr().writeStreamingAll(c.init.io, try c.fmt("forbidden project tooling: {s}\n", .{path}));
        }
    }
    if (failed) return error.ForbiddenProjectTooling;
    try c.output("tooling: no Python scripts or interpreter calls outside upstream submodules\n");
}

fn containsInterpreter(content: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, content, " \t\r\n\"'`()[]{};,|&<>:=\\");
    while (tokens.next()) |token| {
        const name = std.fs.path.basename(token);
        if (!std.mem.startsWith(u8, name, "py" ++ "thon")) continue;
        const suffix = name[6..];
        if (suffix.len == 0) return true;
        if (!std.ascii.isDigit(suffix[0])) continue;
        var version = true;
        for (suffix) |ch| if (!std.ascii.isDigit(ch) and ch != '.') {
            version = false;
            break;
        };
        if (version) return true;
    }
    return false;
}

test "release labels preserve matching versions and reject unsafe identifiers" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("0.1.0", try resolveVersion(a, "0.1.0", "0.1.0", "refs/heads/main", "12345"));
    try std.testing.expectEqualStrings("12345", try resolveVersion(a, "0.1.0", "", "refs/heads/main", "12345"));
    try std.testing.expectError(error.VersionMismatch, resolveVersion(a, "0.1.0", "9.9.9", "refs/heads/main", "12345"));
    try std.testing.expectError(error.UnsafeLabel, resolveVersion(a, "0.1.0", "", "refs/heads/main", "../unsafe"));
    try std.testing.expectError(error.UnsafeLabel, resolveVersion(a, "0.1.0", "", "", ""));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectEqualStrings("0.1.0", try resolveVersion(arena.allocator(), "0.1.0", "", "refs/tags/v0.1.0", "12345"));
    try std.testing.expectError(error.VersionMismatch, resolveVersion(arena.allocator(), "0.1.0", "", "refs/tags/v9.9.9", "12345"));
}

fn simulatorList(c: Context, args: []const []const u8) !void {
    if (args.len != 2) return error.Usage;
    const Device = struct { name: []const u8 = "", identifier: []const u8 };
    const Runtime = struct { isAvailable: bool = false, identifier: []const u8 = "" };
    const Inventory = struct { devicetypes: []const Device = &.{}, runtimes: []const Runtime = &.{} };
    const parsed = try std.json.parseFromSlice(Inventory, c.allocator(), try c.read(args[1]), .{ .ignore_unknown_fields = true });
    if (std.mem.eql(u8, args[0], "devices")) {
        for (parsed.value.devicetypes) |device| if (std.mem.startsWith(u8, device.name, "iPhone")) {
            try c.output(try c.fmt("{s}\n", .{device.identifier}));
        };
    } else if (std.mem.eql(u8, args[0], "runtimes")) {
        for (parsed.value.runtimes) |runtime| if (runtime.isAvailable and std.mem.startsWith(u8, runtime.identifier, "com.apple.CoreSimulator.SimRuntime.iOS-")) {
            try c.output(try c.fmt("{s}\n", .{runtime.identifier}));
        };
    } else return error.Usage;
}

fn harmonyFacade(c: Context, args: []const []const u8) !void {
    if (args.len != 2) return error.Usage;
    const source = try c.read(args[0]);
    const native = try std.mem.replaceOwned(u8, c.allocator(), source, "import native from 'libjsbay_harmony.so'", "declare const require: (name: string) => any\ndeclare const process: { env: { JSBAY_HARMONY_NODE?: string } }\nconst native: any = require(process.env.JSBAY_HARMONY_NODE as string)");
    const adapted = try std.mem.replaceOwned(u8, c.allocator(), native, "import util from '@ohos.util'", "const util = { TextDecoder: { create: (encoding?: string) => ({ decodeToString: (input: Uint8Array, _options?: { stream?: boolean }) => new TextDecoder(encoding).decode(input) }) } }");
    try c.write(args[1], adapted);
}

fn checkMaven(c: Context, args: []const []const u8) !void {
    if (args.len != 2 or !safeLabel(args[1])) return error.Usage;
    const File = struct { name: []const u8, size: u64, md5: []const u8, sha1: []const u8, sha256: []const u8, sha512: []const u8 };
    const Metadata = struct { variants: []const struct { files: []const File = &.{} } };
    const name = try c.fmt("js-bay-android-{s}.aar", .{args[1]});
    const bytes = try c.read(try c.fmt("{s}/{s}", .{ args[0], name }));
    const text = try c.read(try c.fmt("{s}/js-bay-android-{s}.module", .{ args[0], args[1] }));
    const parsed = try std.json.parseFromSlice(Metadata, c.allocator(), text, .{ .ignore_unknown_fields = true });
    var found = false;
    for (parsed.value.variants) |variant| for (variant.files) |file| {
        if (!std.mem.eql(u8, file.name, name)) continue;
        found = true;
        if (file.size != bytes.len) return error.MavenSizeMismatch;
        inline for (.{ "md5", "sha1", "sha256", "sha512" }, .{ std.crypto.hash.Md5, std.crypto.hash.Sha1, std.crypto.hash.sha2.Sha256, std.crypto.hash.sha2.Sha512 }) |algorithm, Hash| {
            var digest: [Hash.digest_length]u8 = undefined;
            Hash.hash(bytes, &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, &hex, @field(file, algorithm))) return error.MavenHashMismatch;
        }
    };
    if (!found) return error.MissingMavenAar;
    inline for (.{ "md5", "sha1", "sha256", "sha512" }, .{ std.crypto.hash.Md5, std.crypto.hash.Sha1, std.crypto.hash.sha2.Sha256, std.crypto.hash.sha2.Sha512 }) |algorithm, Hash| {
        var digest: [Hash.digest_length]u8 = undefined;
        Hash.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const sidecar = std.mem.trim(u8, try c.read(try c.fmt("{s}/{s}.{s}", .{ args[0], name, algorithm })), " \t\r\n");
        if (!std.mem.eql(u8, &hex, sidecar)) return error.MavenSidecarMismatch;
    }
}
