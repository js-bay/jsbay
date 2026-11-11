//! Binary property-list support for the WebKit Inspector Relay envelope.
//!
//! The relay transports JSON protocol messages inside `WIRSocketDataKey` data values, but the
//! envelope itself (message name plus user info) is a binary plist. The bridge needs only the
//! value kinds the relay uses: dictionaries, arrays, strings, integers, booleans, data, real
//! numbers, dates, and UIDs. Unsupported object kinds are reported as invalid input.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidPlist,
    Truncated,
    UnsupportedVersion,
    DepthLimit,
    OutOfMemory,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    date: f64,
    string: []const u8,
    data: []const u8,
    array: []const Value,
    dict: []const Entry,
    uid: u64,

    pub fn get(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .dict => |entries| for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return entry.value;
            } else null,
            else => null,
        };
    }

    pub fn getString(self: Value, key: []const u8) ?[]const u8 {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .string => |text| text,
            else => null,
        };
    }

    pub fn getInt(self: Value, key: []const u8) ?i64 {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .integer => |number| number,
            else => null,
        };
    }

    pub fn getBool(self: Value, key: []const u8) ?bool {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .boolean => |flag| flag,
            else => null,
        };
    }
};

const max_depth: u8 = 64;
const max_objects: u64 = 1 << 20;
const trailer_size: usize = 32;

/// Parses a binary plist. All strings, data blobs, and containers are allocated from `allocator`.
pub fn parse(allocator: Allocator, bytes: []const u8) Error!Value {
    if (bytes.len < 8 + trailer_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], "bplist00")) return error.UnsupportedVersion;

    const trailer = bytes[bytes.len - trailer_size ..];
    const offset_size = trailer[6];
    const ref_size = trailer[7];
    if (offset_size == 0 or offset_size > 8 or ref_size == 0 or ref_size > 8) return error.InvalidPlist;

    const object_count = readUInt(trailer[8..16]);
    const top_object = readUInt(trailer[16..24]);
    const table_offset = readUInt(trailer[24..32]);
    if (object_count == 0 or object_count > max_objects) return error.InvalidPlist;
    if (top_object >= object_count) return error.InvalidPlist;

    const table_start: usize = @intCast(table_offset);
    const table_len = std.math.mul(usize, @intCast(object_count), offset_size) catch return error.InvalidPlist;
    if (table_start > bytes.len - trailer_size or table_len > bytes.len - trailer_size - table_start) return error.InvalidPlist;

    var parser = Parser{
        .cache = .empty,
        .allocator = allocator,
        .bytes = bytes,
        .offset_size = offset_size,
        .ref_size = ref_size,
        .object_count = object_count,
        .table_start = table_start,
    };
    defer parser.cache.deinit(allocator);
    return parser.object(top_object, 0);
}

const Parser = struct {
    /// Objects that were already built. A plist may reference one object from several containers, and without this a diamond of references would cost exponential time.
    cache: std.AutoHashMapUnmanaged(u64, Value),
    allocator: Allocator,
    bytes: []const u8,
    offset_size: u8,
    ref_size: u8,
    object_count: u64,
    table_start: usize,

    fn objectOffset(self: Parser, index: u64) Error!usize {
        if (index >= self.object_count) return error.InvalidPlist;
        const entry = self.table_start + @as(usize, @intCast(index)) * self.offset_size;
        const offset = readUInt(self.bytes[entry .. entry + self.offset_size]);
        if (offset >= self.table_start) return error.InvalidPlist;
        return @intCast(offset);
    }

    fn object(self: *Parser, index: u64, depth: u8) Error!Value {
        if (self.cache.get(index)) |cached| return cached;
        const value = try self.objectBody(index, depth);
        self.cache.put(self.allocator, index, value) catch {};
        return value;
    }

    fn objectBody(self: *Parser, index: u64, depth: u8) Error!Value {
        if (depth > max_depth) return error.DepthLimit;
        const offset = try self.objectOffset(index);
        if (offset >= self.bytes.len) return error.Truncated;
        var cursor = offset;
        const marker = self.bytes[cursor];
        cursor += 1;
        const kind = marker >> 4;
        const low = marker & 0x0F;

        const value: Error!Value = switch (kind) {
            0x0 => return switch (low) {
                0x0 => .null,
                0x8 => .{ .boolean = false },
                0x9 => .{ .boolean = true },
                else => error.InvalidPlist,
            },
            0x1 => {
                const size = intSize(low) orelse return error.InvalidPlist;
                const raw = try self.take(&cursor, size);
                return .{ .integer = signedBigEndian(raw) };
            },
            0x2 => return switch (low) {
                0x2 => .{ .real = @floatCast(@as(f32, @bitCast(@as(u32, @intCast(readUInt(try self.take(&cursor, 4))))))) },
                0x3 => .{ .real = @bitCast(readUInt(try self.take(&cursor, 8))) },
                else => error.InvalidPlist,
            },
            0x3 => {
                if (low != 0x3) return error.InvalidPlist;
                return .{ .date = @bitCast(readUInt(try self.take(&cursor, 8))) };
            },
            0x4 => {
                const byte_count = try self.length(low, &cursor);
                return .{ .data = try self.allocator.dupe(u8, try self.take(&cursor, byte_count)) };
            },
            0x5 => {
                const byte_count = try self.length(low, &cursor);
                return .{ .string = try self.allocator.dupe(u8, try self.take(&cursor, byte_count)) };
            },
            0x6 => {
                const units = try self.length(low, &cursor);
                const raw = try self.take(&cursor, std.math.mul(usize, units, 2) catch return error.InvalidPlist);
                return .{ .string = try decodeUtf16(self.allocator, raw) };
            },
            0x8 => {
                const size: usize = @as(usize, low) + 1;
                return .{ .uid = readUInt(try self.take(&cursor, size)) };
            },
            0xA => {
                const count = try self.length(low, &cursor);
                const items = try self.allocator.alloc(Value, count);
                errdefer self.allocator.free(items);
                for (items) |*item| item.* = try self.object(try self.ref(&cursor), depth + 1);
                return .{ .array = items };
            },
            0xB, 0xC => return error.InvalidPlist,
            0xD => {
                const count = try self.length(low, &cursor);
                const keys = try self.allocator.alloc([]const u8, count);
                defer self.allocator.free(keys);
                const entries = try self.allocator.alloc(Entry, count);
                errdefer self.allocator.free(entries);
                for (keys) |*key| {
                    const value = try self.object(try self.ref(&cursor), depth + 1);
                    key.* = switch (value) {
                        .string => |text| text,
                        else => return error.InvalidPlist,
                    };
                }
                for (entries, keys) |*entry, key| entry.* = .{ .key = key, .value = try self.object(try self.ref(&cursor), depth + 1) };
                return .{ .dict = entries };
            },
            else => return error.InvalidPlist,
        };
        return value;
    }

    fn length(self: Parser, low: u8, cursor: *usize) Error!usize {
        if (low != 0x0F) return low;
        const marker = self.bytes[cursor.*];
        if ((marker >> 4) != 0x1) return error.InvalidPlist;
        cursor.* += 1;
        const size = intSize(marker & 0x0F) orelse return error.InvalidPlist;
        const raw = try self.take(cursor, size);
        return @intCast(readUInt(raw));
    }

    fn ref(self: Parser, cursor: *usize) Error!u64 {
        return readUInt(try self.take(cursor, self.ref_size));
    }

    fn take(self: Parser, cursor: *usize, count: usize) Error![]const u8 {
        if (cursor.* > self.bytes.len or count > self.bytes.len - cursor.*) return error.Truncated;
        const slice = self.bytes[cursor.* .. cursor.* + count];
        cursor.* += count;
        return slice;
    }
};

fn intSize(low: u8) ?usize {
    return switch (low) {
        0x0 => 1,
        0x1 => 2,
        0x2 => 4,
        0x3 => 8,
        else => null,
    };
}

fn signedBigEndian(raw: []const u8) i64 {
    return switch (raw.len) {
        1 => @as(i64, @as(i8, @bitCast(raw[0]))),
        2 => @as(i64, @as(i16, @bitCast(std.mem.readInt(u16, raw[0..2], .big)))),
        4 => @as(i64, @as(i32, @bitCast(std.mem.readInt(u32, raw[0..4], .big)))),
        8 => @bitCast(std.mem.readInt(u64, raw[0..8], .big)),
        else => 0,
    };
}

fn readUInt(raw: []const u8) u64 {
    var value: u64 = 0;
    for (raw) |byte| value = (value << 8) | byte;
    return value;
}

fn decodeUtf16(allocator: Allocator, raw: []const u8) Error![]const u8 {
    if (raw.len % 2 != 0) return error.InvalidPlist;
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < raw.len) {
        const unit = readUInt(raw[index .. index + 2]);
        index += 2;
        var code: u21 = @intCast(unit);
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (index >= raw.len) return error.InvalidPlist;
            const low = readUInt(raw[index .. index + 2]);
            index += 2;
            if (low < 0xDC00 or low > 0xDFFF) return error.InvalidPlist;
            code = 0x10000 + ((@as(u21, @intCast(unit - 0xD800)) << 10) | @as(u21, @intCast(low - 0xDC00)));
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            return error.InvalidPlist;
        }
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code, &buffer) catch return error.InvalidPlist;
        try out.appendSlice(allocator, buffer[0..length]);
    }
    return out.toOwnedSlice(allocator);
}

/// Encodes a binary plist. The returned slice is allocated from `allocator` and owned by the caller.
pub fn encode(allocator: Allocator, value: Value) Error![]u8 {
    var encoder = Encoder{ .allocator = allocator };
    defer encoder.deinit();
    const top = try encoder.add(value);
    return encoder.finish(top);
}

const Ref = u32;
const DictRefs = struct {
    keys: []Ref,
    values: []Ref,
};

const Node = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    string: []const u8,
    data: []const u8,
    array: []Ref,
    dict: DictRefs,
    uid: u64,
};

const Encoder = struct {
    allocator: Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,

    fn deinit(self: *Encoder) void {
        for (self.nodes.items) |node| switch (node) {
            .array => |refs| self.allocator.free(refs),
            .dict => |dict| {
                self.allocator.free(dict.keys);
                self.allocator.free(dict.values);
            },
            else => {},
        };
        self.nodes.deinit(self.allocator);
    }

    fn add(self: *Encoder, value: Value) Error!Ref {
        const index: Ref = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .null);
        errdefer _ = self.nodes.pop();
        // Evaluate the node before touching `items`: recursive `add` calls may grow and reallocate the list, so the placeholder must be written back through a fresh view.
        const node: Node = switch (value) {
            .null => .null,
            .boolean => |flag| .{ .boolean = flag },
            .integer => |number| .{ .integer = number },
            .real => |number| .{ .real = number },
            .date => |number| .{ .real = number },
            .string => |text| .{ .string = text },
            .data => |bytes| .{ .data = bytes },
            .uid => |id| .{ .uid = id },
            .array => |items| blk: {
                const refs = try self.allocator.alloc(Ref, items.len);
                errdefer self.allocator.free(refs);
                for (items, 0..) |item, i| refs[i] = try self.add(item);
                break :blk .{ .array = refs };
            },
            .dict => |entries| blk: {
                const keys = try self.allocator.alloc(Ref, entries.len);
                errdefer self.allocator.free(keys);
                const values = try self.allocator.alloc(Ref, entries.len);
                errdefer self.allocator.free(values);
                for (entries, 0..) |entry, i| {
                    keys[i] = try self.add(.{ .string = entry.key });
                    values[i] = try self.add(entry.value);
                }
                break :blk .{ .dict = .{ .keys = keys, .values = values } };
            },
        };
        self.nodes.items[index] = node;
        return index;
    }

    fn finish(self: *Encoder, top: Ref) Error![]u8 {
        const count = self.nodes.items.len;
        const ref_size: u8 = bytesNeeded(count);
        var encoded = try self.allocator.alloc([]u8, count);
        defer {
            for (encoded) |bytes| self.allocator.free(bytes);
            self.allocator.free(encoded);
        }
        var body_len: usize = 0;
        for (self.nodes.items, 0..) |node, i| {
            encoded[i] = try self.encodeNode(node, ref_size);
            body_len = std.math.add(usize, body_len, encoded[i].len) catch return error.InvalidPlist;
        }

        var offset_size: u8 = 1;
        while (offset_size < 8) : (offset_size += 1) {
            const candidate_table_len = std.math.mul(usize, count, offset_size) catch return error.InvalidPlist;
            var candidate_total = std.math.add(usize, body_len, candidate_table_len) catch return error.InvalidPlist;
            candidate_total = std.math.add(usize, candidate_total, 8 + trailer_size) catch return error.InvalidPlist;
            if (candidate_total <= maxForSize(offset_size)) break;
        }

        const header_len: usize = 8;
        const table_offset = header_len + body_len;
        const table_len = std.math.mul(usize, count, offset_size) catch return error.InvalidPlist;
        var total = std.math.add(usize, table_offset, table_len) catch return error.InvalidPlist;
        total = std.math.add(usize, total, trailer_size) catch return error.InvalidPlist;

        var out = try self.allocator.alloc(u8, total);
        errdefer self.allocator.free(out);
        @memset(out, 0);
        @memcpy(out[0..8], "bplist00");

        var offset: usize = header_len;
        for (encoded, 0..) |bytes, i| {
            writeBigEndian(out[table_offset + i * offset_size ..][0..offset_size], offset, offset_size);
            @memcpy(out[offset..][0..bytes.len], bytes);
            offset += bytes.len;
        }

        var trailer = out[total - trailer_size ..][0..trailer_size];
        @memset(trailer, 0);
        trailer[6] = offset_size;
        trailer[7] = ref_size;
        std.mem.writeInt(u64, trailer[8..16], count, .big);
        std.mem.writeInt(u64, trailer[16..24], top, .big);
        std.mem.writeInt(u64, trailer[24..32], table_offset, .big);
        return out;
    }

    fn encodeNode(self: *Encoder, node: Node, ref_size: u8) Error![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(self.allocator);
        switch (node) {
            .null => try out.append(self.allocator, 0x00),
            .boolean => |flag| try out.append(self.allocator, if (flag) 0x09 else 0x08),
            .integer => |number| {
                try out.append(self.allocator, 0x13);
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(i64, &bytes, number, .big);
                try out.appendSlice(self.allocator, &bytes);
            },
            .real => |number| {
                try out.append(self.allocator, 0x23);
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, @bitCast(number), .big);
                try out.appendSlice(self.allocator, &bytes);
            },
            .string => |text| {
                if (std.unicode.utf8ValidateSlice(text) and isAscii(text)) {
                    try appendCount(&out, self.allocator, 0x50, text.len);
                    try out.appendSlice(self.allocator, text);
                } else {
                    const units = try utf16Units(self.allocator, text);
                    defer self.allocator.free(units);
                    try appendCount(&out, self.allocator, 0x60, units.len);
                    for (units) |unit| {
                        var bytes: [2]u8 = undefined;
                        std.mem.writeInt(u16, &bytes, unit, .big);
                        try out.appendSlice(self.allocator, &bytes);
                    }
                }
            },
            .data => |bytes| {
                try appendCount(&out, self.allocator, 0x40, bytes.len);
                try out.appendSlice(self.allocator, bytes);
            },
            .uid => |id| {
                var size: usize = 1;
                while (size < 8 and id >= (@as(u64, 1) << @intCast(size * 8))) size += 1;
                try out.append(self.allocator, 0x80 | @as(u8, @intCast(size - 1)));
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, id, .big);
                try out.appendSlice(self.allocator, bytes[8 - size ..]);
            },
            .array => |refs| {
                try appendCount(&out, self.allocator, 0xA0, refs.len);
                for (refs) |ref| try appendRef(&out, self.allocator, ref, ref_size);
            },
            .dict => |dict| {
                try appendCount(&out, self.allocator, 0xD0, dict.keys.len);
                for (dict.keys) |ref| try appendRef(&out, self.allocator, ref, ref_size);
                for (dict.values) |ref| try appendRef(&out, self.allocator, ref, ref_size);
            },
        }
        return out.toOwnedSlice(self.allocator);
    }
};

fn appendCount(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, marker: u8, count: usize) Error!void {
    if (count < 15) {
        try out.append(allocator, marker | @as(u8, @intCast(count)));
        return;
    }
    try out.append(allocator, marker | 0x0F);
    var size: usize = 1;
    var marker_bits: u8 = 0;
    while (size < 8 and count > maxForSize(@intCast(marker_bits + 1))) {
        size <<= 1;
        marker_bits += 1;
    }
    try out.append(allocator, 0x10 | marker_bits);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, count, .big);
    try out.appendSlice(allocator, bytes[8 - size ..]);
}

fn appendRef(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, ref: Ref, ref_size: u8) Error!void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, ref, .big);
    try out.appendSlice(allocator, bytes[8 - ref_size ..]);
}

fn writeBigEndian(out: []u8, value: usize, size: u8) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    @memcpy(out, bytes[8 - size ..]);
}

fn bytesNeeded(count: usize) u8 {
    if (count <= 0xFF) return 1;
    if (count <= 0xFFFF) return 2;
    if (count <= 0xFFFFFF) return 3;
    return 4;
}

fn maxForSize(size: u8) usize {
    var value: usize = 1;
    var i: u8 = 0;
    while (i < size) : (i += 1) value = std.math.mul(usize, value, 256) catch return std.math.maxInt(usize);
    return value - 1;
}

fn isAscii(text: []const u8) bool {
    for (text) |byte| if (byte >= 0x80) return false;
    return true;
}

fn utf16Units(allocator: Allocator, text: []const u8) Error![]u16 {
    var out = std.ArrayListUnmanaged(u16).empty;
    errdefer out.deinit(allocator);
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidPlist;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |code| {
        if (code <= 0xFFFF) {
            try out.append(allocator, @intCast(code));
        } else {
            const value = code - 0x10000;
            try out.append(allocator, @intCast(0xD800 + (value >> 10)));
            try out.append(allocator, @intCast(0xDC00 + (value & 0x3FF)));
        }
    }
    return out.toOwnedSlice(allocator);
}

test "a plist that references one object twice does not cost exponential time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Object 0 holds an integer; every following object is an array of two references to the previous one, so the graph has 40 levels and 2^40 paths.
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    try bytes.appendSlice(allocator, "bplist00");
    var offsets: std.ArrayListUnmanaged(u64) = .empty;
    const levels: u64 = 40;
    var object: u64 = 0;
    while (object <= levels) : (object += 1) {
        try offsets.append(allocator, bytes.items.len);
        if (object == 0) {
            try bytes.appendSlice(allocator, &.{ 0x10, 0x07 });
            continue;
        }
        const previous: u8 = @intCast(object - 1);
        try bytes.appendSlice(allocator, &.{ 0xA2, previous, previous });
    }
    const table_start = bytes.items.len;
    var word: [8]u8 = undefined;
    for (offsets.items) |offset| {
        std.mem.writeInt(u32, word[0..4], @intCast(offset), .big);
        try bytes.appendSlice(allocator, word[0..4]);
    }
    try bytes.appendSlice(allocator, &.{ 0, 0, 0, 0, 0, 0, 4, 1 });
    std.mem.writeInt(u64, &word, offsets.items.len, .big);
    try bytes.appendSlice(allocator, &word);
    std.mem.writeInt(u64, &word, offsets.items.len - 1, .big);
    try bytes.appendSlice(allocator, &word);
    std.mem.writeInt(u64, &word, table_start, .big);
    try bytes.appendSlice(allocator, &word);

    const value = try parse(allocator, bytes.items);
    // Both halves of every array are the same parsed object.
    var current = value;
    var remaining: u64 = levels;
    while (remaining > 1) : (remaining -= 1) {
        const left = current.array[0];
        const right = current.array[1];
        try std.testing.expect(left.array.ptr == right.array.ptr);
        current = left;
    }
    try std.testing.expectEqual(@as(i64, 7), current.array[0].integer);
}

test "decode a plist produced by the platform serializer" {
    const fixture = [_]u8{
        0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30, 0xd1, 0x01, 0x02, 0x51, 0x61, 0x51, 0x62, 0x08,
        0x0b, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x0f,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parse(arena.allocator(), &fixture);
    try std.testing.expectEqualStrings("b", value.getString("a").?);
}

test "round trip the relay envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const envelope = Value{ .dict = &.{
        .{ .key = "messageName", .value = .{ .string = "_rpc_reportIdentifier:" } },
        .{ .key = "userInfo", .value = .{ .dict = &.{
            .{ .key = "WIRConnectionIdentifierKey", .value = .{ .string = "6F9B3A0E-1111-2222-3333-444455556666" } },
            .{ .key = "WIRPageIdentifierKey", .value = .{ .integer = 1 } },
        } } },
    } };

    const bytes = try encode(allocator, envelope);
    const decoded = try parse(allocator, bytes);
    try std.testing.expectEqualStrings("_rpc_reportIdentifier:", decoded.getString("messageName").?);
    const info = decoded.get("userInfo").?;
    try std.testing.expectEqualStrings("6F9B3A0E-1111-2222-3333-444455556666", info.getString("WIRConnectionIdentifierKey").?);
    try std.testing.expectEqual(@as(i64, 1), info.getInt("WIRPageIdentifierKey").?);
}

test "round trip long strings and data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const long = try allocator.alloc(u8, 300);
    @memset(long, 'x');
    const payload = "{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1+1\"}}";
    const value = Value{ .dict = &.{
        .{ .key = "long", .value = .{ .string = long } },
        .{ .key = "payload", .value = .{ .data = payload } },
    } };
    const bytes = try encode(allocator, value);
    const decoded = try parse(allocator, bytes);
    try std.testing.expectEqualStrings(long, decoded.getString("long").?);
    try std.testing.expectEqualStrings(payload, decoded.get("payload").?.data);
}
