const std = @import("std");

/// Creates the iOS standard-library overlay used by the root build.  The source files are inspected before anything is written, so an unknown Zig release fails closed instead of receiving a guessed textual patch.
pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 2) return error.Usage;
    const allocator = init.arena.allocator();
    const process_path = args[0];
    const output = args[1];
    const process = try std.Io.Dir.cwd().readFileAlloc(init.io, process_path, allocator, .limited(16 * 1024 * 1024));
    const patched_process = try patchProcessSource(allocator, process);
    const source_abs = try std.Io.Dir.cwd().realPathFileAlloc(init.io, process_path, allocator);
    const std_dir = std.fs.path.dirname(source_abs) orelse return error.InvalidPath;
    const lib_dir = std.fs.path.dirname(std_dir) orelse return error.InvalidPath;
    const output_abs = try canonicalDestination(init.io, allocator, output);
    if (std.mem.eql(u8, output_abs, lib_dir) or (std.mem.startsWith(u8, output_abs, lib_dir) and output_abs.len > lib_dir.len and std.fs.path.isSep(output_abs[lib_dir.len]))) return error.UnsafeOverlayPath;
    const threaded_path = try std.fs.path.join(allocator, &.{ lib_dir, "std", "Io", "Threaded.zig" });
    const threaded = try std.Io.Dir.cwd().readFileAlloc(init.io, threaded_path, allocator, .limited(32 * 1024 * 1024));
    const old_preadv = "const have_preadv = switch (native_os) {\n    .windows, .haiku => false,\n    else => true,\n};";
    const new_preadv = "const have_preadv = switch (native_os) {\n    .windows, .haiku => false,\n    .ios => builtin.os.isAtLeast(.ios, .{ .major = 14, .minor = 0, .patch = 0 }) orelse false,\n    else => true,\n};";
    const old_write = "else\n            pwritev_sym(file.handle, &iovecs, @intCast(iovlen), @bitCast(offset));";
    const new_write = "else if (have_preadv)\n            pwritev_sym(file.handle, &iovecs, @intCast(iovlen), @bitCast(offset))\n        else\n            pwrite_sym(file.handle, iovecs[0].base, @intCast(iovecs[0].len), @bitCast(offset));";
    if (std.mem.indexOf(u8, threaded, new_preadv) == null and std.mem.indexOf(u8, threaded, old_preadv) == null) return error.UnrecognizedThreadedDefinition;
    if (std.mem.indexOf(u8, threaded, new_write) == null and std.mem.indexOf(u8, threaded, old_write) == null) return error.UnrecognizedThreadedDefinition;
    try refuseSymlink(init, output);
    try std.Io.Dir.cwd().createDirPath(init.io, output);
    const out_std = try std.fs.path.join(allocator, &.{ output, "std" });
    try refuseSymlink(init, out_std);
    try std.Io.Dir.cwd().createDirPath(init.io, out_std);
    const process_out = try std.fs.path.join(allocator, &.{ out_std, "process.zig" });
    try refuseSymlink(init, process_out);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = process_out, .data = patched_process });
    const out_io = try std.fs.path.join(allocator, &.{ out_std, "Io" });
    try refuseSymlink(init, out_io);
    try std.Io.Dir.cwd().createDirPath(init.io, out_io);
    const threaded_out = try std.fs.path.join(allocator, &.{ out_io, "Threaded.zig" });
    try refuseSymlink(init, threaded_out);
    var patched_threaded = threaded;
    if (std.mem.indexOf(u8, patched_threaded, new_preadv) == null) patched_threaded = try std.mem.replaceOwned(u8, allocator, patched_threaded, old_preadv, new_preadv);
    if (std.mem.indexOf(u8, patched_threaded, new_write) == null) patched_threaded = try std.mem.replaceOwned(u8, allocator, patched_threaded, old_write, new_write);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = threaded_out, .data = patched_threaded });
    try linkChildren(init, allocator, try std.fs.path.join(allocator, &.{ lib_dir, "std" }), out_std, &.{ "process.zig", "Io" });
    try linkChildren(init, allocator, try std.fs.path.join(allocator, &.{ lib_dir, "std", "Io" }), out_io, &.{"Threaded.zig"});
    try linkChildren(init, allocator, lib_dir, output, &.{"std"});
}

/// Match the declaration's tokens, rather than examples in comments or other switches. Unknown compiler layouts fail before any output is created.
pub fn patchProcessSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const terminated = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(terminated);
    var tokenizer = std.zig.Tokenizer.init(terminated);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag != .keyword_const) continue;
        const name = tokenizer.next();
        if (name.tag != .identifier or !std.mem.eql(u8, source[name.loc.start..name.loc.end], "can_replace")) continue;
        var normalized: std.Io.Writer.Allocating = .init(allocator);
        defer normalized.deinit();
        try normalized.writer.writeAll("constcan_replace");
        var end = name.loc.end;
        while (true) {
            const next = tokenizer.next();
            if (next.tag == .eof or next.tag == .invalid) return error.UnrecognizedProcessCapability;
            if (next.tag == .doc_comment or next.tag == .container_doc_comment) continue;
            try normalized.writer.writeAll(source[next.loc.start..next.loc.end]);
            end = next.loc.end;
            if (next.tag == .semicolon) break;
        }
        const old = "constcan_replace=switch(native_os){.windows,.haiku,.wasi=>false,else=>true,};";
        const fixed = "constcan_replace=switch(native_os){.windows,.haiku,.wasi,.ios,.tvos,.visionos,.watchos=>false,else=>true,};";
        if (std.mem.eql(u8, normalized.written(), fixed)) return allocator.dupe(u8, source);
        if (!std.mem.eql(u8, normalized.written(), old)) return error.UnrecognizedProcessCapability;
        return std.mem.concat(allocator, u8, &.{ source[0..token.loc.start], "const can_replace = switch (native_os) {\n    .windows, .haiku, .wasi, .ios, .tvos, .visionos, .watchos => false,\n    else => true,\n};", source[end..] });
    }
    return error.UnrecognizedProcessCapability;
}

fn canonicalDestination(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Parent traversal after a symlink has different filesystem and lexical meanings. Overlay destinations must be explicit, without parent steps.
    var components = std.mem.tokenizeAny(u8, path, if (@import("builtin").os.tag == .windows) "/\\" else "/");
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return error.UnsafeOverlayPath;
    const cwd = try std.process.currentPathAlloc(io, allocator);
    const absolute = try std.fs.path.resolve(allocator, &.{ cwd, path });
    var ancestor: []const u8 = absolute;
    while (true) {
        const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, ancestor, allocator) catch |err| switch (err) {
            error.FileNotFound => {
                ancestor = std.fs.path.dirname(ancestor) orelse return err;
                continue;
            },
            else => return err,
        };
        return std.fs.path.resolve(allocator, &.{ resolved, std.mem.trimStart(u8, absolute[ancestor.len..], "/\\") });
    }
}

test "process patch rejects comment decoys and unrelated switches" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnrecognizedProcessCapability, patchProcessSource(a, "// .windows, .haiku, .wasi, .ios, .tvos, .visionos, .watchos => false,\npub const can_replace = mystery();"));
    try std.testing.expectError(error.UnrecognizedProcessCapability, patchProcessSource(a, "const other = switch (native_os) { .windows, .haiku, .wasi => false, else => true, };\npub const can_replace = mystery();"));
}

fn refuseSymlink(init: std.process.Init, path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(init.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.RefusingSymlink;
}

fn linkChildren(init: std.process.Init, allocator: std.mem.Allocator, source: []const u8, destination: []const u8, skip: []const []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(init.io, source, .{ .iterate = true });
    defer dir.close(init.io);
    var it = dir.iterate();
    while (try it.next(init.io)) |entry| {
        var ignored = false;
        for (skip) |name| {
            if (std.mem.eql(u8, entry.name, name)) ignored = true;
        }
        if (ignored) continue;
        const target = try std.fs.path.join(allocator, &.{ source, entry.name });
        const link = try std.fs.path.join(allocator, &.{ destination, entry.name });
        try refreshLink(init, allocator, target, link, entry.kind == .directory);
    }
}

fn refreshLink(init: std.process.Init, allocator: std.mem.Allocator, target: []const u8, link: []const u8, is_directory: bool) !void {
    const stat = std.Io.Dir.cwd().statFile(init.io, link, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.cwd().symLink(init.io, target, link, .{ .is_directory = is_directory });
            return;
        },
        else => return err,
    };
    if (stat.kind != .sym_link) return error.UnexpectedOverlayEntry;
    // Cached overlays keep absolute symlinks into the Zig install. When CI restores
    // zig-cache after setup-zig extracts a new install path, those links dangle and
    // realPath fails — replace them instead of aborting the iOS build.
    const existing_target = std.Io.Dir.cwd().realPathFileAlloc(init.io, link, allocator) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.cwd().deleteFile(init.io, link);
            try std.Io.Dir.cwd().symLink(init.io, target, link, .{ .is_directory = is_directory });
            return;
        },
        else => return err,
    };
    defer allocator.free(existing_target);
    const expected_target = try std.Io.Dir.cwd().realPathFileAlloc(init.io, target, allocator);
    defer allocator.free(expected_target);
    if (std.mem.eql(u8, existing_target, expected_target)) return;
    try std.Io.Dir.cwd().deleteFile(init.io, link);
    try std.Io.Dir.cwd().symLink(init.io, target, link, .{ .is_directory = is_directory });
}
