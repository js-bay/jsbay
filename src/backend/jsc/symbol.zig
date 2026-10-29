//! JavaScriptCore symbols.
//!
//! `makeUnique` is `Symbol(description)` via `JSValueMakeSymbol`. `makeFor` is `Symbol.for(key)` so it shares the JS global registry. Returned values are not protected; the caller roots them before the next JS call that could collect.

const common = @import("common.zig");

const jsc = common.jsc;

extern fn JSValueMakeSymbol(ctx: jsc.JSContextRef, description: jsc.JSStringRef) jsc.JSValueRef;

pub fn makeUnique(ctx: jsc.JSContextRef, desc: []const u8) ?jsc.JSValueRef {
    const js = common.jsStringFromSlice(desc) orelse return null;
    defer jsc.JSStringRelease(js);
    const sym = JSValueMakeSymbol(ctx, js);
    if (sym == null) return null;
    return sym;
}

pub fn makeFor(ctx: jsc.JSContextRef, key: []const u8) ?jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    if (global == null) return null;

    const symbol_name = jsc.JSStringCreateWithUTF8CString("Symbol");
    defer jsc.JSStringRelease(symbol_name);
    var exc: jsc.JSValueRef = null;
    const symbol_val = jsc.JSObjectGetProperty(ctx, global, symbol_name, &exc);
    if (exc != null or symbol_val == null) return null;
    exc = null;
    const symbol_obj = jsc.JSValueToObject(ctx, symbol_val, &exc);
    if (exc != null or symbol_obj == null) return null;

    const for_name = jsc.JSStringCreateWithUTF8CString("for");
    defer jsc.JSStringRelease(for_name);
    exc = null;
    const for_val = jsc.JSObjectGetProperty(ctx, symbol_obj, for_name, &exc);
    if (exc != null or for_val == null) return null;
    exc = null;
    const for_fn = jsc.JSValueToObject(ctx, for_val, &exc);
    if (exc != null or for_fn == null) return null;

    const arg = common.makeStringValue(ctx, key) orelse return null;
    var args = [_]jsc.JSValueRef{arg};
    exc = null;
    const result = jsc.JSObjectCallAsFunction(ctx, for_fn, symbol_obj, 1, &args, &exc);
    if (exc != null or result == null) return null;
    return result;
}
