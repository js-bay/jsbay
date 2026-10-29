//! Inspect and safely extract Mach-O objects from Apple `ar` archives.
const std = @import("std");

const Dir = std.Io.Dir;
const ar_magic = "!<arch>\n";
const header_size = 60;

const Member = struct {
    name: []const u8,
    name_owned: bool = false,
    header_offset: usize,
    payload_offset: usize,
    data_offset: usize,
    size: usize,
    data_size: usize,
    kind: Kind,
    aligned_8: ?bool,
};

const Kind = enum { metadata, macho, other };

const ArchiveError = error{
    MissingArHeader,
    TruncatedMemberHeader,
    InvalidMemberTrailer,
    InvalidMemberSize,
    PayloadOutsideArchive,
    InvalidBsdNameLength,
    BsdNameOutsidePayload,
    GnuNameBeforeTable,
    InvalidGnuReference,
    GnuNameOutsideTable,
    UnterminatedGnuName,
    TruncatedUniversalHeader,
    InvalidUniversalCount,
    DuplicateArchitecture,
    InvalidUniversalSlice,
    OverlappingUniversalSlices,
    UniversalSliceWithoutMachO,
};

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (args.len == 0) return error.Usage;
    if (std.mem.eql(u8, args[0], "check")) return check(init, args[1..]);
    if (std.mem.eql(u8, args[0], "extract")) return extract(init, args[1..]);
    return error.Usage;
}

fn check(init: std.process.Init, args: []const []const u8) !void {
    var as_json = false;
    var archive_path: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json") and !as_json) as_json = true else if (archive_path == null) archive_path = arg else return error.Usage;
    }
    const path = archive_path orelse return error.Usage;
    const members = parsePath(init, path) catch |err| return reportError(init, "check", err);
    if (!hasMachO(members)) return reportError(init, "check", error.NoMachOMembers);
    if (as_json) try writeJson(init, path, members) else try writeCheck(init, path, members);
    for (members) |member| if (member.kind == .macho and !member.aligned_8.?) return error.PolicyFailure;
}

fn extract(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 4 or !std.mem.eql(u8, args[2], "--filelist")) return error.Usage;
    const archive_path = args[0];
    const output_dir = args[1];
    const filelist = args[3];
    const raw = Dir.cwd().readFileAlloc(init.io, archive_path, init.arena.allocator(), .limited(512 * 1024 * 1024)) catch |err| return reportError(init, "extract", err);
    const members = parse(raw, init.arena.allocator()) catch |err| return reportError(init, "extract", err);
    if (!hasMachO(members)) return reportError(init, "extract", error.NoMachOMembers);
    for (members) |member| if (member.kind == .other) {
        try stderr(init, "apple archive extract: refusing to drop non-Mach-O archive members: {s}\n", .{member.name});
        return error.InvalidExtraction;
    };
    try Dir.cwd().createDirPath(init.io, output_dir);
    var objects_dir = try Dir.cwd().openDir(init.io, output_dir, .{});
    defer objects_dir.close(init.io);
    var names: std.Io.Writer.Allocating = .init(init.arena.allocator());
    var index: usize = 0;
    for (members) |member| {
        if (member.kind != .macho) continue;
        var basename: [16]u8 = undefined;
        const object_name = try std.fmt.bufPrint(&basename, "{d:0>5}.o", .{index});
        var object = objects_dir.createFile(init.io, object_name, .{ .exclusive = true, .resolve_beneath = true }) catch |err| return reportError(init, "extract", err);
        defer object.close(init.io);
        try object.writeStreamingAll(init.io, raw[member.data_offset .. member.data_offset + member.data_size]);
        const name = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}", .{ output_dir, object_name });
        try names.writer.print("{s}\n", .{name});
        index += 1;
    }
    try Dir.cwd().writeFile(init.io, .{ .sub_path = filelist, .data = names.written() });
}

fn parsePath(init: std.process.Init, path: []const u8) ![]Member {
    const data = try Dir.cwd().readFileAlloc(init.io, path, init.arena.allocator(), .limited(512 * 1024 * 1024));
    return parse(data, init.arena.allocator());
}

fn parse(data: []const u8, allocator: std.mem.Allocator) ![]Member {
    if (isFatMagic(data)) return parseUniversal(data, allocator);
    return parseAr(data, allocator);
}

fn parseUniversal(data: []const u8, allocator: std.mem.Allocator) ![]Member {
    if (data.len < 8) return error.TruncatedUniversalHeader;
    const little = std.mem.eql(u8, data[0..4], "\xbe\xba\xfe\xca") or std.mem.eql(u8, data[0..4], "\xbf\xba\xfe\xca");
    const wide = std.mem.eql(u8, data[0..4], "\xca\xfe\xba\xbf") or std.mem.eql(u8, data[0..4], "\xbf\xba\xfe\xca");
    const count = read32(data[4..8], little);
    const entry_size: usize = if (wide) 32 else 20;
    const header_end = std.math.mul(usize, count, entry_size) catch return error.InvalidUniversalCount;
    if (count == 0 or header_end > data.len - 8) return error.InvalidUniversalCount;
    var members: std.ArrayList(Member) = .empty;
    defer members.deinit(allocator);
    var ranges: std.ArrayList(struct { start: usize, end: usize }) = .empty;
    defer ranges.deinit(allocator);
    var architectures: std.AutoHashMap(struct { cpu: u32, subtype: u32 }, void) = .init(allocator);
    defer architectures.deinit();
    errdefer deinitMembers(allocator, members.items);
    for (0..count) |index| {
        const entry = data[8 + index * entry_size .. 8 + (index + 1) * entry_size];
        const cpu = read32(entry[0..4], little);
        const subtype = read32(entry[4..8], little);
        const offset: usize = if (wide) read64(entry[8..16], little) else read32(entry[8..12], little);
        const size: usize = if (wide) read64(entry[16..24], little) else read32(entry[12..16], little);
        const alignment: usize = if (wide) read32(entry[24..28], little) else read32(entry[16..20], little);
        if (architectures.contains(.{ .cpu = cpu, .subtype = subtype })) return error.DuplicateArchitecture;
        try architectures.put(.{ .cpu = cpu, .subtype = subtype }, {});
        const end = std.math.add(usize, offset, size) catch return error.InvalidUniversalSlice;
        if (alignment > 63 or size == 0 or offset < 8 + header_end or end > data.len or offset % (@as(usize, 1) << @intCast(alignment)) != 0) return error.InvalidUniversalSlice;
        for (ranges.items) |range| if (offset < range.end and range.start < end) return error.OverlappingUniversalSlices;
        try ranges.append(allocator, .{ .start = offset, .end = end });
        const slice_members = try parseAr(data[offset..end], allocator);
        defer allocator.free(slice_members);
        if (!hasMachO(slice_members)) return error.UniversalSliceWithoutMachO;
        for (slice_members) |member| {
            const name = try std.fmt.allocPrint(allocator, "{x}:{x}/{s}", .{ cpu, subtype, member.name });
            try members.append(allocator, .{ .name = name, .name_owned = true, .header_offset = member.header_offset + offset, .payload_offset = member.payload_offset + offset, .data_offset = member.data_offset + offset, .size = member.size, .data_size = member.data_size, .kind = member.kind, .aligned_8 = if (member.kind == .macho) (member.data_offset + offset) % 8 == 0 else null });
        }
    }
    return members.toOwnedSlice(allocator);
}

fn parseAr(data: []const u8, allocator: std.mem.Allocator) ![]Member {
    if (!std.mem.startsWith(u8, data, ar_magic)) return error.MissingArHeader;
    var result: std.ArrayList(Member) = .empty;
    var gnu_names: ?[]const u8 = null;
    var offset: usize = ar_magic.len;
    while (offset < data.len) {
        if (data.len - offset < header_size) return error.TruncatedMemberHeader;
        const header = data[offset .. offset + header_size];
        if (!std.mem.eql(u8, header[58..60], "`\n")) return error.InvalidMemberTrailer;
        const size = try decimal(header[48..58]);
        const payload = offset + header_size;
        const end = std.math.add(usize, payload, size) catch return error.PayloadOutsideArchive;
        if (end > data.len) return error.PayloadOutsideArchive;
        const raw_name = std.mem.trimEnd(u8, header[0..16], " ");
        var data_offset = payload;
        var name: []const u8 = raw_name;
        if (std.mem.startsWith(u8, raw_name, "#1/")) {
            const length = decimal(raw_name[3..]) catch return error.InvalidBsdNameLength;
            if (length > size) return error.BsdNameOutsidePayload;
            name = std.mem.trimEnd(u8, data[payload .. payload + length], "\x00");
            data_offset += length;
        } else if (raw_name.len > 1 and raw_name[0] == '/' and !std.mem.eql(u8, raw_name, "//")) {
            const table = gnu_names orelse return error.GnuNameBeforeTable;
            const position = decimal(raw_name[1..]) catch return error.InvalidGnuReference;
            if (position >= table.len) return error.GnuNameOutsideTable;
            const tail = table[position..];
            const newline = std.mem.indexOfScalar(u8, tail, '\n') orelse return error.UnterminatedGnuName;
            name = std.mem.trimEnd(u8, tail[0..newline], "/");
        } else if (!std.mem.eql(u8, raw_name, "/") and !std.mem.eql(u8, raw_name, "//")) name = std.mem.trimEnd(u8, raw_name, "/");
        const contents = data[data_offset..end];
        const kind: Kind = if (std.mem.eql(u8, raw_name, "//")) .metadata else if (std.mem.eql(u8, raw_name, "/") or std.mem.startsWith(u8, name, "__.SYMDEF")) .metadata else if (isMachO(contents)) .macho else .other;
        if (std.mem.eql(u8, raw_name, "//")) gnu_names = contents;
        try result.append(allocator, .{ .name = name, .header_offset = offset, .payload_offset = payload, .data_offset = data_offset, .size = size, .data_size = end - data_offset, .kind = kind, .aligned_8 = if (kind == .macho) data_offset % 8 == 0 else null });
        offset = end + (size % 2);
    }
    return result.toOwnedSlice(allocator);
}

fn decimal(field: []const u8) !usize {
    const text = std.mem.trim(u8, field, " ");
    if (text.len == 0) return error.InvalidMemberSize;
    var result: usize = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidMemberSize;
        result = std.math.mul(usize, result, 10) catch return error.InvalidMemberSize;
        result = std.math.add(usize, result, byte - '0') catch return error.InvalidMemberSize;
    }
    return result;
}

fn isFatMagic(data: []const u8) bool {
    return data.len >= 4 and (std.mem.eql(u8, data[0..4], "\xca\xfe\xba\xbe") or std.mem.eql(u8, data[0..4], "\xbe\xba\xfe\xca") or std.mem.eql(u8, data[0..4], "\xca\xfe\xba\xbf") or std.mem.eql(u8, data[0..4], "\xbf\xba\xfe\xca"));
}
fn isMachO(data: []const u8) bool {
    return data.len >= 4 and (std.mem.eql(u8, data[0..4], "\xcf\xfa\xed\xfe") or std.mem.eql(u8, data[0..4], "\xfe\xed\xfa\xcf") or std.mem.eql(u8, data[0..4], "\xce\xfa\xed\xfe") or std.mem.eql(u8, data[0..4], "\xfe\xed\xfa\xce") or isFatMagic(data));
}
fn hasMachO(members: []const Member) bool {
    for (members) |member| if (member.kind == .macho) return true;
    return false;
}
fn deinitMembers(allocator: std.mem.Allocator, members: []const Member) void {
    for (members) |member| if (member.name_owned) allocator.free(member.name);
}
fn read32(data: []const u8, little: bool) u32 {
    return if (little) std.mem.readInt(u32, data[0..4], .little) else std.mem.readInt(u32, data[0..4], .big);
}
fn read64(data: []const u8, little: bool) usize {
    const value = if (little) std.mem.readInt(u64, data[0..8], .little) else std.mem.readInt(u64, data[0..8], .big);
    return @intCast(value);
}

fn writeCheck(init: std.process.Init, path: []const u8, members: []const Member) !void {
    for (members) |member| if (member.kind == .macho) try stdout(init, "{s}: {s}: {s}: Mach-O offset {d}\n", .{ path, if (member.aligned_8.?) "ok" else "MISALIGNED", member.name, member.data_offset });
}
fn writeJson(init: std.process.Init, path: []const u8, members: []const Member) !void {
    var writer: std.Io.Writer.Allocating = .init(init.arena.allocator());
    try writer.writer.print("{{\n  \"archive\": ", .{});
    try jsonString(&writer, path);
    try writer.writer.writeAll(",\n  \"members\": [");
    for (members, 0..) |member, i| {
        if (i != 0) try writer.writer.writeAll(",");
        try writer.writer.writeAll("\n    ");
        try jsonMember(&writer, member);
    }
    try writer.writer.writeAll("\n  ],\n  \"macho_members\": [");
    var first = true;
    for (members) |member| {
        if (member.kind != .macho) continue;
        if (!first) try writer.writer.writeAll(",");
        first = false;
        try writer.writer.writeAll("\n    ");
        try jsonMember(&writer, member);
    }
    try writer.writer.writeAll("\n  ]\n}\n");
    try std.Io.File.stdout().writeStreamingAll(init.io, writer.written());
}
fn jsonMember(writer: *std.Io.Writer.Allocating, member: Member) !void {
    try writer.writer.writeAll("{\"aligned_8\":");
    if (member.aligned_8) |aligned| try writer.writer.writeAll(if (aligned) "true" else "false") else try writer.writer.writeAll("null");
    try writer.writer.writeAll(",\"data_offset\":");
    try writer.writer.print("{d}", .{member.data_offset});
    try writer.writer.writeAll(",\"data_size\":");
    try writer.writer.print("{d}", .{member.data_size});
    try writer.writer.writeAll(",\"header_offset\":");
    try writer.writer.print("{d}", .{member.header_offset});
    try writer.writer.writeAll(",\"kind\":");
    try jsonString(writer, @tagName(member.kind));
    try writer.writer.writeAll(",\"name\":");
    try jsonString(writer, member.name);
    try writer.writer.writeAll(",\"payload_offset\":");
    try writer.writer.print("{d}", .{member.payload_offset});
    try writer.writer.writeAll(",\"size\":");
    try writer.writer.print("{d}", .{member.size});
    try writer.writer.writeAll("}");
}
fn jsonString(writer: *std.Io.Writer.Allocating, value: []const u8) !void {
    try writer.writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writer.writeAll("\\\""),
        '\\' => try writer.writer.writeAll("\\\\"),
        '\n' => try writer.writer.writeAll("\\n"),
        '\r' => try writer.writer.writeAll("\\r"),
        '\t' => try writer.writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.writer.print("\\u00{x:0>2}", .{byte}) else try writer.writer.writeByte(byte),
    };
    try writer.writer.writeByte('"');
}
fn stdout(init: std.process.Init, comptime format: []const u8, args: anytype) !void {
    var writer: std.Io.Writer.Allocating = .init(init.arena.allocator());
    try writer.writer.print(format, args);
    try std.Io.File.stdout().writeStreamingAll(init.io, writer.written());
}
fn stderr(init: std.process.Init, comptime format: []const u8, args: anytype) !void {
    var writer: std.Io.Writer.Allocating = .init(init.arena.allocator());
    try writer.writer.print(format, args);
    try std.Io.File.stderr().writeStreamingAll(init.io, writer.written());
}
fn reportError(init: std.process.Init, command: []const u8, err: anyerror) !void {
    const message: []const u8 = switch (err) {
        error.NoMachOMembers => "archive has no Mach-O members",
        error.TruncatedMemberHeader => "truncated member header",
        error.PayloadOutsideArchive => "member payload exceeds archive size",
        error.TruncatedUniversalHeader => "truncated universal archive header",
        error.InvalidUniversalCount => "invalid universal archive architecture count",
        error.OverlappingUniversalSlices => "overlapping universal archive slices",
        error.InvalidUniversalSlice => "invalid universal archive slice bounds or alignment",
        else => @errorName(err),
    };
    try stderr(init, "apple archive {s}: {s}\n", .{ command, message });
    return err;
}

fn appendMember(writer: *std.Io.Writer.Allocating, name: []const u8, contents: []const u8) !void {
    try writer.writer.print("{s:<16}{s:<12}{s:<6}{s:<6}{s:<8}{d:<10}`\n", .{ name, "0", "0", "0", "100644", contents.len });
    try writer.writer.writeAll(contents);
    if (contents.len % 2 != 0) try writer.writer.writeByte('\n');
}

const macho64_le = "\xcf\xfa\xed\xfe\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";

test "BSD and GNU names retain payload offsets" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try bytes.writer.writeAll(ar_magic);
    try appendMember(&bytes, "/", "symbol-table");
    try appendMember(&bytes, "#1/20", "a-very-long-member.o" ++ macho64_le);
    try appendMember(&bytes, "//", "another-long-member.o/\n");
    try appendMember(&bytes, "/0", macho64_le);
    const members = try parseAr(bytes.written(), std.testing.allocator);
    defer {
        deinitMembers(std.testing.allocator, members);
        std.testing.allocator.free(members);
    }
    try std.testing.expectEqual(@as(usize, 4), members.len);
    try std.testing.expectEqualStrings("a-very-long-member.o", members[1].name);
    try std.testing.expectEqual(@as(usize, 8 + 60 + 12 + 60 + 20), members[1].data_offset);
    try std.testing.expectEqualStrings("another-long-member.o", members[3].name);
    try std.testing.expect(members[1].kind == .macho and members[3].kind == .macho);
}

test "misaligned ar member is identified while BSD prefix can align it" {
    var misaligned: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer misaligned.deinit();
    try misaligned.writer.writeAll(ar_magic);
    try appendMember(&misaligned, "probe.o/", macho64_le);
    const bad = try parseAr(misaligned.written(), std.testing.allocator);
    defer {
        deinitMembers(std.testing.allocator, bad);
        std.testing.allocator.free(bad);
    }
    try std.testing.expectEqual(@as(usize, 68), bad[0].data_offset);
    try std.testing.expectEqual(false, bad[0].aligned_8.?);

    var aligned: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aligned.deinit();
    try aligned.writer.writeAll(ar_magic);
    try appendMember(&aligned, "#1/4", "foo\x00" ++ macho64_le);
    const good = try parseAr(aligned.written(), std.testing.allocator);
    defer {
        deinitMembers(std.testing.allocator, good);
        std.testing.allocator.free(good);
    }
    try std.testing.expectEqual(@as(usize, 72), good[0].data_offset);
    try std.testing.expectEqual(true, good[0].aligned_8.?);
}

test "rejects truncated members and oversized payloads" {
    try std.testing.expectError(error.TruncatedMemberHeader, parseAr(ar_magic ++ "short", std.testing.allocator));
    var data: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data.deinit();
    try data.writer.writeAll(ar_magic);
    try data.writer.print("{s:<16}{s:<12}{s:<6}{s:<6}{s:<8}{s:<10}`\n", .{ "probe.o/", "0", "0", "0", "100644", "32" });
    try std.testing.expectError(error.PayloadOutsideArchive, parseAr(data.written(), std.testing.allocator));
}

test "rejects overlapping and unaligned universal slices" {
    var ar: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ar.deinit();
    try ar.writer.writeAll(ar_magic);
    try appendMember(&ar, "#1/4", "obj\x00" ++ macho64_le);
    var fat: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fat.deinit();
    try fat.writer.writeAll("\xca\xfe\xba\xbe");
    try appendBe32(&fat, 2);
    try appendBe32(&fat, 0x0100000c);
    try appendBe32(&fat, 0);
    try appendBe32(&fat, 4096);
    try appendBe32(&fat, @intCast(ar.written().len));
    try appendBe32(&fat, 12);
    try appendBe32(&fat, 0x01000007);
    try appendBe32(&fat, 3);
    try appendBe32(&fat, 4096);
    try appendBe32(&fat, @intCast(ar.written().len));
    try appendBe32(&fat, 12);
    while (fat.written().len < 4096) try fat.writer.writeByte(0);
    try fat.writer.writeAll(ar.written());
    try std.testing.expectError(error.OverlappingUniversalSlices, parseUniversal(fat.written(), std.testing.allocator));
}

test "universal archives inspect every architecture" {
    var aligned: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aligned.deinit();
    try aligned.writer.writeAll(ar_magic);
    try appendMember(&aligned, "#1/4", "obj\x00" ++ macho64_le);
    var misaligned: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer misaligned.deinit();
    try misaligned.writer.writeAll(ar_magic);
    try appendMember(&misaligned, "obj.o/", macho64_le);
    var fat: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fat.deinit();
    try fat.writer.writeAll("\xca\xfe\xba\xbe");
    try appendBe32(&fat, 2);
    try appendFatEntry(&fat, 0x0100000c, 0, 4096, @intCast(aligned.written().len), 12);
    try appendFatEntry(&fat, 0x01000007, 3, 8192, @intCast(misaligned.written().len), 12);
    while (fat.written().len < 4096) try fat.writer.writeByte(0);
    try fat.writer.writeAll(aligned.written());
    while (fat.written().len < 8192) try fat.writer.writeByte(0);
    try fat.writer.writeAll(misaligned.written());
    const members = try parseUniversal(fat.written(), std.testing.allocator);
    defer {
        deinitMembers(std.testing.allocator, members);
        std.testing.allocator.free(members);
    }
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqual(true, members[0].aligned_8.?);
    try std.testing.expectEqual(false, members[1].aligned_8.?);
    try std.testing.expectEqualStrings("100000c:0/obj", members[0].name);
    try std.testing.expectEqualStrings("1000007:3/obj.o", members[1].name);
}

test "rejects universal slice outside the input" {
    const bad = "\xca\xfe\xba\xbe\x00\x00\x00\x01\x01\x00\x00\x0c\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x80\x00\x00\x00\x0c";
    try std.testing.expectError(error.InvalidUniversalSlice, parseUniversal(bad, std.testing.allocator));
}

fn appendBe32(writer: *std.Io.Writer.Allocating, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try writer.writer.writeAll(&bytes);
}

fn appendFatEntry(writer: *std.Io.Writer.Allocating, cpu: u32, subtype: u32, offset: u32, size: u32, alignment: u32) !void {
    try appendBe32(writer, cpu);
    try appendBe32(writer, subtype);
    try appendBe32(writer, offset);
    try appendBe32(writer, size);
    try appendBe32(writer, alignment);
}
