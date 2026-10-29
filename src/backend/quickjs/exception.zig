//! Exception extraction + JSON / toString helpers.
//!
//! `getAndFormatException` drains the pending exception from `ctx`, building a "<message>\n<stack>" report in a c_allocator-owned slice. `jsonStringify` and `valueToString` produce c_allocator-owned UTF-8 representations of arbitrary JSValues — both ALWAYS free their internal cstr/JSValue dups so callers never need to touch QuickJS refcounts here.

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

pub fn getAndFormatException(ctx: ?*qjs.JSContext) ?[]const u8 {
    const exc = qjs.JS_GetException(ctx);
    var buf: std.ArrayList(u8) = .empty;
    // toOwnedSlice hands the list buffer to the caller. deinit is then a no-op.
    defer buf.deinit(std.heap.c_allocator);

    if (!appendCStringLen(ctx, &buf, exc)) {
        buf.appendSlice(std.heap.c_allocator, "JavaScript error") catch {};
    }

    const stack = qjs.JS_GetPropertyStr(ctx, exc, "stack");
    if (!c.jsIsUndefined(stack) and !c.jsIsNull(stack)) {
        buf.append(std.heap.c_allocator, '\n') catch {};
        _ = appendCStringLen(ctx, &buf, stack);
    }
    c.jsbay_qjs_JS_FreeValue(ctx, stack);
    c.jsbay_qjs_JS_FreeValue(ctx, exc);

    if (buf.items.len == 0) return null;
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

const Pending = struct {
    promise: qjs.JSValue,
    reason: qjs.JSValue,
};

var rejection_lock: sync.Mutex = .{};
var hosts: ?std.AutoHashMap(i32, Host) = null;
var installed_rts: ?std.AutoHashMap(*qjs.JSRuntime, u8) = null;
var pending_by_instance: ?std.AutoHashMap(i32, std.ArrayList(Pending)) = null;

/// Set while `flushPendingRejections` owns the queue. A throwing `Error` reached from stringification can run jobs that would flush again; that nested flush must return instead of walking the same queue.
threadlocal var flushing: bool = false;

/// Set while converting a rejection reason to text. `toString` (or a replaced `Error` constructor it calls) can re-enter the tracker. A nested conversion skips JS so the process cannot recurse without bound.
threadlocal var in_reason_text: bool = false;

fn hostMap() *std.AutoHashMap(i32, Host) {
    if (hosts == null) hosts = std.AutoHashMap(i32, Host).init(std.heap.c_allocator);
    return &hosts.?;
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
    if (@import("../../inspector/root.zig").exceptions.isEnabled(instance_id)) return;
    while (takeInstanceQueue(instance_id)) |queue_value| {
        var queue = queue_value;
        freeQueue(ctx, &queue);
    }
}

/// Install the runtime observer without replacing a host's per-instance tracker.
pub fn ensureRejectionTracker(ctx: ?*qjs.JSContext) void {
    const rt = qjs.JS_GetRuntime(ctx) orelse return;
    rejection_lock.lock();
    defer rejection_lock.unlock();
    if (runtimeMap().contains(rt)) return;
    runtimeMap().put(rt, 1) catch return;
    qjs.JS_SetHostPromiseRejectionTracker(rt, &onRejection, null);
}

/// Tell the host about rejections that survived this microtask drain.
///
/// A throwing `then` leaves the job exception pending. Clear it before stringifying. Only the records queued at entry are reported. Anything a replaced `Error` rejects while we are inside `toString` is freed without another conversion, so the report cannot loop.
pub fn flushPendingRejections(ctx: ?*qjs.JSContext) void {
    if (ctx == null) return;
    if (flushing) return;
    flushing = true;
    defer flushing = false;

    clearPendingException(ctx);
    const id = instanceIdFromCtx(ctx);
    if (takeInstanceQueue(id)) |queued_value| {
        var queued = queued_value;
        defer queued.deinit(std.heap.c_allocator);
        for (queued.items) |item| {
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
}

/// Forget that `rt` had the C tracker installed. The runtime is about to be freed.
pub fn forgetRejectionRuntime(rt: ?*qjs.JSRuntime) void {
    const runtime = rt orelse return;
    rejection_lock.lock();
    defer rejection_lock.unlock();
    if (installed_rts) |*map| _ = map.remove(runtime);
}
