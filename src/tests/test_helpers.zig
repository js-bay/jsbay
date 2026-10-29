//! Shared helpers for test suites that exercise the full JS Bay public API.
//!
//! Provides:
//!   - withEngine(id, fn): create + destroy engine instance for a single test
//!   - evalOk / evalErr: evaluate JS and assert outcome
//!   - evalInt / evalString: evaluate + extract primitive
//!   - nextInstanceId(): monotonically increasing id to avoid collisions across tests
//!
//! These helpers ride on top of the public `engine` module so they exercise the same code paths a real consumer would.

const std = @import("std");
const testing = std.testing;

const engine = @import("../engine.zig");
const types = @import("../types.zig");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");

const ActiveEngine = backend.ActiveEngine;

/// Monotonically increasing instance id. Each test should call this once so concurrent test runs (when Zig enables parallel tests) do not collide on instance_map entries.
var g_next_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(10_000);

pub fn nextInstanceId() i32 {
    return g_next_id.fetchAdd(1, .seq_cst);
}

/// Fixture that owns an engine instance for the lifetime of a test closure.
pub fn withEngine(instance_id: i32, config: types.EngineConfig, comptime test_fn: fn (i32) anyerror!void) !void {
    if (!engine.create(instance_id, config)) return error.EngineCreateFailed;
    defer engine.destroy(instance_id);
    try test_fn(instance_id);
}

/// Convenience wrapper: default EngineConfig.
pub fn withDefaultEngine(comptime test_fn: fn (i32) anyerror!void) !void {
    const id = nextInstanceId();
    try withEngine(id, .{}, test_fn);
}

/// Evaluate a script and assert no error occurred.
pub fn evalOk(instance_id: i32, script: []const u8) !void {
    const res = engine.evalScript(instance_id, script, "<test>");
    defer freeEvalResult(res);
    if (res.err) |message| {
        std.debug.print("JavaScript evaluation failed: {s}\n", .{message});
        return error.JSException;
    }
}

/// Evaluate a script and assert an exception was thrown.
pub fn evalErr(instance_id: i32, script: []const u8) !void {
    const res = engine.evalScript(instance_id, script, "<test>");
    defer freeEvalResult(res);
    if (res.err == null) return error.ExpectedException;
}

/// Evaluate a script that returns a number, return it as i64.
pub fn evalInt(instance_id: i32, script: []const u8) !i64 {
    const res = engine.evalScript(instance_id, script, "<test>");
    defer freeEvalResult(res);
    if (res.err != null) return error.JSException;
    const s = res.result orelse return error.NoResult;
    return std.fmt.parseInt(i64, s, 10) catch error.NotAnInt;
}

/// Evaluate a script that returns a string, return owned copy (caller frees).
pub fn evalString(allocator: std.mem.Allocator, instance_id: i32, script: []const u8) ![]u8 {
    const res = engine.evalScript(instance_id, script, "<test>");
    defer freeEvalResult(res);
    if (res.err != null) return error.JSException;
    const s = res.result orelse return error.NoResult;
    return allocator.dupe(u8, s);
}

/// Assert that an eval returns a specific string value (primitive string or number stringified). Uses `String(expr)` under the hood when `wrap` is true.
pub fn expectEvalEquals(instance_id: i32, script: []const u8, expected: []const u8) !void {
    const res = engine.evalScript(instance_id, script, "<test>");
    defer freeEvalResult(res);
    if (res.err != null) return error.JSException;
    const actual = res.result orelse return error.NoResult;
    try testing.expectEqualStrings(expected, actual);
}

pub fn freeEvalResult(res: types.EvalResult) void {
    if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
    if (res.err_is_heap) {
        if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
    }
}

// ---- Low-level helpers (no engine instance, direct backend) ----

/// Run a test with a fresh runtime+context, no engine instance. Use when you need to exercise pure backend ops without the lifecycle plumbing.
pub fn withBareContext(comptime test_fn: fn (ActiveEngine.Context, ActiveEngine.Runtime) anyerror!void) !void {
    const rt = ActiveEngine.newRuntime() orelse return error.RuntimeCreationFailed;
    defer ActiveEngine.freeRuntime(rt);
    const ctx = ActiveEngine.newContext(rt) orelse return error.ContextCreationFailed;
    defer ActiveEngine.freeContext(ctx);
    try test_fn(ctx, rt);
}
