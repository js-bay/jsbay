//! Structured error API helpers for the JSC backend (see ../errors.zig).
//!
//! JSC's public C API exposes JSObjectMakeError for a plain Error and nothing for the derived built-ins (TypeError, RangeError, ...). We fetch the desired constructor off globalThis and invoke it via JSObjectCallAsConstructor. `jscIsError` uses `instanceof Error` through JSValueIsInstanceOfConstructor.

const std = @import("std");
const common = @import("common.zig");

const jsc = common.jsc;

pub const JscErrorKind = enum(u8) {
    generic,
    type_error,
    range_error,
    reference_error,
    syntax_error,
    uri_error,
    eval_error,
    internal_error,
    aggregate_error,
};

/// Frames inside `jscNewTypedError` on this thread. Past one frame we refuse to call a constructor again.
threadlocal var jsc_error_depth: u8 = 0;

fn jscErrorCtorName(kind: JscErrorKind) ?[*:0]const u8 {
    return switch (kind) {
        .generic => "Error",
        .type_error => "TypeError",
        .range_error => "RangeError",
        .reference_error => "ReferenceError",
        .syntax_error => "SyntaxError",
        .uri_error => "URIError",
        .eval_error => "EvalError",
        // JSC has no "InternalError" global (unlike SpiderMonkey); fall back to plain Error. Tests must not assert on internal_error under JSC.
        .internal_error => "Error",
        .aggregate_error => "AggregateError",
    };
}

/// Create a new Error object of the requested kind with `message` attached. Returns `null` on allocation failure (caller must tolerate). The returned value is a raw JSObjectRef — the caller is responsible for protecting / freeing (matches the `jscNewExternal` contract).
pub fn jscNewTypedError(
    ctx: jsc.JSContextRef,
    kind: JscErrorKind,
    message: []const u8,
) jsc.JSObjectRef {
    if (jsc_error_depth >= 1) return null;
    jsc_error_depth += 1;
    defer jsc_error_depth -= 1;

    const msg_js = common.jsStringFromSlice(message) orelse return null;
    defer jsc.JSStringRelease(msg_js);
    const msg_val = jsc.JSValueMakeString(ctx, msg_js);

    if (jscErrorCtorName(kind)) |ctor_name| {
        const global = jsc.JSContextGetGlobalObject(ctx);
        const ctor_key = jsc.JSStringCreateWithUTF8CString(ctor_name);
        defer jsc.JSStringRelease(ctor_key);
        var exc: jsc.JSValueRef = null;
        const ctor_val = jsc.JSObjectGetProperty(ctx, global, ctor_key, &exc);
        if (exc != null or ctor_val == null or !jsc.JSValueIsObject(ctx, ctor_val)) {
            return jscMakePlainError(ctx, msg_val);
        }
        const ctor: jsc.JSObjectRef = @constCast(ctor_val);

        if (kind == .aggregate_error) {
            // AggregateError(errors, message) — first arg must be iterable.
            const empty_arr = jsc.JSObjectMakeArray(ctx, 0, null, null);
            var args = [_]jsc.JSValueRef{ empty_arr, msg_val };
            var call_exc: jsc.JSValueRef = null;
            const result = jsc.JSObjectCallAsConstructor(ctx, ctor, 2, &args, &call_exc);
            if (call_exc != null or result == null) {
                // User constructor threw. Do not call Error again.
                if (call_exc != null) return null;
                return jscMakePlainError(ctx, msg_val);
            }
            return result;
        }

        var args = [_]jsc.JSValueRef{msg_val};
        var call_exc: jsc.JSValueRef = null;
        const result = jsc.JSObjectCallAsConstructor(ctx, ctor, 1, &args, &call_exc);
        if (call_exc != null or result == null) {
            if (call_exc != null) return null;
            return jscMakePlainError(ctx, msg_val);
        }
        return result;
    }

    return jscMakePlainError(ctx, msg_val);
}

fn jscMakePlainError(ctx: jsc.JSContextRef, msg_val: jsc.JSValueRef) jsc.JSObjectRef {
    var args = [_]jsc.JSValueRef{msg_val};
    var exc: jsc.JSValueRef = null;
    const obj = jsc.JSObjectMakeError(ctx, 1, &args, &exc);
    if (exc != null) return null;
    return obj;
}

/// True iff `val` is an Error (by `instanceof Error` on globalThis.Error).
pub fn jscIsError(ctx: jsc.JSContextRef, val: jsc.JSValueRef) bool {
    if (val == null) return false;
    if (!jsc.JSValueIsObject(ctx, val)) return false;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const err_name = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(err_name);
    var exc: jsc.JSValueRef = null;
    const ctor_val = jsc.JSObjectGetProperty(ctx, global, err_name, &exc);
    if (exc != null or ctor_val == null or !jsc.JSValueIsObject(ctx, ctor_val)) return false;
    const ctor: jsc.JSObjectRef = @constCast(ctor_val);
    var inst_exc: jsc.JSValueRef = null;
    const is = jsc.JSValueIsInstanceOfConstructor(ctx, val, ctor, &inst_exc);
    if (inst_exc != null) return false;
    return is;
}

// ---- Promise settlement records ----
//
// The public JavaScriptCore C API can create a deferred promise but cannot read its state. Records are written when this engine creates or settles a promise and dropped when the context goes away. They are not a stand-in for a host rejection tracker (JSC has no equivalent of JS_SetHostPromiseRejectionTracker).

const sync = @import("zev");

pub const PromiseStateTag = enum(u8) {
    pending,
    fulfilled,
    rejected,
};

const PromiseRecord = struct {
    instance_id: i32,
    state: PromiseStateTag,
    /// Extra JSValueProtect, or null when pending / no result was stored.
    result: jsc.JSValueRef,
};

var promise_lock: sync.Mutex = .{};
var promise_records: ?std.AutoHashMap(usize, PromiseRecord) = null;

fn promiseMap() *std.AutoHashMap(usize, PromiseRecord) {
    if (promise_records == null) {
        promise_records = std.AutoHashMap(usize, PromiseRecord).init(std.heap.c_allocator);
    }
    return &promise_records.?;
}

pub const JscPromiseView = struct {
    state: PromiseStateTag,
    result: jsc.JSValueRef,
};

/// Remember `promise`'s state. `result` is protected when non-null; a previous result for the same promise is unprotected.
pub fn jscPromiseNote(
    ctx: jsc.JSContextRef,
    instance_id: i32,
    promise: jsc.JSValueRef,
    state: PromiseStateTag,
    result: jsc.JSValueRef,
) void {
    const promise_ptr = promise orelse return;
    var protected: jsc.JSValueRef = null;
    if (result) |value| {
        jsc.JSValueProtect(ctx, value);
        protected = value;
    }

    promise_lock.lock();
    const map = promiseMap();
    const key = @intFromPtr(promise_ptr);
    const previous: jsc.JSValueRef = if (map.fetchRemove(key)) |kv| kv.value.result else null;
    const stored = map.put(key, .{
        .instance_id = instance_id,
        .state = state,
        .result = protected,
    });
    promise_lock.unlock();

    if (previous) |value| jsc.JSValueUnprotect(ctx, value);
    stored catch {
        if (protected) |value| jsc.JSValueUnprotect(ctx, value);
    };
}

pub fn jscPromiseQuery(promise: jsc.JSValueRef) ?JscPromiseView {
    const promise_ptr = promise orelse return null;
    promise_lock.lock();
    defer promise_lock.unlock();
    const rec = promiseMap().get(@intFromPtr(promise_ptr)) orelse return null;
    return .{ .state = rec.state, .result = rec.result };
}

pub fn jscPromiseForget(ctx: jsc.JSContextRef, promise: jsc.JSValueRef) void {
    const promise_ptr = promise orelse return;
    promise_lock.lock();
    const removed = promiseMap().fetchRemove(@intFromPtr(promise_ptr));
    promise_lock.unlock();
    if (removed) |kv| {
        if (kv.value.result) |value| jsc.JSValueUnprotect(ctx, value);
    }
}

/// Unprotect every stored result that belongs to `instance_id`.
pub fn jscPromiseReleaseInstance(ctx: jsc.JSContextRef, instance_id: i32) void {
    const Doomed = struct {
        key: usize,
        result: jsc.JSValueRef,
    };
    var doomed: std.ArrayList(Doomed) = .empty;
    defer doomed.deinit(std.heap.c_allocator);

    promise_lock.lock();
    const map = promiseMap();
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.instance_id != instance_id) continue;
        doomed.append(std.heap.c_allocator, .{
            .key = entry.key_ptr.*,
            .result = entry.value_ptr.result,
        }) catch {};
    }
    for (doomed.items) |item| _ = map.remove(item.key);
    promise_lock.unlock();

    for (doomed.items) |item| {
        if (item.result) |value| jsc.JSValueUnprotect(ctx, value);
    }
}
