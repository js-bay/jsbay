const zev = @import("zev");

pub const WriterTestBarrier = struct {
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    pause_next: bool = true,
    paused: bool = false,
    released: bool = false,
    close_started: bool = false,

    pub fn deinit(self: *WriterTestBarrier) void {
        self.changed.deinit();
        self.mutex.deinit();
    }

    pub fn pauseWriter(self: *WriterTestBarrier) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.pause_next) return;
        self.pause_next = false;
        self.paused = true;
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
        self.mutex.lock();
        defer self.mutex.unlock();
        var remaining = timeout_ms;
        while (!self.paused and remaining != 0) {
            const started = zev.monotonicMilliseconds();
            if (self.changed.waitTimeout(&self.mutex, remaining) == .timed_out) break;
            const elapsed = zev.monotonicMilliseconds() - started;
            remaining = if (elapsed >= remaining) 0 else remaining - elapsed;
        }
        return self.paused;
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
