//! Small synchronization wrappers built on native blocking primitives.

const Waiter = @import("root.zig").Waiter;
const native = @import("native.zig");

pub const Mutex = struct {
    native: native.Mutex = .{},

    pub fn lock(self: *Mutex) void {
        self.native.lock();
    }
    pub fn unlock(self: *Mutex) void {
        self.native.unlock();
    }
    pub fn tryLock(self: *Mutex) bool {
        return self.native.tryLock();
    }
    pub fn deinit(self: *Mutex) void {
        self.native.deinit();
    }
};

pub const Condition = struct {
    pub const WaitResult = enum { notified, timed_out };

    native: Waiter = .init,
    pub const init: Condition = .{};
    pub fn deinit(self: *Condition) void {
        self.native.deinit();
    }
    pub fn broadcast(self: *Condition) void {
        self.native.broadcast();
    }
    pub fn signal(self: *Condition) void {
        self.native.signal();
    }
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = self.waitTimeout(mutex, null);
    }
    /// Snapshots generation before releasing `mutex`, preventing a missed notification. The mutex is held again when this returns.
    pub fn waitTimeout(self: *Condition, mutex: *Mutex, timeout_ms: ?u64) WaitResult {
        const generation = self.native.generation();
        mutex.unlock();
        defer mutex.lock();
        return if (self.native.waitUntilChange(generation, timeout_ms)) .notified else .timed_out;
    }
};
