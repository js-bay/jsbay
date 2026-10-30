//! Bytecode cache — compile a JS script once, serialize bytes for the same trusted build, and re-execute without re-parsing on subsequent starts.
//!
//! This is a significant perf win for large scripts loaded at startup (napi-rs and rquickjs expose equivalent APIs). The pattern is:
//!
//! const bytes = bytecode.compile(id, source, "app.js") orelse unreachable; defer bytecode.freeBytecode(bytes); // ... persist `bytes` to disk ...
//!
//! // later, on the cold path: const bytes = std.Io.Dir.cwd().readFileAlloc(io.get(), path, gpa, .limited(max_size)); const res = bytecode.runBytecode(id, bytes); defer helpers.freeEvalResult(res);
//!
//! Backend support:
//! - QuickJS: fully implemented via JS_WriteObject / JS_ReadObject + JS_EvalFunction.
//! - JavaScriptCore / Escargot: no stable public bytecode blob API. `compile` returns a not-supported sentinel; `runBytecode` returns the same.
//! - Hermes: compile via hermesc to `.hbc`, run via JSI `evaluateJavaScript` Buffer.
//!
//! Safety contract: like every other engine API, operations on a given `instance_id` MUST happen on the owning thread.

const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const instance_map = @import("../runtime/instance_map.zig");
const types = @import("../types.zig");

/// Result of `compile`.
///
/// * Success: `bytes != null and err == null`. The slice is heap-allocated (c_allocator) — caller must release it via `freeBytecode` (or `std.heap.c_allocator.free(@constCast(bytes))`).
/// * Error: `bytes == null and err != null`. `err` is c_allocator-owned when `err_is_heap` is true (compile errors reported by the engine); it is a string literal when `err_is_heap` is false (e.g. dead instance, JSC "not supported"). Free identically to `EvalResult.err`.
pub const CompileResult = struct {
    bytes: ?[]u8 = null,
    err: ?[]const u8 = null,
    /// true if `err` is heap-allocated (c_allocator); false for string literals. Mirrors the `EvalResult.err_is_heap` contract so callers can use the same free helper on both.
    err_is_heap: bool = false,
};

/// Compile `source` into bytecode for this build. The bytes are not a cross-engine, cross-version, or cross-architecture format. `filename` appears in stack traces for runtime errors produced when the bytecode is later executed — pass a stable identifier (e.g. the original script path).
///
/// Returns an error CompileResult when `instance_id` is not live, when allocation fails, or when `source` has a syntax error. On JSC, returns the sentinel "not supported" error.
pub fn compile(
    instance_id: i32,
    source: []const u8,
    filename: []const u8,
) CompileResult {
    if (instance_map.getInstance(instance_id) == null) {
        return .{ .err = "Instance not found", .err_is_heap = false };
    }
    if (instance_map.isTeardownPending(instance_id)) {
        return .{ .err = "Engine is tearing down", .err_is_heap = false };
    }
    const engine_thread = @import("../runtime/engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed) {
        const err = if (instance_map.getInstance(instance_id) == null)
            "Instance not found"
        else if (instance_map.isTeardownPending(instance_id))
            "Engine is tearing down"
        else
            engine_thread.foreign_eval_err;
        return .{ .err = err, .err_is_heap = false };
    }
    const ctx = engine.getContext(instance_id) orelse
        return .{ .err = "Instance not found", .err_is_heap = false };

    var execution = @import("../runtime/js_scheduler.zig").beginExecution(instance_id) orelse
        return .{ .err = "Instance not found", .err_is_heap = false };
    defer {
        execution.end();
        @import("../runtime/js_scheduler.zig").checkpoint(instance_id, ctx);
    }

    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const out = qjs_mod.qjsCompileBytecode(ctx, source, filename);
            if (out.bytes) |b| {
                return .{ .bytes = b, .err = null, .err_is_heap = false };
            }
            // Backend returned an error. `err` is c_allocator-owned (produced by getAndFormatException); flag err_is_heap accordingly.
            return .{ .bytes = null, .err = out.err, .err_is_heap = out.err != null };
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const out = jsc_mod.jscCompileBytecode(@ptrCast(ctx), source, filename);
            // JSC always returns the static "not supported" literal — not heap.
            return .{ .bytes = out.bytes, .err = out.err, .err_is_heap = false };
        },
        .escargot => return .{ .err = "bytecode cache is not supported on Escargot backend", .err_is_heap = false },
        .hermes => {
            // Hermes .hbc via hermesc + JSI Buffer (only analyzed when -Dbackend=hermes).
            if (comptime !backend.isHermesBackend(backend.active_backend)) {
                return .{ .err = "bytecode cache is not supported on this backend", .err_is_heap = false };
            }
            const out = @import("../backend/hermes.zig").hermesCompileBytecode(source, filename);
            if (out.bytes) |b| return .{ .bytes = b, .err = null, .err_is_heap = false };
            return .{ .bytes = null, .err = out.err, .err_is_heap = out.err != null };
        },
    }
}

/// Release the `bytes` slice returned by `compile`. No-op on a null/empty slice, matching the convention of the other `free*` helpers in this module tree.
pub fn freeBytecode(bytes: []u8) void {
    if (bytes.len == 0) return;
    // Both backends allocate via c_allocator (QJS copies out of js_malloc into c_allocator at compile time; JSC never returns bytes).
    std.heap.c_allocator.free(bytes);
}

/// Load previously-compiled bytecode and execute it, returning the same EvalResult shape as `engine.evalScript`. `bytes` may be freed as soon as this function returns — QuickJS copies the buffer internally during `JS_ReadObject`.
///
/// Returns an error EvalResult when `instance_id` is dead, when the bytes are corrupt, or when the script throws at runtime. On JSC, always returns the sentinel "not supported" error.
pub fn runBytecode(instance_id: i32, bytes: []const u8) types.EvalResult {
    if (instance_map.getInstance(instance_id) == null) {
        return .{ .result = null, .err = engine.instance_not_found_err, .err_is_heap = false };
    }
    if (instance_map.isTeardownPending(instance_id)) {
        return .{ .result = null, .err = "Engine is tearing down", .err_is_heap = false };
    }
    const engine_thread = @import("../runtime/engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed) {
        if (instance_map.getInstance(instance_id) == null) {
            return .{ .result = null, .err = engine.instance_not_found_err, .err_is_heap = false };
        }
        const err = if (instance_map.isTeardownPending(instance_id))
            "Engine is tearing down"
        else
            engine_thread.foreign_eval_err;
        return .{
            .result = null,
            .err = err,
            .err_is_heap = false,
        };
    }
    const ctx = engine.getContext(instance_id) orelse
        return .{ .result = null, .err = engine.instance_not_found_err, .err_is_heap = false };

    var execution = @import("../runtime/js_scheduler.zig").beginExecution(instance_id) orelse
        return .{ .err = "Instance not found", .err_is_heap = false };
    defer {
        execution.end();
        @import("../runtime/js_scheduler.zig").checkpoint(instance_id, ctx);
    }

    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            return qjs_mod.qjsRunBytecode(ctx, bytes);
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            return jsc_mod.jscRunBytecode(@ptrCast(ctx), bytes);
        },
        .escargot => return .{ .err = "bytecode cache is not supported on Escargot backend", .err_is_heap = false },
        .hermes => {
            if (comptime !backend.isHermesBackend(backend.active_backend)) {
                return .{ .err = "bytecode cache is not supported on this backend", .err_is_heap = false };
            }
            return @import("../backend/hermes.zig").hermesRunBytecode(ctx, bytes);
        },
    }
}

/// Free a `CompileResult` uniformly. Releases both the heap-allocated bytes slice (if present) and the heap-allocated error message (if present). Safe to call on a zero-initialised result.
pub fn freeCompileResult(res: CompileResult) void {
    if (res.bytes) |b| freeBytecode(b);
    if (res.err_is_heap) {
        if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
    }
}
