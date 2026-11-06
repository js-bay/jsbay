//! Exception extraction + JSON / toString helpers.
//!
//! `getAndFormatException` drains the pending exception from `ctx`, building a message and stack report without repeating a matching stack header in a c_allocator-owned slice. `jsonStringify` and `valueToString` produce c_allocator-owned UTF-8 representations of arbitrary JSValues — both ALWAYS free their internal cstr/JSValue dups so callers never need to touch QuickJS refcounts here.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

fn appendCStringLen(ctx: ?*qjs.JSContext, buf: *std.ArrayList(u8), val: qjs.JSValue) bool {
    var len: usize = 0;
    const ptr = qjs.JS_ToCStringLen(ctx, &len, val) orelse return false;
    defer qjs.JS_FreeCString(ctx, ptr);
    buf.appendSlice(std.heap.c_allocator, ptr[0..len]) catch return false;
    return true;
}

fn matchingStackHeaderLength(stack: []const u8, description: []const u8) ?usize {
    if (std.mem.startsWith(u8, stack, description) and (stack.len == description.len or stack[description.len] == '\n' or stack[description.len] == '\r')) return description.len;
    const newline = std.mem.indexOfScalar(u8, stack, '\n') orelse return null;
    if (!std.mem.startsWith(u8, stack[newline + 1 ..], "    at ")) return null;
    const header = std.mem.trimEnd(u8, stack[0..newline], "\r");
    const header_name_end = std.mem.indexOfScalar(u8, header, ':') orelse header.len;
    const description_name_end = std.mem.indexOfScalar(u8, description, ':') orelse description.len;
    const native_names = .{ "Error", "EvalError", "RangeError", "ReferenceError", "SyntaxError", "TypeError", "URIError", "InternalError", "AggregateError", "SuppressedError" };
    inline for (native_names) |name| {
        if (std.mem.eql(u8, description[0..description_name_end], name)) return null;
    }
    if (!std.mem.eql(u8, header[header_name_end..], description[description_name_end..])) return null;
    // Generated stacks capture the native name before application code can rename the error.
    inline for (native_names) |name| {
        if (std.mem.eql(u8, header[0..header_name_end], name)) return newline;
    }
    return null;
}

pub fn getAndFormatException(ctx: ?*qjs.JSContext) ?[]const u8 {
    const exc = qjs.JS_GetException(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, exc);
    return formatExceptionValue(ctx, exc);
}

/// Format an exception value owned by the caller without consuming it.
pub fn formatExceptionValue(ctx: ?*qjs.JSContext, exc: qjs.JSValue) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    // toOwnedSlice hands the list buffer to the caller. deinit is then a no-op.
    defer buf.deinit(std.heap.c_allocator);

    if (!appendCStringLen(ctx, &buf, exc)) {
        buf.appendSlice(std.heap.c_allocator, "JavaScript error") catch {};
    }

    const stack = qjs.JS_GetPropertyStr(ctx, exc, "stack");
    if (!c.jsIsUndefined(stack) and !c.jsIsNull(stack)) {
        var stack_text: std.ArrayList(u8) = .empty;
        defer stack_text.deinit(std.heap.c_allocator);
        if (appendCStringLen(ctx, &stack_text, stack)) {
            if (matchingStackHeaderLength(stack_text.items, buf.items)) |header_length| {
                buf.appendSlice(std.heap.c_allocator, stack_text.items[header_length..]) catch {};
            } else {
                buf.append(std.heap.c_allocator, '\n') catch {};
                buf.appendSlice(std.heap.c_allocator, stack_text.items) catch {};
            }
        }
    }
    c.jsbay_qjs_JS_FreeValue(ctx, stack);

    if (buf.items.len == 0) return null;
    // Diagnostics cross SDK boundaries that require valid UTF-8. Lone UTF-16 surrogates become replacement characters.
    std.unicode.wtf8ToUtf8Lossy(buf.items, buf.items) catch return null;
    return buf.toOwnedSlice(std.heap.c_allocator) catch null;
}

pub fn jsonStringify(ctx: ?*qjs.JSContext, val: qjs.JSValue) ?[]const u8 {
    const json = qjs.JS_JSONStringify(ctx, val, c.JS_UNDEFINED, c.JS_UNDEFINED);
    if (c.jsIsException(json)) {
        c.jsbay_qjs_JS_FreeValue(ctx, json);
        return null;
    }
    var len: usize = 0;
    const ptr = qjs.JS_ToCStringLen(ctx, &len, json) orelse {
        c.jsbay_qjs_JS_FreeValue(ctx, json);
        return null;
    };
    defer qjs.JS_FreeCString(ctx, ptr);
    defer c.jsbay_qjs_JS_FreeValue(ctx, json);
    return std.heap.c_allocator.dupe(u8, ptr[0..len]) catch null;
}

pub fn valueToStringAlloc(allocator: std.mem.Allocator, ctx: ?*qjs.JSContext, val: qjs.JSValue) ?[]u8 {
    var len: usize = 0;
    const ptr = qjs.JS_ToCStringLen(ctx, &len, val) orelse return null;
    defer qjs.JS_FreeCString(ctx, ptr);
    return allocator.dupe(u8, ptr[0..len]) catch null;
}

pub fn valueToString(ctx: ?*qjs.JSContext, val: qjs.JSValue) ?[]const u8 {
    return valueToStringAlloc(std.heap.c_allocator, ctx, val);
}

// ---- Host promise rejection tracker ----
//
// QuickJS fires JSHostPromiseRejectionTracker synchronously, including for `Promise.reject(x).catch(fn)` (unhandled, then immediately handled) before the current job queue drains. Record the unhandled rejection and only tell the host after the outermost microtask drain. A `.catch` that arrives before that flush removes the record and does not notify. A `.catch` after the host was already told notifies once with handled=true.

const sync = @import("zev");

/// Host callback. `reason_ptr` / `reason_len` are valid only for the call.
pub const RejectionTracker = *const fn (
    instance_id: i32,
    handled: bool,
    reason_ptr: [*]const u8,
    reason_len: usize,
    userdata: ?*anyopaque,
) callconv(.c) void;

const Host = struct {
    func: RejectionTracker,
    userdata: ?*anyopaque,
};

const ErrorObserver = struct {
    func: @import("../../types.zig").ErrorObserver,
    userdata: ?*anyopaque,
};

const ObserverRegistration = enum { applied, out_of_memory };

const Pending = struct {
    promise: qjs.JSValue,
    reason: qjs.JSValue,
};

var rejection_lock: sync.Mutex = .{};
var hosts: ?std.AutoHashMap(i32, Host) = null;
var error_observers: ?std.AutoHashMap(i32, ErrorObserver) = null;
var installed_rts: ?std.AutoHashMap(*qjs.JSRuntime, u8) = null;
var pending_by_instance: ?std.AutoHashMap(i32, std.ArrayList(Pending)) = null;

/// Tracks flushing contexts on this thread. Frames live on active flush stacks, so nesting has no fixed limit.
const FlushFrame = struct {
    ctx: ?*qjs.JSContext,
    previous: ?*const FlushFrame,
};
threadlocal var flush_head: ?*const FlushFrame = null;

fn isFlushing(ctx: ?*qjs.JSContext) bool {
    var frame = flush_head;
    while (frame) |active| : (frame = active.previous) if (active.ctx == ctx) return true;
    return false;
}

/// Set while converting a rejection reason to text. `toString` (or a replaced `Error` constructor it calls) can re-enter the tracker. A nested conversion skips JS so the process cannot recurse without bound.
threadlocal var in_reason_text: bool = false;

fn hostMap() *std.AutoHashMap(i32, Host) {
    if (hosts == null) hosts = std.AutoHashMap(i32, Host).init(std.heap.c_allocator);
    return &hosts.?;
}

fn errorObserverMap() *std.AutoHashMap(i32, ErrorObserver) {
    if (error_observers == null) error_observers = std.AutoHashMap(i32, ErrorObserver).init(std.heap.c_allocator);
    return &error_observers.?;
}

fn registerObserver(map: *std.AutoHashMap(i32, ErrorObserver), instance_id: i32, observer: ErrorObserver) ObserverRegistration {
    map.put(instance_id, observer) catch return .out_of_memory;
    return .applied;
}

fn runtimeMap() *std.AutoHashMap(*qjs.JSRuntime, u8) {
    if (installed_rts == null) installed_rts = std.AutoHashMap(*qjs.JSRuntime, u8).init(std.heap.c_allocator);
    return &installed_rts.?;
}

fn pendingMap() *std.AutoHashMap(i32, std.ArrayList(Pending)) {
    if (pending_by_instance == null) {
        pending_by_instance = std.AutoHashMap(i32, std.ArrayList(Pending)).init(std.heap.c_allocator);
    }
    return &pending_by_instance.?;
}

fn instanceIdFromCtx(ctx: ?*qjs.JSContext) i32 {
    const ptr = qjs.JS_GetContextOpaque(ctx);
    return @bitCast(@as(u32, @truncate(@intFromPtr(ptr))));
}

fn samePromise(a: qjs.JSValue, b: qjs.JSValue) bool {
    return a.tag == qjs.JS_TAG_OBJECT and b.tag == qjs.JS_TAG_OBJECT and a.u.ptr == b.u.ptr;
}

fn copyHost(instance_id: i32) ?Host {
    rejection_lock.lock();
    defer rejection_lock.unlock();
    return hostMap().get(instance_id);
}

fn copyErrorObserver(instance_id: i32) ?ErrorObserver {
    rejection_lock.lock();
    defer rejection_lock.unlock();
    return errorObserverMap().get(instance_id);
}

fn dispatchError(_: ?*qjs.JSContext, instance_id: i32, kind: @import("../../types.zig").ErrorKind, promise: qjs.JSValue, value: qjs.JSValue) bool {
    const control = @import("../../runtime/runtime_control.zig");
    if (control.isInterruptRequested(instance_id) or control.isStopRequested(instance_id)) return false;
    if (control.remainingExecutionLimitMillis(instance_id)) |remaining| if (remaining == 0) return false;
    const target = copyErrorObserver(instance_id) orelse return true;
    const api_value = @import("../../abi/api_value.zig");
    const promise_handle = if (kind == .async_uncaught) 0 else api_value.putBorrowed(instance_id, promise) orelse return true;
    defer if (promise_handle != 0) api_value.revokeBorrowed(promise_handle);
    const value_handle = api_value.putBorrowed(instance_id, value) orelse return true;
    defer api_value.revokeBorrowed(value_handle);
    var event = @import("../../types.zig").ErrorEvent{ .struct_size = @sizeOf(@import("../../types.zig").ErrorEvent), .kind = kind, .instance_id = instance_id, .promise = promise_handle, .value = value_handle };
    target.func(&event, target.userdata);
    return true;
}

/// Notify only the typed observer for an asynchronous uncaught exception. The caller retains ownership of `value`.
pub fn reportAsyncUncaught(ctx: ?*qjs.JSContext, instance_id: i32, value: qjs.JSValue) void {
    const control = @import("../../runtime/runtime_control.zig");
    if (control.isInterruptRequested(instance_id) or control.isStopRequested(instance_id)) return;
    if (control.remainingExecutionLimitMillis(instance_id)) |remaining| if (remaining == 0) return;
    _ = dispatchError(ctx, instance_id, .async_uncaught, value, value);
}

fn pushPending(ctx: ?*qjs.JSContext, instance_id: i32, promise: qjs.JSValue, reason: qjs.JSValue) void {
    rejection_lock.lock();
    const entry = pendingMap().getOrPut(instance_id) catch {
        rejection_lock.unlock();
        c.jsbay_qjs_JS_FreeValue(ctx, promise);
        c.jsbay_qjs_JS_FreeValue(ctx, reason);
        return;
    };
    const created = !entry.found_existing;
    if (created) entry.value_ptr.* = .empty;
    const appended = entry.value_ptr.append(std.heap.c_allocator, .{
        .promise = promise,
        .reason = reason,
    });
    appended catch {
        if (created) {
            var removed = pendingMap().fetchRemove(instance_id).?;
            removed.value.deinit(std.heap.c_allocator);
        }
        rejection_lock.unlock();
        c.jsbay_qjs_JS_FreeValue(ctx, promise);
        c.jsbay_qjs_JS_FreeValue(ctx, reason);
        return;
    };
    rejection_lock.unlock();
}

fn takeMatch(instance_id: i32, promise: qjs.JSValue) ?Pending {
    rejection_lock.lock();
    defer rejection_lock.unlock();
    const queue = pendingMap().getPtr(instance_id) orelse return null;
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        if (samePromise(queue.items[i].promise, promise)) {
            const item = queue.swapRemove(i);
            if (queue.items.len == 0) {
                var removed = pendingMap().fetchRemove(instance_id).?;
                removed.value.deinit(std.heap.c_allocator);
            }
            return item;
        }
    }
    return null;
}

fn takeInstanceQueue(instance_id: i32) ?std.ArrayList(Pending) {
    rejection_lock.lock();
    defer rejection_lock.unlock();
    const entry = pendingMap().fetchRemove(instance_id) orelse return null;
    return entry.value;
}

fn freePending(ctx: ?*qjs.JSContext, item: Pending) void {
    c.jsbay_qjs_JS_FreeValue(ctx, item.promise);
    c.jsbay_qjs_JS_FreeValue(ctx, item.reason);
}

fn freeQueue(ctx: ?*qjs.JSContext, queue: *std.ArrayList(Pending)) void {
    for (queue.items) |item| {
        freePending(ctx, item);
    }
    queue.deinit(std.heap.c_allocator);
}

fn shouldDeferPendingRejections(instance_id: i32) bool {
    const control = @import("../../runtime/runtime_control.zig");
    if (control.isInterruptRequested(instance_id) or control.isStopRequested(instance_id)) return true;
    return if (control.remainingExecutionLimitMillis(instance_id)) |remaining| remaining == 0 else false;
}

fn restorePendingTail(ctx: ?*qjs.JSContext, instance_id: i32, queue: *std.ArrayList(Pending), start: usize) void {
    const tail_len = queue.items.len - start;
    std.mem.copyForwards(Pending, queue.items[0..tail_len], queue.items[start..]);
    queue.items.len = tail_len;
    while (takeInstanceQueue(instance_id)) |reentrant_value| {
        var reentrant = reentrant_value;
        freeQueue(ctx, &reentrant);
    }
    rejection_lock.lock();
    pendingMap().put(instance_id, queue.*) catch {
        rejection_lock.unlock();
        std.log.warn("dropping deferred promise rejections after allocation failure", .{});
        freeQueue(ctx, queue);
        return;
    };
    queue.* = .empty;
    rejection_lock.unlock();
}

/// Drop a pending exception left by a microtask or by user code that threw while the reason was turned into text. `JS_GetException` yields `JS_UNINITIALIZED` when the slot is empty; that value must not be freed.
fn clearPendingException(ctx: ?*qjs.JSContext) void {
    if (ctx == null) return;
    const exc = qjs.JS_GetException(ctx);
    if (exc.tag != qjs.JS_TAG_UNINITIALIZED and !c.jsIsNull(exc)) {
        c.jsbay_qjs_JS_FreeValue(ctx, exc);
    }
}

const ReasonText = struct {
    bytes: []const u8,
    owned: bool,
};

fn reasonText(ctx: ?*qjs.JSContext, reason: qjs.JSValue) ReasonText {
    if (in_reason_text) return .{ .bytes = "", .owned = false };
    in_reason_text = true;
    defer in_reason_text = false;
    // Runs before the flag is cleared, so a finalizer that re-enters stays on the empty-text path.
    defer clearPendingException(ctx);

    var len: usize = 0;
    // ToCString threw (a replaced Error constructor, a throwing toString). The deferred clear drops that exception. The host still gets a call with an empty reason, which is a quiet failure of the text only.
    const ptr = qjs.JS_ToCStringLen(ctx, &len, reason) orelse {
        return .{ .bytes = "", .owned = false };
    };
    defer qjs.JS_FreeCString(ctx, ptr);
    const owned = std.heap.c_allocator.dupe(u8, ptr[0..len]) catch {
        return .{ .bytes = "", .owned = false };
    };
    return .{ .bytes = owned, .owned = true };
}

fn dispatch(ctx: ?*qjs.JSContext, instance_id: i32, handled: bool, promise: qjs.JSValue, reason: qjs.JSValue) void {
    const events = @import("../../inspector/root.zig").exceptions;
    const host = copyHost(instance_id);
    const observed = events.isEnabled(instance_id);
    if (host == null and !observed) return;
    // Inspector observation must not introduce JS coercion. The host callback explicitly requests text, so only that callback converts the reason.
    if (observed) events.reportRejection(instance_id, promise, handled, reason);
    if (host) |target| {
        const text = reasonText(ctx, reason);
        defer if (text.owned) std.heap.c_allocator.free(@constCast(text.bytes));
        const empty = [_]u8{0};
        const ptr: [*]const u8 = if (text.bytes.len == 0) &empty else text.bytes.ptr;
        target.func(instance_id, handled, ptr, text.bytes.len, target.userdata);
    }
}

fn onRejection(
    ctx: ?*qjs.JSContext,
    promise: qjs.JSValue,
    reason: qjs.JSValue,
    is_handled: c_int,
    _: ?*anyopaque,
) callconv(.c) void {
    const handled = is_handled != 0;
    const id = instanceIdFromCtx(ctx);
    if (handled) {
        if (takeMatch(id, promise)) |item| {
            // Caught before this turn's microtasks finished. Stay quiet.
            freePending(ctx, item);
            return;
        }
        dispatch(ctx, id, true, promise, reason);
        _ = dispatchError(ctx, id, .rejection_handled, promise, reason);
        return;
    }
    const kept_promise = c.jsbay_qjs_JS_DupValue(ctx, promise);
    const kept_reason = c.jsbay_qjs_JS_DupValue(ctx, reason);
    pushPending(ctx, id, kept_promise, kept_reason);
}

/// Install or clear the per-instance host callback. The QuickJS runtime hook is registered on first use. `tracker == null` drops the callback and any not-yet-reported rejections without notifying.
pub fn setRejectionTracker(
    ctx: ?*qjs.JSContext,
    instance_id: i32,
    tracker: ?RejectionTracker,
    userdata: ?*anyopaque,
) void {
    ensureRejectionTracker(ctx);
    rejection_lock.lock();
    if (tracker) |func| {
        hostMap().put(instance_id, .{ .func = func, .userdata = userdata }) catch {};
        rejection_lock.unlock();
        return;
    }
    _ = hostMap().remove(instance_id);
    rejection_lock.unlock();
    if (@import("../../inspector/root.zig").exceptions.isEnabled(instance_id) or copyErrorObserver(instance_id) != null) return;
    while (takeInstanceQueue(instance_id)) |queue_value| {
        var queue = queue_value;
        freeQueue(ctx, &queue);
    }
}

pub fn setErrorObserver(ctx: ?*qjs.JSContext, instance_id: i32, observer: ?@import("../../types.zig").ErrorObserver, userdata: ?*anyopaque) bool {
    if (observer != null and !ensureRejectionTrackerFallible(ctx)) return false;
    rejection_lock.lock();
    if (observer) |func| {
        if (registerObserver(errorObserverMap(), instance_id, .{ .func = func, .userdata = userdata }) == .out_of_memory) {
            rejection_lock.unlock();
            return false;
        }
    } else {
        _ = errorObserverMap().remove(instance_id);
    }
    rejection_lock.unlock();
    return true;
}

test "error observer registry OOM preserves existing observer" {
    const testing = std.testing;
    const Dummy = struct {
        fn callback(_: *const @import("../../types.zig").ErrorEvent, _: ?*anyopaque) callconv(.c) void {}
    };
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var map = std.AutoHashMap(i32, ErrorObserver).init(failing.allocator());
    defer map.deinit();
    const old = ErrorObserver{ .func = Dummy.callback, .userdata = null };
    try testing.expectEqual(ObserverRegistration.applied, registerObserver(&map, 1, old));
    failing.fail_index = failing.alloc_index;
    var id: i32 = 2;
    while (registerObserver(&map, id, old) == .applied) : (id += 1) {
        try testing.expect(id < 1024);
    }
    try testing.expectEqual(old.func, map.get(1).?.func);
}

/// Install the runtime observer without replacing a host's per-instance tracker.
pub fn ensureRejectionTracker(ctx: ?*qjs.JSContext) void {
    _ = ensureRejectionTrackerFallible(ctx);
}

/// Install the runtime hook and report allocation failure to typed registrations.
fn ensureRejectionTrackerFallible(ctx: ?*qjs.JSContext) bool {
    const rt = qjs.JS_GetRuntime(ctx) orelse return false;
    rejection_lock.lock();
    defer rejection_lock.unlock();
    if (runtimeMap().contains(rt)) return true;
    runtimeMap().put(rt, 1) catch return false;
    qjs.JS_SetHostPromiseRejectionTracker(rt, &onRejection, null);
    return true;
}

/// Tell the host about rejections that survived this microtask drain.
///
/// A throwing `then` leaves the job exception pending. Clear it before stringifying. Only the records queued at entry are reported. Anything a replaced `Error` rejects while we are inside `toString` is freed without another conversion, so the report cannot loop.
pub fn flushPendingRejections(ctx: ?*qjs.JSContext) void {
    if (ctx == null) return;
    const id = instanceIdFromCtx(ctx);
    if (shouldDeferPendingRejections(id)) return;
    if (isFlushing(ctx)) return;
    var frame = FlushFrame{ .ctx = ctx, .previous = flush_head };
    flush_head = &frame;
    defer flush_head = frame.previous;

    clearPendingException(ctx);
    if (takeInstanceQueue(id)) |queued_value| {
        var queued = queued_value;
        defer queued.deinit(std.heap.c_allocator);
        var index: usize = 0;
        while (index < queued.items.len) : (index += 1) {
            if (shouldDeferPendingRejections(id)) {
                restorePendingTail(ctx, id, &queued, index);
                return;
            }
            const item = queued.items[index];
            if (!dispatchError(ctx, id, .unhandled_rejection, item.promise, item.reason)) {
                restorePendingTail(ctx, id, &queued, index);
                return;
            }
            dispatch(ctx, id, false, item.promise, item.reason);
            freePending(ctx, item);
            clearPendingException(ctx);
        }
    }
    while (takeInstanceQueue(id)) |reentrant_value| {
        var reentrant = reentrant_value;
        freeQueue(ctx, &reentrant);
    }
    clearPendingException(ctx);
}

/// Free still-queued rejection values. Called while `ctx` is alive.
pub fn dropRejectionState(ctx: ?*qjs.JSContext) void {
    if (ctx == null) return;
    const id = instanceIdFromCtx(ctx);
    while (takeInstanceQueue(id)) |queue_value| {
        var queue = queue_value;
        freeQueue(ctx, &queue);
    }
    rejection_lock.lock();
    defer rejection_lock.unlock();
    if (hosts) |*map| _ = map.remove(id);
    if (error_observers) |*map| _ = map.remove(id);
}

/// Forget that `rt` had the C tracker installed. The runtime is about to be freed.
pub fn forgetRejectionRuntime(rt: ?*qjs.JSRuntime) void {
    const runtime = rt orelse return;
    rejection_lock.lock();
    defer rejection_lock.unlock();
    if (installed_rts) |*map| _ = map.remove(runtime);
}
