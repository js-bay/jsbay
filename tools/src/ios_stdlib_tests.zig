//! Black-box fixtures for `prepare-ios-stdlib`.  The command must construct an isolated library overlay without changing the compiler installation.
const std = @import("std");
const sdk = @import("sdk.zig");

const testing = std.testing;
const Dir = std.Io.Dir;

const threaded_original =
    \\const have_preadv = switch (native_os) {
    \\    .windows, .haiku => false,
    \\    else => true,
    \\};
    \\
    \\fn fileWritePositional() void {
    \\    while (true) {
    \\        const rc = if (native_os == .haiku)
    \\            posix.system.writev_pos(file.handle, @bitCast(offset), &iovecs, @intCast(iovlen))
    \\        else
    \\            pwritev_sym(file.handle, &iovecs, @intCast(iovlen), @bitCast(offset));
    \\        _ = rc;
    \\    }
    \\}
;

const threaded_patched =
    \\const have_preadv = switch (native_os) {
    \\    .windows, .haiku => false,
    \\    .ios => builtin.os.isAtLeast(.ios, .{ .major = 14, .minor = 0, .patch = 0 }) orelse false,
    \\    else => true,
    \\};
    \\
    \\fn fileWritePositional() void {
    \\    while (true) {
    \\        const rc = if (native_os == .haiku)
    \\            posix.system.writev_pos(file.handle, @bitCast(offset), &iovecs, @intCast(iovlen))
    \\        else if (have_preadv)
    \\            pwritev_sym(file.handle, &iovecs, @intCast(iovlen), @bitCast(offset))
    \\        else
    \\            pwrite_sym(file.handle, iovecs[0].base, @intCast(iovecs[0].len), @bitCast(offset));
    \\        _ = rc;
    \\    }
    \\}
;

const process_original =
    \\pub const can_replace = switch (native_os) {
    \\    .windows, .haiku, .wasi => false,
    \\    else => true,
    \\};
;
const process_patched =
    \\pub const can_replace = switch (native_os) {
    \\    .windows, .haiku, .wasi, .ios, .tvos, .visionos, .watchos => false,
    \\    else => true,
    \\};
;

fn makeTemp(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var random: [12]u8 = undefined;
    io.random(&random);
    const path = try std.fmt.allocPrint(allocator, "/tmp/jsbay-ios-stdlib-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try Dir.cwd().createDir(io, path, .default_dir);
    return path;
}

fn toolPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return sdk.toolPath(allocator, io);
}

fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

fn writeFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
}

fn prepareSource(allocator: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8, process: []const u8, threaded: []const u8) ![]u8 {
    const source = try join(allocator, &.{ root, name });
    try Dir.cwd().createDirPath(io, try join(allocator, &.{ source, "std", "Io" }));
    try writeFile(io, try join(allocator, &.{ source, "std", "std.zig" }), "pub const process = @import(\"process.zig\");\n");
    try writeFile(io, try join(allocator, &.{ source, "std", "process.zig" }), process);
    try writeFile(io, try join(allocator, &.{ source, "std", "keep.zig" }), name);
    try writeFile(io, try join(allocator, &.{ source, "std", "Io", "Threaded.zig" }), threaded);
    try writeFile(io, try join(allocator, &.{ source, "std", "Io", "keep.zig" }), name);
    try writeFile(io, try join(allocator, &.{ source, "fuzzer.zig" }), name);
    return source;
}

fn runPrepare(allocator: std.mem.Allocator, io: std.Io, tool: []const u8, root: []const u8, source: []const u8, overlay: []const u8) !sdk.Output {
    const process = try join(allocator, &.{ source, "std", "process.zig" });
    return sdk.run(allocator, io, &.{ tool, "prepare-ios-stdlib", process, overlay }, root);
}

fn expectLink(io: std.Io, path: []const u8) !void {
    const stat = try Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    try testing.expectEqual(.sym_link, stat.kind);
}

fn outputContains(output: sdk.Output, needle: []const u8) bool {
    return std.mem.indexOf(u8, output.result.stdout, needle) != null or std.mem.indexOf(u8, output.result.stderr, needle) != null;
}

test "prepare-ios-stdlib rejects declaration decoys and relative output inside installation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const root_dir = try makeTemp(a, io);
    defer Dir.cwd().deleteTree(io, root_dir) catch {};
    const tool = try toolPath(a, io);
    const source = try prepareSource(a, io, root_dir, "installed", process_original, threaded_original);
    var inside = try runPrepare(a, io, tool, root_dir, source, "installed/new-overlay");
    defer inside.deinit();
    try testing.expect(!inside.succeeded());
    try testing.expect(outputContains(inside, "UnsafeOverlayPath"));
    try testing.expectError(error.FileNotFound, Dir.cwd().access(io, try join(a, &.{ source, "new-overlay" }), .{}));
    try Dir.cwd().symLink(io, try join(a, &.{ source, "std" }), try join(a, &.{ root_dir, "alias" }), .{ .is_directory = true });
    var traversal = try runPrepare(a, io, tool, root_dir, source, "alias/../new-overlay");
    defer traversal.deinit();
    try testing.expect(!traversal.succeeded());
    try testing.expect(outputContains(traversal, "UnsafeOverlayPath"));
    const decoy = "// .windows, .haiku, .wasi, .ios, .tvos, .visionos, .watchos => false,\npub const can_replace = mystery();\n";
    try writeFile(io, try join(a, &.{ source, "std", "process.zig" }), decoy);
    var result = try runPrepare(a, io, tool, root_dir, source, try join(a, &.{ root_dir, "overlay" }));
    defer result.deinit();
    try testing.expect(!result.succeeded());
    try testing.expect(outputContains(result, "UnrecognizedProcessCapability"));
}

test "prepare-ios-stdlib patches process into an isolated repeatable overlay" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(allocator, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try toolPath(allocator, io);
    const source = try prepareSource(allocator, io, root, "installed", process_original, threaded_original);
    const overlay = try join(allocator, &.{ root, "overlay" });
    var output = try runPrepare(allocator, io, tool, root, source, overlay);
    defer output.deinit();
    try testing.expect(output.succeeded());
    try testing.expectEqualStrings(process_original, try Dir.cwd().readFileAlloc(io, try join(allocator, &.{ source, "std", "process.zig" }), allocator, .limited(4096)));
    const patched = try Dir.cwd().readFileAlloc(io, try join(allocator, &.{ overlay, "std", "process.zig" }), allocator, .limited(4096));
    try testing.expect(std.mem.indexOf(u8, patched, ".ios") != null);
    try testing.expect(std.mem.indexOf(u8, patched, ".watchos => false") != null);
    try expectLink(io, try join(allocator, &.{ overlay, "std", "keep.zig" }));
    var repeated = try runPrepare(allocator, io, tool, root, source, overlay);
    defer repeated.deinit();
    try testing.expect(repeated.succeeded());
}

test "prepare-ios-stdlib patches Threaded for iOS 13 without touching source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(allocator, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try toolPath(allocator, io);
    const source = try prepareSource(allocator, io, root, "installed", process_original, threaded_original);
    const overlay = try join(allocator, &.{ root, "overlay" });
    var output = try runPrepare(allocator, io, tool, root, source, overlay);
    defer output.deinit();
    try testing.expect(output.succeeded());
    try testing.expectEqualStrings(threaded_original, try Dir.cwd().readFileAlloc(io, try join(allocator, &.{ source, "std", "Io", "Threaded.zig" }), allocator, .limited(4096)));
    const patched = try Dir.cwd().readFileAlloc(io, try join(allocator, &.{ overlay, "std", "Io", "Threaded.zig" }), allocator, .limited(4096));
    try testing.expect(std.mem.indexOf(u8, patched, ".ios => builtin.os.isAtLeast") != null);
    try testing.expect(std.mem.indexOf(u8, patched, "else if (have_preadv)") != null);
    try testing.expect(std.mem.indexOf(u8, patched, "pwrite_sym(file.handle") != null);
    try expectLink(io, try join(allocator, &.{ overlay, "std", "Io", "keep.zig" }));
}

test "prepare-ios-stdlib rejects an old Io symlink overlay without changing source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(allocator, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try toolPath(allocator, io);
    const source = try prepareSource(allocator, io, root, "installed", process_original, threaded_original);
    const overlay = try join(allocator, &.{ root, "overlay" });
    var first = try runPrepare(allocator, io, tool, root, source, overlay);
    defer first.deinit();
    try testing.expect(first.succeeded());
    const out_io = try join(allocator, &.{ overlay, "std", "Io" });
    try Dir.cwd().deleteTree(io, out_io);
    try Dir.cwd().symLink(io, try join(allocator, &.{ source, "std", "Io" }), out_io, .{ .is_directory = true });
    var rejected = try runPrepare(allocator, io, tool, root, source, overlay);
    defer rejected.deinit();
    try testing.expect(!rejected.succeeded());
    try testing.expect(outputContains(rejected, "RefusingSymlink"));
    const stat = try Dir.cwd().statFile(io, out_io, .{ .follow_symlinks = false });
    try testing.expectEqual(.sym_link, stat.kind);
    try testing.expectEqualStrings(threaded_original, try Dir.cwd().readFileAlloc(io, try join(allocator, &.{ source, "std", "Io", "Threaded.zig" }), allocator, .limited(4096)));
}

test "prepare-ios-stdlib refuses a std symlink overlay without changing source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(allocator, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try toolPath(allocator, io);
    const source = try prepareSource(allocator, io, root, "installed", process_original, threaded_original);
    const overlay = try join(allocator, &.{ root, "overlay" });
    var first = try runPrepare(allocator, io, tool, root, source, overlay);
    defer first.deinit();
    try testing.expect(first.succeeded());
    const out_std = try join(allocator, &.{ overlay, "std" });
    try Dir.cwd().deleteTree(io, out_std);
    try Dir.cwd().symLink(io, try join(allocator, &.{ source, "std" }), out_std, .{ .is_directory = true });
    var rejected = try runPrepare(allocator, io, tool, root, source, overlay);
    defer rejected.deinit();
    try testing.expect(!rejected.succeeded());
    try testing.expect(outputContains(rejected, "RefusingSymlink"));
    try testing.expectEqualStrings(process_original, try Dir.cwd().readFileAlloc(io, try join(allocator, &.{ source, "std", "process.zig" }), allocator, .limited(4096)));
    try testing.expectEqualStrings(threaded_original, try Dir.cwd().readFileAlloc(io, try join(allocator, &.{ source, "std", "Io", "Threaded.zig" }), allocator, .limited(4096)));
}

test "prepare-ios-stdlib rejects an unknown Threaded definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(allocator, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try toolPath(allocator, io);
    const source = try prepareSource(allocator, io, root, "installed", process_original, "const have_preadv = false;\n");
    const overlay = try join(allocator, &.{ root, "overlay" });
    var output = try runPrepare(allocator, io, tool, root, source, overlay);
    defer output.deinit();
    try testing.expect(!output.succeeded());
    try testing.expect(outputContains(output, "UnrecognizedThreadedDefinition"));
}

test "prepare-ios-stdlib leaves an already patched Threaded definition unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(allocator, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try toolPath(allocator, io);
    const source = try prepareSource(allocator, io, root, "installed", process_patched, threaded_patched);
    const overlay = try join(allocator, &.{ root, "overlay" });
    var output = try runPrepare(allocator, io, tool, root, source, overlay);
    defer output.deinit();
    try testing.expect(output.succeeded());
    try testing.expectEqualStrings(threaded_patched, try Dir.cwd().readFileAlloc(io, try join(allocator, &.{ overlay, "std", "Io", "Threaded.zig" }), allocator, .limited(4096)));
}

test "prepare-ios-stdlib relinks a cached overlay when the compiler moves" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(allocator, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try toolPath(allocator, io);
    const overlay = try join(allocator, &.{ root, "overlay" });
    const old_source = try prepareSource(allocator, io, root, "old-install", process_original, threaded_original);
    var old = try runPrepare(allocator, io, tool, root, old_source, overlay);
    defer old.deinit();
    try testing.expect(old.succeeded());
    const new_source = try prepareSource(allocator, io, root, "new-install", process_original, threaded_original);
    var new = try runPrepare(allocator, io, tool, root, new_source, overlay);
    defer new.deinit();
    try testing.expect(new.succeeded());
    const fuzzer = try Dir.cwd().realPathFileAlloc(io, try join(allocator, &.{ overlay, "fuzzer.zig" }), allocator);
    const expected_fuzzer = try Dir.cwd().realPathFileAlloc(io, try join(allocator, &.{ new_source, "fuzzer.zig" }), allocator);
    try testing.expectEqualStrings(expected_fuzzer, fuzzer);
    const keep = try Dir.cwd().realPathFileAlloc(io, try join(allocator, &.{ overlay, "std", "keep.zig" }), allocator);
    const expected_keep = try Dir.cwd().realPathFileAlloc(io, try join(allocator, &.{ new_source, "std", "keep.zig" }), allocator);
    try testing.expectEqualStrings(expected_keep, keep);
}

test "prepare-ios-stdlib leaves an already patched process definition unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(allocator, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try toolPath(allocator, io);
    const source = try prepareSource(allocator, io, root, "installed", process_patched, threaded_original);
    const overlay = try join(allocator, &.{ root, "overlay" });
    var output = try runPrepare(allocator, io, tool, root, source, overlay);
    defer output.deinit();
    try testing.expect(output.succeeded());
    try testing.expectEqualStrings(process_patched, try Dir.cwd().readFileAlloc(io, try join(allocator, &.{ overlay, "std", "process.zig" }), allocator, .limited(4096)));
}

test "prepare-ios-stdlib rejects unknown process capability definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(allocator, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try toolPath(allocator, io);
    const source = try prepareSource(allocator, io, root, "installed", "pub const can_replace = mystery();\n", threaded_original);
    const overlay = try join(allocator, &.{ root, "overlay" });
    var output = try runPrepare(allocator, io, tool, root, source, overlay);
    defer output.deinit();
    try testing.expect(!output.succeeded());
    try testing.expect(outputContains(output, "UnrecognizedProcessCapability"));
}

test "prepare-ios-stdlib refuses the installed library as output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(allocator, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try toolPath(allocator, io);
    const source = try prepareSource(allocator, io, root, "installed", process_original, threaded_original);
    var output = try runPrepare(allocator, io, tool, root, source, source);
    defer output.deinit();
    try testing.expect(!output.succeeded());
    try testing.expectEqualStrings(process_original, try Dir.cwd().readFileAlloc(io, try join(allocator, &.{ source, "std", "process.zig" }), allocator, .limited(4096)));
}

test "prepare-ios-stdlib rejects mobile tags on a true process arm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(allocator, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try toolPath(allocator, io);
    const changed = "pub const can_replace = switch (native_os) {\n    .ios, .tvos, .visionos, .watchos => true,\n    else => false,\n};\n";
    const source = try prepareSource(allocator, io, root, "installed", changed, threaded_original);
    const overlay = try join(allocator, &.{ root, "overlay" });
    var output = try runPrepare(allocator, io, tool, root, source, overlay);
    defer output.deinit();
    try testing.expect(!output.succeeded());
    try testing.expect(outputContains(output, "UnrecognizedProcessCapability"));
}
