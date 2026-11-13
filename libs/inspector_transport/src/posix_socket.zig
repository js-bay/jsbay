const std = @import("std");

pub const Handle = isize;
pub const PollEvent = enum { read, write };
pub const AcceptResult = union(enum) { accepted: Handle, retry };
pub const PollResult = struct { timed_out: bool, ready: bool, closed: bool };

pub const Socket = struct {
    handle: Handle,

    pub fn close(self: Socket) void {
        _ = std.posix.system.close(toFd(self.handle));
    }

    pub fn setNonBlocking(self: Socket, enabled: bool) !void {
        const fd = toFd(self.handle);
        const flags = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
        if (flags < 0) return error.NonBlockingFailed;
        const mask: c_int = @intCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
        const new_flags: c_int = if (enabled) flags | mask else flags & ~mask;
        if (std.posix.system.fcntl(fd, std.posix.F.SETFL, new_flags) < 0) return error.NonBlockingFailed;
    }

    pub fn read(self: Socket, buffer: []u8) !usize {
        return std.posix.read(toFd(self.handle), buffer);
    }

    pub fn write(self: Socket, buffer: []const u8) !usize {
        const count = std.c.send(toFd(self.handle), buffer.ptr, buffer.len, std.posix.MSG.NOSIGNAL);
        if (count < 0) {
            return switch (std.posix.errno(count)) {
                .INTR => error.Interrupted,
                .AGAIN => error.WouldBlock,
                else => error.SocketIoFailed,
            };
        }
        return @intCast(count);
    }

    pub fn shutdownBoth(self: Socket) void {
        _ = std.posix.system.shutdown(toFd(self.handle), std.posix.SHUT.RDWR);
    }

    pub fn poll(self: Socket, event: PollEvent, timeout_ms: i32) !PollResult {
        const events: i16 = switch (event) {
            .read => std.posix.POLL.IN,
            .write => std.posix.POLL.OUT,
        };
        var descriptors = [_]std.posix.pollfd{.{
            .fd = toFd(self.handle),
            .events = events,
            .revents = 0,
        }};
        const result = std.posix.poll(&descriptors, timeout_ms) catch |err| {
            if (err == error.Interrupted) return .{ .timed_out = true, .ready = false, .closed = false };
            return error.PollFailed;
        };
        const returned = descriptors[0].revents;
        const closed = returned & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0;
        const ready_bit: i16 = switch (event) {
            .read => std.posix.POLL.IN,
            .write => std.posix.POLL.OUT,
        };
        return .{
            .timed_out = result == 0,
            .ready = returned & ready_bit != 0,
            .closed = closed,
        };
    }

    pub fn setReceiveBuffer(self: Socket, bytes: c_int) !void {
        try std.posix.setsockopt(toFd(self.handle), std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&bytes));
    }

    pub fn connectStatus(self: Socket) !void {
        var err_code: c_int = 0;
        var len: std.posix.socklen_t = @sizeOf(c_int);
        if (std.posix.system.getsockopt(toFd(self.handle), std.posix.SOL.SOCKET, std.posix.SO.ERROR, @ptrCast(&err_code), &len) < 0)
            return error.ConnectFailed;
        if (err_code != 0) return error.ConnectFailed;
    }
};

pub const Listener = struct {
    socket: Socket,
    port: u16,

    pub fn close(self: Listener) void {
        self.socket.close();
    }

    pub fn accept(self: Listener) !AcceptResult {
        const accepted = std.posix.system.accept(toFd(self.socket.handle), null, null);
        if (accepted < 0) {
            return switch (std.posix.errno(accepted)) {
                .AGAIN, .INTR, .CONNABORTED, .MFILE, .NFILE => .retry,
                else => error.AcceptFailed,
            };
        }
        return .{ .accepted = fromFd(@intCast(accepted)) };
    }
};

pub fn listenLoopback(requested_port: u16) !Listener {
    const raw = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (raw < 0) return error.SocketFailed;
    const fd: std.posix.fd_t = @intCast(raw);
    errdefer _ = std.posix.system.close(fd);

    const reuse: c_int = 1;
    try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&reuse));
    var address: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, requested_port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
    };
    if (std.posix.system.bind(fd, @ptrCast(&address), @sizeOf(std.posix.sockaddr.in)) < 0) return error.BindFailed;
    if (std.posix.system.listen(fd, 128) < 0) return error.ListenFailed;
    var actual: std.posix.sockaddr.in = undefined;
    var actual_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.posix.system.getsockname(fd, @ptrCast(&actual), &actual_len) < 0) return error.GetSockNameFailed;
    return .{ .socket = .{ .handle = fromFd(fd) }, .port = std.mem.bigToNative(u16, actual.port) };
}

pub fn connectLoopback(port: u16) !Socket {
    const raw = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (raw < 0) return error.SocketFailed;
    const fd: std.posix.fd_t = @intCast(raw);
    errdefer _ = std.posix.system.close(fd);
    var address: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
    };
    if (std.posix.system.connect(fd, @ptrCast(&address), @sizeOf(std.posix.sockaddr.in)) < 0) return error.ConnectFailed;
    return .{ .handle = fromFd(fd) };
}

pub const BeginConnect = struct { socket: Socket, done: bool };

/// Create a non-blocking loopback socket and start connect. `done` is true when the handshake already completed.
pub fn beginConnectLoopback(port: u16) !BeginConnect {
    const raw = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (raw < 0) return error.SocketFailed;
    const fd: std.posix.fd_t = @intCast(raw);
    var sock = Socket{ .handle = fromFd(fd) };
    errdefer sock.close();
    try sock.setNonBlocking(true);
    var address: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
    };
    const rc = std.posix.system.connect(fd, @ptrCast(&address), @sizeOf(std.posix.sockaddr.in));
    if (rc < 0) {
        return switch (std.posix.errno(rc)) {
            .INTR, .AGAIN, .INPROGRESS, .ALREADY => .{ .socket = sock, .done = false },
            .ISCONN => .{ .socket = sock, .done = true },
            else => error.ConnectFailed,
        };
    }
    return .{ .socket = sock, .done = true };
}

fn toFd(handle: Handle) std.posix.fd_t {
    return @intCast(handle);
}

fn fromFd(fd: std.posix.fd_t) Handle {
    return @intCast(fd);
}
