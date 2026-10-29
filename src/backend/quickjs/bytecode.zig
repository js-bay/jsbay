//! Bytecode cache support.
//!
//! Expose QuickJS's portable bytecode serialization so consumers can compile a script once and run the resulting bytes many times, skipping the parse step on hot startup paths. Pairs:
//!
//! qjsCompileBytecode(ctx, source, filename) -> bytes (c_allocator-owned) qjsRunBytecode(ctx, bytes) -> EvalResult
//!
//! Steps (compile):
//!   1. JS_Eval(..., JS_EVAL_FLAG_COMPILE_ONLY | JS_EVAL_TYPE_GLOBAL) -> fn obj
//!   2. JS_WriteObject(ctx, &size, fn_obj, JS_WRITE_OBJ_BYTECODE) -> raw bytes
//! 3. Copy raw bytes into a c_allocator slice (the raw buffer must be freed with js_free; owning the copy locally frees callers of that concern).
//!   4. Free the JSValue and the raw buffer.
//!
//! Steps (run):
//!   1. JS_ReadObject(ctx, buf, len, JS_READ_OBJ_BYTECODE) -> unevaluated fn
//!   2. JS_EvalFunction(ctx, fn_obj) — consumes fn_obj, returns eval result.
//!   3. Stringify the result the same way `eval` does.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

const exception = @import("exception.zig");
const lifecycle = @import("lifecycle.zig");
const module_mod = @import("module.zig");
const types_mod = @import("../../types.zig");

/// QuickJS bytecode flags. The header defines these as `#define` so we mirror them here rather than relying on cImport — a few translate-c setups drop object-like macros whose value is a shifted 1, producing compile errors at use-sites. The values match quickjs.h exactly.
pub const QJS_WRITE_OBJ_BYTECODE: c_int = 1 << 0;
pub const QJS_READ_OBJ_BYTECODE: c_int = 1 << 0;

pub const QjsCompileResult = struct {
    /// Non-null on success. Heap-allocated via c_allocator; free with qjsFreeBytecode or `std.heap.c_allocator.free` on `@constCast` if the caller owns it directly.
    bytes: ?[]u8 = null,
    /// Non-null on compile error; heap-allocated via c_allocator (consistent with EvalResult.err_is_heap = true contract).
    err: ?[]const u8 = null,
};

/// Compile `source` to portable bytecode bytes. Returned bytes are a c_allocator-owned slice; caller frees with `qjsFreeBytecode` or plain `std.heap.c_allocator.free`.
pub fn qjsCompileBytecode(
    ctx: ?*qjs.JSContext,
    source: []const u8,
    filename: []const u8,
) QjsCompileResult {
    if (!lifecycle.enterJs(ctx)) {
        return .{ .err = std.heap.c_allocator.dupe(u8, lifecycle.cross_thread_reentry_msg) catch null };
    }
    defer lifecycle.leaveJs(ctx);
    lifecycle.syncStackTopForJs(ctx);
    const fname = std.heap.c_allocator.dupeSentinel(u8, filename, 0) catch {
        return .{ .err = null }; // allocation failure — treated as silent fail
    };
    defer std.heap.c_allocator.free(fname);

    const src = std.heap.c_allocator.dupeSentinel(u8, source, 0) catch {
        return .{ .err = null };
    };
    defer std.heap.c_allocator.free(src);

    const compiled = qjs.JS_Eval(
        ctx,
        src.ptr,
        src.len,
        fname.ptr,
        qjs.JS_EVAL_TYPE_GLOBAL | module_mod.QJS_EVAL_FLAG_COMPILE_ONLY,
    );

    if (c.jsIsException(compiled)) {
        const msg = exception.getAndFormatException(ctx);
        c.jsbay_qjs_JS_FreeValue(ctx, compiled);
        return .{ .err = msg };
    }

    var out_size: usize = 0;
    const raw_ptr = qjs.JS_WriteObject(ctx, &out_size, compiled, QJS_WRITE_OBJ_BYTECODE);
    // JS_WriteObject returns NULL on failure with the exception parked in ctx.
    if (raw_ptr == null) {
        const msg = exception.getAndFormatException(ctx);
        c.jsbay_qjs_JS_FreeValue(ctx, compiled);
        return .{ .err = msg };
    }

    // Copy into c_allocator memory so the API boundary doesn't leak the js_free ownership requirement.
    const owned = std.heap.c_allocator.alloc(u8, out_size) catch {
        qjs.js_free(ctx, raw_ptr);
        c.jsbay_qjs_JS_FreeValue(ctx, compiled);
        return .{ .err = null };
    };
    if (out_size > 0) {
        @memcpy(owned, raw_ptr[0..out_size]);
    }
    qjs.js_free(ctx, raw_ptr);
    c.jsbay_qjs_JS_FreeValue(ctx, compiled);
    return .{ .bytes = owned };
}

/// Release a byte slice returned by `qjsCompileBytecode`.
pub fn qjsFreeBytecode(bytes: []u8) void {
    if (bytes.len == 0) return;
    std.heap.c_allocator.free(bytes);
}

/// Load previously-compiled bytecode and execute it. Returns an EvalResult in the same shape as `QuickJsBackend.eval`.
pub fn qjsRunBytecode(ctx: ?*qjs.JSContext, bytes: []const u8) types_mod.EvalResult {
    if (!lifecycle.enterJs(ctx)) return .{ .result = null, .err = lifecycle.cross_thread_reentry_msg, .err_is_heap = false };
    defer lifecycle.leaveJs(ctx);
    lifecycle.syncStackTopForJs(ctx);
    if (bytes.len == 0) {
        // An empty buffer is undecodable, not a script that threw: flag decode_failed so a cache consumer deletes the empty artifact and rebuilds instead of failing on every subsequent replay.
        return .{ .result = null, .err = "bytecode buffer is empty", .err_is_heap = false, .decode_failed = true };
    }
    // JS_ReadObject is safe to call with a non-NUL-terminated buffer (unlike JS_Eval); no copy required.
    const fn_obj = qjs.JS_ReadObject(ctx, bytes.ptr, bytes.len, QJS_READ_OBJ_BYTECODE);
    if (c.jsIsException(fn_obj)) {
        const msg = exception.getAndFormatException(ctx);
        c.jsbay_qjs_JS_FreeValue(ctx, fn_obj);
        // Decode failure, not a script runtime error: tell cache consumers this payload can't be replayed (stale/corrupt) so they may delete and recompile instead of surfacing it as a script exception.
        return .{ .result = null, .err = msg, .err_is_heap = true, .decode_failed = true };
    }

    // JS_EvalFunction consumes `fn_obj` — do NOT free it separately.
    const result = qjs.JS_EvalFunction(ctx, fn_obj);

    if (c.jsIsException(result)) {
        const msg = exception.getAndFormatException(ctx);
        c.jsbay_qjs_JS_FreeValue(ctx, result);
        return .{ .result = null, .err = msg, .err_is_heap = true };
    }

    // Drain microtasks queued by the executed bytecode.
    lifecycle.processPendingJobsImpl(ctx);

    const ret: ?[]const u8 = if (c.jsIsUndefined(result) or c.jsIsNull(result))
        null
    else if (c.jsIsObject(result))
        exception.jsonStringify(ctx, result)
    else
        exception.valueToString(ctx, result);

    c.jsbay_qjs_JS_FreeValue(ctx, result);
    return .{ .result = ret, .err = null };
}

/// Result of `qjsRunBytecodeToFn`: a compiled function value recovered from bytecode, ready to be called with an explicit argument list.
pub const BytecodeToFnResult = struct {
    /// The recovered function value. Caller owns it and MUST free with `jsbay_qjs_JS_FreeValue` (or by passing it into a call that consumes it). Null when the bytecode could not decode.
    fn_value: ?qjs.JSValue = null,
    err: ?[]const u8 = null,
    err_is_heap: bool = false,
    decode_failed: bool = false,
};

/// Load previously-compiled bytecode and recover the compiled function value WITHOUT executing it as a top-level script. This is the primitive the CommonJS path needs: a module body compiled via `(function(exports, module, require, ...) { ... })` must come back as a *function* so it can be invoked with the per-module `exports`/`module`/ `require` environment (unlike `qjsRunBytecode`, which calls `JS_EvalFunction` and flattens the result to a string).
pub fn qjsRunBytecodeToFn(ctx: ?*qjs.JSContext, bytes: []const u8) BytecodeToFnResult {
    if (!lifecycle.enterJs(ctx)) {
        return .{ .err = lifecycle.cross_thread_reentry_msg, .err_is_heap = false, .decode_failed = false };
    }
    defer lifecycle.leaveJs(ctx);
    lifecycle.syncStackTopForJs(ctx);
    if (bytes.len == 0) {
        return .{ .err = null, .decode_failed = true };
    }

    const fn_obj = qjs.JS_ReadObject(ctx, bytes.ptr, bytes.len, QJS_READ_OBJ_BYTECODE);
    if (c.jsIsException(fn_obj)) {
        const msg = exception.getAndFormatException(ctx);
        c.jsbay_qjs_JS_FreeValue(ctx, fn_obj);
        return .{ .err = msg, .err_is_heap = true, .decode_failed = true };
    }

    // JS_EvalFunction evaluates a compiled function expression: for a `(function(){...})` bytecode this yields the function value itself (the body is NOT invoked). We hand that value back to the caller so it can construct the module environment and call it.
    const fn_value = qjs.JS_EvalFunction(ctx, fn_obj);
    if (c.jsIsException(fn_value)) {
        const msg = exception.getAndFormatException(ctx);
        c.jsbay_qjs_JS_FreeValue(ctx, fn_value);
        return .{ .err = msg, .err_is_heap = true };
    }
    return .{ .fn_value = fn_value };
}
