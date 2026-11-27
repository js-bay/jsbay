const zev = @import("zev");

pub const WriterTestBarrier = struct {
    const max_sessions = 32;

    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    pause_limit: usize = 1,
    paused: bool = false,
    paused_count: usize = 0,
    released: bool = false,
    close_started: bool = false,
    close_deadline_ms: i64 = 0,
    close_deadline_changed: bool = false,
    close_deadline_write_observations: usize = 0,
    close_deadline_drain_sessions: [max_sessions]u64 = @splat(0),
    close_deadline_drain_count: usize = 0,
    close_deadline_writer_sessions: [max_sessions]u64 = @splat(0),
    close_deadline_writer_count: usize = 0,

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

    pub fn notifyCloseStarted(self: *WriterTestBarrier, session_id: u64, deadline_ms: i64) void {
        self.mutex.lock();
        self.close_started = true;
        self.observeCloseDeadlineLocked(session_id, deadline_ms, false);
        self.changed.broadcast();
        self.mutex.unlock();
    }

    pub fn observeWriteDeadline(self: *WriterTestBarrier, session_id: u64, deadline_ms: i64) void {
        if (deadline_ms == 0) return;
        self.mutex.lock();
        self.observeCloseDeadlineLocked(session_id, deadline_ms, true);
        self.mutex.unlock();
    }

    fn observeCloseDeadlineLocked(self: *WriterTestBarrier, session_id: u64, deadline_ms: i64, is_write: bool) void {
        if (deadline_ms == 0) return;
        if (self.close_deadline_ms == 0) {
            self.close_deadline_ms = deadline_ms;
        } else if (self.close_deadline_ms != deadline_ms) {
            self.close_deadline_changed = true;
        }
        const ids: *[max_sessions]u64 = if (is_write) &self.close_deadline_writer_sessions else &self.close_deadline_drain_sessions;
        const count: *usize = if (is_write) &self.close_deadline_writer_count else &self.close_deadline_drain_count;
        for (ids[0..count.*]) |observed_id| {
            if (observed_id == session_id) {
                if (is_write) self.close_deadline_write_observations += 1;
                return;
            }
        }
        if (count.* < max_sessions) {
            ids[count.*] = session_id;
            count.* += 1;
        }
        if (is_write) self.close_deadline_write_observations += 1;
    }

    pub fn closeDeadlineStayedStable(self: *WriterTestBarrier, drain_sessions: usize, writer_sessions: usize, writes: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.close_deadline_ms != 0 and !self.close_deadline_changed and self.close_deadline_drain_count >= drain_sessions and self.close_deadline_writer_count >= writer_sessions and self.close_deadline_write_observations >= writes;
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
