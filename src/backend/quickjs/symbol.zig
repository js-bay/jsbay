//! QuickJS symbols.
//!
//! `is_global == false` is `Symbol(description)` (a new identity every call). `is_global == true` is `Symbol.for(key)` (the global symbol registry).

const std = @import("std");
const c = @import("c_api.zig");

const qjs = c.qjs;

/// Owned JSValue. On failure the context has a pending exception.
pub fn make(ctx: ?*qjs.JSContext, text: []const u8, is_global: bool) qjs.JSValue {
    const z = std.heap.c_allocator.dupeSentinel(u8, text, 0) catch return qjs.JS_ThrowOutOfMemory(ctx);
    defer std.heap.c_allocator.free(z);
    return c.jsbay_qjs_JS_NewSymbol(ctx, z.ptr, @intFromBool(is_global));
}
