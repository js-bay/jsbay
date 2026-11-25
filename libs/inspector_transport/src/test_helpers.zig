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

    pub fn waitUntilEntered(self: *LargeWriteBarrier) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.entered) {
            if (self.changed.waitTimeout(&self.mutex, 10_000) == .timed_out) return false;
        }
        return true;
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
