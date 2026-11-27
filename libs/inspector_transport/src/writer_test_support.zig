const zev = @import("zev");

pub const WriterTestBarrier = struct {
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    pause_limit: usize = 1,
    paused: bool = false,
    paused_count: usize = 0,
    released: bool = false,
    close_started: bool = false,

    pub fn deinit(self: *WriterTestBarrier) void {
        self.changed.deinit();
        self.mutex.deinit();
    }

    pub fn pauseWriter(self: *WriterTestBarrier) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.paused_count >= self.pause_limit) return;
        self.paused = true;
        self.paused_count += 1;
        self.changed.broadcast();
        while (!self.released) self.changed.wait(&self.mutex);
    }

    pub fn notifyCloseStarted(self: *WriterTestBarrier) void {
        self.mutex.lock();
        self.close_started = true;
        self.changed.broadcast();
        self.mutex.unlock();
    }

    pub fn waitUntilPaused(self: *WriterTestBarrier, timeout_ms: u64) bool {
        return self.waitUntilPausedCount(1, timeout_ms);
    }

    pub fn waitUntilPausedCount(self: *WriterTestBarrier, want: usize, timeout_ms: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var remaining = timeout_ms;
        while (self.paused_count < want and remaining != 0) {
            const started = zev.monotonicMilliseconds();
            if (self.changed.waitTimeout(&self.mutex, remaining) == .timed_out) break;
            const elapsed = zev.monotonicMilliseconds() - started;
            remaining = if (elapsed >= remaining) 0 else remaining - elapsed;
        }
        return self.paused_count >= want;
    }

    pub fn waitUntilCloseStarted(self: *WriterTestBarrier, timeout_ms: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var remaining = timeout_ms;
        while (!self.close_started and remaining != 0) {
            const started = zev.monotonicMilliseconds();
            if (self.changed.waitTimeout(&self.mutex, remaining) == .timed_out) break;
            const elapsed = zev.monotonicMilliseconds() - started;
            remaining = if (elapsed >= remaining) 0 else remaining - elapsed;
        }
        return self.close_started;
    }

    pub fn releaseWriter(self: *WriterTestBarrier) void {
        self.mutex.lock();
        self.released = true;
        self.changed.broadcast();
        self.mutex.unlock();
    }
};
