//! Tests for backend/jsc/native_handle.zig — JSC counterpart of native_handle.
//!
//! These tests run only when the build is configured with -Dbackend=jsc. The aggregator (all_tests.zig) gates this file behind the active backend.

const std = @import("std");
const testing = std.testing;

const native_handle = @import("../backend/jsc/native_handle.zig");
const jsc = native_handle.jsc;

// JSSynchronousGarbageCollectForDebugging is exported by JavaScriptCore.framework but absent from the public header. It runs an immediate, synchronous full collection — indispensable for deterministic finalizer tests.
extern fn JSSynchronousGarbageCollectForDebugging(ctx: jsc.JSContextRef) void;

fn forceGc(ctx: jsc.JSContextRef) void {
    JSSynchronousGarbageCollectForDebugging(ctx);
}

// ── Test fixture: bare JSC context ───────────────────────────────────────

const Fixture = struct {
    group: jsc.JSContextGroupRef,
    ctx: jsc.JSGlobalContextRef,
    ctx_ref: jsc.JSContextRef,
    global: jsc.JSObjectRef,

    fn init() !Fixture {
        // Initialize the NativeHandle class once (idempotent).
        native_handle.init();

        const group = jsc.JSContextGroupCreate() orelse return error.GroupCreateFailed;
        const ctx = jsc.JSGlobalContextCreateInGroup(group, null) orelse {
            jsc.JSContextGroupRelease(group);
            return error.ContextCreateFailed;
        };
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const global = jsc.JSContextGetGlobalObject(ctx_ref);
        return .{
            .group = group,
            .ctx = ctx,
            .ctx_ref = ctx_ref,
            .global = global,
        };
    }

    fn deinit(self: *Fixture) void {
        jsc.JSGlobalContextRelease(self.ctx);
        jsc.JSContextGroupRelease(self.group);
    }

    fn setGlobal(self: *Fixture, name: [*:0]const u8, val: jsc.JSValueRef) void {
        const js_name = jsc.JSStringCreateWithUTF8CString(name);
        defer jsc.JSStringRelease(js_name);
        var exc: jsc.JSValueRef = null;
        jsc.JSObjectSetProperty(self.ctx_ref, self.global, js_name, val, 0, &exc);
    }

    fn clearGlobal(self: *Fixture, name: [*:0]const u8) void {
        const js_name = jsc.JSStringCreateWithUTF8CString(name);
        defer jsc.JSStringRelease(js_name);
        var exc: jsc.JSValueRef = null;
        _ = jsc.JSObjectDeleteProperty(self.ctx_ref, self.global, js_name, &exc);
    }

    fn eval(self: *Fixture, script: []const u8) !jsc.JSValueRef {
        const z = try std.heap.c_allocator.dupeSentinel(u8, script, 0);
        defer std.heap.c_allocator.free(z);
        const js_script = jsc.JSStringCreateWithUTF8CString(z.ptr);
        defer jsc.JSStringRelease(js_script);

        var exc: jsc.JSValueRef = null;
        const result = jsc.JSEvaluateScript(self.ctx_ref, js_script, null, null, 1, &exc);
        if (exc != null) return error.JSException;
        return result;
    }

    fn evalIsException(self: *Fixture, script: []const u8) bool {
        const z = std.heap.c_allocator.dupeSentinel(u8, script, 0) catch return false;
        defer std.heap.c_allocator.free(z);
        const js_script = jsc.JSStringCreateWithUTF8CString(z.ptr);
        defer jsc.JSStringRelease(js_script);

        var exc: jsc.JSValueRef = null;
        _ = jsc.JSEvaluateScript(self.ctx_ref, js_script, null, null, 1, &exc);
        return exc != null;
    }

    fn evalToInt(self: *Fixture, script: []const u8) !i64 {
        const v = try self.eval(script);
        if (v == null) return error.NoResult;
        var exc: jsc.JSValueRef = null;
        const d = jsc.JSValueToNumber(self.ctx_ref, v, &exc);
        if (exc != null) return error.NotANumber;
        if (!std.math.isFinite(d)) return error.NotFinite;
        return @intFromFloat(d);
    }

    fn evalToOwnedString(self: *Fixture, allocator: std.mem.Allocator, script: []const u8) ![]u8 {
        const v = try self.eval(script);
        if (v == null) return error.NoResult;
        var exc: jsc.JSValueRef = null;
        const js_str = jsc.JSValueToStringCopy(self.ctx_ref, v, &exc);
        if (js_str == null) return error.NotAString;
        defer jsc.JSStringRelease(js_str);
        const max = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
        const buf = try allocator.alloc(u8, max);
        const written = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max);
        const trimmed = if (written > 0) buf[0 .. written - 1] else buf[0..0];
        const owned = try allocator.dupe(u8, trimmed);
        allocator.free(buf);
        return owned;
    }
};

// ── Shared test state ────────────────────────────────────────────────────

const TestCounter = struct {
    call_count: i32 = 0,
    finalize_count: i32 = 0,
    last_argc: usize = 0,
};

var g_test_counter: TestCounter = .{};

fn resetCounter() void {
    g_test_counter = .{};
}

fn testCallFn(
    ctx: jsc.JSContextRef,
    _: ?*anyopaque,
    argc: usize,
    _: [*c]const jsc.JSValueRef,
    _: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    g_test_counter.call_count += 1;
    g_test_counter.last_argc = argc;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(g_test_counter.call_count));
}

fn testFinalizeFn(_: ?*anyopaque) void {
    g_test_counter.finalize_count += 1;
}

fn testMethodGetValue(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    this_obj: jsc.JSObjectRef,
    _: usize,
    _: [*c]const jsc.JSValueRef,
    exception: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const data = native_handle.getOpaque(ctx, this_obj) orelse {
        const msg = jsc.JSStringCreateWithUTF8CString("no opaque");
        defer jsc.JSStringRelease(msg);
        const v = jsc.JSValueMakeString(ctx, msg);
        if (exception != null) exception[0] = v;
        return jsc.JSValueMakeUndefined(ctx);
    };
    const counter: *TestCounter = @ptrCast(@alignCast(data.ptr.?));
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(counter.call_count));
}

fn testMethodIncrement(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    this_obj: jsc.JSObjectRef,
    _: usize,
    _: [*c]const jsc.JSValueRef,
    exception: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const data = native_handle.getOpaque(ctx, this_obj) orelse {
        const msg = jsc.JSStringCreateWithUTF8CString("no opaque");
        defer jsc.JSStringRelease(msg);
        const v = jsc.JSValueMakeString(ctx, msg);
        if (exception != null) exception[0] = v;
        return jsc.JSValueMakeUndefined(ctx);
    };
    const counter: *TestCounter = @ptrCast(@alignCast(data.ptr.?));
    counter.call_count += 1;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(counter.call_count));
}

fn testMethodEcho(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argc: usize,
    argv: [*c]const jsc.JSValueRef,
    _: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argc < 1) {
        const empty = jsc.JSStringCreateWithUTF8CString("");
        defer jsc.JSStringRelease(empty);
        return jsc.JSValueMakeString(ctx, empty);
    }
    return argv[0];
}

// ── Tests ────────────────────────────────────────────────────────────────

test "JSC NativeHandle: direct call dispatches to call_fn" {
    var fx = try Fixture.init();
    defer fx.deinit();
    resetCounter();

    const obj = native_handle.create(fx.ctx_ref, .{ .call_fn = testCallFn });
    fx.setGlobal("h", obj);

    const result = try fx.evalToInt("h()");
    try testing.expectEqual(@as(i64, 1), result);
    try testing.expectEqual(@as(i32, 1), g_test_counter.call_count);
}

test "JSC NativeHandle: multiple calls accumulate" {
    var fx = try Fixture.init();
    defer fx.deinit();
    resetCounter();

    const obj = native_handle.create(fx.ctx_ref, .{ .call_fn = testCallFn });
    fx.setGlobal("h", obj);

    _ = try fx.evalToInt("h()");
    _ = try fx.evalToInt("h()");
    const result = try fx.evalToInt("h()");
    try testing.expectEqual(@as(i64, 3), result);
    try testing.expectEqual(@as(i32, 3), g_test_counter.call_count);
}

test "JSC NativeHandle: call arguments forwarded" {
    var fx = try Fixture.init();
    defer fx.deinit();
    resetCounter();

    const obj = native_handle.create(fx.ctx_ref, .{ .call_fn = testCallFn });
    fx.setGlobal("h", obj);

    _ = try fx.evalToInt("h('a', 'b', 'c', 'd', 'e')");
    try testing.expectEqual(@as(usize, 5), g_test_counter.last_argc);
}

test "JSC NativeHandle: call without call_fn throws TypeError" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const obj = native_handle.create(fx.ctx_ref, .{}); // no call_fn
    fx.setGlobal("h", obj);

    try testing.expect(fx.evalIsException("h()"));
}

test "JSC NativeHandle: method reads opaque state" {
    var fx = try Fixture.init();
    defer fx.deinit();
    resetCounter();
    g_test_counter.call_count = 42;

    const obj = native_handle.create(fx.ctx_ref, .{ .ptr = @ptrCast(&g_test_counter) });
    native_handle.setMethod(fx.ctx_ref, obj, "getValue", testMethodGetValue);
    fx.setGlobal("h", obj);

    const result = try fx.evalToInt("h.getValue()");
    try testing.expectEqual(@as(i64, 42), result);
}

test "JSC NativeHandle: method mutates opaque state" {
    var fx = try Fixture.init();
    defer fx.deinit();
    resetCounter();

    const obj = native_handle.create(fx.ctx_ref, .{ .ptr = @ptrCast(&g_test_counter) });
    native_handle.setMethod(fx.ctx_ref, obj, "inc", testMethodIncrement);
    native_handle.setMethod(fx.ctx_ref, obj, "get", testMethodGetValue);
    fx.setGlobal("h", obj);

    _ = try fx.evalToInt("h.inc()");
    _ = try fx.evalToInt("h.inc()");
    _ = try fx.evalToInt("h.inc()");
    const result = try fx.evalToInt("h.get()");
    try testing.expectEqual(@as(i64, 3), result);
}

test "JSC NativeHandle: string and int properties visible from JS" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const obj = native_handle.create(fx.ctx_ref, .{});
    native_handle.setStringProp(fx.ctx_ref, obj, "type", "webview");
    native_handle.setIntProp(fx.ctx_ref, obj, "id", 42);
    fx.setGlobal("h", obj);

    const t = try fx.evalToOwnedString(testing.allocator, "h.type");
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("webview", t);

    const id = try fx.evalToInt("h.id");
    try testing.expectEqual(@as(i64, 42), id);
}

test "JSC NativeHandle: createWithMethods" {
    var fx = try Fixture.init();
    defer fx.deinit();
    resetCounter();
    g_test_counter.call_count = 10;

    const methods = [_]native_handle.MethodEntry{
        .{ .name = "get", .func = testMethodGetValue },
        .{ .name = "inc", .func = testMethodIncrement },
        .{ .name = "echo", .func = testMethodEcho },
    };
    const obj = native_handle.createWithMethods(fx.ctx_ref, .{
        .ptr = @ptrCast(&g_test_counter),
        .call_fn = testCallFn,
    }, &methods);
    fx.setGlobal("h", obj);

    // call_fn fires (increments g_test_counter.call_count: 10 -> 11)
    _ = try fx.evalToInt("h()");
    // method reads mutated state
    const v = try fx.evalToInt("h.get()");
    try testing.expectEqual(@as(i64, 11), v);
}

test "JSC NativeHandle: finalizer fires on context teardown" {
    // NOTE: JSC's public GC entry points (JSGarbageCollect, and even the private JSSynchronousGarbageCollectForDebugging) are cooperative; in a short-lived test the heap never reaches the threshold that would trigger a sweep, and conservative stack scanning keeps recently-created JSObjectRefs pinned anyway. The durable guarantee JSC gives us is that `JSGlobalContextRelease` runs finalizers for every live object before returning. That's what we verify here.
    resetCounter();
    {
        var fx = try Fixture.init();
        defer fx.deinit();
        _ = native_handle.create(fx.ctx_ref, .{
            .call_fn = testCallFn,
            .finalize_fn = testFinalizeFn,
        });
        // Discard the only JS-level handle we had; nothing else references it, so context teardown is responsible for running its finalizer.
    }
    try testing.expect(g_test_counter.finalize_count >= 1);
}

test "JSC NativeHandle: finalizer does not fire while referenced" {
    var fx = try Fixture.init();
    defer fx.deinit();
    resetCounter();

    const obj = native_handle.create(fx.ctx_ref, .{ .finalize_fn = testFinalizeFn });
    fx.setGlobal("h", obj);

    forceGc(fx.ctx_ref);
    try testing.expectEqual(@as(i32, 0), g_test_counter.finalize_count);

    // Cleanup so we don't leak the global into other tests.
    fx.clearGlobal("h");
}

test "JSC NativeHandle: getOpaque on plain object returns null" {
    var fx = try Fixture.init();
    defer fx.deinit();

    // A plain JS object — not a NativeHandle.
    const plain = jsc.JSObjectMake(fx.ctx_ref, null, null);
    try testing.expect(native_handle.getOpaque(fx.ctx_ref, @ptrCast(plain)) == null);

    // A primitive too.
    const num = jsc.JSValueMakeNumber(fx.ctx_ref, 42.0);
    try testing.expect(native_handle.getOpaque(fx.ctx_ref, num) == null);
}

test "JSC NativeHandle: getOpaque on NativeHandle returns data" {
    var fx = try Fixture.init();
    defer fx.deinit();

    var counter = TestCounter{ .call_count = 99 };
    const obj = native_handle.create(fx.ctx_ref, .{ .ptr = @ptrCast(&counter) });
    const data = native_handle.getOpaque(fx.ctx_ref, @ptrCast(obj));
    try testing.expect(data != null);
    const c2: *TestCounter = @ptrCast(@alignCast(data.?.ptr.?));
    try testing.expectEqual(@as(i32, 99), c2.call_count);
}
