const std = @import("std");
const ws2 = std.os.windows.ws2_32;

pub const Handle = usize;
pub const PollEvent = enum(c_int) { read = 1, write = 2 };
pub const AcceptResult = union(enum) { accepted: Handle, retry };

const SocketHandle = usize;
const invalid_socket = std.math.maxInt(SocketHandle);
const wsa_eintr = 10004;
const wsa_e_would_block = 10035;
const wsa_e_conn_aborted = 10053;
const wsa_e_conn_reset = 10054;
const wsa_e_net_down = 10050;
const wsa_e_net_reset = 10052;
const wsa_e_shutdown = 10058;
const wsa_e_too_many_files = 10024;
const wsa_e_no_buffers = 10055;
const af_inet = 2;
const sock_stream = 1;
const ipproto_tcp = 6;
const sol_socket = 0xffff;
const so_exclusiveaddruse = -5;
const so_rcvbuf = 0x1002;
const fionbio: c_long = @bitCast(@as(u32, 0x8004667e));
const sd_both = 2;
const poll_read = 0x0100;
const poll_write = 0x0010;
const poll_error = 0x0001;
const poll_hup = 0x0002;
const poll_invalid = 0x0004;
const loopback_addr = 0x7f000001;
const startup_version = 0x0202;

const WsaData = if (@sizeOf(usize) == 8)
    extern struct {
        wVersion: u16,
        wHighVersion: u16,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?[*]u8,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
    }
else
    extern struct {
        wVersion: u16,
        wHighVersion: u16,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?[*]u8,
    };

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(WsaData) == 408);
        std.debug.assert(@offsetOf(WsaData, "lpVendorInfo") == 8);
        std.debug.assert(@offsetOf(WsaData, "szDescription") == 16);
    } else {
        std.debug.assert(@sizeOf(WsaData) == 400);
        std.debug.assert(@offsetOf(WsaData, "szDescription") == 4);
        std.debug.assert(@offsetOf(WsaData, "lpVendorInfo") == 396);
    }
}

const PollFd = extern struct {
    fd: SocketHandle,
    events: i16,
    revents: i16,
};

extern "ws2_32" fn WSAStartup(version: u16, data: *WsaData) callconv(.winapi) c_int;
extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
extern "ws2_32" fn socket(af: c_int, kind: c_int, protocol: c_int) callconv(.winapi) SocketHandle;
extern "ws2_32" fn bind(handle: SocketHandle, address: *const ws2.sockaddr, length: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn listen(handle: SocketHandle, backlog: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn getsockname(handle: SocketHandle, address: *ws2.sockaddr, length: *c_int) callconv(.winapi) c_int;
extern "ws2_32" fn setsockopt(handle: SocketHandle, level: c_int, option: c_int, value: [*]const u8, length: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn connect(handle: SocketHandle, address: *const ws2.sockaddr, length: c_int) callconv(.winapi) c_int;
const winsockAccept = @extern(*const fn (SocketHandle, ?*ws2.sockaddr, ?*c_int) callconv(.winapi) SocketHandle, .{ .name = "accept" });
extern "ws2_32" fn ioctlsocket(handle: SocketHandle, command: c_long, value: *u32) callconv(.winapi) c_int;
extern "ws2_32" fn recv(handle: SocketHandle, buffer: [*]u8, length: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn send(handle: SocketHandle, buffer: [*]const u8, length: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn WSAPoll(fds: *PollFd, count: u32, timeout_ms: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn shutdown(handle: SocketHandle, how: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn closesocket(handle: SocketHandle) callconv(.winapi) c_int;
extern "ws2_32" fn htons(value: u16) callconv(.winapi) u16;
extern "ws2_32" fn htonl(value: u32) callconv(.winapi) u32;

fn startup() bool {
    var data: WsaData = undefined;
    return WSAStartup(startup_version, &data) == 0;
}

fn native(handle: Handle) SocketHandle {
    return handle;
}

fn toHandle(handle: SocketHandle) Handle {
    return handle;
}

pub fn roundTripHandleForTest(handle: Handle) Handle {
    return toHandle(native(handle));
}

fn address(port: u16) ws2.sockaddr.in {
    return .{ .port = htons(port), .addr = htonl(loopback_addr) };
}

fn statusError(code: c_int) anyerror {
    return switch (code) {
        wsa_e_would_block => error.WouldBlock,
        wsa_eintr => error.Interrupted,
        wsa_e_conn_aborted, wsa_e_conn_reset, wsa_e_net_down, wsa_e_net_reset, wsa_e_shutdown, wsa_e_too_many_files, wsa_e_no_buffers => error.Transient,
        else => error.SocketFailed,
    };
}

pub const Socket = struct {
    handle: Handle,

    pub fn close(self: Socket) void {
        _ = closesocket(native(self.handle));
        _ = WSACleanup();
    }

    pub fn setNonBlocking(self: Socket, enabled: bool) !void {
        var mode: u32 = @intFromBool(enabled);
        if (ioctlsocket(native(self.handle), fionbio, &mode) != 0) return error.NonBlockingFailed;
    }

    pub fn read(self: Socket, buffer: []u8) !usize {
        while (true) {
            const amount: c_int = @intCast(@min(buffer.len, std.math.maxInt(c_int)));
            const count = recv(native(self.handle), buffer.ptr, amount, 0);
            if (count >= 0) return @intCast(count);
            const err = statusError(WSAGetLastError());
            if (err == error.Interrupted) continue;
            return err;
        }
    }

    pub fn write(self: Socket, buffer: []const u8) !usize {
        const amount: c_int = @intCast(@min(buffer.len, std.math.maxInt(c_int)));
        const count = send(native(self.handle), buffer.ptr, amount, 0);
        if (count >= 0) return @intCast(count);
        return statusError(WSAGetLastError());
    }

    pub fn shutdownBoth(self: Socket) void {
        _ = shutdown(native(self.handle), sd_both);
    }

    pub fn poll(self: Socket, event: PollEvent, timeout_ms: i32) !PollResult {
        const event_mask: i16 = if (event == .read) poll_read else poll_write;
        var descriptor = PollFd{ .fd = native(self.handle), .events = event_mask, .revents = 0 };
        const result = WSAPoll(&descriptor, 1, timeout_ms);
        if (result < 0) {
            if (WSAGetLastError() == wsa_eintr) return .{ .timed_out = true, .ready = false, .closed = false };
            return error.PollFailed;
        }
        return .{
            .timed_out = result == 0,
            .ready = (descriptor.revents & event_mask) != 0,
            .closed = (descriptor.revents & (poll_error | poll_hup | poll_invalid)) != 0,
        };
    }

    pub fn setReceiveBuffer(self: Socket, bytes: c_int) !void {
        if (setsockopt(native(self.handle), sol_socket, so_rcvbuf, std.mem.asBytes(&bytes), @sizeOf(c_int)) != 0) return error.ReceiveBufferFailed;
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
        const handle = winsockAccept(native(self.socket.handle), null, null);
        if (handle != invalid_socket) {
            if (!startup()) {
                _ = closesocket(handle);
                return error.SocketFailed;
            }
            return .{ .accepted = toHandle(handle) };
        }
        return switch (statusError(WSAGetLastError())) {
            error.WouldBlock, error.Interrupted, error.Transient => .retry,
            else => error.AcceptFailed,
        };
    }
};

pub fn listenLoopback(requested_port: u16) !Listener {
    if (!startup()) return error.ListenFailed;
    const handle = socket(af_inet, sock_stream, ipproto_tcp);
    if (handle == invalid_socket) {
        _ = WSACleanup();
        return error.ListenFailed;
    }
    var exclusive: c_int = 1;
    if (setsockopt(handle, sol_socket, so_exclusiveaddruse, std.mem.asBytes(&exclusive), @sizeOf(c_int)) != 0) return listenFail(handle);
    var addr = address(requested_port);
    const addr_ptr: *ws2.sockaddr = @ptrCast(&addr);
    if (bind(handle, addr_ptr, @sizeOf(ws2.sockaddr.in)) != 0 or listen(handle, 128) != 0) return listenFail(handle);
    var length: c_int = @sizeOf(ws2.sockaddr.in);
    if (getsockname(handle, addr_ptr, &length) != 0) return listenFail(handle);
    return .{ .socket = .{ .handle = toHandle(handle) }, .port = htons(addr.port) };
}

fn listenFail(handle: SocketHandle) error{ListenFailed} {
    _ = closesocket(handle);
    _ = WSACleanup();
    return error.ListenFailed;
}

pub fn connectLoopback(port: u16) !Socket {
    if (!startup()) return error.ConnectFailed;
    const handle = socket(af_inet, sock_stream, ipproto_tcp);
    if (handle == invalid_socket) {
        _ = WSACleanup();
        return error.ConnectFailed;
    }
    var addr = address(port);
    if (connect(handle, @ptrCast(&addr), @sizeOf(ws2.sockaddr.in)) != 0) {
        _ = closesocket(handle);
        _ = WSACleanup();
        return error.ConnectFailed;
    }
    return .{ .handle = toHandle(handle) };
}
