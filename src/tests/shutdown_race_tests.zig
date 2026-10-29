//! Host shutdown races for the typical embedder pattern:
//! stop_loop → run_loop returns → inspector_stop → release values → destroy,
//! plus destroy-then-immediate-reuse / second-destroy waits, and post-destroy API inertia.
//!
//! These tests exercise the public C ABI on the owner thread (and one foreign stopper/
//! destroyer) so they match what embedded hosts actually call.

const std = @import("std");
const testing = std.testing;
const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const zev = @import("zev");
const io = @import("../platform/io.zig");

const API_OK: c_int = 0;
const API_INSTANCE_NOT_FOUND: c_int = 4;
const API_STALE_VALUE: c_int = 5;

const Api = struct {
    fn eval(id: i32, source: []const u8) !void {
        var value: u64 = 0;
        var exception: u64 = 0;
        try testing.expectEqual(API_OK, c_api.jsbay_engine_evaluate(
            id,
            .{ .data = source.ptr, .len = source.len },
            .{ .data = "shutdown-race.js".ptr, .len = "shutdown-race.js".len },
            null,
            &value,
            &exception,
        ));
        defer {
            if (value != 0) _ = c_api.jsbay_value_release(value);
            if (exception != 0) _ = c_api.jsbay_value_release(exception);
        }
    }

    fn bind(id: i32, name: []const u8, callback: *const fn (i32, ?*anyopaque, u64, usize, ?[*]const u64, *u64, *u64) callconv(.c) c_int, userdata: ?*anyopaque) !void {
        var function: u64 = 0;
        var exception: u64 = 0;
        try testing.expectEqual(API_OK, c_api.jsbay_engine_bind(
            id,
            .{ .data = name.ptr, .len = name.len },
            callback,
            userdata,
            null,
            &function,
            &exception,
        ));
        defer _ = c_api.jsbay_value_release(function);
        try testing.expectEqual(@as(u64, 0), exception);
    }
};

const StopProbe = struct {
    calls: std.atomic.Value(usize) = .init(0),

    fn stop(id: i32, userdata: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
        const self: *StopProbe = @ptrCast(@alignCast(userdata.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        out_exception.* = 0;
        _ = c_api.jsbay_engine_stop_loop(id);
        return c_api.jsbay_value_undefined(id, out_value);
    }
};

const DestroyFromHost = struct {
    entered: std.atomic.Value(bool) = .init(false),
    returned: std.atomic.Value(bool) = .init(false),

    fn destroy(id: i32, userdata: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
        const self: *DestroyFromHost = @ptrCast(@alignCast(userdata.?));
        self.entered.store(true, .seq_cst);
        out_value.* = 0;
        out_exception.* = 0;
        c_api.jsbay_engine_destroy(id);
        self.returned.store(true, .seq_cst);
        return 0;
    }
};

fn spinUntil(flag: *const std.atomic.Value(bool), timeout_ms: i64) bool {
    const start = io.monotonicMilliseconds();
    while (!flag.load(.seq_cst)) {
        if (io.monotonicMilliseconds() - start >= timeout_ms) return false;
        std.Thread.yield() catch {};
    }
    return true;
}

test "shutdown race: ordered stop → run returns → inspector_stop → release → destroy" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));

    var held: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(API_OK, c_api.jsbay_engine_evaluate(
        id,
        .{ .data = "({ keep: 1 })".ptr, .len = "({ keep: 1 })".len },
        .{ .data = "hold.js".ptr, .len = "hold.js".len },
        null,
        &held,
        &exception,
    ));
    try testing.expect(held != 0);
    try testing.expectEqual(@as(u64, 0), exception);

    const inspector_enabled = @import("build_options").inspector;
    if (comptime inspector_enabled) {
        var port: u16 = 0;
        try testing.expect(c_api.jsbay_engine_inspector_start(id, 0, &port));
        try testing.expect(port != 0);
    }

    var stop = StopProbe{};
    try Api.bind(id, "__shutdownStop", StopProbe.stop, &stop);
    try Api.eval(id, "setTimeout(__shutdownStop, 1)");

    try testing.expectEqual(API_OK, c_api.jsbay_engine_run_loop(id));
    try testing.expectEqual(@as(usize, 1), stop.calls.load(.seq_cst));

    if (comptime inspector_enabled) {
        c_api.jsbay_engine_inspector_stop(id);
    }

    try testing.expectEqual(API_OK, c_api.jsbay_value_release(held));
    held = 0;

    c_api.jsbay_engine_destroy(id);

    // Post-destroy inertia: control plane and owner APIs must not touch a freed runtime.
    try testing.expect(!c_api.jsbay_engine_stop_loop(id));
    try testing.expectEqual(API_INSTANCE_NOT_FOUND, c_api.jsbay_engine_run_loop(id));
    var dead_value: u64 = 0;
    var dead_exception: u64 = 0;
    try testing.expectEqual(API_INSTANCE_NOT_FOUND, c_api.jsbay_engine_evaluate(
        id,
        .{ .data = "1".ptr, .len = 1 },
        .{ .data = "dead.js".ptr, .len = "dead.js".len },
        null,
        &dead_value,
        &dead_exception,
    ));
    try testing.expectEqual(@as(u64, 0), dead_value);
    try testing.expect(engine.getContext(id) == null);
}

test "shutdown race: foreign stop_loop ends run_loop then destroy is clean" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));

    const Ready = struct {
        ready: zev.Waiter = .init,
        seen: std.atomic.Value(bool) = .init(false),

        fn ping(id_: i32, userdata: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.seen.store(true, .seq_cst);
            self.ready.signal();
            out_exception.* = 0;
            return c_api.jsbay_value_undefined(id_, out_value);
        }
    };
    var probe: Ready = .{};
    defer probe.ready.deinit();
    try Api.bind(id, "__shutdownReady", Ready.ping, &probe);
    try Api.eval(id, "setInterval(__shutdownReady, 1)");

    const ForeignStop = struct {
        fn run(instance: i32, state: *Ready) void {
            const gen = state.ready.generation();
            while (!state.seen.load(.seq_cst)) {
                if (!state.ready.waitUntilChange(gen, 5_000)) return;
            }
            _ = c_api.jsbay_engine_stop_loop(instance);
        }
    };
    const foreign = try std.Thread.spawn(.{}, ForeignStop.run, .{ id, &probe });
    defer foreign.join();

    try testing.expectEqual(API_OK, c_api.jsbay_engine_run_loop(id));
    try testing.expect(probe.seen.load(.seq_cst));

    c_api.jsbay_engine_destroy(id);
    try testing.expect(engine.getContext(id) == null);
    try testing.expect(!c_api.jsbay_engine_stop_loop(id));
}

test "shutdown race: foreign C destroy while run_loop active waits until runtime is gone" {
    // destroy is thread-safe and must join: host-style "destroy then terminate" relies on
    // the caller observing a finished teardown before killing the owner thread.
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));

    const Entered = struct {
        entered: std.atomic.Value(bool) = .init(false),

        fn tick(id_: i32, userdata: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.entered.store(true, .seq_cst);
            out_exception.* = 0;
            return c_api.jsbay_value_undefined(id_, out_value);
        }
    };
    var entered: Entered = .{};
    try Api.bind(id, "__loopTick", Entered.tick, &entered);
    try Api.eval(id, "setInterval(__loopTick, 1)");

    var destroy_done = std.atomic.Value(bool).init(false);
    const Destroyer = struct {
        fn run(instance: i32, gate: *Entered, done: *std.atomic.Value(bool)) void {
            _ = spinUntil(&gate.entered, 5_000);
            c_api.jsbay_engine_destroy(instance);
            done.store(true, .seq_cst);
        }
    };
    const destroyer = try std.Thread.spawn(.{}, Destroyer.run, .{ id, &entered, &destroy_done });

    const status = c_api.jsbay_engine_run_loop(id);

    if (!spinUntil(&destroy_done, 5_000)) {
        std.debug.print("foreign C destroy did not return after waking run_loop\n", .{});
        std.process.exit(1);
    }
    destroyer.join();

    try testing.expectEqual(API_OK, status);
    try testing.expect(entered.entered.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);
    try testing.expect(!c_api.jsbay_engine_stop_loop(id));
    // Idempotent after teardown finished.
    c_api.jsbay_engine_destroy(id);
}

test "shutdown race: held value survives until release-or-destroy; release after destroy is stale" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));

    var held: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(API_OK, c_api.jsbay_engine_evaluate(
        id,
        .{ .data = "'pin'".ptr, .len = "'pin'".len },
        .{ .data = "pin.js".ptr, .len = "pin.js".len },
        null,
        &held,
        &exception,
    ));
    try testing.expect(held != 0);

    // Destroy while the host still holds the handle. dropInstance frees the backend value;
    // a late release must not UAF (STALE once the handle table is cleared, or INSTANCE_NOT_FOUND
    // if teardown admission closed before dropInstance finished).
    c_api.jsbay_engine_destroy(id);
    try testing.expect(engine.getContext(id) == null);

    const release_status = c_api.jsbay_value_release(held);
    try testing.expect(release_status == API_STALE_VALUE or release_status == API_INSTANCE_NOT_FOUND);
}

test "shutdown race: deferred callback destroy; foreign C destroy waits until gone" {
    // Control thread destroy must join deferred owner-callback teardown before terminate.
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));

    var dying: DestroyFromHost = .{};
    try Api.bind(id, "__destroyNow", DestroyFromHost.destroy, &dying);
    try Api.eval(id, "setTimeout(__destroyNow, 0)");

    const SecondDestroy = struct {
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This(), instance: i32, gate: *DestroyFromHost) void {
            if (!spinUntil(&gate.entered, 5_000)) return;
            self.started.store(true, .seq_cst);
            c_api.jsbay_engine_destroy(instance);
            self.done.store(true, .seq_cst);
        }
    };
    var second: SecondDestroy = .{};
    const foreign = try std.Thread.spawn(.{}, SecondDestroy.run, .{ &second, id, &dying });

    try testing.expectEqual(API_OK, c_api.jsbay_engine_run_loop(id));
    try testing.expect(dying.entered.load(.seq_cst));
    try testing.expect(dying.returned.load(.seq_cst));

    if (!spinUntil(&second.done, 5_000)) {
        std.debug.print("second C destroy did not wait out deferred teardown\n", .{});
        std.process.exit(1);
    }
    foreign.join();

    try testing.expect(second.started.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);
    // Recreate on the same id must succeed after teardown finished.
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    c_api.jsbay_engine_destroy(id);
}

test "shutdown race: destroy on a never-created id is a finite no-op" {
    const id = helpers.nextInstanceId();
    c_api.jsbay_engine_destroy(id);
    c_api.jsbay_engine_destroy(id);
    try testing.expect(engine.getContext(id) == null);
    try testing.expect(!c_api.jsbay_engine_stop_loop(id));
}

test "shutdown race: destroy from timer callback leaves stop/run inert before host terminate" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));

    var dying: DestroyFromHost = .{};
    try Api.bind(id, "__die", DestroyFromHost.destroy, &dying);
    try Api.eval(id, "setTimeout(__die, 0)");

    try testing.expectEqual(API_OK, c_api.jsbay_engine_run_loop(id));
    try testing.expect(dying.returned.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);

    // Host may Worker.terminate() immediately after observing destroy return from the
    // owner thread's run_loop. Control plane must already be inert.
    try testing.expect(!c_api.jsbay_engine_stop_loop(id));
    try testing.expectEqual(API_INSTANCE_NOT_FOUND, c_api.jsbay_engine_run_loop(id));
    try testing.expectEqual(API_INSTANCE_NOT_FOUND, c_api.jsbay_engine_loop_status(id));
}
