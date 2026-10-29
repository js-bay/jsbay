//! Converts process termination signals into an ordinary thread-safe loop stop.
const std = @import("std");
const dispatch = @import("jsbay_tools").dispatch;
var signal_fd: std.atomic.Value(c_int) = .init(-1);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    const fd = signal_fd.swap(-1, .seq_cst);
    if (fd >= 0) _ = std.c.write(fd, &.{1}, 1);
}

pub const SignalStop = struct {
    fds: [2]c_int = undefined,
    thread: ?std.Thread = null,
    old_int: std.posix.Sigaction = undefined,
    old_term: std.posix.Sigaction = undefined,
    instance_id: i32 = 0,
    stop: *const fn (i32) void = undefined,

    pub fn start(self: *SignalStop, instance_id: i32, stop: *const fn (i32) void) !void {
        if (std.c.pipe(&self.fds) != 0) return error.SignalPipeFailed;
        errdefer {
            _ = std.c.close(self.fds[0]);
            _ = std.c.close(self.fds[1]);
        }
        self.instance_id = instance_id;
        self.stop = stop;
        self.thread = try std.Thread.spawn(.{}, wait, .{self});
        const action = std.posix.Sigaction{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        signal_fd.store(self.fds[1], .seq_cst);
        std.posix.sigaction(std.posix.SIG.INT, &action, &self.old_int);
        std.posix.sigaction(std.posix.SIG.TERM, &action, &self.old_term);
    }

    fn wait(self: *SignalStop) void {
        var byte: [1]u8 = undefined;
        while (true) {
            const result = std.c.read(self.fds[0], &byte, 1);
            if (result == 1) {
                _ = dispatch.postTask(self.instance_id, .{ .ctx = self, .run = stopOnOwner });
                return;
            }
            if (result == 0 or std.posix.errno(result) != .INTR) return;
        }
    }

    fn stopOnOwner(context: ?*anyopaque) void {
        const self: *SignalStop = @ptrCast(@alignCast(context.?));
        self.stop(self.instance_id);
    }

    pub fn deinit(self: *SignalStop) void {
        std.posix.sigaction(std.posix.SIG.INT, &self.old_int, null);
        std.posix.sigaction(std.posix.SIG.TERM, &self.old_term, null);
        signal_fd.store(-1, .seq_cst);
        _ = std.c.close(self.fds[1]);
        if (self.thread) |thread| thread.join();
        _ = std.c.close(self.fds[0]);
    }
};
