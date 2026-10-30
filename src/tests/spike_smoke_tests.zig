//! Capability-gated smoke for Escargot/Hermes native backends.
const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const ActiveEngine = backend.ActiveEngine;
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

const native_handle = switch (backend.active_backend) {
    .escargot => @import("../backend/escargot/native_handle.zig"),
    .hermes => @import("../backend/hermes/native_handle.zig"),
    else => @import("../backend/escargot/native_handle.zig"), // unused when skipped
};

var g_nh_fin_count: u32 = 0;
fn nhFin(ptr: ?*anyopaque) void {
    _ = ptr;
    g_nh_fin_count += 1;
}

fn nhCall(ctx: native_handle.Context, this: native_handle.Value, args: []const native_handle.Value) native_handle.Value {
    _ = this;
    _ = args;
    // return 42
    return switch (backend.active_backend) {
        .escargot => @import("../backend/escargot/c_api.zig").escargot_new_int32(42),
        .hermes => @import("../backend/hermes/c_api.zig").hermes_new_int32(ctx, 42),
        else => null,
    };
}

test "spike smoke: native_handle opaque + finalize on teardown" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    g_nh_fin_count = 0;
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;

    {
        const ctx = engine.getContext(id) orelse {
            engine.destroy(id);
            return error.NoContext;
        };
        native_handle.init();
        var marker: u32 = 0x4E48;
        const h = native_handle.create(ctx, .{
            .ptr = @ptrCast(&marker),
            .finalize_fn = nhFin,
        });
        try testing.expect(h != null);
        const opaque_ptr = native_handle.getOpaque(ctx, h);
        try testing.expect(opaque_ptr != null);
        try testing.expect(opaque_ptr.?.ptr == @as(?*anyopaque, @ptrCast(&marker)));
        const plain = ActiveEngine.newObject(ctx);
        defer ActiveEngine.freeValue(ctx, plain);
        try testing.expect(native_handle.getOpaque(ctx, plain) == null);

        const global = ActiveEngine.getGlobalObject(ctx);
        defer ActiveEngine.freeValue(ctx, global);
        ActiveEngine.setPropertyStr(ctx, global, "__nh", h);
    }

    engine.destroy(id);
    try testing.expect(g_nh_fin_count >= 1);
}

test "spike smoke: native_handle callable returns 42" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            const ctx = engine.getContext(inst) orelse return error.NoContext;
            native_handle.init();
            const h = native_handle.create(ctx, .{ .call_fn = nhCall });
            try testing.expect(h != null);
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "nh", h);
            try helpers.expectEvalEquals(inst, "nh()", "42");
            try helpers.expectEvalEquals(inst, "typeof nh", "function");
        }
    }.run);
}

fn nhMethodInc(ctx: native_handle.Context, this: native_handle.Value, args: []const native_handle.Value) native_handle.Value {
    _ = args;
    const data = native_handle.getOpaque(ctx, this) orelse return null;
    const counter: *i32 = @ptrCast(@alignCast(data.ptr orelse return null));
    counter.* += 1;
    return switch (backend.active_backend) {
        .escargot => @import("../backend/escargot/c_api.zig").escargot_new_int32(counter.*),
        .hermes => @import("../backend/hermes/c_api.zig").hermes_new_int32(ctx, counter.*),
        else => null,
    };
}

test "spike smoke: native_handle method this-binding (detached)" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(inst: i32) !void {
            const ctx = engine.getContext(inst) orelse return error.NoContext;
            native_handle.init();
            var counter: i32 = 0;
            const h = native_handle.createWithMethods(ctx, .{ .ptr = @ptrCast(&counter) }, &.{
                .{ .name = "inc", .method = nhMethodInc },
            });
            try testing.expect(h != null);
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "nh", h);
            try helpers.expectEvalEquals(inst, "typeof nh", "object");
            try helpers.expectEvalEquals(inst, "typeof nh.inc", "function");
            try helpers.expectEvalEquals(inst, "nh.inc()", "1");
            // Detached method must still bind to the NativeHandle (MethodBox).
            try helpers.expectEvalEquals(inst, "const f = nh.inc; f()", "2");
            try testing.expectEqual(@as(i32, 2), counter);
        }
    }.run);
}

test "spike smoke: engine_thread start / id / stop" {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    // Minimal contract only: post/wait still throws on Escargot spike (status=exception) — leave full suite to non-spike.
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.js_bay_engine_create(id, null, null));
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
    try testing.expect(c_api.js_bay_engine_create(id, null, null));
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

test "spike smoke: C ABI create2 MaxHeapSize; set_memory_limit false; request_interrupt false" {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    var opts = c_api.CreateOptions{
        .struct_size = @sizeOf(c_api.CreateOptions),
        .log_handler = null,
        .log_user_data = null,
        .max_heap_size = 64 * 1024 * 1024,
    };
    try testing.expect(c_api.js_bay_engine_create2(id, &opts));
    defer engine.destroy(id);
    try helpers.expectEvalEquals(id, "2+2", "4");
    try testing.expect(!c_api.js_bay_engine_set_memory_limit(id, 1));
    try testing.expect(!c_api.js_bay_engine_request_interrupt(id));
    try testing.expect(!runtime_control.supportsMidScriptUserInterrupt());
}


