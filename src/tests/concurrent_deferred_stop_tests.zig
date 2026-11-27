const std = @import("std");
const testing = std.testing;
const engine = @import("../engine.zig");
const engine_thread_mod = @import("../runtime/engine_thread.zig");
const helpers = @import("test_helpers.zig");
const io = @import("../platform/io.zig");
const host_value = @import("../abi/host_value.zig");
const support = @import("engine_thread_tests.zig");

const JsBayHostValue = host_value.HostValue;

const ConcurrentDeferredStops = struct {
    shutdown_calls: std.atomic.Value(u32) = .init(0),
    finalize_calls: std.atomic.Value(u32) = .init(0),
    callback_entered: std.atomic.Value(bool) = .init(false),

    fn shutdownHook(user_data: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(user_data.?));
        _ = self.shutdown_calls.fetchAdd(1, .seq_cst);
    }

    fn finalizeHook(user_data: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(user_data.?));
        _ = self.finalize_calls.fetchAdd(1, .seq_cst);
        const deadline = io.monotonicMilliseconds() + 2_000;
        while (self.finalize_calls.load(.seq_cst) < 2) {
            if (io.monotonicMilliseconds() >= deadline) {
                std.debug.print("concurrent deferred stop did not reach both finalizers\n", .{});
                std.process.exit(1);
            }
            std.Thread.yield() catch {};
        }
    }

    fn destroyAfterBothStops(
        instance_id: c_int,
        user_data: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(user_data.?));
        self.callback_entered.store(true, .seq_cst);
        const deadline = io.monotonicMilliseconds() + 2_000;
        while (self.shutdown_calls.load(.seq_cst) < 2) {
            if (io.monotonicMilliseconds() >= deadline) {
                std.debug.print("concurrent deferred stop callback did not observe both stops\n", .{});
                std.process.exit(1);
            }
            std.Thread.yield() catch {};
        }
        engine.destroy(instance_id);
        support.clearHost(out);
        return 0;
    }
};

test "engine_thread: concurrent stop callers claim deferred teardown once" {
    try support.skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try support.createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();

    var race = ConcurrentDeferredStops{};
    try support.install(id, "destroyAfterBothStops", ConcurrentDeferredStops.destroyAfterBothStops, &race);
    try support.startThread(&live);
    try testing.expect(engine_thread_mod.setShutdownBeforeLifeHookForTesting(id, ConcurrentDeferredStops.shutdownHook, &race));
    try testing.expect(engine_thread_mod.setDeferredStopHookForTesting(id, ConcurrentDeferredStops.finalizeHook, &race));

    var poster = support.Poster{ .id = id, .src = "destroyAfterBothStops()" };
    const post_thread = try std.Thread.spawn(.{}, support.Poster.go, .{&poster});
    if (!support.spinUntil(&poster.returned, 1_000)) {
        std.debug.print("concurrent deferred stop setup: post did not return\n", .{});
        std.process.exit(1);
    }
    post_thread.join();
    if (!support.spinUntil(&race.callback_entered, 1_000)) {
        std.debug.print("concurrent deferred stop setup: callback did not enter\n", .{});
        std.process.exit(1);
    }

    var first = support.StopRunner{ .id = id };
    var second = support.StopRunner{ .id = id };
    const first_thread = try std.Thread.spawn(.{}, support.StopRunner.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, support.StopRunner.run, .{&second});
    support.joinOrExit(first_thread, &first.done, 3_000, "first deferred stop caller did not finish");
    support.joinOrExit(second_thread, &second.done, 3_000, "second deferred stop caller did not finish");

    cleanup = false;
    live.closed = true;
    live.started = false;
    try testing.expectEqual(@as(u32, 2), race.finalize_calls.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);
}
