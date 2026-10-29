//! Observable scheduling contracts for the JS event loop.
//!
//! These tests intentionally use the public sync-binding and host-dispatch paths.  They do not reach into scheduler state: a host must not be able to make queued JavaScript run while a synchronous native call is active.

const std = @import("std");
const testing = std.testing;
const c_api = @import("../c_api.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const backend = @import("../backend.zig");
const tsfn = @import("../runtime/tsfn.zig");

const ActiveEngine = backend.ActiveEngine;

const TypedSyncProbe = struct {
    id: i32,
    function: u64,
    call_status: std.atomic.Value(c_int) = .init(-1),
    completion_thread: ?std.Thread = null,

    fn complete(request_id: u64) void {
        _ = c_api.jsbay_sync_complete(request_id, 0, 2, .{ .data = "null".ptr, .len = 4 });
    }

    fn start(instance_id: i32, data: ?*anyopaque, request_id: u64, _: u64, _: usize, _: ?[*]const u64) callconv(.c) void {
        const self: *TypedSyncProbe = @ptrCast(@alignCast(data.?));
        // This is a public typed call.  It is permitted to invoke the target native callback, but it must not use its API-exit job drain to run unrelated Promise work from the suspended outer script.
        var value: u64 = 0;
        var exception: u64 = 0;
        const status = c_api.jsbay_value_call(self.function, self.function, null, 0, &value, &exception);
        if (value != 0) _ = c_api.jsbay_value_release(value);
        if (exception != 0) _ = c_api.jsbay_value_release(exception);
        self.call_status.store(status, .seq_cst);
        self.completion_thread = std.Thread.spawn(.{}, complete, .{request_id}) catch unreachable;
        std.debug.assert(instance_id == self.id);
    }
};

fn typedNoop(instance_id: i32, _: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
    out_exception.* = 0;
    return c_api.jsbay_value_undefined(instance_id, out_value);
}

const SyncProbe = struct {
    id: i32,
    task_runs: std.atomic.Value(usize) = .init(0),
    tsfn_enqueued: std.atomic.Value(bool) = .init(false),
    tsfn_handle: ?tsfn.TsfnHandle = null,
    completion_thread: ?std.Thread = null,

    fn runQueuedTask(data: ?*anyopaque) void {
        const self: *SyncProbe = @ptrCast(@alignCast(data.?));
        _ = self.task_runs.fetchAdd(1, .seq_cst);
        const result = engine.evalScript(self.id, "globalThis.__js_event_loop_trace__.push('dispatch')", "<queued-dispatch>");
        helpers.freeEvalResult(result);
    }

    fn complete(request_id: u64) void {
        _ = c_api.jsbay_sync_complete(request_id, 0, 2, .{ .data = "null".ptr, .len = 4 });
    }

    fn start(instance_id: i32, data: ?*anyopaque, request_id: u64, _: u64, _: usize, _: ?[*]const u64) callconv(.c) void {
        const self: *SyncProbe = @ptrCast(@alignCast(data.?));
        std.debug.assert(instance_id == self.id);
        std.debug.assert(dispatch.postTask(instance_id, .{ .ctx = self, .run = runQueuedTask }));
        if (self.tsfn_handle) |handle| self.tsfn_enqueued.store(tsfn.call(handle, "sync-call"), .seq_cst);

        // A host is allowed to request a tick while setting up its native operation.  Until this synchronous call returns, that request must be remembered, not allowed to re-enter unrelated JavaScript.
        _ = c_api.test_only.advance(instance_id, 0);
        std.debug.assert(dispatch.tickInstance(instance_id) == 0);
        std.debug.assert(tsfn.drainPending(instance_id) == 0);

        self.completion_thread = std.Thread.spawn(.{}, complete, .{request_id}) catch unreachable;
    }
};

test "js event loop: a sync native call excludes queued JavaScript until its synchronous continuation" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var probe = SyncProbe{ .id = id };
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "syncWaitForNative";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind_sync(id, .{ .data = name.ptr, .len = name.len }, SyncProbe.start, &probe, null, 500, &function, &exception));
    defer _ = c_api.jsbay_value_release(function);

    try helpers.evalOk(id, "globalThis.__js_event_loop_sync_tsfn__ = () => __js_event_loop_trace__.push('tsfn');");
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const tsfn_name: [:0]const u8 = "__js_event_loop_sync_tsfn__";
    const tsfn_callback = ActiveEngine.getPropertyVal(ctx, global, tsfn_name.ptr) orelse return error.TsfnCallbackMissing;
    defer ActiveEngine.freeValue(ctx, tsfn_callback);
    const handle = tsfn.acquire(id, tsfn_callback) orelse return error.TsfnAcquireFailed;
    defer tsfn.release(handle);
    probe.tsfn_handle = handle;

    // `evalScript` has its own post-script microtask checkpoint, so setup and the synchronous native call must share one outer script.  This makes `after` observable as the last synchronous operation before that checkpoint, rather than letting setup itself drain the Promise first.
    const source =
        \\globalThis.__js_event_loop_trace__ = [];
        \\Promise.resolve().then(() => __js_event_loop_trace__.push('microtask'));
        \\setTimeout(() => __js_event_loop_trace__.push('timer'), 0);
        \\syncWaitForNative();
        \\__js_event_loop_trace__.push('after');
    ;
    try helpers.evalOk(id, source);
    if (probe.completion_thread) |thread| thread.join();

    try testing.expectEqual(@as(usize, 0), probe.task_runs.load(.seq_cst));
    try testing.expect(probe.tsfn_enqueued.load(.seq_cst));
    try helpers.expectEvalEquals(id, "__js_event_loop_trace__.join(',')", "after,microtask");

    // Dispatch, TSFN, and timer callbacks each occupy a separate turn.
    for (0..3) |_| _ = c_api.test_only.advance(id, 0);
    try helpers.expectEvalEquals(id, "JSON.stringify(__js_event_loop_trace__.slice().sort())", "[\"after\",\"dispatch\",\"microtask\",\"timer\",\"tsfn\"]");
    try testing.expectEqual(@as(usize, 1), probe.task_runs.load(.seq_cst));
}

test "js event loop: typed value calls inside sync native work do not drain the outer Promise" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var typed_function: u64 = 0;
    var exception: u64 = 0;
    const typed_name = "typedCallDuringSync";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = typed_name.ptr, .len = typed_name.len }, typedNoop, null, null, &typed_function, &exception));
    defer _ = c_api.jsbay_value_release(typed_function);

    var probe = TypedSyncProbe{ .id = id, .function = typed_function };
    var sync_function: u64 = 0;
    const sync_name = "syncTypedCall";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind_sync(id, .{ .data = sync_name.ptr, .len = sync_name.len }, TypedSyncProbe.start, &probe, null, 500, &sync_function, &exception));
    defer _ = c_api.jsbay_value_release(sync_function);

    try helpers.evalOk(id,
        \\globalThis.__js_event_loop_typed_trace__ = [];
        \\Promise.resolve().then(() => __js_event_loop_typed_trace__.push('microtask'));
        \\syncTypedCall();
        \\__js_event_loop_typed_trace__.push('after');
    );
    if (probe.completion_thread) |thread| thread.join();
    try testing.expectEqual(@as(c_int, 0), probe.call_status.load(.seq_cst));
    try helpers.expectEvalEquals(id, "__js_event_loop_typed_trace__.join(',')", "after,microtask");
}

test "js event loop: sync native work inside one Promise reaction cannot run the next reaction" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var typed_function: u64 = 0;
    var exception: u64 = 0;
    const typed_name = "typedCallInsidePromise";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = typed_name.ptr, .len = typed_name.len }, typedNoop, null, null, &typed_function, &exception));
    defer _ = c_api.jsbay_value_release(typed_function);

    var probe = TypedSyncProbe{ .id = id, .function = typed_function };
    var sync_function: u64 = 0;
    const sync_name = "syncTypedCallInsidePromise";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind_sync(id, .{ .data = sync_name.ptr, .len = sync_name.len }, TypedSyncProbe.start, &probe, null, 500, &sync_function, &exception));
    defer _ = c_api.jsbay_value_release(sync_function);

    try helpers.evalOk(id,
        \\globalThis.__js_event_loop_nested_sync_trace__ = [];
        \\Promise.resolve().then(() => {
        \\  __js_event_loop_nested_sync_trace__.push('A');
        \\  syncTypedCallInsidePromise();
        \\  __js_event_loop_nested_sync_trace__.push('afterA');
        \\});
        \\Promise.resolve().then(() => __js_event_loop_nested_sync_trace__.push('B'));
    );
    if (probe.completion_thread) |thread| thread.join();
    try testing.expectEqual(@as(c_int, 0), probe.call_status.load(.seq_cst));
    try helpers.expectEvalEquals(id, "__js_event_loop_nested_sync_trace__.join(',')", "A,afterA,B");
}

test "js event loop: an ordinary native callback cannot tick unrelated work into its caller" {
    const Probe = struct {
        const Self = @This();
        id: i32,
        task_runs: std.atomic.Value(usize) = .init(0),

        fn task(data: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(data.?));
            _ = self.task_runs.fetchAdd(1, .seq_cst);
            const result = engine.evalScript(self.id, "globalThis.__js_event_loop_native_trace__.push('task')", "<ordinary-native-task>");
            helpers.freeEvalResult(result);
        }
        fn callback(instance_id: i32, data: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
            const self: *Self = @ptrCast(@alignCast(data.?));
            std.debug.assert(dispatch.postTask(instance_id, .{ .ctx = self, .run = task }));
            _ = c_api.test_only.advance(instance_id, 0);
            out_exception.* = 0;
            return c_api.jsbay_value_undefined(instance_id, out_value);
        }
    };

    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var probe = Probe{ .id = id };
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "ordinaryReentrantTick";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = name.ptr, .len = name.len }, Probe.callback, &probe, null, &function, &exception));
    defer _ = c_api.jsbay_value_release(function);

    try helpers.evalOk(id,
        \\globalThis.__js_event_loop_native_trace__ = [];
        \\Promise.resolve().then(() => __js_event_loop_native_trace__.push('microtask'));
        \\setTimeout(() => __js_event_loop_native_trace__.push('timer'), 0);
        \\ordinaryReentrantTick();
        \\__js_event_loop_native_trace__.push('after');
    );
    try testing.expectEqual(@as(usize, 0), probe.task_runs.load(.seq_cst));
    try helpers.expectEvalEquals(id, "__js_event_loop_native_trace__.join(',')", "after,microtask");

    // The queued task and timer callback each occupy a separate turn.
    for (0..2) |_| _ = c_api.test_only.advance(id, 0);
    try helpers.expectEvalEquals(id, "JSON.stringify(__js_event_loop_native_trace__.slice().sort())", "[\"after\",\"microtask\",\"task\",\"timer\"]");
}

test "js event loop: a native callback from a microtask cannot insert a task into that checkpoint" {
    const Probe = struct {
        const Self = @This();
        id: i32,
        task_runs: std.atomic.Value(usize) = .init(0),

        fn task(data: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(data.?));
            _ = self.task_runs.fetchAdd(1, .seq_cst);
            const result = engine.evalScript(self.id, "globalThis.__js_event_loop_checkpoint_trace__.push('task')", "<checkpoint-task>");
            helpers.freeEvalResult(result);
        }
        fn callback(instance_id: i32, data: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
            const self: *Self = @ptrCast(@alignCast(data.?));
            std.debug.assert(dispatch.postTask(instance_id, .{ .ctx = self, .run = task }));
            _ = c_api.test_only.advance(instance_id, 0);
            out_exception.* = 0;
            return c_api.jsbay_value_undefined(instance_id, out_value);
        }
    };

    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var probe = Probe{ .id = id };
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "checkpointReentrantTick";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = name.ptr, .len = name.len }, Probe.callback, &probe, null, &function, &exception));
    defer _ = c_api.jsbay_value_release(function);

    try helpers.evalOk(id,
        \\globalThis.__js_event_loop_checkpoint_trace__ = [];
        \\Promise.resolve().then(() => {
        \\  __js_event_loop_checkpoint_trace__.push('microA');
        \\  checkpointReentrantTick();
        \\  __js_event_loop_checkpoint_trace__.push('microB');
        \\});
        \\Promise.resolve().then(() => __js_event_loop_checkpoint_trace__.push('microC'));
    );
    try testing.expectEqual(@as(usize, 0), probe.task_runs.load(.seq_cst));
    try helpers.expectEvalEquals(id, "__js_event_loop_checkpoint_trace__.join(',')", "microA,microB,microC");

    _ = c_api.test_only.advance(id, 0);
    try helpers.expectEvalEquals(id, "__js_event_loop_checkpoint_trace__.join(',')", "microA,microB,microC,task");
}

test "js event loop: every independent TSFN callback gets its microtask checkpoint before the next callback" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try helpers.evalOk(id,
        \\globalThis.__js_event_loop_order__ = [];
        \\globalThis.__js_event_loop_first__ = () => {
        \\  __js_event_loop_order__.push('A');
        \\  Promise.resolve().then(() => __js_event_loop_order__.push('microA'));
        \\};
        \\globalThis.__js_event_loop_second__ = () => __js_event_loop_order__.push('B');
    );
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const first_name: [:0]const u8 = "__js_event_loop_first__";
    const first_callback = ActiveEngine.getPropertyVal(ctx, global, first_name.ptr) orelse return error.FirstCallbackMissing;
    defer ActiveEngine.freeValue(ctx, first_callback);
    const second_name: [:0]const u8 = "__js_event_loop_second__";
    const second_callback = ActiveEngine.getPropertyVal(ctx, global, second_name.ptr) orelse return error.SecondCallbackMissing;
    defer ActiveEngine.freeValue(ctx, second_callback);
    const first = tsfn.acquire(id, first_callback) orelse return error.FirstTsfnAcquireFailed;
    defer tsfn.release(first);
    const second = tsfn.acquire(id, second_callback) orelse return error.SecondTsfnAcquireFailed;
    defer tsfn.release(second);
    try testing.expect(tsfn.call(first, "first"));
    try testing.expect(tsfn.call(second, "second"));

    _ = engine.testing.advance(id, 0);
    _ = engine.testing.advance(id, 0);
    try helpers.expectEvalEquals(id, "__js_event_loop_order__.join(',')", "A,microA,B");
}
