//! Console event tap — a per-instance side-channel for console.log output.
//!
//! This module exists so a Chrome DevTools inspector (or any other observer) can subscribe to the pre-formatted string that the backends route into `log_handler`. The existing `log_handler` pathway is kept exactly as-is; backends call `fire` in parallel immediately after `log_handler` runs.
//!
//! ## Contract
//!
//! - `set` installs a callback keyed by instance_id. At most one tap per instance; installing a new one replaces (and returns) the prior.
//! - `clear` removes the tap for an instance (idempotent).
//! - `fire` is called by backends on every console.* invocation. If no tap is installed for the instance, it is a no-op.
//! - `dropInstance` is called during engine teardown to drop any lingering tap. Safe to call even if no tap was registered.
//!
//! ## Threading
//!
//! Expected to be called on the instance's owning thread (same model as log_handler). An internal mutex still protects the global map because engines can be created/destroyed on different threads. `fire` looks up and COPIES the entry under the lock, then releases the lock before invoking user code — user callbacks never run with the tap lock held.
//!
//! ## Reference
//!
//! Implementation mirrors `src/runtime/tsfn.zig`: lazy-init `AutoHashMap` behind a `sync.Mutex`.

const std = @import("std");
const sync = @import("zev");
const types = @import("../types.zig");

pub const Level = types.LogLevel;

pub const TapLease = struct {
    acquire: *const fn (ctx: ?*anyopaque) bool,
    release: *const fn (ctx: ?*anyopaque) void,
};

pub const TapCallback = *const fn (
    ctx: ?*anyopaque,
    instance_id: i32,
    level: Level,
    message: [*:0]const u8,
) callconv(.c) void;

/// Optional structured arguments for the callback invoked by `fire`.
///
/// Backends that can see the raw JS values (QuickJS) install this on the calling thread immediately before `fire` and clear it afterwards. The pointers are borrowed from that stack frame and are only valid until `fire` returns. Backends that leave it unset keep the joined-string path.
pub const ArgView = struct {
    ctx: ?*anyopaque,
    argc: usize,
    argv: ?*anyopaque,
    /// CDP `consoleAPICalled.type`. Empty means the inspector derives it from `LogLevel` (JSC, and QuickJS `console.log`).
    cdp_type: []const u8 = "",
    /// Borrowed until `fire` returns. The backend copies native frames into this shape, including the 0-based CDP line and column, so the inspector does not depend on a JS engine's frame layout.
    frames: []const CallFrame = &.{},
};

pub const CallFrame = struct {
    function_name: []const u8,
    url: []const u8,
    line: i32,
    column: i32,
    /// Native compilation identity when the backend exposes one; zero is unknown.
    script_tag: u64 = 0,
};

threadlocal var arg_view: ?ArgView = null;

pub fn setArgView(view: ?ArgView) void {
    arg_view = view;
}

pub fn currentArgView() ?ArgView {
    return arg_view;
}

const TapEntry = struct {
    ctx: ?*anyopaque,
    cb: TapCallback,
    lease: ?TapLease = null,
};

/// A leased observer. Backends acquire this before materializing optional debug-only arguments or stacks, then finish it after those borrowed values are ready. A missing observer performs no diagnostic work.
pub const ActiveTap = struct {
    entry: ?TapEntry = null,

    pub fn isActive(self: ActiveTap) bool {
        return self.entry != null;
    }

    pub fn finish(self: *ActiveTap, instance_id: i32, level: Level, message: [*:0]const u8) void {
        const e = self.entry orelse return;
        self.entry = null;
        defer if (e.lease) |lease| lease.release(e.ctx);
        e.cb(e.ctx, instance_id, level, message);
    }
};

var tap_mutex: sync.Mutex = .{};
var tap_map: ?std.AutoHashMap(i32, TapEntry) = null;

fn ensureMap() *std.AutoHashMap(i32, TapEntry) {
    if (tap_map == null) {
        tap_map = std.AutoHashMap(i32, TapEntry).init(std.heap.c_allocator);
    }
    return &tap_map.?;
}

/// Install (or replace) the tap for this instance. If a prior tap was registered, it is silently replaced — callers that want to chain must do so themselves.
///
/// Thread-safety: safe to call from any thread; map is mutex-protected.
pub fn set(instance_id: i32, ctx: ?*anyopaque, cb: TapCallback) void {
    setLeased(instance_id, ctx, cb, null);
}

pub fn setLeased(instance_id: i32, ctx: ?*anyopaque, cb: TapCallback, lease: ?TapLease) void {
    tap_mutex.lock();
    defer tap_mutex.unlock();
    const map = ensureMap();
    map.put(instance_id, .{ .ctx = ctx, .cb = cb, .lease = lease }) catch {
        // Out of memory — drop silently. The tap simply won't fire. This matches the log_handler path which also swallows dupeZ OOMs.
    };
}

/// Remove tap for instance (idempotent — no-op if none registered).
pub fn clear(instance_id: i32) void {
    tap_mutex.lock();
    defer tap_mutex.unlock();
    if (tap_map) |*m| {
        _ = m.remove(instance_id);
    }
}

/// Called by backends. No-op if no tap is set for this instance.
///
/// `message` must be a null-terminated UTF-8 string owned by the caller for the duration of the call. The tap is invoked OUTSIDE the global lock so user code cannot deadlock with `set`/`clear`.
pub fn begin(instance_id: i32) ActiveTap {
    const entry: ?TapEntry = blk: {
        tap_mutex.lock();
        defer tap_mutex.unlock();
        if (tap_map) |*m| {
            if (m.get(instance_id)) |e| {
                if (e.lease) |lease| {
                    if (!lease.acquire(e.ctx)) break :blk null;
                }
                break :blk e;
            }
        }
        break :blk null;
    };
    return .{ .entry = entry };
}

pub fn fire(instance_id: i32, level: Level, message: [*:0]const u8) void {
    var active = begin(instance_id);
    active.finish(instance_id, level, message);
}

/// Called during engine teardown to drop any lingering tap for this instance. Safe to call even if no tap was registered.
pub fn dropInstance(instance_id: i32) void {
    clear(instance_id);
}
