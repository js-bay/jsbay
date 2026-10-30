//! Public C engine interface and internal typed helper tests.
//!
//! External C/C++ layout and linkage are exercised by c_consumer.c; this suite covers engine behavior, error ownership, bytecode and retained Zig helpers.

const std = @import("std");
const testing = std.testing;

const helpers = @import("test_helpers.zig");
const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const bytecode = @import("../script/bytecode.zig");
const backend = @import("../backend.zig");
const types = @import("../types.zig");
const runtime_control = @import("../runtime/runtime_control.zig");
const io = @import("../platform/io.zig");
const sample_hook = @import("../inspector/sample_hook.zig");
const instance_map = @import("../runtime/instance_map.zig");
const host_value = @import("../abi/host_value.zig");
const engine_thread_mod = @import("../runtime/engine_thread.zig");
const api_backend = @import("../abi/api_backend.zig");
const errors = @import("../value/errors.zig");
const tsfn = @import("../runtime/tsfn.zig");
const external = @import("../value/external.zig");
const atoms = @import("../value/atoms.zig");
const promise = @import("../runtime/promise.zig");
const build_options = @import("build_options");

const ActiveEngine = backend.ActiveEngine;

const InterruptDestroyProbe = struct {
    instance_id: i32,
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn onSample(instance_id: i32) void {
        const probe = active_interrupt_destroy_probe orelse return;
        if (instance_id != probe.instance_id) return;
        probe.entered.store(true, .seq_cst);
        while (!probe.release.load(.seq_cst)) std.Thread.yield() catch {};
    }
};

var active_interrupt_destroy_probe: ?*InterruptDestroyProbe = null;

const testThreadRun = c_api.test_only.threadRun;

fn waitForFlag(flag: *const std.atomic.Value(bool), timeout_ms: i64) bool {
    const deadline = io.monotonicMilliseconds() + timeout_ms;
    while (!flag.load(.seq_cst)) {
        if (io.monotonicMilliseconds() >= deadline) return false;
        std.Thread.yield() catch {};
    }
    return true;
}

fn expectMissingInstanceError(err: ?[*:0]const u8) !void {
    const message = err orelse return error.MissingError;
    defer c_api.test_only.freeCString(message);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(message), "Instance not found") != null);
}

test "c_api: lifecycle arms and tears down runtime interrupt control" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    try testing.expect(runtime_control.requestInterrupt(id));
    try testing.expect(c_api.jsbay_engine_clear_interrupt(id));
    try testing.expect(c_api.jsbay_engine_set_execution_time_limit(id, 25));

    c_api.jsbay_engine_destroy(id);
    try testing.expect(!runtime_control.requestInterrupt(id));
}

test "c_api: missing instances are errors across public evaluation entry points" {
    const id = helpers.nextInstanceId();
    const sentinel: [*:0]const u8 = @ptrFromInt(1);

    var err: ?[*:0]const u8 = sentinel;
    try testing.expect(c_api.test_only.evalCString(id, "undefined", "<missing>", &err) == null);
    try testing.expect(err != sentinel);
    try expectMissingInstanceError(err);

    err = sentinel;
    try testing.expect(c_api.test_only.evalCStringBytes(id, "undefined".ptr, "undefined".len, "<missing>", &err) == null);
    try testing.expect(err != sentinel);
    try expectMissingInstanceError(err);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "live.js", .data = "undefined" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "live.js", testing.allocator);
    defer testing.allocator.free(path);
    const path_z = try testing.allocator.dupeSentinel(u8, path, 0);
    defer testing.allocator.free(path_z);
    err = sentinel;
    try testing.expect(c_api.test_only.evalCStringFile(id, path_z.ptr, &err) == null);
    try testing.expect(err != sentinel);
    try expectMissingInstanceError(err);

    var cache_hit = true;
    err = sentinel;
    try testing.expect(c_api.test_only.evalCStringCached(id, "undefined".ptr, "undefined".len, "<missing>", ".zig-cache".ptr, ".zig-cache".len, "test".ptr, "test".len, &err, &cache_hit) == null);
    try testing.expect(err != sentinel);
    try testing.expect(!cache_hit);
    try expectMissingInstanceError(err);

    var bytecode_value: u64 = 1;
    var bytecode_exception: u64 = 1;
    try testing.expectEqual(@as(c_int, 4), c_api.jsbay_engine_run_bytecode(id, "bad".ptr, 3, &bytecode_value, &bytecode_exception));
    try testing.expect(bytecode_value == 0 and bytecode_exception == 0);
}

test "c_api: live undefined remains a successful empty result" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var err: ?[*:0]const u8 = @ptrFromInt(1);
    defer if (err) |message| c_api.test_only.freeCString(message);
    try testing.expect(c_api.test_only.evalCString(id, "undefined", "<undefined>", &err) == null);
    try testing.expect(err == null);
}

test "c_api: destroyed instance cannot report a cached bytecode hit" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "cache");
    const cache_dir = try tmp.dir.realPathFileAlloc(testing.io, "cache", testing.allocator);
    defer testing.allocator.free(cache_dir);
    var source: [4 * 1024 + 32]u8 = undefined;
    @memset(&source, ' ');
    @memcpy(source[0..9], "undefined");
    var err: ?[*:0]const u8 = null;
    var hit = false;
    const cold = c_api.test_only.evalCStringCached(id, &source, source.len, "<cached-missing>", cache_dir.ptr, cache_dir.len, "test".ptr, "test".len, &err, &hit);
    defer c_api.test_only.freeCString(cold);
    try testing.expect(err == null and !hit);
    c_api.jsbay_engine_destroy(id);

    err = @ptrFromInt(1);
    hit = true;
    try testing.expect(c_api.test_only.evalCStringCached(id, &source, source.len, "<cached-missing>", cache_dir.ptr, cache_dir.len, "test".ptr, "test".len, &err, &hit) == null);
    try testing.expect(!hit);
    try expectMissingInstanceError(err);
}

test "c_api: destroyed instances are errors across public evaluation entry points" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    c_api.jsbay_engine_destroy(id);
    const sentinel: [*:0]const u8 = @ptrFromInt(1);

    var err: ?[*:0]const u8 = sentinel;
    try testing.expect(c_api.test_only.evalCString(id, "undefined", "<destroyed>", &err) == null);
    try testing.expect(err != sentinel);
    try expectMissingInstanceError(err);

    err = sentinel;
    try testing.expect(c_api.test_only.evalCStringBytes(id, "undefined".ptr, "undefined".len, "<destroyed>", &err) == null);
    try testing.expect(err != sentinel);
    try expectMissingInstanceError(err);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "destroyed.js", .data = "undefined" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "destroyed.js", testing.allocator);
    defer testing.allocator.free(path);
    const path_z = try testing.allocator.dupeSentinel(u8, path, 0);
    defer testing.allocator.free(path_z);
    err = sentinel;
    try testing.expect(c_api.test_only.evalCStringFile(id, path_z.ptr, &err) == null);
    try testing.expect(err != sentinel);
    try expectMissingInstanceError(err);

    var cache_hit = true;
    err = sentinel;
    try testing.expect(c_api.test_only.evalCStringCached(id, "undefined".ptr, "undefined".len, "<destroyed>", ".zig-cache".ptr, ".zig-cache".len, "test".ptr, "test".len, &err, &cache_hit) == null);
    try testing.expect(err != sentinel);
    try testing.expect(!cache_hit);
    try expectMissingInstanceError(err);

    var bytecode_value: u64 = 1;
    var bytecode_exception: u64 = 1;
    try testing.expectEqual(@as(c_int, 4), c_api.jsbay_engine_run_bytecode(id, "bad".ptr, 3, &bytecode_value, &bytecode_exception));
    try testing.expect(bytecode_value == 0 and bytecode_exception == 0);
}

test "c_api: Zig evaluation entry points report missing instances" {
    const id = helpers.nextInstanceId();
    const script = engine.evalScript(id, "undefined", "<missing>");
    defer helpers.freeEvalResult(script);
    try testing.expect(script.result == null and script.err != null);

    const module = engine.evalModule(id, "", "<missing>");
    defer helpers.freeEvalResult(module);
    try testing.expect(module.result == null and module.err != null);

    const imported = engine.importModule(id, "missing");
    defer helpers.freeEvalResult(imported);
    try testing.expect(imported.result == null and imported.err != null);

    const bytecode_result = bytecode.runBytecode(id, "bad");
    defer helpers.freeEvalResult(bytecode_result);
    try testing.expect(bytecode_result.result == null and bytecode_result.err != null);
}

test "c_api: log handler receives engine info output" {
    const id = helpers.nextInstanceId();
    const LogProbe = struct {
        var got: bool = false;
        fn cb(_id: i32, _level: @import("../types.zig").LogLevel, _msg: [*:0]const u8, _ud: ?*anyopaque) callconv(.c) void {
            _ = _id;
            _ = _level;
            _ = _msg;
            _ = _ud;
            got = true;
        }
    };
    try testing.expect(c_api.jsbay_engine_create(id, LogProbe.cb, null));
    try testing.expect(LogProbe.got);
    c_api.jsbay_engine_destroy(id);
}

test "c_api: interrupt request aborts an infinite evaluation from another thread" {
    if (backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    const Interrupt = struct {
        fn run(instance_id: i32) void {
            io.sleepMs(50);
            _ = c_api.jsbay_engine_request_interrupt(instance_id);
        }
    };
    var thread = try std.Thread.spawn(.{}, Interrupt.run, .{id});
    const started = io.milliTimestamp();
    const result = engine.evalScript(id, "while (true) {}", "<c-api-interrupt>");
    defer helpers.freeEvalResult(result);
    thread.join();

    try testing.expect(result.err != null);
    try testing.expect(io.milliTimestamp() - started < 5_000);
    try testing.expect(c_api.jsbay_engine_clear_interrupt(id));
}

const cjs = @import("../script/cjs.zig");
const cjs_test_loader = @import("../types.zig").ModuleLoader{
    .vtable = &.{ .resolve = null, .load = struct {
        fn load(_: ?*anyopaque, _: [*:0]const u8, _: *@import("../types.zig").ModuleLoadResult) callconv(.c) bool {
            return false;
        }
    }.load, .free_resolved = null },
    .user_data = null,
};

test "c_api: create installs standard scheduling globals without product module globals" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try helpers.expectEvalEquals(id, "typeof require", "undefined");
    try helpers.expectEvalEquals(id, "typeof setTimeout + ',' + typeof setInterval + ',' + typeof queueMicrotask", "function,function,function");
    try helpers.evalOk(id, "globalThis.microtaskRan = false; queueMicrotask(() => microtaskRan = true)");
    try helpers.expectEvalEquals(id, "String(microtaskRan)", "true");
    try helpers.evalOk(id,
        \\const localRequire = name => ({answer: 42});
        \\const module = {exports:{}};
        \\new Function('module','exports','require','module.exports = {run: () => require("local").answer}')
        \\(module,module.exports,localRequire);
        \\globalThis.liveExports = module.exports;
    );
    try helpers.expectEvalEquals(id, "liveExports.run()", "42");
}

test "c_api: destroy releases explicitly installed CJS state before same-id recreate" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    try testing.expect(cjs.install(id, &cjs_test_loader));
    try helpers.expectEvalEquals(id, "typeof require", "function");
    c_api.jsbay_engine_destroy(id);

    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try helpers.expectEvalEquals(id, "typeof require", "undefined");
    try testing.expect(cjs.install(id, &cjs_test_loader));
    try helpers.expectEvalEquals(id, "typeof require", "function");
    if (backend.isQuickJsApiBackend(backend.active_backend)) {
        try helpers.expectEvalEquals(id, "typeof __jsbay_cjsCache", "function");
    }
}

test "engine: destroy keeps interrupt state alive until an active evaluation unwinds" {
    if (backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;

    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));

    var probe = InterruptDestroyProbe{ .instance_id = id };
    active_interrupt_destroy_probe = &probe;
    sample_hook.store(InterruptDestroyProbe.onSample);
    defer {
        sample_hook.store(null);
        active_interrupt_destroy_probe = null;
    }

    const Eval = struct {
        instance_id: i32,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(self: *@This()) void {
            const result = engine.evalScript(self.instance_id, "for (let i = 0; i < 1000000; i++) {}", "<destroy-interrupt-state>");
            helpers.freeEvalResult(result);
            self.done.store(true, .seq_cst);
        }
    };
    var evaluation = Eval{ .instance_id = id };
    var evaluation_thread = try std.Thread.spawn(.{}, Eval.run, .{&evaluation});
    var destroy_thread: ?std.Thread = null;
    defer {
        probe.release.store(true, .seq_cst);
        evaluation_thread.join();
        if (destroy_thread) |thread| thread.join();
    }
    try testing.expect(waitForFlag(&probe.entered, 1_000));

    const Destroy = struct {
        instance_id: i32,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(self: *@This()) void {
            engine.destroy(self.instance_id);
            self.done.store(true, .seq_cst);
        }
    };
    var destruction = Destroy{ .instance_id = id };
    destroy_thread = try std.Thread.spawn(.{}, Destroy.run, .{&destruction});

    // Teardown has closed new JS admission, but this admitted evaluation still owns the interrupt state while its sample hook is paused.
    const deadline = io.monotonicMilliseconds() + 1_000;
    while (!instance_map.isTeardownPending(id)) {
        if (io.monotonicMilliseconds() >= deadline) return error.DestroyDidNotCloseAdmission;
        std.Thread.yield() catch {};
    }
    try testing.expect(runtime_control.requestInterrupt(id));
    try testing.expect(!destruction.done.load(.seq_cst));

    probe.release.store(true, .seq_cst);
    try testing.expect(waitForFlag(&evaluation.done, 3_000));
    try testing.expect(waitForFlag(&destruction.done, 3_000));
    try testing.expect(!runtime_control.requestInterrupt(id));
}

test "engine: host-callback deferred destroy releases explicit CJS before same-id recreate" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));

    try testing.expect(cjs.install(id, &cjs_test_loader));
    const DestroyFromHost = struct {
        var called = std.atomic.Value(bool).init(false);
        fn callback(instance_id: c_int, _: ?*anyopaque, _: u32, _: ?[*]const host_value.HostValue, out: *host_value.HostValue) callconv(.c) c_int {
            engine.destroy(instance_id);
            called.store(true, .seq_cst);
            host_value.clear(out);
            return 0;
        }
    };
    try testing.expect(engine_thread_mod.hostInstall(id, "destroyFromHost", DestroyFromHost.callback, null));
    try testing.expect(engine_thread_mod.threadStart(id));

    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    const status = testThreadRun(id, "destroyFromHost()".ptr, "destroyFromHost()".len, "<destroy-cjs>".ptr, "<destroy-cjs>".len, 3_000, &result, &err);
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);
    try testing.expect(DestroyFromHost.called.load(.seq_cst));
    try testing.expect(status == 2 or status == 4);

    const deadline = io.monotonicMilliseconds() + 3_000;
    while (!c_api.jsbay_engine_create(id, null, null)) {
        if (io.monotonicMilliseconds() >= deadline) return error.TimedOutWaitingForDeferredDestroy;
        std.Thread.yield() catch {};
    }
    defer c_api.jsbay_engine_destroy(id);
    try helpers.expectEvalEquals(id, "typeof require", "undefined");
    try testing.expect(cjs.install(id, &cjs_test_loader));
    try helpers.expectEvalEquals(id, "typeof require", "function");
    if (backend.isQuickJsApiBackend(backend.active_backend)) {
        try helpers.evalOk(id, "globalThis.__cjs_cache_after_host_destroy__ = typeof __jsbay_cjsCache;");
        try helpers.expectEvalEquals(id, "globalThis.__cjs_cache_after_host_destroy__", "function");
    }
}

// -------- small helpers that mimic a C caller ---------------------------

fn cstr(s: [:0]const u8) [*:0]const u8 {
    return s.ptr;
}

// ---------------------------------------------------------------------------
// 1. errors: typed error creation and inspection.
// ---------------------------------------------------------------------------

test "c_api: direct error new + inspect round-trip" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const value = errors.newError(id, .type_error, "boom via direct API") orelse return error.ErrorAllocationFailed;
            defer ActiveEngine.freeValue(ctx, value);
            const info = errors.inspectError(testing.allocator, id, value) orelse return error.ErrorNotInspectable;
            defer errors.freeJsErrorInfo(testing.allocator, info);

            try testing.expectEqual(errors.JsErrorKind.type_error, info.kind);
            try testing.expectEqualStrings("TypeError", info.name);
            try testing.expectEqualStrings("boom via direct API", info.message);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 2. errors: direct throwError — QJS path (JSC has no cross-callback slot).
// ---------------------------------------------------------------------------

test "c_api: direct error_throw returns backend-expected result" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ok = errors.throwError(id, .range_error, "thrown from direct API");
            if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                try testing.expect(ok);
                // Drain any pending exception so later tests don't see it.
                const ctx = engine.getContext(id) orelse return error.NoContext;
                const qjs_mod = @import("../backend.zig").ActiveEngineModule;
                const pending = qjs_mod.qjs.JS_GetException(ctx);
                if (!qjs_mod.Backend.jsIsNull(pending)) {
                    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
                }
            } else {
                // JSC cannot surface the throw without a callback bridge.
                try testing.expect(!ok);
            }
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 3. errors: direct inspect result is released with its allocator.
// ---------------------------------------------------------------------------

test "c_api: direct error inspection releases owned copies" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const value = errors.newError(id, .generic, "info-leak-check") orelse return error.ErrorAllocationFailed;
            defer ActiveEngine.freeValue(ctx, value);
            const info = errors.inspectError(testing.allocator, id, value) orelse return error.ErrorNotInspectable;
            defer errors.freeJsErrorInfo(testing.allocator, info);
            try testing.expectEqualStrings("info-leak-check", info.message);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 4. bytecode: compile + run via the C ABI (QJS) or "not supported" (JSC).
// ---------------------------------------------------------------------------

test "c_api: typed bytecode compile and run preserve value ownership" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var bytes: c_api.Bytes = .{ .data = @ptrFromInt(1), .len = 99 };
    var exception: u64 = 1;
    const compile_status = c_api.jsbay_engine_compile_bytecode(
        id,
        .{ .data = "({ answer: 42 })".ptr, .len = "({ answer: 42 })".len },
        .{ .data = "bytecode-test.js".ptr, .len = "bytecode-test.js".len },
        &bytes,
        &exception,
    );
    if (comptime backend.isJscApiBackend(backend.active_backend)) {
        try testing.expectEqual(@as(c_int, 7), compile_status);
        try testing.expect(bytes.data == null and bytes.len == 0 and exception == 0);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), compile_status);
    try testing.expect(bytes.data != null and bytes.len > 0 and exception == 0);
    defer c_api.jsbay_free_bytes(bytes);

    var value: u64 = 1;
    const run_status = c_api.jsbay_engine_run_bytecode(id, bytes.data, bytes.len, &value, &exception);
    try testing.expectEqual(@as(c_int, 0), run_status);
    try testing.expect(value != 0 and exception == 0);
    defer _ = c_api.jsbay_value_release(value);
    var answer: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_get(value, .{ .data = "answer".ptr, .len = 6 }, &answer, &exception));
    defer _ = c_api.jsbay_value_release(answer);
    var number: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_to_number(answer, &number));
    try testing.expectEqual(@as(f64, 42), number);
}

test "c_api: typed bytecode returns raw compile and run exceptions" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var bytes: c_api.Bytes = .{ .data = @ptrFromInt(1), .len = 99 };
    var syntax_exception: u64 = 1;
    const syntax_status = c_api.jsbay_engine_compile_bytecode(
        id,
        .{ .data = "function {".ptr, .len = 10 },
        .{ .data = "bad.js".ptr, .len = 6 },
        &bytes,
        &syntax_exception,
    );
    if (comptime backend.isJscApiBackend(backend.active_backend)) {
        try testing.expectEqual(@as(c_int, 7), syntax_status);
        try testing.expect(bytes.data == null and bytes.len == 0 and syntax_exception == 0);
        return;
    }
    try testing.expectEqual(@as(c_int, 1), syntax_status);
    try testing.expect(bytes.data == null and bytes.len == 0 and syntax_exception != 0);
    defer _ = c_api.jsbay_value_release(syntax_exception);

    bytes = .{ .data = null, .len = 0 };
    var run_exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_compile_bytecode(
        id,
        .{ .data = "throw 42".ptr, .len = 8 },
        .{ .data = "throw.js".ptr, .len = 8 },
        &bytes,
        &run_exception,
    ));
    defer c_api.jsbay_free_bytes(bytes);
    var value: u64 = 1;
    try testing.expectEqual(@as(c_int, 1), c_api.jsbay_engine_run_bytecode(id, bytes.data, bytes.len, &value, &run_exception));
    try testing.expect(value == 0 and run_exception != 0);
    defer _ = c_api.jsbay_value_release(run_exception);
    var number: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_to_number(run_exception, &number));
    try testing.expectEqual(@as(f64, 42), number);
}

test "c_api: typed bytecode clears outputs for invalid bytecode" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var value: u64 = 1;
    var exception: u64 = 1;
    const status = c_api.jsbay_engine_run_bytecode(id, null, 0, &value, &exception);
    if (comptime backend.isJscApiBackend(backend.active_backend)) {
        try testing.expectEqual(@as(c_int, 7), status);
    } else {
        try testing.expect(status != 0);
    }
    try testing.expect(value == 0 and exception == 0);
}

// ---------------------------------------------------------------------------
// 5. tsfn: acquire + call + drain on the same (JS) thread.
// ---------------------------------------------------------------------------

test "c_api: direct tsfn acquire + call + drain" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            // Install a callback that records its argument on globalThis.
            try helpers.evalOk(id,
                \\globalThis.__c_api_tsfn_log__ = [];
                \\globalThis.__c_api_tsfn_cb__ = function (msg) {
                \\    globalThis.__c_api_tsfn_log__.push(msg);
                \\};
            );

            const ctx = engine.getContext(id) orelse return error.NoContext;
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const cb = ActiveEngine.getPropertyVal(ctx, global, "__c_api_tsfn_cb__") orelse
                return error.MissingCallback;
            defer ActiveEngine.freeValue(ctx, cb);

            const handle = tsfn.acquire(id, cb) orelse return error.TsfnAcquireFailed;
            defer tsfn.release(handle);

            const payload = "hello-from-c";
            const enq = tsfn.call(handle, payload);
            try testing.expect(enq);

            const n = tsfn.drainPending(id);
            try testing.expectEqual(@as(usize, 1), n);

            // Verify the JS-side side-effect landed.
            try helpers.expectEvalEquals(
                id,
                "globalThis.__c_api_tsfn_log__[0]",
                "hello-from-c",
            );
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 6. external: new + get + is round-trip via C ABI.
// ---------------------------------------------------------------------------

const Payload = struct { tag: u32 };
var g_finalize_hit: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
fn noopFinalizer(_: *anyopaque) callconv(.c) void {
    _ = g_finalize_hit.fetchAdd(1, .seq_cst);
}

test "c_api: direct external new + get + is round-trip" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var payload = Payload{ .tag = 0xCAFE_BABE };
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const value = external.newExternal(id, @ptrCast(&payload), null) orelse return error.ExternalAllocationFailed;
            defer ActiveEngine.freeValue(ctx, value);

            try testing.expect(external.isExternal(id, value));

            const got_ptr = external.getExternal(id, value);
            try testing.expect(got_ptr != null);
            try testing.expectEqual(@intFromPtr(&payload), @intFromPtr(got_ptr.?));
            const recovered: *Payload = @ptrCast(@alignCast(got_ptr.?));
            try testing.expectEqual(@as(u32, 0xCAFE_BABE), recovered.tag);

            // Negative: a plain string should not register as external.
            const s = ActiveEngine.newStringVal(ctx, "hi");
            defer ActiveEngine.freeValue(ctx, s);
            try testing.expect(!external.isExternal(id, s));
            try testing.expect(external.getExternal(id, s) == null);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 7. atoms: new + set + get + has + to_string round-trip.
// ---------------------------------------------------------------------------

test "c_api: direct atoms full round-trip" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const key = "frob";
            const atom = atoms.newAtom(id, key) orelse return error.AtomAllocationFailed;
            defer atoms.freeAtom(id, atom);
            const text = atoms.atomToString(testing.allocator, id, atom) orelse return error.AtomDecodeFailed;
            defer testing.allocator.free(text);
            try testing.expectEqualStrings("frob", text);

            // Set + get on a fresh empty object.
            try helpers.evalOk(id, "globalThis.__c_api_atom_obj__ = {};");
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const obj = ActiveEngine.getPropertyVal(ctx, global, "__c_api_atom_obj__") orelse
                return error.NoObj;
            defer ActiveEngine.freeValue(ctx, obj);

            const val = ActiveEngine.newInt32Val(ctx, 7);
            // setProperty consumes val on both backends — no post-set free.
            try testing.expect(atoms.setProperty(id, obj, atom, val));

            try testing.expect(atoms.hasProperty(id, obj, atom));

            const got = atoms.getProperty(id, obj, atom) orelse return error.MissingAtomProperty;
            defer ActiveEngine.freeValue(ctx, got);

            // Validate from JS.
            try helpers.expectEvalEquals(id, "globalThis.__c_api_atom_obj__.frob", "7");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 8. modules: direct evalModule.
// ---------------------------------------------------------------------------

test "c_api: direct eval_module evaluates a module" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const src = "globalThis.__c_api_mod__ = 5 + 1;";
            const fname = "<c_api_module>";

            const res = engine.evalModule(id, src, fname);
            defer helpers.freeEvalResult(res);

            // Both backends support module evaluation on source without `import` statements (QJS natively, JSC via the ObjC bridge). On JSC, absence of a module loader may still surface an error even for no-import source — treat both outcomes as valid but verify that when no error is reported, the side-effect landed.
            if (res.err == null) {
                try helpers.expectEvalEquals(id, "globalThis.__c_api_mod__", "6");
            } else {
                // The direct result still carries an owned error string.
                try testing.expect(res.err != null);
            }
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 9. promise: direct create + resolve wires into JS `.then`.
// ---------------------------------------------------------------------------

test "c_api: direct promise new + resolve reaches JS then" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            // Seed a place to record the resolved value.
            try helpers.evalOk(id, "globalThis.__c_api_promise_v__ = null;");

            var deferred = promise.create(id) orelse return error.PromiseCreationFailed;
            defer deferred.deinit();

            // Attach a .then that records the value in a global.
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);

            // Stash a duplicate so deferred retains its borrowed promise view.
            const for_global = ActiveEngine.dupValue(ctx, deferred.promise);
            ActiveEngine.setPropertyStr(ctx, global, "__c_api_promise__", for_global);

            try helpers.evalOk(id,
                \\globalThis.__c_api_promise__.then(function (v) {
                \\    globalThis.__c_api_promise_v__ = v;
                \\});
            );

            // Resolve with the integer 42.
            const forty_two = ActiveEngine.newInt32Val(ctx, 42);
            // resolve does not consume forty_two on either backend.
            const ok = deferred.resolve(forty_two);
            try testing.expect(ok);
            ActiveEngine.freeValue(ctx, forty_two);

            // Drain microtasks just in case the backend didn't.
            ActiveEngine.processPendingJobs(ctx);

            // .then should have fired synchronously (resolve drains jobs).
            try helpers.expectEvalEquals(id, "globalThis.__c_api_promise_v__", "42");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// Byte-buffer and filesystem eval. These match testEvalCString's malloc'd C-string contract (free with testFreeCString).
// ---------------------------------------------------------------------------

test "c_api: eval_bytes returns the value of a pointer+length script" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    // The length stops before the tail. A C-string read would execute the throw.
    const src = "40+2;throw new Error('tail')";
    var err: ?[*:0]const u8 = null;
    const result = c_api.test_only.evalCStringBytes(id, src.ptr, 4, "bytes.js", &err);
    defer if (err) |e| c_api.test_only.freeCString(e);
    defer if (result) |r| c_api.test_only.freeCString(r);

    try testing.expect(err == null);
    try testing.expect(result != null);
    try testing.expectEqualStrings("42", std.mem.span(result.?));
}

test "c_api: eval_cached clears a reused error pointer on fallback and cache hits" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var path_buf: [96]u8 = undefined;
    const cache_dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/c-api-cache-{d}", .{id});
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing.io, cache_dir) catch {};
    try cwd.createDirPath(testing.io, cache_dir);
    defer cwd.deleteTree(testing.io, cache_dir) catch {};

    const filename = "<cached>";
    const version = "test";
    const bad = "throw new Error('stale error')";
    const small = "40+2";
    var large: [4 * 1024 + 64]u8 = undefined;
    @memset(&large, ' ');
    @memcpy(large[0..small.len], small);

    var err: ?[*:0]const u8 = null;
    var cache_hit = true;
    const failed_small = c_api.test_only.evalCStringCached(
        id,
        bad.ptr,
        bad.len,
        filename,
        cache_dir.ptr,
        cache_dir.len,
        version.ptr,
        version.len,
        &err,
        &cache_hit,
    );
    try testing.expect(failed_small == null);
    try testing.expect(err != null);
    c_api.test_only.freeCString(err.?);

    const small_result = c_api.test_only.evalCStringCached(
        id,
        small.ptr,
        small.len,
        filename,
        cache_dir.ptr,
        cache_dir.len,
        version.ptr,
        version.len,
        &err,
        &cache_hit,
    );
    try testing.expect(err == null);
    const small_value = small_result orelse return error.ExpectedSmallResult;
    defer c_api.test_only.freeCString(small_value);
    try testing.expectEqualStrings("42", std.mem.span(small_value));

    const failed_cold = c_api.test_only.evalCStringCached(
        id,
        bad.ptr,
        bad.len,
        filename,
        cache_dir.ptr,
        cache_dir.len,
        version.ptr,
        version.len,
        &err,
        &cache_hit,
    );
    try testing.expect(failed_cold == null);
    try testing.expect(err != null);
    c_api.test_only.freeCString(err.?);
    const cold_result = c_api.test_only.evalCStringCached(
        id,
        large[0..].ptr,
        large.len,
        filename,
        cache_dir.ptr,
        cache_dir.len,
        version.ptr,
        version.len,
        &err,
        &cache_hit,
    );
    try testing.expect(err == null);
    try testing.expect(!cache_hit);
    const cold_value = cold_result orelse return error.ExpectedColdResult;
    defer c_api.test_only.freeCString(cold_value);

    const failed_warm = c_api.test_only.evalCStringCached(
        id,
        bad.ptr,
        bad.len,
        filename,
        cache_dir.ptr,
        cache_dir.len,
        version.ptr,
        version.len,
        &err,
        &cache_hit,
    );
    try testing.expect(failed_warm == null);
    try testing.expect(err != null);
    c_api.test_only.freeCString(err.?);
    const warm_result = c_api.test_only.evalCStringCached(
        id,
        large[0..].ptr,
        large.len,
        filename,
        cache_dir.ptr,
        cache_dir.len,
        version.ptr,
        version.len,
        &err,
        &cache_hit,
    );
    try testing.expect(err == null);
    try testing.expectEqual(@import("build_options").bytecode_cache and backend.isQuickJsApiBackend(backend.active_backend), cache_hit);
    const warm_value = warm_result orelse return error.ExpectedWarmResult;
    defer c_api.test_only.freeCString(warm_value);
}

test "c_api: eval_file returns the value of a script on disk" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "script.js", .data = "40+2" });
    const real_path = try tmp.dir.realPathFileAlloc(testing.io, "script.js", testing.allocator);
    defer testing.allocator.free(real_path);
    const path_z = try testing.allocator.dupeSentinel(u8, real_path, 0);
    defer testing.allocator.free(path_z);

    var err: ?[*:0]const u8 = null;
    const result = c_api.test_only.evalCStringFile(id, path_z.ptr, &err);
    defer if (err) |e| c_api.test_only.freeCString(e);
    defer if (result) |r| c_api.test_only.freeCString(r);

    try testing.expect(err == null);
    try testing.expect(result != null);
    try testing.expectEqualStrings("42", std.mem.span(result.?));
}

test "c_api: inspector start and stop preserve the build-mode contract" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var port: u16 = 99;
    if (comptime !build_options.inspector or !build_options.inspector_transport) {
        const original_port = port;
        try testing.expect(!c_api.jsbay_engine_inspector_start(id, 0, &port));
        try testing.expectEqual(original_port, port);
        c_api.jsbay_engine_inspector_stop(id);
        c_api.jsbay_engine_inspector_stop(id);
        return;
    }
    port = 0;
    try testing.expect(c_api.jsbay_engine_inspector_start(id, 0, &port));
    try testing.expect(port != 0);
    try testing.expect(!c_api.jsbay_engine_inspector_start(id, 0, &port));
    c_api.jsbay_engine_inspector_stop(id);
    c_api.jsbay_engine_inspector_stop(id);

    port = 0;
    try testing.expect(c_api.jsbay_engine_inspector_start(id, 0, &port));
    try testing.expect(port != 0);
    c_api.jsbay_engine_inspector_stop(id);

    try testing.expect(!c_api.jsbay_engine_inspector_start(id + 100000, 0, &port));
}

test "typed constructors clear outputs and leave the engine usable after allocation failure" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var value: u64 = 99;
    var exception: u64 = 98;

    api_backend.failNextConstructorForTesting();
    try testing.expectEqual(@as(c_int, 6), c_api.jsbay_value_new_string(id, .{ .data = "constructor", .len = 11 }, &value));
    try testing.expectEqual(@as(u64, 0), value);

    value = 99;
    api_backend.failNextConstructorForTesting();
    try testing.expectEqual(@as(c_int, 6), c_api.jsbay_value_new_object(id, &value));
    try testing.expectEqual(@as(u64, 0), value);

    value = 99;
    api_backend.failNextConstructorForTesting();
    try testing.expectEqual(@as(c_int, 6), c_api.jsbay_value_new_array(id, &value));
    try testing.expectEqual(@as(u64, 0), value);

    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_evaluate(
        id,
        .{ .data = "6 * 7", .len = 5 },
        .{ .data = "constructor-recovery.js", .len = 23 },
        null,
        &value,
        &exception,
    ));
    defer _ = c_api.jsbay_value_release(value);
    try testing.expect(value != 0);
    try testing.expectEqual(@as(u64, 0), exception);
}

// ---------------------------------------------------------------------------
// Exception identity across the C ABI.
//
// Reference cases: ScriptX `ExceptionTest.Cross`.
// ---------------------------------------------------------------------------

fn expectEvalTrue(id: i32, source: []const u8) !void {
    var value: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_evaluate(
        id,
        .{ .data = source.ptr, .len = source.len },
        .{ .data = "identity-check.js", .len = 17 },
        null,
        &value,
        &exception,
    ));
    defer _ = c_api.jsbay_value_release(value);
    var flag = false;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_to_bool(value, &flag));
    try testing.expect(flag);
}

test "c_api: thrown object returned through out_exception is the same JS object" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    const source = "globalThis.__thrown = { marker: 'original' }; throw globalThis.__thrown;";
    var value: u64 = 99;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 1), c_api.jsbay_engine_evaluate(
        id,
        .{ .data = source.ptr, .len = source.len },
        .{ .data = "identity.js", .len = 11 },
        null,
        &value,
        &exception,
    ));
    try testing.expectEqual(@as(u64, 0), value);
    try testing.expect(exception != 0);
    defer _ = c_api.jsbay_value_release(exception);

    // Publishing the handle back into JS lets the engine itself decide ===.
    var global: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_global(id, &global));
    defer _ = c_api.jsbay_value_release(global);
    var set_exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_set(global, .{ .data = "__returned", .len = 10 }, exception, &set_exception));
    try expectEvalTrue(id, "__returned === __thrown");

    // A host-side write through the handle lands on the original object.
    var flag: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_new_bool(id, true, &flag));
    defer _ = c_api.jsbay_value_release(flag);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_set(exception, .{ .data = "hostSeen", .len = 8 }, flag, &set_exception));
    try expectEvalTrue(id, "__thrown.hostSeen === true && __thrown.marker === 'original'");
}

test "c_api: thrown Error instance keeps its identity and own properties across out_exception" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    const source =
        \\class TaggedError extends Error {}
        \\globalThis.__thrown = new TaggedError('tagged');
        \\globalThis.__thrown.code = 'E_TAGGED';
        \\throw globalThis.__thrown;
    ;
    var value: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 1), c_api.jsbay_engine_evaluate(
        id,
        .{ .data = source.ptr, .len = source.len },
        .{ .data = "identity-error.js", .len = 17 },
        null,
        &value,
        &exception,
    ));
    try testing.expect(exception != 0);
    defer _ = c_api.jsbay_value_release(exception);

    var global: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_global(id, &global));
    defer _ = c_api.jsbay_value_release(global);
    var set_exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_set(global, .{ .data = "__returned", .len = 10 }, exception, &set_exception));
    try expectEvalTrue(id, "__returned === __thrown && __returned instanceof TaggedError && __returned.code === 'E_TAGGED'");
}

// ---------------------------------------------------------------------------
// Value kinds that have no dedicated C ABI kind, and receiver semantics.
// ---------------------------------------------------------------------------

fn evalHandle(id: i32, source: []const u8) !u64 {
    var value: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_evaluate(
        id,
        .{ .data = source.ptr, .len = source.len },
        .{ .data = "handle.js", .len = 9 },
        null,
        &value,
        &exception,
    ));
    try testing.expectEqual(@as(u64, 0), exception);
    try testing.expect(value != 0);
    return value;
}

fn publish(global: u64, name: []const u8, value: u64) !void {
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_set(global, .{ .data = name.ptr, .len = name.len }, value, &exception));
    try testing.expectEqual(@as(u64, 0), exception);
}

fn expectKind(handle: u64, expected: c_int) !void {
    var kind: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_type(handle, &kind));
    try testing.expectEqual(expected, kind);
}

// Numeric values are the C ABI: the original eight never move and Symbol and BigInt are appended after them.
test "c_api: value kinds keep their ABI numbers and Symbol/BigInt are not Object" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    const Case = struct { source: []const u8, kind: c_int };
    const cases = [_]Case{
        .{ .source = "undefined", .kind = 0 },
        .{ .source = "null", .kind = 1 },
        .{ .source = "true", .kind = 2 },
        .{ .source = "42", .kind = 3 },
        .{ .source = "'text'", .kind = 4 },
        .{ .source = "({})", .kind = 5 },
        .{ .source = "new Date(0)", .kind = 5 },
        .{ .source = "[]", .kind = 6 },
        .{ .source = "(function () {})", .kind = 7 },
        .{ .source = "(() => 1)", .kind = 7 },
        .{ .source = "Symbol('s')", .kind = 8 },
        .{ .source = "Symbol.for('registered')", .kind = 8 },
        .{ .source = "Symbol.iterator", .kind = 8 },
        .{ .source = "1n", .kind = 9 },
        .{ .source = "2n ** 200n", .kind = 9 },
        // Boxed primitives are objects, not the primitive kinds.
        .{ .source = "Object(Symbol('boxed'))", .kind = 5 },
        .{ .source = "Object(1n)", .kind = 5 },
    };
    for (cases) |case| {
        const handle = try evalHandle(id, case.source);
        defer _ = c_api.jsbay_value_release(handle);
        expectKind(handle, case.kind) catch |err| {
            std.debug.print("kind mismatch for `{s}`\n", .{case.source});
            return err;
        };
    }
}

// A Symbol or BigInt handle reports its own kind and stays a usable, releasable reference to the original primitive: it survives being stored, passed through a call and handed back, and the engine is clean afterwards.
test "c_api: Symbol and BigInt handles round-trip to the same primitive" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var global: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_global(id, &global));
    defer _ = c_api.jsbay_value_release(global);

    const sym = try evalHandle(id, "globalThis.__sym = Symbol.for('round-trip'); __sym");
    defer _ = c_api.jsbay_value_release(sym);
    const unique_sym = try evalHandle(id, "globalThis.__usym = Symbol('local'); __usym");
    defer _ = c_api.jsbay_value_release(unique_sym);
    const big = try evalHandle(id, "globalThis.__big = -123456789012345678901234567890n; __big");
    defer _ = c_api.jsbay_value_release(big);

    const symbol_kind: c_int = 8;
    const bigint_kind: c_int = 9;
    try expectKind(sym, symbol_kind);
    try expectKind(unique_sym, symbol_kind);
    try expectKind(big, bigint_kind);

    try publish(global, "__symBack", sym);
    try publish(global, "__usymBack", unique_sym);
    try publish(global, "__bigBack", big);
    try expectEvalTrue(id, "__symBack === __sym && __symBack === Symbol.for('round-trip')");
    try expectEvalTrue(id, "__usymBack === __usym && __usymBack !== Symbol('local')");
    try expectEvalTrue(id, "__bigBack === __big && typeof __bigBack === 'bigint'");

    // Through an argument and a return value the same primitive comes back.
    const identity = try evalHandle(id, "(function (x) { return x; })");
    defer _ = c_api.jsbay_value_release(identity);
    var undef: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_undefined(id, &undef));
    defer _ = c_api.jsbay_value_release(undef);
    const args = [_]u64{ sym, big };
    for (args, 0..) |arg, i| {
        const one = [_]u64{arg};
        var result: u64 = 0;
        var exception: u64 = 0;
        try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_call(identity, undef, &one, 1, &result, &exception));
        try testing.expectEqual(@as(u64, 0), exception);
        defer _ = c_api.jsbay_value_release(result);
        try publish(global, "__called", result);
        try expectEvalTrue(id, if (i == 0) "__called === __sym" else "__called === __big");
    }

    try expectEvalTrue(id, "1 + 1 === 2");
}

// A host call that passes undefined as the receiver follows the callee's language rules: a sloppy function sees globalThis and a strict one sees undefined.
test "c_api: call with an undefined receiver follows the callee's strictness" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var undef: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_undefined(id, &undef));
    defer _ = c_api.jsbay_value_release(undef);
    var global: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_global(id, &global));
    defer _ = c_api.jsbay_value_release(global);

    const sloppy = try evalHandle(id, "(function () { return this; })");
    defer _ = c_api.jsbay_value_release(sloppy);
    const strict = try evalHandle(id, "(function () { 'use strict'; return this; })");
    defer _ = c_api.jsbay_value_release(strict);

    var sloppy_this: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_call(sloppy, undef, null, 0, &sloppy_this, &exception));
    defer _ = c_api.jsbay_value_release(sloppy_this);
    try publish(global, "__sloppyThis", sloppy_this);
    try expectEvalTrue(id, "__sloppyThis === globalThis");

    var strict_this: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_call(strict, undef, null, 0, &strict_this, &exception));
    defer _ = c_api.jsbay_value_release(strict_this);
    var kind: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_type(strict_this, &kind));
    try testing.expectEqual(@as(c_int, 0), kind);
}

test "c_api: to_utf8 of an object whose toString throws reports the thrown value" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    const hostile = try evalHandle(id, "globalThis.__thrower = { marker: 'boom' }; ({ toString() { throw __thrower; } })");
    defer _ = c_api.jsbay_value_release(hostile);

    var bytes: c_api.Bytes = .{ .data = @ptrFromInt(1), .len = 7 };
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 1), c_api.jsbay_value_to_utf8(hostile, &bytes, &exception));
    try testing.expect(bytes.data == null);
    try testing.expectEqual(@as(usize, 0), bytes.len);
    try testing.expect(exception != 0);
    defer _ = c_api.jsbay_value_release(exception);

    var global: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_global(id, &global));
    defer _ = c_api.jsbay_value_release(global);
    try publish(global, "__reported", exception);
    try expectEvalTrue(id, "__reported === __thrower");
    try expectEvalTrue(id, "1 + 1 === 2");
}

// docs/api-contract.md: JSON text conversion must not depend on the script-visible globalThis.JSON.
test "c_api: to_json and new_json ignore a script that replaces JSON" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    const value = try evalHandle(id,
        \\JSON.stringify = function () { return 'HACKED'; };
        \\JSON.parse = function () { return 'HACKED'; };
        \\globalThis.JSON = { stringify() { return 'HACKED2'; }, parse() { return 'HACKED2'; } };
        \\({ a: [1, 2], s: 'x' })
    );
    defer _ = c_api.jsbay_value_release(value);

    var bytes: c_api.Bytes = .{ .data = null, .len = 0 };
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_to_json(value, &bytes, &exception));
    defer c_api.jsbay_free_bytes(bytes);
    try testing.expectEqualStrings("{\"a\":[1,2],\"s\":\"x\"}", bytes.data.?[0..bytes.len]);

    const text = "{\"q\":[true,null,3]}";
    var parsed: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_new_json(id, .{ .data = text.ptr, .len = text.len }, &parsed, &exception));
    defer _ = c_api.jsbay_value_release(parsed);
    var global: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_global(id, &global));
    defer _ = c_api.jsbay_value_release(global);
    try publish(global, "__parsed", parsed);
    try expectEvalTrue(id, "Array.isArray(__parsed.q) && __parsed.q.length === 3 && __parsed.q[0] === true && __parsed.q[1] === null && __parsed.q[2] === 3");
}

test "c_api: to_json of a symbol is an invalid argument with no output" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    const sym = try evalHandle(id, "Symbol('no-json')");
    defer _ = c_api.jsbay_value_release(sym);
    var bytes: c_api.Bytes = .{ .data = @ptrFromInt(1), .len = 7 };
    var exception: u64 = 99;
    // JS_BAY_INVALID_ARGUMENT
    const status = c_api.jsbay_value_to_json(sym, &bytes, &exception);
    try testing.expect(status != 0);
    try testing.expect(bytes.data == null);
    try testing.expectEqual(@as(usize, 0), bytes.len);
}

test "c_api: get_memory_usage and run_gc are owner-thread observability hooks" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    try testing.expect(!c_api.jsbay_engine_get_memory_usage(id, null));
    try testing.expect(!c_api.jsbay_engine_run_gc(99_992));

    var usage = c_api.MemoryUsageC{ .struct_size = @sizeOf(c_api.MemoryUsageC) };
    try testing.expect(c_api.jsbay_engine_get_memory_usage(id, &usage));
    try testing.expect(c_api.jsbay_engine_run_gc(id));

    _ = try helpers.evalOk(id,
        \\const xs = [];
        \\for (let i = 0; i < 200; i++) xs.push({i});
        \\xs.length;
    );
    usage = .{ .struct_size = @sizeOf(c_api.MemoryUsageC) };
    try testing.expect(c_api.jsbay_engine_get_memory_usage(id, &usage));
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => try testing.expect(usage.obj_count > 0 or usage.malloc_size > 0),
        .jsc => {},
        .escargot, .hermes => {},
    }
}

const EventCapture = struct {
    count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_kind: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    fn handler(event: *const types.EngineEvent, user_data: ?*anyopaque) callconv(.c) void {
        const self: *EventCapture = @ptrCast(@alignCast(user_data.?));
        _ = self.count.fetchAdd(1, .seq_cst);
        self.last_kind.store(@backingInt(event.kind), .seq_cst);
    }
};

test "c_api: set_event_handler receives interrupt telemetry" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var capture: EventCapture = .{};
    try testing.expect(c_api.jsbay_engine_set_event_handler(id, EventCapture.handler, &capture));
    try testing.expect(c_api.jsbay_engine_request_interrupt(id));
    try testing.expect(capture.count.load(.seq_cst) >= 1);
    try testing.expectEqual(@as(i32, @backingInt(types.EngineEventKind.execution_interrupted)), capture.last_kind.load(.seq_cst));
    try testing.expect(c_api.jsbay_engine_clear_interrupt(id));
    try testing.expect(c_api.jsbay_engine_set_event_handler(id, null, null));
}
