const std = @import("std");
const t = std.testing;
const c = @import("../c_api.zig");
const engine = @import("../engine.zig");
const map = @import("../runtime/instance_map.zig");
const helpers = @import("test_helpers.zig");

const pending: c_int = 1;
const complete: c_int = 2;
const invalid: c_int = 3;
const wrong_thread: c_int = 4;
const stale: c_int = 5;

const Probe = struct {
    id: i32,
    generation: u64,
    owner: std.Thread.Id,
    calls: std.atomic.Value(usize) = .init(0),
    on_owner: std.atomic.Value(bool) = .init(false),
    reenter: bool = false,
    reenter_status: c_int = -1,

    fn finalize(raw: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        self.on_owner.store(self.owner == std.Thread.getCurrentId(), .seq_cst);
        if (self.reenter) self.reenter_status = c.jsbay_engine_drain_destroy(self.id, self.generation);
    }

    fn callback(_: i32, _: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out: *u64, exception: *u64) callconv(.c) c_int {
        out.* = 0;
        exception.* = 0;
        return 2;
    }
};

fn createProbe(id: i32, probe: *Probe) !void {
    try t.expect(c.jsbay_engine_create(id, null, null));
    probe.* = .{ .id = id, .generation = map.captureGeneration(id).?, .owner = std.Thread.getCurrentId() };
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "ownerDestroyProbe";
    try t.expectEqual(@as(c_int, 0), c.jsbay_engine_bind(id, .{ .data = name.ptr, .len = name.len }, Probe.callback, probe, Probe.finalize, &function, &exception));
    try t.expect(function != 0 and exception == 0);
    try t.expectEqual(@as(c_int, 0), c.jsbay_value_release(function));
    engine.testing.resetOwnerDestroyCounters();
}

fn expectReleased(probe: *Probe) !void {
    try t.expectEqual(@as(usize, 1), probe.calls.load(.seq_cst));
    try t.expect(probe.on_owner.load(.seq_cst));
    try t.expect(c.jsbay_engine_is_destroyed(probe.id, probe.generation));
    try t.expectEqual(@as(usize, 1), engine.testing.vm_free_calls.load(.seq_cst));
    try t.expectEqual(@as(usize, 1), engine.testing.context_free_calls.load(.seq_cst));
    try t.expectEqual(probe.owner, engine.testing.last_vm_free_tid.load(.seq_cst));
}

const Request = struct {
    id: i32,
    generation: u64,
    status: c_int = -1,
    drain_status: c_int = -1,
    fn run(self: *Request) void {
        self.status = c.jsbay_engine_request_destroy(self.id, self.generation);
        self.drain_status = c.jsbay_engine_drain_destroy(self.id, self.generation);
    }
};

test "owner destroy: foreign request returns pending without a pumping creator" {
    const id = helpers.nextInstanceId();
    var probe: Probe = undefined;
    try createProbe(id, &probe);
    defer engine.destroy(id);
    var request = Request{ .id = id, .generation = probe.generation };
    const worker = try std.Thread.spawn(.{}, Request.run, .{&request});
    worker.join();
    try t.expectEqual(pending, request.status);
    try t.expectEqual(wrong_thread, request.drain_status);
    try t.expectEqual(@as(usize, 0), probe.calls.load(.seq_cst));
    try t.expectEqual(@as(usize, 0), engine.testing.vm_free_calls.load(.seq_cst));
    for (0..10) |_| try t.expectEqual(pending, c.jsbay_engine_destroy_status(id, probe.generation));
    try t.expect(!c.jsbay_engine_is_destroyed(id, probe.generation));
    var value: u64 = 99;
    try t.expectEqual(@as(c_int, 4), c.jsbay_value_new_number(id, 42, &value));
    try t.expectEqual(@as(u64, 0), value);
    try t.expectEqual(complete, c.jsbay_engine_drain_destroy(id, probe.generation));
    try expectReleased(&probe);
    try t.expectEqual(complete, c.jsbay_engine_drain_destroy(id, probe.generation));
    try t.expectEqual(complete, c.jsbay_engine_request_destroy(id, probe.generation));
}

test "owner destroy: concurrent duplicate requests coalesce without duplicate finalizers" {
    const id = helpers.nextInstanceId();
    var probe: Probe = undefined;
    try createProbe(id, &probe);
    defer engine.destroy(id);
    var requests: [8]Request = undefined;
    var workers: [8]std.Thread = undefined;
    var started: usize = 0;
    defer for (workers[0..started]) |worker| worker.join();
    for (&requests, &workers) |*request, *worker| {
        request.* = .{ .id = id, .generation = probe.generation };
        worker.* = try std.Thread.spawn(.{}, Request.run, .{request});
        started += 1;
    }
    for (workers) |worker| worker.join();
    started = 0;
    for (requests) |request| {
        try t.expectEqual(pending, request.status);
        try t.expectEqual(wrong_thread, request.drain_status);
    }
    try t.expectEqual(complete, c.jsbay_engine_drain_destroy(id, probe.generation));
    try expectReleased(&probe);
}

test "owner destroy: callback requests defer cleanup until an explicit owner drain" {
    const id = helpers.nextInstanceId();
    var probe: Probe = undefined;
    try createProbe(id, &probe);
    defer engine.destroy(id);
    const Scope = struct {
        probe: *Probe,
        requested: c_int = -1,
        drained: c_int = -1,
        fn run(raw: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.requested = c.jsbay_engine_request_destroy(self.probe.id, self.probe.generation);
            self.drained = c.jsbay_engine_drain_destroy(self.probe.id, self.probe.generation);
        }
    };
    var scope = Scope{ .probe = &probe };
    try t.expectEqual(@as(c_int, 0), c.jsbay_engine_with_value_scope(id, Scope.run, &scope));
    try t.expectEqual(pending, scope.requested);
    try t.expectEqual(pending, scope.drained);
    try t.expectEqual(@as(usize, 0), probe.calls.load(.seq_cst));
    try t.expectEqual(@as(usize, 0), engine.testing.vm_free_calls.load(.seq_cst));
    try t.expectEqual(complete, c.jsbay_engine_drain_destroy(id, probe.generation));
    try expectReleased(&probe);
}

test "owner destroy: stale tokens cannot close a replacement instance" {
    const id = helpers.nextInstanceId();
    var probe: Probe = undefined;
    try createProbe(id, &probe);
    defer engine.destroy(id);
    const old = probe.generation;
    try t.expectEqual(invalid, c.jsbay_engine_request_destroy(id, 0));
    try t.expectEqual(pending, c.jsbay_engine_request_destroy(id, old));
    try t.expectEqual(complete, c.jsbay_engine_drain_destroy(id, old));
    try expectReleased(&probe);
    try t.expect(c.jsbay_engine_create(id, null, null));
    try t.expect(map.captureGeneration(id).? != old);
    try t.expectEqual(stale, c.jsbay_engine_request_destroy(id, old));
    try t.expectEqual(stale, c.jsbay_engine_drain_destroy(id, old));
    try t.expectEqual(complete, c.jsbay_engine_destroy_status(id, old));
    try helpers.expectEvalEquals(id, "40+2", "42");
}

test "owner destroy: control leases and legacy foreign calls cannot steal pending cleanup" {
    const id = helpers.nextInstanceId();
    var probe: Probe = undefined;
    try createProbe(id, &probe);
    defer engine.destroy(id);
    const lease = map.beginControlPlane(id).?;
    var request = Request{ .id = id, .generation = probe.generation };
    const worker = try std.Thread.spawn(.{}, Request.run, .{&request});
    worker.join();
    const held_status = c.jsbay_engine_drain_destroy(id, probe.generation);
    lease.end();
    try t.expectEqual(pending, held_status);
    try t.expectEqual(@as(usize, 0), probe.calls.load(.seq_cst));
    const Legacy = struct {
        fn run(instance_id: i32) void {
            c.jsbay_engine_destroy(instance_id);
        }
    };
    const legacy = try std.Thread.spawn(.{}, Legacy.run, .{id});
    legacy.join();
    try t.expectEqual(@as(usize, 0), probe.calls.load(.seq_cst));
    try t.expectEqual(pending, c.jsbay_engine_destroy_status(id, probe.generation));
    try t.expectEqual(complete, c.jsbay_engine_drain_destroy(id, probe.generation));
    try expectReleased(&probe);
}

test "owner destroy: finalizer reentry observes pending without recursion" {
    const id = helpers.nextInstanceId();
    var probe: Probe = undefined;
    try createProbe(id, &probe);
    defer engine.destroy(id);
    probe.reenter = true;
    try t.expectEqual(pending, c.jsbay_engine_request_destroy(id, probe.generation));
    try t.expectEqual(complete, c.jsbay_engine_drain_destroy(id, probe.generation));
    try t.expectEqual(pending, probe.reenter_status);
    try expectReleased(&probe);
}
