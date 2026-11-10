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

/// Picture lock wrapper robust to Windows CRLF checkout conversions. If disk golden has `\r` but matches `expected` when stripped, rewrites with LF before locking.
pub fn lockNormalized(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: []const u8,
) !void {
    if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20))) |disk| {
        defer allocator.free(disk);
        if (std.mem.indexOfScalar(u8, disk, '\r') != null) {
            var clean = try allocator.alloc(u8, disk.len);
            defer allocator.free(clean);
            var i: usize = 0;
            for (disk) |c| {
                if (c != '\r') {
                    clean[i] = c;
                    i += 1;
                }
            }
            if (std.mem.eql(u8, expected, clean[0..i])) {
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = expected });
            }
        }
    } else |_| {}
    try state_tcas.picture.lock(io, allocator, path, expected);
}

/// DFS duck: world + Safety + Liveness.
pub fn Monitored(comptime Act: type, comptime World: type) type {
    return struct {
        inner: *World,
        saf: *state_tcas.monitor.Safety(*World),
        liv: *state_tcas.monitor.Liveness(*World),

        pub fn enabled(self: *@This()) []const Act {
            return self.inner.enabled();
        }

        pub fn step(self: *@This(), act: Act) !void {
            try self.inner.step(act);
            try self.saf.observe();
            self.liv.note();
        }

        pub fn undo(self: *@This(), act: Act) void {
            self.inner.undo(act);
        }
    };
}

/// dfsKeyed duck: monitored step plus `key` forwarded from the world.
pub fn MonitoredKeyed(comptime Act: type, comptime World: type) type {
    return struct {
        inner: *World,
        saf: *state_tcas.monitor.Safety(*World),
        liv: *state_tcas.monitor.Liveness(*World),

        pub fn enabled(self: *@This()) []const Act {
            return self.inner.enabled();
        }

        pub fn step(self: *@This(), act: Act) !void {
            try self.inner.step(act);
            try self.saf.observe();
            self.liv.note();
        }

        pub fn undo(self: *@This(), act: Act) void {
            self.inner.undo(act);
        }

        pub fn key(self: *const @This()) u64 {
            return self.inner.key();
        }
    };
}

/// dfsKeyed duck without monitors (world already folds checks into step, or prune-only smoke).
pub fn KeyedOnly(comptime Act: type, comptime World: type) type {
    return struct {
        inner: *World,

        pub fn enabled(self: *@This()) []const Act {
            return self.inner.enabled();
        }

        pub fn step(self: *@This(), act: Act) !void {
            try self.inner.step(act);
        }

        pub fn undo(self: *@This(), act: Act) void {
            self.inner.undo(act);
        }

        pub fn key(self: *const @This()) u64 {
            return self.inner.key();
        }
    };
}
