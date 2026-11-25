const zev = @import("zev");

pub const LargeWriteBarrier = struct {
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    entered: bool = false,
    released: bool = false,

    pub fn observe(ctx: ?*anyopaque, _: []const u8) void {
        const self: *LargeWriteBarrier = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entered) return;
        self.entered = true;
        self.changed.broadcast();
        while (!self.released) self.changed.wait(&self.mutex);
    }

    pub fn waitUntilEntered(self: *LargeWriteBarrier, timeout_ms: u64) error{TimedOut}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.entered) {
            if (self.changed.waitTimeout(&self.mutex, timeout_ms) == .timed_out) return error.TimedOut;
        }
    }

    pub fn release(self: *LargeWriteBarrier) void {
        self.mutex.lock();
        self.released = true;
        self.changed.broadcast();
        self.mutex.unlock();
    }

    pub fn deinit(self: *LargeWriteBarrier) void {
        self.changed.deinit();
        self.mutex.deinit();
    }
};

test "barrier reports a timeout" {
    var barrier = LargeWriteBarrier{};
    defer barrier.deinit();
    try @import("std").testing.expectError(error.TimedOut, barrier.waitUntilEntered(0));
}
