//! TCP and WebSocket helpers shared by inspector test suites.
const std = @import("std");
const testing = std.testing;
const io = @import("../platform/io.zig");

pub const TestStream = struct {
    handle: std.posix.fd_t,

    pub fn read(s: TestStream, buf: []u8) !usize {
        return std.posix.read(s.handle, buf);
    }

    pub fn writeAll(s: TestStream, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.posix.system.write(s.handle, bytes.ptr + off, bytes.len - off);
            if (n < 0) {
                if (std.posix.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            off += @intCast(n);
        }
    }

    pub fn close(s: TestStream) void {
        _ = std.posix.system.close(s.handle);
    }
};

pub fn connectLoopback(port: u16) !TestStream {
    const raw_fd = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (raw_fd < 0) return error.SocketFailed;
    const fd: std.posix.fd_t = @intCast(raw_fd);
    errdefer _ = std.posix.system.close(fd);
    var addr: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
    };
    if (std.posix.system.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.ConnectFailed;
    return .{ .handle = fd };
}

pub fn connect(port: u16) !TestStream {
    const stream = try connectLoopback(port);
    // Apply SO_RCVTIMEO so reads return EAGAIN after ~50ms instead of blocking. The tests poll read + tickInstance in a loop; without a timeout, evaluate responses that require a JS-thread tick can't arrive because the test is stuck in a blocking read.
    var tv: std.posix.timeval = .{ .sec = 0, .usec = 50_000 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
    return stream;
}

pub fn readUntilEof(alloc: std.mem.Allocator, stream: TestStream, out: *std.ArrayList(u8)) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch 0;
        if (n == 0) return;
        try out.appendSlice(alloc, buf[0..n]);
    }
}

pub fn readHttpHeaders(alloc: std.mem.Allocator, stream: TestStream) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [1]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) return error.EndOfStream;
        try list.append(alloc, buf[0]);
        if (list.items.len >= 4) {
            const tail = list.items[list.items.len - 4 ..];
            if (std.mem.eql(u8, tail, "\r\n\r\n")) break;
        }
    }
    return list.toOwnedSlice(alloc);
}

pub fn readAtLeast(stream: TestStream, buf: []u8, need: usize) !usize {
    var got: usize = 0;
    while (got < need) {
        const n = try stream.read(buf[got..]);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
    return got;
}

pub fn writeMaskedText(stream: TestStream, text: []const u8) !void {
    var header: [14]u8 = undefined;
    var hlen: usize = 0;
    header[0] = 0x80 | 0x1; // FIN + text
    if (text.len <= 125) {
        header[1] = 0x80 | @as(u8, @intCast(text.len));
        hlen = 2;
    } else if (text.len <= 0xFFFF) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @as(u16, @intCast(text.len)), .big);
        hlen = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], @as(u64, text.len), .big);
        hlen = 10;
    }
    const mask_key: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };
    @memcpy(header[hlen..][0..4], &mask_key);
    hlen += 4;
    try stream.writeAll(header[0..hlen]);

    var masked_buf: [1024]u8 = undefined;
    var off: usize = 0;
    while (off < text.len) {
        const chunk = @min(masked_buf.len, text.len - off);
        for (0..chunk) |i| {
            masked_buf[i] = text[off + i] ^ mask_key[(off + i) & 3];
        }
        try stream.writeAll(masked_buf[0..chunk]);
        off += chunk;
    }
}

pub const Frame = struct {
    opcode: u8,
    payload: []u8,
};

/// Owns partial server→client WebSocket frame state across socket timeouts.
pub const FrameReader = struct {
    stream: TestStream,
    header: [2]u8 = undefined,
    header_len: usize = 0,
    extended: [8]u8 = undefined,
    extended_len: usize = 0,
    extended_need: usize = 0,
    payload: ?[]u8 = null,
    payload_len: usize = 0,
    payload_read: usize = 0,

    pub fn init(stream: TestStream) FrameReader {
        return .{ .stream = stream };
    }

    pub fn deinit(self: *FrameReader, alloc: std.mem.Allocator) void {
        if (self.payload) |payload| alloc.free(payload);
        self.payload = null;
    }

    fn readPartial(self: *FrameReader, target: []u8, have: *usize) !bool {
        const n = self.stream.read(target[have.*..]) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        have.* += n;
        return true;
    }

    fn beginPayload(self: *FrameReader, alloc: std.mem.Allocator) !void {
        if ((self.header[1] & 0x80) != 0) return error.MaskedServerFrame;
        const encoded_len = self.header[1] & 0x7f;
        const plen: u64 = switch (encoded_len) {
            126 => std.mem.readInt(u16, self.extended[0..2], .big),
            127 => std.mem.readInt(u64, self.extended[0..8], .big),
            else => encoded_len,
        };
        if (plen > std.math.maxInt(usize)) return error.FrameTooLarge;
        self.payload_len = @intCast(plen);
        self.payload = try alloc.alloc(u8, self.payload_len);
        self.payload_read = 0;
    }

    /// Returns null after a socket timeout while preserving any consumed bytes.
    pub fn readTimed(self: *FrameReader, alloc: std.mem.Allocator, timeout_ms: u64) !?Frame {
        const deadline = io.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        errdefer self.deinit(alloc);
        while (io.milliTimestamp() < deadline) {
            if (self.header_len < self.header.len) {
                if (!try self.readPartial(&self.header, &self.header_len)) return null;
                if (self.header_len < self.header.len) continue;
                const encoded_len = self.header[1] & 0x7f;
                self.extended_need = if (encoded_len == 126) 2 else if (encoded_len == 127) 8 else 0;
            }
            if (self.extended_len < self.extended_need) {
                if (!try self.readPartial(self.extended[0..self.extended_need], &self.extended_len)) return null;
                if (self.extended_len < self.extended_need) continue;
            }
            if (self.payload == null) try self.beginPayload(alloc);
            if (self.payload_read < self.payload_len) {
                if (!try self.readPartial(self.payload.?[0..self.payload_len], &self.payload_read)) return null;
                if (self.payload_read < self.payload_len) continue;
            }
            const frame = Frame{ .opcode = self.header[0] & 0x0f, .payload = self.payload.? };
            self.payload = null;
            self.header_len = 0;
            self.extended_len = 0;
            self.extended_need = 0;
            self.payload_len = 0;
            self.payload_read = 0;
            return frame;
        }
        return null;
    }
};

pub fn doWsHandshake(alloc: std.mem.Allocator, stream: TestStream, target_id: []const u8) !void {
    const req = try std.fmt.allocPrint(
        alloc,
        "GET /{s} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
        .{target_id},
    );
    defer alloc.free(req);
    try stream.writeAll(req);

    const hdrs = try readHttpHeaders(alloc, stream);
    defer alloc.free(hdrs);
    try testing.expect(std.mem.startsWith(u8, hdrs, "HTTP/1.1 101"));
}
