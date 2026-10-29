//! Black-box contracts for the Apple static-archive command.
const std = @import("std");
const sdk = @import("sdk.zig");

const testing = std.testing;
const Dir = std.Io.Dir;
const ar_magic = "!<arch>\n";
const macho64_le = "\xcf\xfa\xed\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";

fn makeTemp(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var random: [12]u8 = undefined;
    io.random(&random);
    const path = try std.fmt.allocPrint(allocator, "/tmp/jsbay-apple-archive-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try Dir.cwd().createDir(io, path, .default_dir);
    return path;
}

fn appendMember(writer: *std.Io.Writer.Allocating, name: []const u8, contents: []const u8) !void {
    try writer.writer.print("{s:<16}{s:<12}{s:<6}{s:<6}{s:<8}{d:<10}`\n", .{ name, "0", "0", "0", "100644", contents.len });
    try writer.writer.writeAll(contents);
    if (contents.len % 2 != 0) try writer.writer.writeByte('\n');
}

fn writeArchive(io: std.Io, path: []const u8, members: []const struct { []const u8, []const u8 }) !void {
    var archive: std.Io.Writer.Allocating = .init(testing.allocator);
    defer archive.deinit();
    try archive.writer.writeAll(ar_magic);
    for (members) |member| try appendMember(&archive, member[0], member[1]);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = archive.written() });
}

fn runTool(allocator: std.mem.Allocator, io: std.Io, tool: []const u8, cwd: []const u8, args: []const []const u8) !sdk.Output {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ tool, "apple-archive" });
    try argv.appendSlice(allocator, args);
    return sdk.run(allocator, io, argv.items, cwd);
}

fn exitCode(output: sdk.Output) !u8 {
    return switch (output.result.term) {
        .exited => |code| code,
        else => error.UnexpectedTermination,
    };
}

fn appendBe32(writer: *std.Io.Writer.Allocating, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try writer.writer.writeAll(&bytes);
}

test "apple-archive check reports alignment and archive parse failures through the CLI" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(a, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try sdk.toolPath(a, io);
    const archive = try std.fs.path.join(a, &.{ root, "mixed.a" });
    try writeArchive(io, archive, &.{
        .{ "/", "symbol-table" },
        .{ "#1/20", "a-very-long-member.o" ++ macho64_le },
        .{ "//", "another-long-member.o/\n" },
        .{ "/0", macho64_le },
    });
    var checked = try runTool(a, io, tool, root, &.{ "check", "--json", archive });
    defer checked.deinit();
    try testing.expectEqual(@as(u8, 0), try exitCode(checked));
    try testing.expect(std.mem.indexOf(u8, checked.result.stdout, "\"name\":\"a-very-long-member.o\"") != null);
    try testing.expect(std.mem.indexOf(u8, checked.result.stdout, "\"data_offset\":160") != null);
    try testing.expect(std.mem.indexOf(u8, checked.result.stdout, "\"name\":\"another-long-member.o\"") != null);

    const misaligned = try std.fs.path.join(a, &.{ root, "misaligned.a" });
    try writeArchive(io, misaligned, &.{.{ "probe.o/", macho64_le }});
    var unaligned = try runTool(a, io, tool, root, &.{ "check", "--json", misaligned });
    defer unaligned.deinit();
    try testing.expectEqual(@as(u8, 1), try exitCode(unaligned));
    try testing.expect(std.mem.indexOf(u8, unaligned.result.stdout, "\"data_offset\":68") != null);
    try testing.expect(std.mem.indexOf(u8, unaligned.result.stdout, "\"aligned_8\":false") != null);

    const truncated = try std.fs.path.join(a, &.{ root, "truncated.a" });
    try Dir.cwd().writeFile(io, .{ .sub_path = truncated, .data = ar_magic ++ "short" });
    var invalid = try runTool(a, io, tool, root, &.{ "check", truncated });
    defer invalid.deinit();
    try testing.expectEqual(@as(u8, 2), try exitCode(invalid));
    try testing.expect(std.mem.indexOf(u8, invalid.result.stderr, "truncated") != null);
}

test "apple-archive extract writes numbered objects and refuses dropped members" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(a, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try sdk.toolPath(a, io);
    const archive = try std.fs.path.join(a, &.{ root, "objects.a" });
    const names = "gnu-object-one.o/\ngnu-object-two.o/\n";
    try writeArchive(io, archive, &.{
        .{ "/", "symbol-table" },
        .{ "//", names },
        .{ "/0", macho64_le ++ "one" },
        .{ "/18", macho64_le ++ "two" },
    });
    const objects = try std.fs.path.join(a, &.{ root, "objects" });
    const filelist = try std.fs.path.join(a, &.{ root, "objects.list" });
    var extracted = try runTool(a, io, tool, root, &.{ "extract", archive, objects, "--filelist", filelist });
    defer extracted.deinit();
    try testing.expectEqual(@as(u8, 0), try exitCode(extracted));
    const listed = try Dir.cwd().readFileAlloc(io, filelist, a, .limited(4096));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/00000.o\n{s}/00001.o\n", .{ objects, objects }), listed);
    try testing.expectEqualStrings(macho64_le ++ "one", try Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ objects, "00000.o" }), a, .limited(4096)));
    try testing.expectEqualStrings(macho64_le ++ "two", try Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ objects, "00001.o" }), a, .limited(4096)));

    const unsafe = try std.fs.path.join(a, &.{ root, "unsafe.a" });
    try writeArchive(io, unsafe, &.{ .{ "note.txt/", "not an object" }, .{ "good.o/", macho64_le } });
    var rejected = try runTool(a, io, tool, root, &.{ "extract", unsafe, try std.fs.path.join(a, &.{ root, "unsafe" }), "--filelist", try std.fs.path.join(a, &.{ root, "unsafe.list" }) });
    defer rejected.deinit();
    try testing.expectEqual(@as(u8, 2), try exitCode(rejected));
    try testing.expect(std.mem.indexOf(u8, rejected.result.stderr, "refusing to drop non-Mach-O") != null);
}

test "apple-archive checks GNU members inside universal archives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const root = try makeTemp(a, io);
    defer Dir.cwd().deleteTree(io, root) catch {};
    const tool = try sdk.toolPath(a, io);
    var slice: std.Io.Writer.Allocating = .init(a);
    defer slice.deinit();
    try slice.writer.writeAll(ar_magic);
    try appendMember(&slice, "/", "symbol-table");
    try appendMember(&slice, "//", "gnu-long-member-name.o/\n");
    try appendMember(&slice, "/0", macho64_le);
    var fat: std.Io.Writer.Allocating = .init(a);
    defer fat.deinit();
    try fat.writer.writeAll("\xca\xfe\xba\xbe");
    try appendBe32(&fat, 1);
    try appendBe32(&fat, 0x0100000c);
    try appendBe32(&fat, 0);
    try appendBe32(&fat, 4096);
    try appendBe32(&fat, @intCast(slice.written().len));
    try appendBe32(&fat, 12);
    while (fat.written().len < 4096) try fat.writer.writeByte(0);
    try fat.writer.writeAll(slice.written());
    const archive = try std.fs.path.join(a, &.{ root, "universal.a" });
    try Dir.cwd().writeFile(io, .{ .sub_path = archive, .data = fat.written() });
    var checked = try runTool(a, io, tool, root, &.{ "check", "--json", archive });
    defer checked.deinit();
    try testing.expectEqual(@as(u8, 0), try exitCode(checked));
    try testing.expect(std.mem.indexOf(u8, checked.result.stdout, "100000c:0/gnu-long-member-name.o") != null);
    try testing.expect(std.mem.indexOf(u8, checked.result.stdout, "\"aligned_8\":true") != null);
}
