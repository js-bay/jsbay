//! Shared explore adapter ducks for state_tcas harnesses in this repo.
//! Forwards `enabled` / `step` / `undo` / optional `key` to a world type and, when monitored, runs Safety then Liveness after each step.
//! Prefer these over copy-pasted Legal/Keyed structs when the world already exposes the explore decls. Custom enabling filters stay local to the harness.

const std = @import("std");
const state_tcas = @import("state_tcas");

/// Monotonic nanoseconds for harness cost samples (Zig 0.17: `std.time.Timer` removed).
pub fn monoNs() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Clock.now(.awake, io);
    return @as(u64, @intCast(@max(ts.nanoseconds, 0)));
}

/// Picture lock wrapper robust to Windows CRLF checkout conversions (state_tcas v0.2.0 handles CRLF normalization natively in `state_tcas.picture.lock`).
pub fn lockNormalized(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: []const u8,
) !void {
    try state_tcas.picture.lock(io, allocator, path, expected);
}

pub const Monitored = state_tcas.Monitored;
pub const MonitoredKeyed = state_tcas.MonitoredKeyed;
pub const KeyedOnly = state_tcas.KeyedOnly;
