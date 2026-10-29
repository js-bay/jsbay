//! Native waiting, synchronization, timer data, and host-driven event runs.
//!
//! The package owns its blocking primitive, clocks, and sleep implementation. It calls operating-system APIs directly and does not initialize or depend on `std.Io` threaded facilities.

const native = @import("native.zig");

pub const Loop = @import("loop.zig").Loop;
pub const RunOptions = @import("loop.zig").RunOptions;
pub const Notifier = @import("loop.zig").Notifier;
pub const Timer = @import("loop.zig").Timer;
pub const Mutex = @import("sync.zig").Mutex;
pub const Condition = @import("sync.zig").Condition;
pub const ios_stdlib_overlay = @import("ios_stdlib_overlay.zig");

pub const Waiter = struct {
    state: native.State = native.init,

    pub const init: Waiter = .{};

    pub fn deinit(self: *Waiter) void {
        native.destroy(&self.state);
    }

    pub fn generation(self: *Waiter) u64 {
        return native.generation(&self.state);
    }
    pub fn signal(self: *Waiter) void {
        native.signal(&self.state);
    }
    pub fn broadcast(self: *Waiter) void {
        native.broadcast(&self.state);
    }
    pub fn waitUntilChange(self: *Waiter, expected_generation: u64, timeout_ms: ?u64) bool {
        return native.waitUntilChange(&self.state, expected_generation, timeout_ms);
    }
};

pub fn monotonicMilliseconds() u64 {
    return native.monotonicMilliseconds();
}
pub fn realtimeMilliseconds() u64 {
    return native.realtimeMilliseconds();
}
pub fn sleepMilliseconds(milliseconds: u64) void {
    native.sleepMilliseconds(milliseconds);
}
