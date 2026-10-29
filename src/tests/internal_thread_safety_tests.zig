//! Internal engine-thread safety regressions.  These use no C-facing thread execution API: production callers only use the owner-thread typed surface.

const std = @import("std");
const testing = std.testing;
const c_api = @import("../c_api.zig");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const host_value = @import("../abi/host_value.zig");
const helpers = @import("test_helpers.zig");

const status_ok: c_int = 0;
const status_out_of_memory: c_int = 5;
const status_destroyed: c_int = 2;
const status_exception: c_int = 3;

const DestroyNative = struct {
    calls: std.atomic.Value(u32) = .init(0),
    eval_active: std.atomic.Value(bool) = .init(false),

    fn callback(
        instance_id: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const host_value.HostValue,
        out: *host_value.HostValue,
    ) callconv(.c) c_int {
        const self: *DestroyNative = @ptrCast(@alignCast(user.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        self.eval_active.store(engine_thread.isEvalActiveOnCurrentThread(instance_id), .seq_cst);
        engine.destroy(instance_id);
        host_value.clear(out);
        return 0;
    }
};

fn createRunningInstance(id: i32) !void {
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    try testing.expect(engine_thread.threadStart(id));
}

test "internal thread run releases a terminal job when result-copy allocation fails" {
    const id = helpers.nextInstanceId();
    try createRunningInstance(id);
    defer if (engine.getContext(id) != null) {
        engine_thread.threadStop(id);
        engine.destroy(id);
    };

    var result: ?[]u8 = null;
    var err: ?[]u8 = null;
    engine_thread.failNextOutputCopyForTesting();
    try testing.expectEqual(
        status_out_of_memory,
        engine_thread.runScriptBytes(id, "'copy'", "<copy-oom>", 2_000, &result, &err),
    );
    try testing.expect(result == null);
    try testing.expect(err == null);
    try testing.expectEqual(@as(usize, 0), engine_thread.jobCountForTesting(id));

    try testing.expectEqual(
        status_ok,
        engine_thread.runScriptBytes(id, "'normal'", "<copy-after-oom>", 2_000, &result, &err),
    );
    defer if (result) |bytes| std.heap.c_allocator.free(bytes);
    defer if (err) |bytes| std.heap.c_allocator.free(bytes);
    try testing.expect(err == null);
    try testing.expectEqualStrings("normal", result orelse return error.MissingResult);
}

test "internal thread keeps typed result conversion admitted and reports its throw" {
    const id = helpers.nextInstanceId();
    try createRunningInstance(id);
    defer if (engine.getContext(id) != null) {
        engine_thread.threadStop(id);
        engine.destroy(id);
    };

    {
        var result: ?[]u8 = null;
        var err: ?[]u8 = null;
        defer if (result) |bytes| std.heap.c_allocator.free(bytes);
        defer if (err) |bytes| std.heap.c_allocator.free(bytes);
        try testing.expectEqual(
            status_exception,
            engine_thread.runScriptBytes(id, "({toString(){throw 7}})", "<to-string-throw>", 2_000, &result, &err),
        );
        try testing.expect(result == null);
        try testing.expectEqualStrings("7", err orelse return error.MissingSerializationThrow);
    }
    {
        var result: ?[]u8 = null;
        var err: ?[]u8 = null;
        defer if (result) |bytes| std.heap.c_allocator.free(bytes);
        defer if (err) |bytes| std.heap.c_allocator.free(bytes);
        try testing.expectEqual(
            status_ok,
            engine_thread.runScriptBytes(
                id,
                "({toString(){Promise.resolve().then(()=>globalThis.__serialized_microtask=41);return 'x'}})",
                "<to-string-microtask>",
                2_000,
                &result,
                &err,
            ),
        );
        try testing.expectEqualStrings("x", result orelse return error.MissingResult);
        try testing.expect(err == null);
    }
    {
        var result: ?[]u8 = null;
        var err: ?[]u8 = null;
        defer if (result) |bytes| std.heap.c_allocator.free(bytes);
        defer if (err) |bytes| std.heap.c_allocator.free(bytes);
        try testing.expectEqual(
            status_ok,
            engine_thread.runScriptBytes(id, "globalThis.__serialized_microtask", "<microtask-observe>", 2_000, &result, &err),
        );
        try testing.expect(err == null);
        try testing.expectEqualStrings("41", result orelse return error.MissingMicrotaskResult);
    }
}

test "internal thread destroy during typed result conversion publishes no result" {
    const id = helpers.nextInstanceId();
    try createRunningInstance(id);
    var destroy = DestroyNative{};
    try testing.expect(engine_thread.hostInstall(id, "destroyNative", DestroyNative.callback, &destroy));

    var result: ?[]u8 = null;
    var err: ?[]u8 = null;
    try testing.expectEqual(
        status_destroyed,
        engine_thread.runScriptBytes(
            id,
            "({toString(){destroyNative();return 'x'}})",
            "<to-string-destroy>",
            2_000,
            &result,
            &err,
        ),
    );
    try testing.expect(result == null);
    try testing.expect(err == null);
    try testing.expectEqual(@as(u32, 1), destroy.calls.load(.seq_cst));
    try testing.expect(destroy.eval_active.load(.seq_cst));
}

test "internal thread result conversion obeys execution limits" {
    const id = helpers.nextInstanceId();
    try createRunningInstance(id);
    defer if (engine.getContext(id) != null) {
        engine_thread.threadStop(id);
        engine.destroy(id);
    };
    var result: ?[]u8 = null;
    var err: ?[]u8 = null;
    defer if (result) |bytes| std.heap.c_allocator.free(bytes);
    defer if (err) |bytes| std.heap.c_allocator.free(bytes);

    try testing.expect(c_api.jsbay_engine_set_execution_time_limit(id, 25));
    try testing.expectEqual(
        status_exception,
        engine_thread.runScriptBytes(
            id,
            "({toString(){for(let i=0;i<1e9;i++);return 'late'}})",
            "<to-string-limit>",
            2_000,
            &result,
            &err,
        ),
    );
    try testing.expect(result == null);
    try testing.expect(err != null);

    if (err) |bytes| std.heap.c_allocator.free(bytes);
    err = null;

    try testing.expect(c_api.jsbay_engine_set_execution_time_limit(id, 0));
    if (backend.isQuickJsApiBackend(backend.active_backend)) {
        const rc = @import("../runtime/runtime_control.zig");
        try testing.expect(rc.clearInterrupt(id));
    }
    result = null;
    err = null;
    try testing.expectEqual(
        status_ok,
        engine_thread.runScriptBytes(id, "({toString(){for(let i=0;i<1000;i++);return 'ok'}})", "<to-string-no-limit>", 2_000, &result, &err),
    );
    try testing.expect(err == null);
    try testing.expectEqualStrings("ok", result orelse return error.MissingResult);
}
