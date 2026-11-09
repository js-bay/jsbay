const builtin = @import("builtin");
const backend = if (builtin.os.tag == .windows) @import("windows_socket.zig") else @import("posix_socket.zig");

pub const Handle = backend.Handle;
pub const PollEvent = backend.PollEvent;
pub const AcceptResult = backend.AcceptResult;
pub const Socket = backend.Socket;
pub const PollResult = backend.PollResult;
pub const Listener = backend.Listener;
pub const listenLoopback = backend.listenLoopback;
pub const connectLoopback = backend.connectLoopback;

pub fn handleRoundTripForTest(handle: Handle) Handle {
    if (builtin.os.tag == .windows) return backend.roundTripHandleForTest(handle);
    return handle;
}
