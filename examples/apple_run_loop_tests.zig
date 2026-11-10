const std = @import("std");
const testing = std.testing;

const AppleRunLoop = opaque {};
const LoopTask = *const fn (?*anyopaque) callconv(.c) void;

extern fn jsbay_apple_run_loop_create() ?*AppleRunLoop;
extern fn jsbay_apple_run_loop_destroy(loop: *AppleRunLoop) void;
extern fn jsbay_apple_run_loop_schedule(loop: ?*anyopaque, delay_ms: u64, task: LoopTask, task_data: ?*anyopaque) callconv(.c) bool;
extern fn jsbay_apple_run_loop_cancel(loop: ?*anyopaque) callconv(.c) void;
extern fn jsbay_apple_run_loop_run(loop: *AppleRunLoop) bool;
extern fn jsbay_apple_run_loop_stop(loop: *AppleRunLoop) void;
extern fn jsbay_apple_run_loop_test_external_stop_fails(loop: *AppleRunLoop) bool;
extern fn jsbay_apple_run_loop_test_cancel_armed_timer(loop: *AppleRunLoop) bool;

const State = struct {
    loop: *AppleRunLoop,
    hits: usize = 0,
};

fn stopAfterTask(context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    state.hits += 1;
    jsbay_apple_run_loop_stop(state.loop);
}

fn countTask(context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    state.hits += 1;
}

const Worker = struct {
    loop: *AppleRunLoop,
    state: *State,
};

fn scheduleFromWorker(worker: *Worker) void {
    std.debug.assert(jsbay_apple_run_loop_schedule(worker.loop, 0, stopAfterTask, worker.state));
}

test "apple run loop accepts worker schedule" {
    const loop = jsbay_apple_run_loop_create() orelse return error.OutOfMemory;
    defer jsbay_apple_run_loop_destroy(loop);
    var state = State{ .loop = loop };
    var worker = Worker{ .loop = loop, .state = &state };
    const thread = try std.Thread.spawn(.{}, scheduleFromWorker, .{&worker});
    defer thread.join();

    try testing.expect(jsbay_apple_run_loop_run(loop));
    try testing.expectEqual(@as(usize, 1), state.hits);
}

test "apple run loop rejects an external stop" {
    const loop = jsbay_apple_run_loop_create() orelse return error.OutOfMemory;
    defer jsbay_apple_run_loop_destroy(loop);

    try testing.expect(jsbay_apple_run_loop_test_external_stop_fails(loop));
}

test "apple run loop cancels an armed timer" {
    const loop = jsbay_apple_run_loop_create() orelse return error.OutOfMemory;
    defer jsbay_apple_run_loop_destroy(loop);

    try testing.expect(jsbay_apple_run_loop_test_cancel_armed_timer(loop));
}

test "apple run loop rejects work after stop" {
    const loop = jsbay_apple_run_loop_create() orelse return error.OutOfMemory;
    defer jsbay_apple_run_loop_destroy(loop);
    var state = State{ .loop = loop };

    jsbay_apple_run_loop_stop(loop);
    try testing.expect(!jsbay_apple_run_loop_schedule(loop, 0, countTask, &state));
    try testing.expectEqual(@as(usize, 0), state.hits);
}
