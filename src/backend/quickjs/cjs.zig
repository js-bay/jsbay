//! CommonJS support (see src/script/cjs.zig).
//!
//! `qjsCjsEvalToValue` evaluates `source` as a global script and returns the raw JSValue of the last expression, WITHOUT stringifying. `cjs.zig` uses this to obtain the wrapping function produced by `(function (exports, module, require, __filename, __dirname) { ... })`.
//!
//! The caller owns the returned value — free it via `jsbay_qjs_JS_FreeValue` (or hand it off to QJS via a call/property-set). On exception the function returns an exception-tagged JSValue and a formatted error message in `out_err` (heap-allocated, caller frees with `std.heap.c_allocator.free`).

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

const exception = @import("exception.zig");
const lifecycle = @import("lifecycle.zig");

pub fn qjsCjsEvalToValue(
    ctx: ?*qjs.JSContext,
    source: []const u8,
    filename: []const u8,
    out_err: *?[]const u8,
) qjs.JSValue {
    if (!lifecycle.enterJs(ctx)) {
        // Refused: another thread is using this runtime, so do NOT touch ctx (no throw). Report via out_err only. Caller must serialize access.
        out_err.* = std.heap.c_allocator.dupe(u8, lifecycle.cross_thread_reentry_msg) catch null;
        return c.JS_EXCEPTION;
    }
    defer lifecycle.leaveJs(ctx);
    lifecycle.syncStackTopForJs(ctx);
    out_err.* = null;
    const fname = std.heap.c_allocator.dupeSentinel(u8, filename, 0) catch {
        out_err.* = std.heap.c_allocator.dupe(u8, "Failed to allocate filename") catch null;
        return c.JS_EXCEPTION;
    };
    defer std.heap.c_allocator.free(fname);
    const src = std.heap.c_allocator.dupeSentinel(u8, source, 0) catch {
        out_err.* = std.heap.c_allocator.dupe(u8, "Failed to allocate script") catch null;
        return c.JS_EXCEPTION;
    };
    defer std.heap.c_allocator.free(src);

    const result = qjs.JS_Eval(
        ctx,
        src.ptr,
        src.len,
        fname.ptr,
        qjs.JS_EVAL_TYPE_GLOBAL,
    );
    if (c.jsIsException(result)) {
        out_err.* = exception.getAndFormatException(ctx);
        return result;
    }
    return result;
}
