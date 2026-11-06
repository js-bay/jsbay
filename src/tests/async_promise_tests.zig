//! Public asynchronous Promise C ABI contract tests.

const std = @import("std");
const testing = std.testing;
const c_api = @import("../c_api.zig");
const api_async = @import("../abi/api_async.zig");
const api_backend = @import("../abi/api_backend.zig");
const backend = @import("../backend.zig");
const helpers = @import("test_helpers.zig");
const io = @import("../platform/io.zig");
const dispatch = @import("../runtime/dispatch.zig");

const kind_string: c_int = 0;
const kind_bytes: c_int = 1;
const kind_json: c_int = 2;
const kind_undefined: c_int = 3;

fn createPromise(id: i32) !struct { request: u64, promise: u64 } {
    var request: u64 = 0;
    var promise: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_promise_create(id, &request, &promise, &exception));
    try testing.expect(request != 0 and promise != 0 and exception == 0);
    return .{ .request = request, .promise = promise };
}

fn installPromise(id: i32, promise: u64, name: []const u8) !void {
    var global: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_global(id, &global));
    defer _ = c_api.jsbay_value_release(global);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_set(global, .{ .data = name.ptr, .len = name.len }, promise, &exception));
    try testing.expectEqual(@as(u64, 0), exception);
}

fn advance(id: i32) void {
    // Completion is deliberately queued. A host without an attached loop drives the
    // next owner turn explicitly; do not make background completion run JavaScript.
    _ = c_api.test_only.advance(id, 0);
}

test "async promise: cross-thread completion queues a string until the owner advances" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    const created = try createPromise(id);
    defer _ = c_api.jsbay_value_release(created.promise);
    try installPromise(id, created.promise, "asyncValue");
    try helpers.evalOk(id, "globalThis.asyncTrace=[]; asyncValue.then(value=>asyncTrace.push(value));");

    const Worker = struct {
        request: u64,
        result: std.atomic.Value(c_int) = .init(-1),
        fn run(self: *@This()) void {
            self.result.store(c_api.jsbay_async_complete(self.request, 0, kind_string, .{ .data = "done".ptr, .len = 4 }), .seq_cst);
        }
    };
    var worker = Worker{ .request = created.request };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    try testing.expectEqual(@as(c_int, 0), worker.result.load(.seq_cst));
    try helpers.expectEvalEquals(id, "asyncTrace.join(',')", "");
    advance(id);
    try helpers.expectEvalEquals(id, "asyncTrace.join(',')", "done");
}

test "async promise: completion payloads preserve JSON, bytes, undefined, and input validation" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    const json = try createPromise(id);
    defer _ = c_api.jsbay_value_release(json.promise);
    try installPromise(id, json.promise, "asyncJson");
    try helpers.evalOk(id, "globalThis.jsonValue=''; asyncJson.then(value=>jsonValue=value.answer);");
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(json.request, 0, kind_json, .{ .data = "{\"answer\":42}".ptr, .len = 13 }));
    advance(id);
    try helpers.expectEvalEquals(id, "String(jsonValue)", "42");

    const bytes = try createPromise(id);
    defer _ = c_api.jsbay_value_release(bytes.promise);
    try installPromise(id, bytes.promise, "asyncBytes");
    try helpers.evalOk(id, "globalThis.byteValue=''; asyncBytes.then(value=>byteValue=[...new Uint8Array(value)].join(','));");
    const binary = [_]u8{ 1, 2, 255 };
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(bytes.request, 0, kind_bytes, .{ .data = &binary, .len = binary.len }));
    advance(id);
    try helpers.expectEvalEquals(id, "byteValue", "1,2,255");

    const undef = try createPromise(id);
    defer _ = c_api.jsbay_value_release(undef.promise);
    try installPromise(id, undef.promise, "asyncUndefined");
    try helpers.evalOk(id, "globalThis.undefinedValue=false; asyncUndefined.then(value=>undefinedValue=value===undefined);");
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(undef.request, 0, kind_undefined, .{ .data = null, .len = 0 }));
    advance(id);
    try helpers.expectEvalEquals(id, "String(undefinedValue)", "true");

    const invalid = try createPromise(id);
    defer _ = c_api.jsbay_value_release(invalid.promise);
    const invalid_utf8 = [_]u8{0xff};
    try testing.expectEqual(@as(c_int, 2), c_api.jsbay_async_complete(invalid.request, 0, kind_string, .{ .data = &invalid_utf8, .len = invalid_utf8.len }));
    try testing.expectEqual(@as(c_int, 2), c_api.jsbay_async_complete(invalid.request, 1, kind_undefined, .{ .data = null, .len = 0 }));
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_cancel(invalid.request));
    advance(id);

    const malformed_json = try createPromise(id);
    defer _ = c_api.jsbay_value_release(malformed_json.promise);
    try installPromise(id, malformed_json.promise, "asyncMalformedJson");
    try helpers.evalOk(id, "globalThis.malformedJsonRejected=false; asyncMalformedJson.catch(()=>malformedJsonRejected=true);");
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(malformed_json.request, 0, kind_json, .{ .data = "{".ptr, .len = 1 }));
    advance(id);
    try helpers.expectEvalEquals(id, "String(malformedJsonRejected)", "true");
}

test "async promise: duplicate completion cannot change the first result" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    const created = try createPromise(id);
    defer _ = c_api.jsbay_value_release(created.promise);
    try installPromise(id, created.promise, "asyncOnce");
    try helpers.evalOk(id, "globalThis.onceValue=''; asyncOnce.then(value=>onceValue=value);");
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "first".ptr, .len = 5 }));
    try testing.expectEqual(@as(c_int, 5), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "second".ptr, .len = 6 }));
    try testing.expectEqual(@as(c_int, 5), c_api.jsbay_async_cancel(created.request));
    advance(id);
    try helpers.expectEvalEquals(id, "onceValue", "first");
}

test "async promise: cancellation rejects once and a nested reaction may destroy the engine" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    const created = try createPromise(id);
    try installPromise(id, created.promise, "asyncCancel");
    _ = c_api.jsbay_value_release(created.promise);
    try helpers.evalOk(id, "globalThis.cancelMessage=''; asyncCancel.catch(error=>{cancelMessage=error.message; return 1;}).then(()=>globalThis.__nestedAsyncClose__());");
    const Close = struct {
        fn callback(instance_id: i32, _: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, _: *u64) callconv(.c) c_int {
            c_api.jsbay_engine_destroy(instance_id);
            out_value.* = 0;
            return 0;
        }
    };
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "__nestedAsyncClose__";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = name.ptr, .len = name.len }, Close.callback, null, null, &function, &exception));
    _ = c_api.jsbay_value_release(function);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_cancel(created.request));
    advance(id);
    try testing.expect(!c_api.jsbay_engine_stop_loop(id));
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try helpers.expectEvalEquals(id, "String(6*7)", "42");
}

test "async promise: completion admission failure leaves a request retryable" {
    const id = helpers.nextInstanceId();
    var limits = c_api.ResourceLimitsC{
        .struct_size = @sizeOf(c_api.ResourceLimitsC),
        .max_timers = 0,
        .max_tsfn_handles = 0,
        .max_pending_calls = 1,
        .max_pending_bytes = 4,
        .max_pending_tasks = 1,
    };
    try testing.expect(c_api.jsbay_engine_create_with_limits(id, null, null, &limits));
    defer c_api.jsbay_engine_destroy(id);
    const created = try createPromise(id);
    defer _ = c_api.jsbay_value_release(created.promise);
    try testing.expectEqual(@as(c_int, 6), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "oversized".ptr, .len = 8 }));
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "ok".ptr, .len = 2 }));
    advance(id);
}

test "async promise: allocation failure before queue admission leaves a request retryable" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    const created = try createPromise(id);
    defer _ = c_api.jsbay_value_release(created.promise);
    dispatch.failNextQueueAllocationForTesting();
    try testing.expectEqual(@as(c_int, 6), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "retry".ptr, .len = 5 }));
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "retry".ptr, .len = 5 }));
    advance(id);
}

test "async promise: delivery allocation failure rejects after the heap limit is lifted" {
    if (comptime backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;

    const Platform = struct {
        task: ?c_api.LoopTask = null,
        data: ?*anyopaque = null,

        fn schedule(context: ?*anyopaque, _: u64, task: c_api.LoopTask, data: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context orelse return false));
            self.task = task;
            self.data = data;
            return true;
        }

        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.task = null;
            self.data = null;
        }

        fn driveOne(self: *@This()) !void {
            const task = self.task orelse return error.MissingScheduledTask;
            const data = self.data;
            self.task = null;
            self.data = null;
            task(data);
        }
    };

    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var platform: Platform = .{};
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(id, Platform.schedule, Platform.cancel, &platform));
    const created = try createPromise(id);
    defer _ = c_api.jsbay_value_release(created.promise);
    try installPromise(id, created.promise, "asyncOom");

    var payload: [64 * 1024]u8 = undefined;
    @memset(&payload, 'x');
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = &payload, .len = payload.len }));
    try testing.expect(c_api.jsbay_engine_set_memory_limit(id, 1));
    defer _ = c_api.jsbay_engine_set_memory_limit(id, 0);
    try platform.driveOne();
    try testing.expect(c_api.jsbay_engine_set_memory_limit(id, 0));

    try helpers.evalOk(id, "globalThis.asyncOomReason=''; asyncOom.catch(reason=>asyncOomReason=reason instanceof Error ? 'error' : 'not-error');");
    try helpers.expectEvalEquals(id, "asyncOomReason", "error");
    var usage: c_api.ResourceUsageC = undefined;
    usage.struct_size = @sizeOf(c_api.ResourceUsageC);
    try testing.expect(c_api.jsbay_engine_get_resource_usage(id, &usage));
    try testing.expectEqual(@as(usize, 0), usage.pending_calls);
}

test "async promise: cancellation allocation failure rejects after the heap limit is lifted" {
    if (comptime backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;
    const Platform = struct {
        task: ?c_api.LoopTask = null,
        data: ?*anyopaque = null,
        fn schedule(context: ?*anyopaque, _: u64, task: c_api.LoopTask, data: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context orelse return false));
            self.task = task;
            self.data = data;
            return true;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.task = null;
            self.data = null;
        }
        fn driveOne(self: *@This()) !void {
            const task = self.task orelse return error.MissingScheduledTask;
            const data = self.data;
            self.task = null;
            self.data = null;
            task(data);
        }
    };
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var platform: Platform = .{};
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(id, Platform.schedule, Platform.cancel, &platform));
    const created = try createPromise(id);
    defer _ = c_api.jsbay_value_release(created.promise);
    try installPromise(id, created.promise, "asyncCancelOom");
    try testing.expect(c_api.jsbay_engine_set_memory_limit(id, 1));
    defer _ = c_api.jsbay_engine_set_memory_limit(id, 0);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_cancel(created.request));
    try platform.driveOne();
    try testing.expect(c_api.jsbay_engine_set_memory_limit(id, 0));
    try helpers.evalOk(id, "globalThis.asyncCancelOomReason=''; asyncCancelOom.catch(reason=>asyncCancelOomReason=reason instanceof Error ? 'error' : 'not-error');");
    try helpers.expectEvalEquals(id, "asyncCancelOomReason", "error");
}

test "async promise: completion constructor failure rejects with an Error and releases capacity" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    const created = try createPromise(id);
    defer _ = c_api.jsbay_value_release(created.promise);
    try installPromise(id, created.promise, "asyncConstructorOom");
    api_backend.failNextConstructorForTesting();
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "value".ptr, .len = 5 }));
    advance(id);
    try helpers.evalOk(id, "globalThis.asyncConstructorOomReason=''; asyncConstructorOom.catch(reason=>asyncConstructorOomReason=reason instanceof Error ? 'error' : 'not-error');");
    try helpers.expectEvalEquals(id, "asyncConstructorOomReason", "error");
    var usage: c_api.ResourceUsageC = undefined;
    usage.struct_size = @sizeOf(c_api.ResourceUsageC);
    try testing.expect(c_api.jsbay_engine_get_resource_usage(id, &usage));
    try testing.expectEqual(@as(usize, 0), usage.pending_calls);
}

test "async promise: failed admission leaves a concurrent cancellation retryable" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    const created = try createPromise(id);
    defer _ = c_api.jsbay_value_release(created.promise);
    const Probe = struct {
        request: u64,
        status: c_int = -1,
        fn hook(_: u64, context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            api_async.setAfterClaimHookForTesting(null, null);
            self.status = c_api.jsbay_async_cancel(self.request);
        }
    };
    var probe = Probe{ .request = created.request };
    api_async.setAfterClaimHookForTesting(Probe.hook, &probe);
    defer api_async.setAfterClaimHookForTesting(null, null);
    dispatch.failNextQueueAllocationForTesting();
    try testing.expectEqual(@as(c_int, 6), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "retry".ptr, .len = 5 }));
    try testing.expectEqual(@as(c_int, 6), probe.status);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(created.request, 0, kind_undefined, .{ .data = null, .len = 0 }));
    advance(id);
}

test "async promise: pending-call capacity is released after settlement" {
    const id = helpers.nextInstanceId();
    var limits = c_api.ResourceLimitsC{
        .struct_size = @sizeOf(c_api.ResourceLimitsC),
        .max_timers = 0,
        .max_tsfn_handles = 0,
        .max_pending_calls = 1,
        .max_pending_bytes = 64,
        .max_pending_tasks = 4,
    };
    try testing.expect(c_api.jsbay_engine_create_with_limits(id, null, null, &limits));
    defer c_api.jsbay_engine_destroy(id);
    const first = try createPromise(id);
    defer _ = c_api.jsbay_value_release(first.promise);
    var usage: c_api.ResourceUsageC = undefined;
    usage.struct_size = @sizeOf(c_api.ResourceUsageC);
    try testing.expect(c_api.jsbay_engine_get_resource_usage(id, &usage));
    try testing.expectEqual(@as(usize, 1), usage.pending_calls);
    var request: u64 = 9;
    var promise: u64 = 9;
    var exception: u64 = 9;
    try testing.expectEqual(@as(c_int, 6), c_api.jsbay_promise_create(id, &request, &promise, &exception));
    try testing.expect(request == 0 and promise == 0 and exception == 0);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(first.request, 0, kind_undefined, .{ .data = null, .len = 0 }));
    advance(id);
    usage = undefined;
    usage.struct_size = @sizeOf(c_api.ResourceUsageC);
    try testing.expect(c_api.jsbay_engine_get_resource_usage(id, &usage));
    try testing.expectEqual(@as(usize, 0), usage.pending_calls);
    const second = try createPromise(id);
    defer _ = c_api.jsbay_value_release(second.promise);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_cancel(second.request));
    advance(id);
}

test "async promise: owner settle accepts only a value owned by the same instance" {
    const id = helpers.nextInstanceId();
    const other_id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try testing.expect(c_api.jsbay_engine_create(other_id, null, null));
    defer c_api.jsbay_engine_destroy(other_id);
    const created = try createPromise(id);
    defer _ = c_api.jsbay_value_release(created.promise);
    try installPromise(id, created.promise, "asyncOwner");
    try helpers.evalOk(id, "globalThis.ownerValue=''; asyncOwner.then(value=>ownerValue=value);");
    var foreign: u64 = 0;
    var exception: u64 = 0;
    const source = "'foreign'";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_evaluate(other_id, .{ .data = source.ptr, .len = source.len }, .{ .data = "<foreign>".ptr, .len = 9 }, null, &foreign, &exception));
    defer _ = c_api.jsbay_value_release(foreign);
    try testing.expectEqual(@as(c_int, 2), c_api.jsbay_promise_settle(created.request, 0, foreign));
    var local: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_new_string(id, .{ .data = "local".ptr, .len = 5 }, &local));
    defer _ = c_api.jsbay_value_release(local);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_promise_settle(created.request, 0, local));
    try helpers.expectEvalEquals(id, "ownerValue", "local");
}

test "async promise: owner settle rejects a non-owner thread without consuming the request" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    const created = try createPromise(id);
    defer _ = c_api.jsbay_value_release(created.promise);
    var value: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_new_string(id, .{ .data = "owner".ptr, .len = 5 }, &value));
    defer _ = c_api.jsbay_value_release(value);
    const Worker = struct {
        request: u64,
        value: u64,
        result: std.atomic.Value(c_int) = .init(-1),
        fn run(self: *@This()) void {
            self.result.store(c_api.jsbay_promise_settle(self.request, 0, self.value), .seq_cst);
        }
    };
    var worker = Worker{ .request = created.request, .value = value };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    try testing.expectEqual(@as(c_int, 3), worker.result.load(.seq_cst));
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_promise_settle(created.request, 0, value));
}

test "async promise: direct owner settlement survives a reaction that destroys the engine" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    const created = try createPromise(id);
    try installPromise(id, created.promise, "directSettle");
    _ = c_api.jsbay_value_release(created.promise);
    const Close = struct {
        fn callback(instance_id: i32, _: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, _: *u64) callconv(.c) c_int {
            c_api.jsbay_engine_destroy(instance_id);
            out_value.* = 0;
            return 0;
        }
    };
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "directSettleClose";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = name.ptr, .len = name.len }, Close.callback, null, null, &function, &exception));
    _ = c_api.jsbay_value_release(function);
    try helpers.evalOk(id, "directSettle.then(()=>directSettleClose());");
    var value: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_new_string(id, .{ .data = "value".ptr, .len = 5 }, &value));
    defer _ = c_api.jsbay_value_release(value);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_promise_settle(created.request, 0, value));
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try helpers.expectEvalEquals(id, "String(6*7)", "42");
}

test "async promise: JSON rejection preserves the value while string rejection creates an Error" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    const json = try createPromise(id);
    defer _ = c_api.jsbay_value_release(json.promise);
    try installPromise(id, json.promise, "jsonReject");
    try helpers.evalOk(id, "globalThis.jsonRejectKind=''; jsonReject.catch(value=>jsonRejectKind=typeof value+':'+String(value));");
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(json.request, 1, kind_json, .{ .data = "42".ptr, .len = 2 }));
    advance(id);
    try helpers.expectEvalEquals(id, "jsonRejectKind", "number:42");

    const string = try createPromise(id);
    defer _ = c_api.jsbay_value_release(string.promise);
    try installPromise(id, string.promise, "stringReject");
    try helpers.evalOk(id, "globalThis.stringRejectKind=''; stringReject.catch(value=>stringRejectKind=(value instanceof Error)+':'+value.message);");
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(string.request, 1, kind_string, .{ .data = "failure".ptr, .len = 7 }));
    advance(id);
    try helpers.expectEvalEquals(id, "stringRejectKind", "true:failure");
}

test "async promise: destroy makes accepted completion stale and an old request cannot affect a reused id" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    const created = try createPromise(id);
    _ = c_api.jsbay_value_release(created.promise);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "late".ptr, .len = 4 }));
    c_api.jsbay_engine_destroy(id);
    try testing.expectEqual(@as(c_int, 5), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "late".ptr, .len = 4 }));
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try helpers.expectEvalEquals(id, "String(6*7)", "42");
}

test "async promise: generation cancellation drops queued work without entering the VM" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    var snapshot: c_api.InstanceSnapshotC = undefined;
    snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try testing.expect(c_api.jsbay_engine_snapshot(id, &snapshot));
    const created = try createPromise(id);
    try installPromise(id, created.promise, "asyncGeneration");
    _ = c_api.jsbay_value_release(created.promise);
    const SideEffect = struct {
        fn callback(_: i32, user_data: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, _: *u64) callconv(.c) c_int {
            const calls: *usize = @ptrCast(@alignCast(user_data orelse unreachable));
            calls.* += 1;
            out_value.* = 0;
            return 0;
        }
    };
    var calls: usize = 0;
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "generationSideEffect";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = name.ptr, .len = name.len }, SideEffect.callback, @ptrCast(&calls), null, &function, &exception));
    _ = c_api.jsbay_value_release(function);
    try helpers.evalOk(id, "asyncGeneration.then(()=>generationSideEffect());");
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "queued".ptr, .len = 6 }));
    try testing.expect(c_api.jsbay_engine_cancel(id, snapshot.generation));
    advance(id);
    try testing.expectEqual(@as(usize, 0), calls);
    try testing.expectEqual(@as(c_int, 5), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "late".ptr, .len = 4 }));
    c_api.jsbay_engine_destroy(id);
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try helpers.expectEvalEquals(id, "String(6*7)", "42");
}

test "async promise: shutdown deadline rejects late completion without entering the VM" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    var snapshot: c_api.InstanceSnapshotC = undefined;
    snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try testing.expect(c_api.jsbay_engine_snapshot(id, &snapshot));
    const created = try createPromise(id);
    try installPromise(id, created.promise, "shutdownDeadline");
    _ = c_api.jsbay_value_release(created.promise);
    const SideEffect = struct {
        fn callback(_: i32, user_data: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, _: *u64) callconv(.c) c_int {
            const calls: *usize = @ptrCast(@alignCast(user_data orelse unreachable));
            calls.* += 1;
            out_value.* = 0;
            return 0;
        }
    };
    var calls: usize = 0;
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "shutdownDeadlineSideEffect";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = name.ptr, .len = name.len }, SideEffect.callback, @ptrCast(&calls), null, &function, &exception));
    _ = c_api.jsbay_value_release(function);
    try helpers.evalOk(id, "shutdownDeadline.then(()=>shutdownDeadlineSideEffect());");
    try testing.expect(c_api.jsbay_engine_begin_shutdown(id, snapshot.generation, 2));
    const wait_until = io.monotonicMilliseconds() + 500;
    var status = c_api.ShutdownStatusC{ .phase = 0, .remaining_ms = 0 };
    while (true) {
        try testing.expect(c_api.jsbay_engine_shutdown_status(id, snapshot.generation, &status));
        if (status.phase == 4) break;
        if (io.monotonicMilliseconds() >= wait_until) return error.ShutdownDeadlineDidNotExpire;
        io.sleepMs(1);
    }
    try testing.expectEqual(@as(c_int, 5), c_api.jsbay_async_complete(created.request, 0, kind_string, .{ .data = "late".ptr, .len = 4 }));
    advance(id);
    try testing.expectEqual(@as(usize, 0), calls);
    c_api.jsbay_engine_destroy(id);
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try helpers.expectEvalEquals(id, "String(6*7)", "42");
}

test "async promise: concurrent completion and destroy never reaches a recreated instance" {
    var iteration: usize = 0;
    while (iteration < 24) : (iteration += 1) {
        const id = helpers.nextInstanceId();
        try testing.expect(c_api.jsbay_engine_create(id, null, null));
        const created = try createPromise(id);
        _ = c_api.jsbay_value_release(created.promise);
        const Worker = struct {
            request: u64,
            result: std.atomic.Value(c_int) = .init(-1),
            fn run(self: *@This()) void {
                self.result.store(c_api.jsbay_async_complete(self.request, 0, kind_string, .{ .data = "race".ptr, .len = 4 }), .seq_cst);
            }
        };
        var worker = Worker{ .request = created.request };
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        c_api.jsbay_engine_destroy(id);
        thread.join();
        const outcome = worker.result.load(.seq_cst);
        try testing.expect(outcome == 0 or outcome == 5);
        try testing.expect(c_api.jsbay_engine_create(id, null, null));
        try helpers.expectEvalEquals(id, "String(6*7)", "42");
        c_api.jsbay_engine_destroy(id);
    }
}
