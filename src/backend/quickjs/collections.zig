//! Map / Set support for `value.zig`.
//!
//! Two layers:
//! * JSON-shape helpers (`qjsMapSetToJson`, `qjsNewMapFromJson`, ...) flatten a Map / Set through `Array.from(...)` + `JSON.stringify` for the fast-path serialisation that `value.zig` uses for simple JSON-safe contents.
//! * Native iteration (`qjsMapForEach`, `qjsSetForEach`) drives the standard iterator protocol (`val.entries()` / `val.values()` → `.next()` → `{done, value}`) without flattening, so callers can inspect the raw JSValues and decide how to encode them themselves.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

const exception = @import("exception.zig");

// ---- Map / Set detection via JS_IsInstanceOf ----

fn qjsGetGlobalCtor(ctx: ?*qjs.JSContext, name: [*:0]const u8) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, global);
    return qjs.JS_GetPropertyStr(ctx, global, name);
}

pub fn qjsIsMap(ctx: ?*qjs.JSContext, val: qjs.JSValue) bool {
    if (!c.jsIsObject(val)) return false;
    const ctor = qjsGetGlobalCtor(ctx, "Map");
    defer c.jsbay_qjs_JS_FreeValue(ctx, ctor);
    if (c.jsIsException(ctor) or c.jsIsUndefined(ctor)) return false;
    return c.JS_IsInstanceOf(ctx, val, ctor) > 0;
}

pub fn qjsIsSet(ctx: ?*qjs.JSContext, val: qjs.JSValue) bool {
    if (!c.jsIsObject(val)) return false;
    const ctor = qjsGetGlobalCtor(ctx, "Set");
    defer c.jsbay_qjs_JS_FreeValue(ctx, ctor);
    if (c.jsIsException(ctor) or c.jsIsUndefined(ctor)) return false;
    return c.JS_IsInstanceOf(ctx, val, ctor) > 0;
}

/// Return `JSON.stringify(Array.from(val))` as an owned slice, or null on error. For a Map this yields `[[k,v],...]`; for a Set it yields `[v,...]`.
pub fn qjsMapSetToJson(ctx: ?*qjs.JSContext, val: qjs.JSValue) ?[]const u8 {
    // Build: globalThis.JSON.stringify(Array.from(val))
    const global = qjs.JS_GetGlobalObject(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, global);

    // Array.from(val)
    const array_ctor = qjs.JS_GetPropertyStr(ctx, global, "Array");
    defer c.jsbay_qjs_JS_FreeValue(ctx, array_ctor);
    if (c.jsIsException(array_ctor) or c.jsIsUndefined(array_ctor)) return null;

    const from_atom = qjs.JS_NewAtom(ctx, "from");
    defer qjs.JS_FreeAtom(ctx, from_atom);

    var argv_from = [_]qjs.JSValue{val};
    const arr = qjs.JS_Invoke(ctx, array_ctor, from_atom, 1, &argv_from);
    if (c.jsIsException(arr)) {
        c.jsbay_qjs_JS_FreeValue(ctx, arr);
        return null;
    }
    defer c.jsbay_qjs_JS_FreeValue(ctx, arr);

    return exception.jsonStringify(ctx, arr);
}

/// Construct `new Map(JSON.parse(json))`. Returns JS_EXCEPTION on error.
pub fn qjsNewMapFromJson(ctx: ?*qjs.JSContext, json: []const u8) qjs.JSValue {
    // QuickJS' JSON lexer reads one byte past `buf_len` (lookahead), so the buffer must be NUL-terminated even though the API takes an explicit length. Callers may hand us a bare slice from `c_allocator.dupe`, which is NOT NUL-terminated — read-past-end then sees uninitialised malloc bytes, and on Linux/glibc that occasionally lands on a non-whitespace character, producing a phantom "SyntaxError: unexpected data at the end". Defensively copy into a sentinel-terminated buffer.
    const buf = std.heap.c_allocator.dupeSentinel(u8, json, 0) catch return c.JS_EXCEPTION;
    defer std.heap.c_allocator.free(buf);
    const parsed = qjs.JS_ParseJSON(ctx, buf.ptr, buf.len, "<map-json>");
    if (c.jsIsException(parsed)) return parsed;
    defer c.jsbay_qjs_JS_FreeValue(ctx, parsed);

    const global = qjs.JS_GetGlobalObject(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, global);
    const ctor = qjs.JS_GetPropertyStr(ctx, global, "Map");
    defer c.jsbay_qjs_JS_FreeValue(ctx, ctor);
    if (c.jsIsException(ctor) or c.jsIsUndefined(ctor)) return c.JS_EXCEPTION;

    var argv = [_]qjs.JSValue{parsed};
    return qjs.JS_CallConstructor(ctx, ctor, 1, &argv);
}

/// Construct `new Set(JSON.parse(json))`. Returns JS_EXCEPTION on error.
pub fn qjsNewSetFromJson(ctx: ?*qjs.JSContext, json: []const u8) qjs.JSValue {
    // See qjsNewMapFromJson: NUL-terminate to placate QuickJS lexer lookahead.
    const buf = std.heap.c_allocator.dupeSentinel(u8, json, 0) catch return c.JS_EXCEPTION;
    defer std.heap.c_allocator.free(buf);
    const parsed = qjs.JS_ParseJSON(ctx, buf.ptr, buf.len, "<set-json>");
    if (c.jsIsException(parsed)) return parsed;
    defer c.jsbay_qjs_JS_FreeValue(ctx, parsed);

    const global = qjs.JS_GetGlobalObject(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, global);
    const ctor = qjs.JS_GetPropertyStr(ctx, global, "Set");
    defer c.jsbay_qjs_JS_FreeValue(ctx, ctor);
    if (c.jsIsException(ctor) or c.jsIsUndefined(ctor)) return c.JS_EXCEPTION;

    var argv = [_]qjs.JSValue{parsed};
    return qjs.JS_CallConstructor(ctx, ctor, 1, &argv);
}

// ============================================================================
// Native iteration + builder helpers for Map and Set.
//
// These support `value.NativeArgs.mapForEach` / `setForEach` / `mapSize` / `setSize`, plus the free-function builder surface (`newMap`, `newSet`, `mapSet`, `setAdd`). They iterate via the standard JS iterator protocol (`val.entries()` / `val.values()` → `.next()` → `{done, value}`), producing raw JSValue references the caller gets to inspect per entry without flattening through JSON. The existing JSON-based helpers above (qjsMapSetToJson / qjsNewMapFromJson / qjsNewSetFromJson) are untouched and remain the fast path for simple JSON-safe contents.
// ============================================================================

/// Callback invoked once per Map entry by `qjsMapForEach`. Return true to keep iterating, false to stop. `key` / `value` are *borrowed* JSValue references owned by the iteration driver — do not free them from the callback and do not retain them past the call without JS_DupValue.
pub const QjsMapForEachFn = fn (
    ctx: ?*qjs.JSContext,
    cb_ctx: ?*anyopaque,
    key: qjs.JSValue,
    value: qjs.JSValue,
) callconv(.c) bool;

/// Callback invoked once per Set entry by `qjsSetForEach`. Same ownership rules as `QjsMapForEachFn`.
pub const QjsSetForEachFn = fn (
    ctx: ?*qjs.JSContext,
    cb_ctx: ?*anyopaque,
    value: qjs.JSValue,
) callconv(.c) bool;

/// Obtain an iterator by calling `val[method]()`. Returns a retained JSValue the caller must free, or null on exception / missing method.
fn qjsObtainIter(ctx: ?*qjs.JSContext, val: qjs.JSValue, method_name: [*:0]const u8) ?qjs.JSValue {
    const atom = qjs.JS_NewAtom(ctx, method_name);
    defer qjs.JS_FreeAtom(ctx, atom);
    const iter = qjs.JS_Invoke(ctx, val, atom, 0, null);
    if (c.jsIsException(iter)) {
        c.jsbay_qjs_JS_FreeValue(ctx, iter);
        const pending = qjs.JS_GetException(ctx);
        if (!c.jsIsNull(pending)) c.jsbay_qjs_JS_FreeValue(ctx, pending);
        return null;
    }
    if (c.jsIsUndefined(iter) or c.jsIsNull(iter)) {
        c.jsbay_qjs_JS_FreeValue(ctx, iter);
        return null;
    }
    return iter;
}

/// Pull one `result = iter.next()` frame. On "not done" returns the retained `result.value` (caller frees) and sets `done_out=false`. On "done" returns null with `done_out=true`. On exception returns null with `done_out=true` (caller treats as stop + error up the stack).
fn qjsIterNextValue(ctx: ?*qjs.JSContext, iter: qjs.JSValue, done_out: *bool) ?qjs.JSValue {
    const next_atom = qjs.JS_NewAtom(ctx, "next");
    defer qjs.JS_FreeAtom(ctx, next_atom);
    const result = qjs.JS_Invoke(ctx, iter, next_atom, 0, null);
    if (c.jsIsException(result)) {
        c.jsbay_qjs_JS_FreeValue(ctx, result);
        const pending = qjs.JS_GetException(ctx);
        if (!c.jsIsNull(pending)) c.jsbay_qjs_JS_FreeValue(ctx, pending);
        done_out.* = true;
        return null;
    }
    defer c.jsbay_qjs_JS_FreeValue(ctx, result);

    const done_val = qjs.JS_GetPropertyStr(ctx, result, "done");
    defer c.jsbay_qjs_JS_FreeValue(ctx, done_val);
    const done_int = qjs.JS_ToBool(ctx, done_val);
    done_out.* = (done_int != 0);
    if (done_out.*) return null;

    const val = qjs.JS_GetPropertyStr(ctx, result, "value");
    if (c.jsIsException(val)) {
        c.jsbay_qjs_JS_FreeValue(ctx, val);
        done_out.* = true;
        return null;
    }
    return val;
}

/// Iterate `val.entries()` and invoke `cb(ctx, cb_ctx, key, value)` per entry. Returns true on clean completion (either exhaustion or early-exit via `cb → false`). Returns false when the input is not a Map or when iteration raised a JS exception.
pub fn qjsMapForEach(
    ctx: ?*qjs.JSContext,
    val: qjs.JSValue,
    cb_ctx: ?*anyopaque,
    cb: *const QjsMapForEachFn,
) bool {
    if (!qjsIsMap(ctx, val)) return false;
    const iter = qjsObtainIter(ctx, val, "entries") orelse return false;
    defer c.jsbay_qjs_JS_FreeValue(ctx, iter);

    while (true) {
        var done: bool = false;
        const entry = qjsIterNextValue(ctx, iter, &done) orelse {
            return done;
        };
        // entry is a 2-element array [key, value].
        const key = qjs.JS_GetPropertyUint32(ctx, entry, 0);
        const value = qjs.JS_GetPropertyUint32(ctx, entry, 1);
        c.jsbay_qjs_JS_FreeValue(ctx, entry);
        if (c.jsIsException(key) or c.jsIsException(value)) {
            if (!c.jsIsException(key)) c.jsbay_qjs_JS_FreeValue(ctx, key);
            if (!c.jsIsException(value)) c.jsbay_qjs_JS_FreeValue(ctx, value);
            return false;
        }

        const keep_going = cb(ctx, cb_ctx, key, value);
        c.jsbay_qjs_JS_FreeValue(ctx, key);
        c.jsbay_qjs_JS_FreeValue(ctx, value);
        if (!keep_going) return true;
    }
}

/// Iterate `val.values()` and invoke `cb(ctx, cb_ctx, value)` per entry.
pub fn qjsSetForEach(
    ctx: ?*qjs.JSContext,
    val: qjs.JSValue,
    cb_ctx: ?*anyopaque,
    cb: *const QjsSetForEachFn,
) bool {
    if (!qjsIsSet(ctx, val)) return false;
    const iter = qjsObtainIter(ctx, val, "values") orelse return false;
    defer c.jsbay_qjs_JS_FreeValue(ctx, iter);

    while (true) {
        var done: bool = false;
        const item = qjsIterNextValue(ctx, iter, &done) orelse {
            return done;
        };
        const keep_going = cb(ctx, cb_ctx, item);
        c.jsbay_qjs_JS_FreeValue(ctx, item);
        if (!keep_going) return true;
    }
}

/// Read `map.size` as a usize. Returns null if `val` is not a Map.
pub fn qjsMapSize(ctx: ?*qjs.JSContext, val: qjs.JSValue) ?usize {
    if (!qjsIsMap(ctx, val)) return null;
    const prop = qjs.JS_GetPropertyStr(ctx, val, "size");
    defer c.jsbay_qjs_JS_FreeValue(ctx, prop);
    if (c.jsIsException(prop)) return null;
    var d: f64 = 0;
    if (qjs.JS_ToFloat64(ctx, &d, prop) != 0) return null;
    if (!std.math.isFinite(d) or d < 0) return null;
    return @intFromFloat(d);
}

/// Read `set.size` as a usize. Returns null if `val` is not a Set.
pub fn qjsSetSize(ctx: ?*qjs.JSContext, val: qjs.JSValue) ?usize {
    if (!qjsIsSet(ctx, val)) return null;
    const prop = qjs.JS_GetPropertyStr(ctx, val, "size");
    defer c.jsbay_qjs_JS_FreeValue(ctx, prop);
    if (c.jsIsException(prop)) return null;
    var d: f64 = 0;
    if (qjs.JS_ToFloat64(ctx, &d, prop) != 0) return null;
    if (!std.math.isFinite(d) or d < 0) return null;
    return @intFromFloat(d);
}

/// Construct an empty `new Map()`. Returns JS_EXCEPTION on failure.
pub fn qjsNewMap(ctx: ?*qjs.JSContext) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, global);
    const ctor = qjs.JS_GetPropertyStr(ctx, global, "Map");
    defer c.jsbay_qjs_JS_FreeValue(ctx, ctor);
    if (c.jsIsException(ctor) or c.jsIsUndefined(ctor)) return c.JS_EXCEPTION;
    return qjs.JS_CallConstructor(ctx, ctor, 0, null);
}

/// Construct an empty `new Set()`. Returns JS_EXCEPTION on failure.
pub fn qjsNewSet(ctx: ?*qjs.JSContext) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, global);
    const ctor = qjs.JS_GetPropertyStr(ctx, global, "Set");
    defer c.jsbay_qjs_JS_FreeValue(ctx, ctor);
    if (c.jsIsException(ctor) or c.jsIsUndefined(ctor)) return c.JS_EXCEPTION;
    return qjs.JS_CallConstructor(ctx, ctor, 0, null);
}

/// Invoke `map.set(key, value)`. QuickJS Map takes +1 refs on both arguments; callers retain ownership of the originals they passed in. Returns true on success, false if `map` isn't callable-as-Map or .set threw.
pub fn qjsMapSet(ctx: ?*qjs.JSContext, map: qjs.JSValue, key: qjs.JSValue, value: qjs.JSValue) bool {
    const atom = qjs.JS_NewAtom(ctx, "set");
    defer qjs.JS_FreeAtom(ctx, atom);
    var args = [_]qjs.JSValue{ key, value };
    const r = qjs.JS_Invoke(ctx, map, atom, 2, &args);
    if (c.jsIsException(r)) {
        c.jsbay_qjs_JS_FreeValue(ctx, r);
        const pending = qjs.JS_GetException(ctx);
        if (!c.jsIsNull(pending)) c.jsbay_qjs_JS_FreeValue(ctx, pending);
        return false;
    }
    c.jsbay_qjs_JS_FreeValue(ctx, r);
    return true;
}

/// Invoke `set.add(value)`. Returns true on success.
pub fn qjsSetAdd(ctx: ?*qjs.JSContext, set: qjs.JSValue, value: qjs.JSValue) bool {
    const atom = qjs.JS_NewAtom(ctx, "add");
    defer qjs.JS_FreeAtom(ctx, atom);
    var args = [_]qjs.JSValue{value};
    const r = qjs.JS_Invoke(ctx, set, atom, 1, &args);
    if (c.jsIsException(r)) {
        c.jsbay_qjs_JS_FreeValue(ctx, r);
        const pending = qjs.JS_GetException(ctx);
        if (!c.jsIsNull(pending)) c.jsbay_qjs_JS_FreeValue(ctx, pending);
        return false;
    }
    c.jsbay_qjs_JS_FreeValue(ctx, r);
    return true;
}
