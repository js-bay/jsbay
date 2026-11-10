//! L2 / Ungated gap probes for live `Driver.testing` — NOT explore acts.
//!
//! These tests intentionally call `dispatchEventsUngated` to lock the contract
//! that L2 still bypasses SyncWait / suspend while L0 does not. Keep them out
//! of `*_harness.zig` so CI can ban Ungated / `loop.dispatchEvents*` from
//! explore files without allowlisting call sites inside the same file.
//!
//! Run: `zig build test-state-tcas` (via state_tcas_harness aggregator).

const std = @import("std");
const js_event_loop = @import("js_event_loop");

const Driver = js_event_loop.Driver;
const Timer = js_event_loop.Timer;
const Notifier = js_event_loop.Notifier;

const early_deadline: u64 = 10;

fn emptyHooks(ctx: ?*anyopaque) Driver.Hooks {
    const H = struct {
        fn runTask(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
    };
    return .{
        .context = ctx,
        .run_one_task = H.runTask,
        .checkpoint = H.checkpoint,
        .next_task_deadline = H.nextDeadline,
    };
}

test "state_tcas Driver gap: dispatchEventsUngated bypasses sync_wait" {
    // L2 Ungated clamp-pushes the clock and calls Loop.dispatchEventsLimited
    // directly — it does not go through Scheduler.runTurn. During an open SyncWait
    // that means native Timer callbacks can still fire. L0 runOnce/advance is gated;
    // Ungated is the explicit escape (never an explore act).
    const Probe = struct {
        fired: usize = 0,
        fn timer(context: ?*anyopaque, _: *Timer) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).fired += 1;
        }
    };
    var probe = Probe{};
    const driver = try Driver.create(std.testing.allocator);
    defer driver.destroy();
    try Driver.testing.setNow(driver, 0);
    var timer: Timer = undefined;
    timer.init(driver, &probe, Probe.timer);
    defer timer.close();
    try timer.startAt(early_deadline);

    var wait = driver.scheduler.beginSyncWait();
    defer wait.end();
    Driver.testing.dispatchEventsUngated(driver, early_deadline + 5);
    try std.testing.expectEqual(@as(usize, 1), probe.fired);
    try std.testing.expect(!timer.isActive());
}

test "state_tcas Driver gap: dispatchEventsUngated bypasses suspend" {
    // Same contract as sync_wait: suspend gates L0 runOnce/advance/runAttached, but L2 still delivers due timers.
    const Probe = struct {
        fired: usize = 0,
        fn timer(context: ?*anyopaque, _: *Timer) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).fired += 1;
        }
    };
    var probe = Probe{};
    const driver = try Driver.create(std.testing.allocator);
    defer driver.destroy();
    try Driver.testing.setNow(driver, 0);
    var timer: Timer = undefined;
    timer.init(driver, &probe, Probe.timer);
    defer timer.close();
    try timer.startAt(early_deadline);

    driver.suspendScheduling();
    defer driver.resumeScheduling();
    _ = Driver.testing.advance(driver, emptyHooks(&probe), early_deadline + 5);
    try std.testing.expectEqual(@as(usize, 0), probe.fired);
    try std.testing.expect(timer.isActive());

    Driver.testing.dispatchEventsUngated(driver, early_deadline + 5);
    try std.testing.expectEqual(@as(usize, 1), probe.fired);
}

test "state_tcas Driver gap: dispatchEventsUngated drains Notifier while suspended" {
    const Probe = struct {
        notes: usize = 0,
        fn onNote(context: ?*anyopaque, _: *Notifier) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).notes += 1;
        }
    };
    var probe = Probe{};
    const driver = try Driver.create(std.testing.allocator);
    defer driver.destroy();
    try Driver.testing.setNow(driver, 0);
    var n: Notifier = undefined;
    n.init(driver, &probe, Probe.onNote);
    defer n.close();

    try std.testing.expect(n.notify());
    driver.suspendScheduling();
    defer driver.resumeScheduling();
    _ = Driver.testing.runOnce(driver, emptyHooks(&probe));
    try std.testing.expectEqual(@as(usize, 0), probe.notes);

    Driver.testing.dispatchEventsUngated(driver, driver.now());
    try std.testing.expectEqual(@as(usize, 1), probe.notes);
}
