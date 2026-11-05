//! Capability-gated smoke for Escargot/Hermes native backends.
const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const c_api = @import("../c_api.zig");
const runtime_control = @import("../runtime/runtime_control.zig");

test "spike smoke: Global survives unrelated eval" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id, "1+1", "2");
            try helpers.expectEvalEquals(id, "'hi'", "hi");
            try helpers.expectEvalEquals(id, "typeof globalThis", "object");
            try helpers.expectEvalEquals(id, "var __spike = 7; __spike", "7");
            try helpers.expectEvalEquals(id, "__spike + 1", "8");
        }
    }.run);
}

test "spike smoke: create/destroy engine cycle" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            try helpers.expectEvalEquals(inst, "({a:1}).a", "1");
            try helpers.expectEvalEquals(inst, "[1,2,3].length", "3");
            try helpers.expectEvalEquals(inst, "JSON.stringify({x:true})", "{\"x\":true}");
        }
    }.run);
}

test "spike smoke: syntax error surfaces" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalErr(id, "@@@");
        }
    }.run);
}

test "spike smoke: two instances are isolated" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    const a = helpers.nextInstanceId();
    const b = helpers.nextInstanceId();
    try helpers.withEngine(a, .{}, struct {
        fn run(inst: i32) !void {
            try helpers.expectEvalEquals(inst, "globalThis.__iso = 'A'; __iso", "A");
        }
    }.run);
    try helpers.withEngine(b, .{}, struct {
        fn run(inst: i32) !void {
            try helpers.expectEvalEquals(inst, "typeof globalThis.__iso", "undefined");
            try helpers.expectEvalEquals(inst, "globalThis.__iso = 'B'; __iso", "B");
        }
    }.run);
}

var g_bind_fin_count: u32 = 0;
fn bindFin(ptr: ?*anyopaque) callconv(.c) void {
    _ = ptr;
    g_bind_fin_count += 1;
}

fn bindReturn42(instance_id: i32, _: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
    out_exception.* = 0;
    return c_api.jsbay_value_new_number(instance_id, 42, out_value);
}

fn bindIncCounter(instance_id: i32, data: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
    out_exception.* = 0;
    const counter: *i32 = @ptrCast(@alignCast(data orelse {
        out_value.* = 0;
        return 2;
    }));
    counter.* += 1;
    return c_api.jsbay_value_new_number(instance_id, @floatFromInt(counter.*), out_value);
}

test "spike smoke: public bind finalize on teardown" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    g_bind_fin_count = 0;
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "spikeBindFin";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(
        id,
        .{ .data = name.ptr, .len = name.len },
        bindReturn42,
        null,
        bindFin,
        &function,
        &exception,
    ));
    if (function != 0) _ = c_api.jsbay_value_release(function);
    if (exception != 0) _ = c_api.jsbay_value_release(exception);
    c_api.jsbay_engine_destroy(id);
    try testing.expect(g_bind_fin_count >= 1);
}

test "spike smoke: public bind callable returns 42" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "nh";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(
        id,
        .{ .data = name.ptr, .len = name.len },
        bindReturn42,
        null,
        null,
        &function,
        &exception,
    ));
    defer if (function != 0) {
        _ = c_api.jsbay_value_release(function);
    };
    defer if (exception != 0) {
        _ = c_api.jsbay_value_release(exception);
    };
    try helpers.expectEvalEquals(id, "nh()", "42");
    try helpers.expectEvalEquals(id, "typeof nh", "function");
}

test "spike smoke: public bind mutates userdata counter" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var counter: i32 = 0;
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "inc";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(
        id,
        .{ .data = name.ptr, .len = name.len },
        bindIncCounter,
        @ptrCast(&counter),
        null,
        &function,
        &exception,
    ));
    defer if (function != 0) {
        _ = c_api.jsbay_value_release(function);
    };
    defer if (exception != 0) {
        _ = c_api.jsbay_value_release(exception);
    };
    try helpers.expectEvalEquals(id, "typeof inc", "function");
    try helpers.expectEvalEquals(id, "inc()", "1");
    try helpers.expectEvalEquals(id, "inc()", "2");
    try testing.expectEqual(@as(i32, 2), counter);
}

test "spike smoke: engine_thread start / id / stop" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    // Minimal contract only: post/wait still throws on Escargot spike (status=exception) — leave full suite to non-spike.
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer {
        engine_thread.threadStop(id);
        engine.destroy(id);
    }
    try testing.expect(engine_thread.threadStart(id));
    var spins: usize = 0;
    while (engine_thread.threadId(id) == 0 and spins < 10_000) : (spins += 1) {
        std.Thread.yield() catch {};
    }
    try testing.expect(engine_thread.threadId(id) != 0);
    engine_thread.threadStop(id);
    try testing.expectEqual(@as(u64, 0), engine_thread.threadId(id));
}

test "spike smoke: engine_thread post/wait eval" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    // Escargot: vendor rebuilt with ENABLE_THREADING + TLS_ACCESS_BY_PTHREAD_KEY;
    // escargot_thread_enter/leave call Globals::initializeThread/finalizeThread.
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer {
        engine_thread.threadStop(id);
        engine.destroy(id);
    }
    try testing.expect(engine_thread.threadStart(id));
    var spins: usize = 0;
    while (engine_thread.threadId(id) == 0 and spins < 10_000) : (spins += 1) {
        std.Thread.yield() catch {};
    }
    try testing.expect(engine_thread.threadId(id) != 0);
    const src = "40 + 2";
    const fname = "<spike-et>";
    const job = c_api.test_only.threadPost(id, src.ptr, src.len, fname.ptr, fname.len);
    try testing.expect(job != 0);
    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    const st = c_api.test_only.threadWait(id, job, 2000, &result, &err);
    defer if (result) |r| c_api.test_only.freeCString(r);
    defer if (err) |e| c_api.test_only.freeCString(e);
    if (st != 0) {
        const msg = if (err) |e| std.mem.span(e) else "(null)";
        std.debug.print("spike et post/wait status={d} err={s}\n", .{ st, msg });
    }
    try testing.expectEqual(@as(c_int, 0), st);
    try testing.expect(result != null);
    try testing.expectEqualStrings("42", std.mem.span(result.?));
}

test "spike smoke: getMemoryUsage soft stats; setMemoryLimit rejected" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id,
                \\const xs = [];
                \\for (let i = 0; i < 200; i++) xs.push({i, s: 'x' + i});
                \\xs.length;
            , "200");
            const usage = runtime_control.getMemoryUsage(id) orelse return error.NoUsage;
            // Soft GC stats — at least one size field non-zero after allocation.
            try testing.expect(usage.malloc_size > 0 or usage.memory_used_size > 0);
            // No runtime heap cap on either spike backend.
            try testing.expect(!runtime_control.setMemoryLimit(id, 1));
            try testing.expect(runtime_control.runGc(id));
        }
    }.run);
}

test "spike smoke: Hermes create-time MaxHeapSize; setMemoryLimit still false" {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    // 64 MiB create-time cap via EngineConfig (not runtime setMemoryLimit).
    try helpers.withEngine(id, .{ .max_heap_size = 64 * 1024 * 1024 }, struct {
        fn run(instance_id: i32) !void {
            try helpers.expectEvalEquals(instance_id, "1+1", "2");
            const usage = runtime_control.getMemoryUsage(instance_id) orelse return error.NoUsage;
            try testing.expect(usage.malloc_size > 0 or usage.memory_used_size > 0);
            // Runtime setMemoryLimit remains unsupported on Hermes.
            try testing.expect(!runtime_control.setMemoryLimit(instance_id, 1));
            try testing.expect(!runtime_control.setMemoryLimit(instance_id, 64 * 1024 * 1024));
        }
    }.run);
}

test "spike smoke: C ABI create_with_options MaxHeapSize; set_memory_limit false; request_interrupt false" {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    var opts = c_api.EngineCreateOptionsC{
        .struct_size = @sizeOf(c_api.EngineCreateOptionsC),
        .backend = .primary,
        .log_handler = null,
        .log_user_data = null,
        .max_heap_size = 64 * 1024 * 1024,
    };
    try testing.expect(c_api.jsbay_engine_create_with_options(id, &opts));
    defer engine.destroy(id);
    try helpers.expectEvalEquals(id, "2+2", "4");
    try testing.expect(!c_api.jsbay_engine_set_memory_limit(id, 1));
    try testing.expect(!c_api.jsbay_engine_request_interrupt(id));
    try testing.expect(!runtime_control.supportsMidScriptUserInterrupt());
}
