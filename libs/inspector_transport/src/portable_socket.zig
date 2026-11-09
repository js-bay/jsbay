const std = @import("std");

pub const Handle = isize;
pub const PollEvent = enum(c_int) { read = 1, write = 2 };
pub const AcceptResult = union(enum) { accepted: Handle, retry };

const ok = 0;
const would_block = 1;
const interrupted = 2;
const transient = 3;
const socket_error = -1;
const read_event = 1;
const write_event = 2;
const closed_event = 4;

extern "c" fn jsbay_socket_listen(u16, *Handle, *u16) c_int;
extern "c" fn jsbay_socket_connect(u16, *Handle) c_int;
extern "c" fn jsbay_socket_accept(Handle, *Handle) c_int;
extern "c" fn jsbay_socket_nonblocking(Handle, c_int) c_int;
extern "c" fn jsbay_socket_read(Handle, ?[*]u8, usize, *c_int) isize;
extern "c" fn jsbay_socket_write(Handle, ?[*]const u8, usize, *c_int) isize;
extern "c" fn jsbay_socket_poll(Handle, c_int, c_int, *c_int) c_int;
extern "c" fn jsbay_socket_shutdown(Handle) void;
extern "c" fn jsbay_socket_close(Handle) void;
extern "c" fn jsbay_socket_receive_buffer(Handle, c_int) c_int;

pub const Socket = struct {
    handle: Handle,

    pub fn close(self: Socket) void {
        jsbay_socket_close(self.handle);
    }

    pub fn setNonBlocking(self: Socket, enabled: bool) !void {
        if (jsbay_socket_nonblocking(self.handle, @intFromBool(enabled)) != 0) return error.NonBlockingFailed;
    }

    pub fn read(self: Socket, buffer: []u8) !usize {
        while (true) {
            var status: c_int = ok;
            const count = jsbay_socket_read(self.handle, buffer.ptr, buffer.len, &status);
            if (count >= 0) return @intCast(count);
            const err = statusError(status);
            if (err == error.Interrupted) continue;
            return err;
        }
    }

    pub fn write(self: Socket, buffer: []const u8) !usize {
        var status: c_int = ok;
        const count = jsbay_socket_write(self.handle, buffer.ptr, buffer.len, &status);
        if (count >= 0) return @intCast(count);
        return statusError(status);
    }

    pub fn shutdownBoth(self: Socket) void {
        jsbay_socket_shutdown(self.handle);
    }

    pub fn poll(self: Socket, event: PollEvent, timeout_ms: i32) !PollResult {
        var ready: c_int = 0;
        const result = jsbay_socket_poll(self.handle, @backingInt(event), timeout_ms, &ready);
        if (result < 0) return error.PollFailed;
        return .{ .timed_out = result == 0, .ready = (ready & @backingInt(event)) != 0, .closed = (ready & closed_event) != 0 };
    }

    pub fn setReceiveBuffer(self: Socket, bytes: c_int) !void {
        if (jsbay_socket_receive_buffer(self.handle, bytes) != 0) return error.ReceiveBufferFailed;
    }
};

pub const PollResult = struct { timed_out: bool, ready: bool, closed: bool };

pub const Listener = struct {
    socket: Socket,
    port: u16,

    pub fn close(self: Listener) void {
        self.socket.close();
    }

    pub fn accept(self: Listener) !AcceptResult {
        var handle: Handle = undefined;
        const result = jsbay_socket_accept(self.socket.handle, &handle);
        return switch (result) {
            ok => .{ .accepted = handle },
            would_block, interrupted, transient => .retry,
            else => error.AcceptFailed,
        };
    }
};

pub fn listenLoopback(requested_port: u16) !Listener {
    var handle: Handle = undefined;
    var port: u16 = undefined;
    if (jsbay_socket_listen(requested_port, &handle, &port) != 0) return error.ListenFailed;
    return .{ .socket = .{ .handle = handle }, .port = port };
}

pub fn connectLoopback(port: u16) !Socket {
    var handle: Handle = undefined;
    if (jsbay_socket_connect(port, &handle) != 0) return error.ConnectFailed;
    return .{ .handle = handle };
}

fn statusError(status: c_int) anyerror {
    return switch (status) {
        would_block => error.WouldBlock,
        interrupted => error.Interrupted,
        transient => error.TransientSocketError,
        else => error.SocketIoFailed,
    };
}
