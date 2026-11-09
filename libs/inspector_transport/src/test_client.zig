const socket = @import("portable_socket");

pub const Stream = struct {
    handle: socket.Handle,

    pub fn read(self: Stream, buffer: []u8) !usize {
        return (socket.Socket{ .handle = self.handle }).read(buffer);
    }

    pub fn writeAll(self: Stream, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const written = (socket.Socket{ .handle = self.handle }).write(bytes[offset..]) catch |err| {
                if (err == error.Interrupted) continue;
                return err;
            };
            if (written == 0) return error.WriteFailed;
            offset += written;
        }
    }

    pub fn readByte(self: Stream) !u8 {
        var byte: [1]u8 = undefined;
        if (try self.read(&byte) == 0) return error.EndOfStream;
        return byte[0];
    }

    pub fn close(self: Stream) void {
        (socket.Socket{ .handle = self.handle }).close();
    }

    pub fn setReceiveBuffer(self: Stream, bytes: c_int) !void {
        try (socket.Socket{ .handle = self.handle }).setReceiveBuffer(bytes);
    }
};

pub fn connectLoopback(port: u16) !Stream {
    const client = try socket.connectLoopback(port);
    return .{ .handle = client.handle };
}
