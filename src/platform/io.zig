//! Library-wide `std.Io` capability adapter.
//!
//! This library is a synchronous C-ABI wrapper with call sites that cannot accept an `Io` parameter, so it holds one process-wide capability value:
//!
//! - By default it is `std.Io.Threaded.global_single_threaded.io()`. This library uses its filesystem and networking operations without creating asynchronous tasks. Event-loop waiting and clocks use `zev`.
//! - `set()` lets an embedder override it (e.g. hand in a `Threaded` instance it owns and controls the lifetime of).
//!
//! We deliberately never call `std.Io.Threaded.init` ourselves: it installs process-wide SIGIO/SIGPIPE handlers, which is a surprising side effect for a library to impose on its host process.

const std = @import("std");
const zev = @import("zev");

var override: ?std.Io = null;

/// Returns the `Io` capability this library uses for filesystem and networking operations.
pub fn get() std.Io {
    return override orelse std.Io.Threaded.global_single_threaded.io();
}

/// Overrides the default `Io` capability for filesystem and networking operations.
pub fn set(io: std.Io) void {
    override = io;
}

/// Milliseconds since the Unix epoch.
pub fn milliTimestamp() i64 {
    return @intCast(@min(zev.realtimeMilliseconds(), @as(u64, std.math.maxInt(i64))));
}

/// Monotonic milliseconds for deadlines and elapsed-time decisions. Unlike `milliTimestamp`, this value is unaffected by wall-clock/NTP changes.
pub fn monotonicMilliseconds() i64 {
    return @intCast(@min(zev.monotonicMilliseconds(), @as(u64, std.math.maxInt(i64))));
}

/// Blocks the calling thread for `ms` milliseconds.
pub fn sleepMs(ms: i64) void {
    if (ms > 0) zev.sleepMilliseconds(@intCast(ms));
}
