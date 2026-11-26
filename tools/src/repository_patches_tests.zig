const std = @import("std");
const repository = @import("repository.zig");
const Dir = std.Io.Dir;

test "debugger compilation instrumentation rejects missing or ambiguous sites" {
    const needle = "helper = JS_Eval(ctx, factory_source, factory_source_len, \"<debugger>\", JS_EVAL_TYPE_GLOBAL);";
    try std.testing.expectError(error.InvalidDebugEvalSource, repository.debugEvalInstrumented(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidDebugEvalSource, repository.debugEvalInstrumented(std.testing.allocator, needle ++ needle));
}

test "patch engine argument count matches the backend patch list" {
    var quickjs_args: [19][]const u8 = undefined;
    @memset(&quickjs_args, "patch");
    quickjs_args[0] = "source";
    quickjs_args[1] = "destination";
    try repository.validatePatchEngineArgs(&quickjs_args, false);
    try std.testing.expectError(error.Usage, repository.validatePatchEngineArgs(quickjs_args[0..18], false));

    var quickjs_ng_args: [18][]const u8 = undefined;
    @memset(&quickjs_ng_args, "patch");
    try repository.validatePatchEngineArgs(&quickjs_ng_args, true);
    try std.testing.expectError(error.Usage, repository.validatePatchEngineArgs(quickjs_ng_args[0..17], true));
    try std.testing.expectError(error.Usage, repository.validatePatchEngineArgs(&quickjs_args, true));
}

test "Hermes frame URL patch applies once and reverse detection succeeds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const patch_text = try Dir.cwd().readFileAlloc(io, "vendor/hermes-cdp-frame-url.patch", allocator, .unlimited);
    defer allocator.free(patch_text);
    const index_start = (std.mem.indexOf(u8, patch_text, "index ") orelse return error.MissingPatchIndex) + "index ".len;
    const index_end = std.mem.indexOfScalarPos(u8, patch_text, index_start, '\n') orelse return error.MissingPatchIndex;
    const index = patch_text[index_start..index_end];
    try std.testing.expect(std.mem.indexOf(u8, index, "0000000") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch_text, "+  result.url = callFrameInfo.location.fileName;") != null);

    var fixture = std.testing.tmpDir(.{});
    defer fixture.cleanup();
    try fixture.dir.createDirPath(io, "API/hermes/cdp");
    var source = std.Io.Writer.Allocating.init(allocator);
    for (0..167) |_| try source.writer.writeAll("placeholder\n");
    var lines = std.mem.splitScalar(u8, patch_text[std.mem.indexOf(u8, patch_text, "@@") orelse return error.MissingPatchHunk ..], '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0 or (line[0] != ' ' and line[0] != '-' and line[0] != '+')) break;
        if (line[0] != '+') {
            try source.writer.writeAll(line[1..]);
            try source.writer.writeAll("\n");
        }
    }
    try fixture.dir.writeFile(io, .{ .sub_path = "API/hermes/cdp/RemoteObjectConverters.cpp", .data = source.written() });
    try fixture.dir.writeFile(io, .{ .sub_path = "frame.patch", .data = patch_text });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture_path = path_buffer[0..try fixture.dir.realPath(io, &path_buffer)];
    const apply = try std.process.run(allocator, io, .{ .argv = &.{ "patch", "-p1", "--forward", "--batch", "-i", "frame.patch" }, .cwd = .{ .path = fixture_path } });
    if (!repository.successful(apply)) std.debug.print("patch apply failed: {s}{s}\n", .{ apply.stdout, apply.stderr });
    try std.testing.expect(switch (apply.term) {
        .exited => |code| code == 0,
        else => false,
    });
    const applied = try fixture.dir.readFileAlloc(io, "API/hermes/cdp/RemoteObjectConverters.cpp", allocator, .unlimited);
    defer allocator.free(applied);
    try std.testing.expect(std.mem.indexOf(u8, applied, "  result.url = callFrameInfo.location.fileName;\n") != null);
    const detect = try std.process.run(allocator, io, .{ .argv = &.{ "patch", "-p1", "--reverse", "--dry-run", "-i", "frame.patch" }, .cwd = .{ .path = fixture_path } });
    try std.testing.expect(switch (detect.term) {
        .exited => |code| code == 0,
        else => false,
    });
}

test "Hermes executable link flags add ICU rpath-link only on Linux" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const helper = try std.fs.path.resolve(allocator, &.{ try std.process.currentPathAlloc(std.testing.io, allocator), "scripts/hermes-cmake-linker-flags.sh" });
    var fixture = std.testing.tmpDir(.{});
    defer fixture.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture_path = path_buffer[0..try fixture.dir.realPath(std.testing.io, &path_buffer)];
    const cache_path = try std.fs.path.join(allocator, &.{ fixture_path, "CMakeCache.txt" });
    const cases = .{
        .{ .platform = "Linux", .icu = "/icu/prefix/lib", .cache = "CMAKE_EXE_LINKER_FLAGS:STRING=-Wl,--as-needed\n", .ldflags = "-pthread", .expected = "<-Wl,--as-needed>\n<-Wl,-rpath-link,/icu/prefix/lib>\n" },
        .{ .platform = "Linux", .icu = "/icu prefix/lib", .cache = "CMAKE_EXE_LINKER_FLAGS:STRING=-Wl,-rpath-link,/icu\\ prefix/lib -Wl,--as-needed\n", .ldflags = "-pthread", .expected = "<-Wl,-rpath-link,/icu prefix/lib>\n<-Wl,--as-needed>\n" },
        .{ .platform = "Linux", .icu = "/icu/prefix/lib", .cache = "", .ldflags = "-Wl,--as-needed -pthread", .expected = "<-Wl,--as-needed>\n<-pthread>\n<-Wl,-rpath-link,/icu/prefix/lib>\n" },
        .{ .platform = "Darwin", .icu = "/icu/prefix/lib", .cache = "CMAKE_EXE_LINKER_FLAGS:STRING=-Wl,--as-needed\n", .ldflags = "-pthread", .expected = "<-Wl,--as-needed>\n" },
        .{ .platform = "Darwin", .icu = "/icu/prefix/lib", .cache = "", .ldflags = "", .expected = "" },
    };
    inline for (cases) |case| {
        try fixture.dir.writeFile(std.testing.io, .{ .sub_path = "CMakeCache.txt", .data = case.cache });
        const result = try std.process.run(allocator, std.testing.io, .{
            .argv = &.{ "bash", "-c", "source \"$1\"; flags=$(hermes_cmake_exe_linker_flags_for_build \"$2\" \"$3\" \"$4\" \"$5\"); eval \"set -- $flags\"; if [[ $# -gt 0 ]]; then printf '<%s>\\n' \"$@\"; fi", "bash", helper, case.platform, case.icu, cache_path, case.ldflags },
        });
        try std.testing.expect(switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        });
        try std.testing.expectEqualStrings(case.expected, result.stdout);
    }
}
