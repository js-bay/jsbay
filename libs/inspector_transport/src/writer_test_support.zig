const std = @import("std");
const zev = @import("zev");

pub const WriterTestBarrier = struct {
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    pause_next: bool = true,
    paused: bool = false,
    released: bool = false,
    close_started: bool = false,
    final_refs_zero: usize = 0,
    socket_close_entered: usize = 0,
    socket_close_returned: usize = 0,

    pub fn closeFinalSession(self: *WriterTestBarrier, close_fn: anytype, stream: anytype) void {
        self.mutex.lock();
        self.final_refs_zero += 1;
        self.socket_close_entered += 1;
        self.mutex.unlock();
        close_fn(stream);
        self.mutex.lock();
        self.socket_close_returned += 1;
        self.changed.broadcast();
        self.mutex.unlock();
    }

    pub fn printSessionCloseDiagnostics(self: *WriterTestBarrier) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.print("SESSION_CLOSE_DIAGNOSTIC final_refs_zero={d} close_entered={d} close_returned={d}\n", .{ self.final_refs_zero, self.socket_close_entered, self.socket_close_returned });
    }

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
