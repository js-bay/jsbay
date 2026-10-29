//! Engine lifecycle and instance-management tests.
//!
//! Covers:
//!   - create / destroy / duplicate id behavior
//!   - getContext round-trips
//!   - evalScript for primitives, objects, arrays, errors
//!   - evalFile (missing file + real file)
//!   - multi-instance global isolation
//!   - dispatchTask + runEventLoopOnce integration
//!   - stopEventLoop no-ops
//!   - microtask drain via Promise.resolve().then(...)
//!   - instance_map low-level round-trips (instanceIdFromCtx, getPtrs)
//!   - log handler integration

const std = @import("std");
const sync = @import("zev");
const testing = std.testing;

const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const types = @import("../types.zig");
const instance_map = @import("../runtime/instance_map.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

// ===================================================================
// Lifecycle basics
// ===================================================================

test "engine: create returns true for fresh id" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
}

test "engine: create returns false on duplicate id" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(!engine.create(id, .{}));
}

test "engine: destroy on unknown id is a no-op" {
    const id = helpers.nextInstanceId();
    // Never created — should not crash.
    engine.destroy(id);
    engine.destroy(id); // second call also fine
}

test "engine: destroy then re-create succeeds" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    engine.destroy(id);
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
}

test "engine: getContext returns non-null for live instance and null after destroy" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const ctx_live = engine.getContext(id);
    try testing.expect(ctx_live != null);

    engine.destroy(id);
    const ctx_dead = engine.getContext(id);
    try testing.expect(ctx_dead == null);
}

test "engine: getContext on unknown id returns null" {
    const unknown_id: i32 = 999_999;
    // Make sure nothing currently occupies this id.
    engine.destroy(unknown_id);
    try testing.expect(engine.getContext(unknown_id) == null);
}

// ===================================================================
// Eval basics
// ===================================================================

test "engine: evalScript 1+2 returns \"3\"" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const res = engine.evalScript(id, "1+2", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result != null);
    try testing.expectEqualStrings("3", res.result.?);
}

test "engine: evalScript string literal returns \"hello\"" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const res = engine.evalScript(id, "'hello'", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result != null);
    try testing.expectEqualStrings("hello", res.result.?);
}

test "engine: evalScript true returns \"true\"" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const res = engine.evalScript(id, "true", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result != null);
    try testing.expectEqualStrings("true", res.result.?);
}

test "engine: evalScript null returns null result (no err)" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const res = engine.evalScript(id, "null", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result == null);
}

test "engine: evalScript undefined returns null result (no err)" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const res = engine.evalScript(id, "undefined", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result == null);
}

test "engine: evalScript object returns JSON form with a===1" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const res = engine.evalScript(id, "({a: 1, b: 'x'})", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, res.result.?, .{});
    defer parsed.deinit();

    const root = parsed.value;
    try testing.expect(root == .object);
    const a = root.object.get("a") orelse return error.MissingKey;
    try testing.expect(a == .integer);
    try testing.expectEqual(@as(i64, 1), a.integer);
}

test "engine: evalScript array returns \"[1,2,3]\"" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const res = engine.evalScript(id, "[1,2,3]", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result != null);
    try testing.expectEqualStrings("[1,2,3]", res.result.?);
}

test "engine: evalScript throw returns err containing 'boom'" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const res = engine.evalScript(id, "throw new Error('boom')", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.result == null);
    try testing.expect(res.err != null);
    try testing.expect(std.mem.indexOf(u8, res.err.?, "boom") != null);
}

test "engine: evalScript syntax error returns err" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const res = engine.evalScript(id, "1+", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err != null);
}

test "engine: evalScript on destroyed instance returns an error" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    engine.destroy(id);

    const res = engine.evalScript(id, "1+2", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.result == null);
    try testing.expect(res.err != null);
    try testing.expectEqualStrings("Instance not found", res.err.?);
}

test "engine: two sequential evalScripts share global state" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    {
        const res = engine.evalScript(id, "var x = 1;", "<test>");
        defer helpers.freeEvalResult(res);
        try testing.expect(res.err == null);
    }
    {
        const res = engine.evalScript(id, "x + 1", "<test>");
        defer helpers.freeEvalResult(res);
        try testing.expect(res.err == null);
        try testing.expect(res.result != null);
        try testing.expectEqualStrings("2", res.result.?);
    }
}

// ===================================================================
// evalFile
// ===================================================================

test "engine: evalFile on missing path returns heap err (no leak)" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const res = engine.evalFile(id, "/nonexistent/path/definitely-not-there.js");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err != null);
    try testing.expect(res.result == null);
}

test "engine: evalFile on real tempfile with \"40+2\" returns \"42\"" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write script into the temp dir.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "script.js", .data = "40+2" });

    const real_path = try tmp.dir.realPathFileAlloc(testing.io, "script.js", testing.allocator);
    defer testing.allocator.free(real_path);

    const res = engine.evalFile(id, real_path);
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result != null);
    try testing.expectEqualStrings("42", res.result.?);
}

// ===================================================================
// Multi-instance isolation
// ===================================================================

test "engine: globals in instance A are not visible in instance B" {
    const id_a = helpers.nextInstanceId();
    const id_b = helpers.nextInstanceId();
    try testing.expect(engine.create(id_a, .{}));
    defer engine.destroy(id_a);
    try testing.expect(engine.create(id_b, .{}));
    defer engine.destroy(id_b);

    {
        const r = engine.evalScript(id_a, "globalThis.x = 42;", "<a>");
        defer helpers.freeEvalResult(r);
        try testing.expect(r.err == null);
    }

    const res = engine.evalScript(id_b, "typeof globalThis.x", "<b>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result != null);
    try testing.expectEqualStrings("undefined", res.result.?);
}

test "engine: console.log in A does not set globals in B" {
    const id_a = helpers.nextInstanceId();
    const id_b = helpers.nextInstanceId();
    try testing.expect(engine.create(id_a, .{}));
    defer engine.destroy(id_a);
    try testing.expect(engine.create(id_b, .{}));
    defer engine.destroy(id_b);

    {
        const r = engine.evalScript(id_a, "console.log('hi'); globalThis.leaked = 'A';", "<a>");
        defer helpers.freeEvalResult(r);
        try testing.expect(r.err == null);
    }

    const res = engine.evalScript(id_b, "typeof globalThis.leaked", "<b>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result != null);
    try testing.expectEqualStrings("undefined", res.result.?);
}

// ===================================================================
// dispatchTask + event loop
// ===================================================================

test "engine: dispatchTask runs on runEventLoopOnce and sets globals" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    try testing.expect(engine.dispatchTask(id, "globalThis.__ran__ = 123;"));
    engine.runEventLoopOnce(id);

    const res = engine.evalScript(id, "globalThis.__ran__", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result != null);
    try testing.expectEqualStrings("123", res.result.?);
}

test "engine: dispatchTask reports rejection for a destroyed instance" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    engine.destroy(id);

    // Should not crash, not leak.
    try testing.expect(!engine.dispatchTask(id, "globalThis.__oops__ = 1;"));
}

test "engine: stopEventLoop before run and before destroy is safe" {
    const unknown_id: i32 = 888_888;
    engine.destroy(unknown_id); // ensure clean
    // stop on a non-existent id should be a no-op.
    engine.stopEventLoop(unknown_id);

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    // stop before any run.
    engine.stopEventLoop(id);
    // Still safe to destroy afterwards.
    engine.destroy(id);
}

test "engine: runEventLoopOnce drains Promise microtasks" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    {
        const r = engine.evalScript(
            id,
            "Promise.resolve().then(() => { globalThis.__p = 1; });",
            "<test>",
        );
        defer helpers.freeEvalResult(r);
        try testing.expect(r.err == null);
    }

    engine.runEventLoopOnce(id);

    const res = engine.evalScript(id, "globalThis.__p", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expect(res.result != null);
    try testing.expectEqualStrings("1", res.result.?);
}

// ===================================================================
// instance_map direct round-trips
// ===================================================================

test "instance_map: instanceIdFromCtx round-trips for live instance" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const ctx = engine.getContext(id) orelse return error.NoCtx;
    const recovered = instance_map.instanceIdFromCtx(ctx);
    try testing.expectEqual(id, recovered);
}

test "instance_map: getPtrs returns non-null for live, null after destroy" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));

    const live = instance_map.getPtrs(id);
    try testing.expect(live != null);

    engine.destroy(id);

    const dead = instance_map.getPtrs(id);
    try testing.expect(dead == null);
}

// ===================================================================
// Log handler integration
// ===================================================================

// Shared static sink for the log handler test. Guarded by a mutex because Zig tests may run in parallel (the handler callback is invoked synchronously on the eval thread, but multiple test runs could still interleave).
const LogSink = struct {
    var mutex: sync.Mutex = .{};
    var buffer: [4096]u8 = undefined;
    var len: usize = 0;
    var last_level: types.LogLevel = .debug;
    var count: usize = 0;

    fn reset() void {
        mutex.lock();
        defer mutex.unlock();
        len = 0;
        count = 0;
        last_level = .debug;
    }

    fn snapshot(out: []u8) usize {
        mutex.lock();
        defer mutex.unlock();
        const n = @min(out.len, len);
        @memcpy(out[0..n], buffer[0..n]);
        return n;
    }
};

fn testLogHandler(
    _id: i32,
    level: types.LogLevel,
    msg: [*:0]const u8,
    _user_data: ?*anyopaque,
) callconv(.c) void {
    _ = _id;
    _ = _user_data;
    const s = std.mem.span(msg);
    LogSink.mutex.lock();
    defer LogSink.mutex.unlock();
    const remaining = LogSink.buffer.len - LogSink.len;
    const n = @min(remaining, s.len);
    @memcpy(LogSink.buffer[LogSink.len .. LogSink.len + n], s[0..n]);
    LogSink.len += n;
    LogSink.last_level = level;
    LogSink.count += 1;
}

test "engine: log handler receives console.log output" {
    LogSink.reset();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = testLogHandler }));
    defer engine.destroy(id);

    {
        const r = engine.evalScript(id, "console.log('A', 123, {x:1})", "<test>");
        defer helpers.freeEvalResult(r);
        try testing.expect(r.err == null);
    }

    // console.log is synchronous in the backend, but drain pending jobs anyway.
    engine.runEventLoopOnce(id);

    var buf: [4096]u8 = undefined;
    const n = LogSink.snapshot(buf[0..]);
    const got = buf[0..n];

    // Must contain all three pieces, space-separated.
    try testing.expect(std.mem.indexOf(u8, got, "A") != null);
    try testing.expect(std.mem.indexOf(u8, got, "123") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"x\":1") != null);

    LogSink.mutex.lock();
    defer LogSink.mutex.unlock();
    try testing.expect(LogSink.count >= 1);
}

// ===================================================================
// Stack limit enforcement (the C API creates engines with a bounded 1 MiB JS stack so unbounded recursion is aborted, not crashed).
// ===================================================================

test "engine: bounded stack aborts deep recursion with a JS exception" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{ .max_stack_size = 1 * 1024 * 1024 }, struct {
        fn run(eid: i32) !void {
            const res = engine.evalScript(eid, "function f(){ return f(); } f();", "<deep>");
            defer helpers.freeEvalResult(res);
            // Must surface as an error, not abort the process.
            try testing.expect(res.err != null);
        }
    }.run);
}

test "engine: bounded stack still runs large flat scripts" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{ .max_stack_size = 1 * 1024 * 1024 }, struct {
        fn run(eid: i32) !void {
            // Deep loop, zero recursion — must run fine under the cap.
            const res = engine.evalScript(eid, "var s=''; for(var i=0;i<2000;i++){ s+='x'; } s.length;", "<flat>");
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);
            try testing.expectEqualStrings("2000", res.result.?);
        }
    }.run);
}
