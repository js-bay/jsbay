const socket = @import("portable_socket");

pub const RawListener = struct {
    listener: socket.Listener,
    port: u16,

    pub fn close(listener: RawListener) void {
        listener.listener.close();
    }

    pub fn listenIp4Loopback(want_port: u16) !RawListener {
        const listener = try socket.listenLoopback(want_port);
        return .{ .listener = listener, .port = listener.port };
    }
};
