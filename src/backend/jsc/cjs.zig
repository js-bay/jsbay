//! CommonJS support for the JSC backend (see src/script/cjs.zig).
//!
//! `jscCjsEvalToValue` evaluates `source` as a global script and returns the raw JSValueRef of the last expression WITHOUT stringifying. `cjs.zig` uses this to obtain the wrapping function produced by `(function (exports, module, require, __filename, __dirname) { ... })`.
//!
//! The returned value is NOT protected — the caller should `JSValueProtect` if they need to hold it across a GC. On exception, the function returns null and a formatted error message in `out_err` (heap-allocated via `std.heap.c_allocator`, caller frees).

const std = @import("std");
const common = @import("common.zig");

const jsc = common.jsc;

pub const Context = jsc.JSGlobalContextRef;

pub fn jscCjsEvalToValue(
    ctx: Context,
    source: []const u8,
    filename: []const u8,
    out_err: *?[]const u8,
) jsc.JSValueRef {
    out_err.* = null;
    const jsc_ctx: jsc.JSContextRef = @ptrCast(ctx);
    const js_script = common.jsStringFromSlice(source) orelse {
        out_err.* = std.heap.c_allocator.dupe(u8, "Out of memory") catch null;
        return null;
    };
    defer jsc.JSStringRelease(js_script);

    const js_url = if (filename.len > 0) common.jsStringFromSlice(filename) orelse {
        out_err.* = std.heap.c_allocator.dupe(u8, "Out of memory") catch null;
        return null;
    } else null;
    defer if (js_url) |u| jsc.JSStringRelease(u);

    var exception: jsc.JSValueRef = null;
    const result = jsc.JSEvaluateScript(jsc_ctx, js_script, null, js_url, 1, &exception);
    if (exception != null) {
        out_err.* = common.formatException(jsc_ctx, exception);
        return null;
    }
    return result;
}
