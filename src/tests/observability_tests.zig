//! Multi-instance list + snapshot (any-thread observability).

const std = @import("std");
const testing = std.testing;
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");
const instance_map = @import("../runtime/instance_map.zig");

fn emptySnapshot() c_api.InstanceSnapshotC {
    return .{
        .struct_size = @sizeOf(c_api.InstanceSnapshotC),
        .instance_id = 0,
        .generation = 0,
        .owner_thread_id = 0,
        .loop_mode = 0,
        .flags = 0,
        .admission_class = .foreground,
        .timers_reserved = 0,
        .timers_registered = 0,
        .script_tasks_queued = 0,
        .native_tasks_queued = 0,
        .pending_bytes = 0,
        .max_timers = 0,
        .max_pending_tasks = 0,
        .max_pending_bytes = 0,
    };
}

test "observability: list reports 0/1/N live ids" {
    const before = c_api.jsbay_engine_list(null, 0);

    const a = helpers.nextInstanceId();
    const b = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(a, null, null));
    defer c_api.jsbay_engine_destroy(a);

    try testing.expectEqual(before + 1, c_api.jsbay_engine_list(null, 0));

    try testing.expect(c_api.jsbay_engine_create(b, null, null));
    defer c_api.jsbay_engine_destroy(b);

    const total = c_api.jsbay_engine_list(null, 0);
    try testing.expectEqual(before + 2, total);

    var buf: [8]c_int = undefined;
    const reported = c_api.jsbay_engine_list(&buf, 1);
    try testing.expectEqual(before + 2, reported);
    // Cap truncates the write but still returns the total.
    try testing.expect(buf[0] == a or buf[0] == b);

    var big: [64]c_int = undefined;
    const n = c_api.jsbay_engine_list(&big, big.len);
    try testing.expectEqual(before + 2, n);
    var saw_a = false;
    var saw_b = false;
    for (big[0..@min(n, big.len)]) |id| {
        if (id == a) saw_a = true;
        if (id == b) saw_b = true;
    }
    try testing.expect(saw_a and saw_b);
}

test "observability: snapshot suspend flag and defaults" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var snap = emptySnapshot();
    try testing.expect(c_api.jsbay_engine_snapshot(id, &snap));
    try testing.expectEqual(id, snap.instance_id);
    try testing.expect(snap.generation != 0);
    try testing.expect(snap.owner_thread_id != 0);
    try testing.expectEqual(@as(u8, 0), snap.flags & 0b1);
    try testing.expectEqual(c_api.AdmissionClassC.foreground, snap.admission_class);
    try testing.expect(snap.max_timers > 0);

    try testing.expect(c_api.jsbay_engine_suspend(id));
    snap = emptySnapshot();
    try testing.expect(c_api.jsbay_engine_snapshot(id, &snap));
    try testing.expectEqual(@as(u8, 1), snap.flags & 0b1);

    try testing.expect(c_api.jsbay_engine_resume(id));
    snap = emptySnapshot();
    try testing.expect(c_api.jsbay_engine_snapshot(id, &snap));
    try testing.expectEqual(@as(u8, 0), snap.flags & 0b1);
}

test "observability: snapshot rejects bad struct_size and missing id" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var bad = emptySnapshot();
    bad.struct_size = 4;
    try testing.expect(!c_api.jsbay_engine_snapshot(id, &bad));
    try testing.expect(!c_api.jsbay_engine_snapshot(id, null));

    const missing = helpers.nextInstanceId();
    var snap = emptySnapshot();
    try testing.expect(!c_api.jsbay_engine_snapshot(missing, &snap));
}

test "observability: destroy removes from list and snapshot returns false" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    var snap = emptySnapshot();
    try testing.expect(c_api.jsbay_engine_snapshot(id, &snap));
    c_api.jsbay_engine_destroy(id);

    snap = emptySnapshot();
    try testing.expect(!c_api.jsbay_engine_snapshot(id, &snap));

    var buf: [64]c_int = undefined;
    const n = c_api.jsbay_engine_list(&buf, buf.len);
    for (buf[0..@min(n, buf.len)]) |listed| {
        try testing.expect(listed != id);
    }
}

test "observability: side-thread snapshot during timers and sync wait" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    const Snapper = struct {
        id: c_int,
        stop: std.atomic.Value(bool) = .init(false),
        ok_count: std.atomic.Value(usize) = .init(0),
        saw_timers: std.atomic.Value(bool) = .init(false),
        saw_sync_wait: std.atomic.Value(bool) = .init(false),
        max_timers_reg: std.atomic.Value(usize) = .init(0),
        fn run(self: *@This()) void {
            while (!self.stop.load(.acquire)) {
                var snap = emptySnapshot();
                if (c_api.jsbay_engine_snapshot(self.id, &snap)) {
                    _ = self.ok_count.fetchAdd(1, .monotonic);
                    if (snap.timers_registered >= 20) self.saw_timers.store(true, .release);
                    if (snap.timers_registered > self.max_timers_reg.load(.monotonic)) {
                        self.max_timers_reg.store(snap.timers_registered, .monotonic);
                    }
                    if ((snap.flags & 0b0001_0000) != 0) self.saw_sync_wait.store(true, .release);
                }
                std.Thread.yield() catch {};
            }
        }
    };
    var snapper = Snapper{ .id = id };
    const snap_thr = try std.Thread.spawn(.{}, Snapper.run, .{&snapper});

    try helpers.evalOk(id, "globalThis.__obs_t = []; for (let i = 0; i < 40; i++) __obs_t.push(setTimeout(() => {}, 60000));");

    var spins: usize = 0;
    while (spins < 2000 and !snapper.saw_timers.load(.acquire)) : (spins += 1) std.Thread.yield() catch {};

    const Hold = struct {
        request_id: std.atomic.Value(u64) = .init(0),
        fn start(_: i32, data: ?*anyopaque, request_id: u64, _: u64, _: usize, _: ?[*]const u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(data orelse return));
            self.request_id.store(request_id, .release);
        }
    };
    var hold = Hold{};
    var function: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind_sync(id, .{ .data = "obsSync".ptr, .len = 7 }, &Hold.start, &hold, null, 2000, &function, &exception));
    defer _ = c_api.jsbay_value_release(function);

    const Completer = struct {
        hold: *Hold,
        snapper: *Snapper,
        fn run(self: *@This()) void {
            var i: usize = 0;
            while (self.hold.request_id.load(.acquire) == 0 and i < 5000) : (i += 1) std.Thread.yield() catch {};
            // Owner is now in SyncWait; give the snapper time to observe bit4.
            i = 0;
            while (!self.snapper.saw_sync_wait.load(.acquire) and i < 5000) : (i += 1) std.Thread.yield() catch {};
            const rid = self.hold.request_id.load(.acquire);
            if (rid != 0) {
                _ = c_api.jsbay_sync_complete(rid, 0, 0, .{ .data = "ok".ptr, .len = 2 });
            }
        }
    };
    var completer = Completer{ .hold = &hold, .snapper = &snapper };
    const complete_thr = try std.Thread.spawn(.{}, Completer.run, .{&completer});

    var value: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_evaluate(id, .{ .data = "obsSync()".ptr, .len = 9 }, .{ .data = "obs.js".ptr, .len = 6 }, null, &value, &exception));
    if (value != 0) _ = c_api.jsbay_value_release(value);
    if (exception != 0) _ = c_api.jsbay_value_release(exception);
    complete_thr.join();

    snapper.stop.store(true, .release);
    snap_thr.join();

    try testing.expect(snapper.ok_count.load(.monotonic) > 0);
    try testing.expect(snapper.saw_timers.load(.acquire));
    try testing.expect(snapper.max_timers_reg.load(.monotonic) >= 20);
    try testing.expect(snapper.saw_sync_wait.load(.acquire));
}

test "observability: teardown-pending omitted from list and snapshot" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));

    instance_map.markTeardownPending(id);

    var snap = emptySnapshot();
    try testing.expect(!c_api.jsbay_engine_snapshot(id, &snap));

    var buf: [64]c_int = undefined;
    const n = c_api.jsbay_engine_list(&buf, buf.len);
    for (buf[0..@min(n, buf.len)]) |listed| {
        try testing.expect(listed != id);
    }

    // Full destroy still succeeds after the early teardown mark.
    c_api.jsbay_engine_destroy(id);
    try testing.expect(!c_api.jsbay_engine_snapshot(id, &snap));
}
