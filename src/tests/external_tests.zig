//! Tests for the External value API (src/value/external.zig).
//!
//! Both backends must pass. External wraps a raw native pointer as an opaque JS object; tests verify:
//!   1. roundtrip — newExternal + getExternal returns the same pointer
//!   2. isExternal predicate — true for Externals, false for other values
//!   3. finalizer fires when the wrapper is collected
//! 4. JS can store the External (e.g. in an array) and the pointer survives roundtripping back to native code

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const external = @import("../value/external.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

// A small owned struct so we have a real *anyopaque to point at.
const Payload = struct {
    tag: u32,
    note: [16]u8,
};

// Module-level finalizer state for the finalizer test. Incremented by countingFinalizer when a wrapper is collected.
var g_finalize_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn countingFinalizer(ptr: *anyopaque) callconv(.c) void {
    _ = ptr;
    _ = g_finalize_count.fetchAdd(1, .seq_cst);
}

// ---------------------------------------------------------------------------
// 1. Roundtrip
// ---------------------------------------------------------------------------

test "External: newExternal + getExternal returns original pointer" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            var payload = Payload{ .tag = 0xBEEF_CAFE, .note = undefined };
            const ext = external.newExternal(id, @ptrCast(&payload), null) orelse
                return error.NewExternalFailed;
            defer ActiveEngine.freeValue(ctx, ext);

            const got = external.getExternal(id, ext) orelse return error.GetReturnedNull;
            try testing.expectEqual(@intFromPtr(&payload), @intFromPtr(got));

            const recovered: *Payload = @ptrCast(@alignCast(got));
            try testing.expectEqual(@as(u32, 0xBEEF_CAFE), recovered.tag);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 2. Type predicate
// ---------------------------------------------------------------------------

test "External: isExternal distinguishes Externals from other values" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            var payload = Payload{ .tag = 1, .note = undefined };
            const ext = external.newExternal(id, @ptrCast(&payload), null) orelse
                return error.NewExternalFailed;
            defer ActiveEngine.freeValue(ctx, ext);
            try testing.expect(external.isExternal(id, ext));

            // Plain string
            const s = ActiveEngine.newStringVal(ctx, "hello");
            defer ActiveEngine.freeValue(ctx, s);
            try testing.expect(!external.isExternal(id, s));

            // Number
            const n = ActiveEngine.newInt32Val(ctx, 42);
            defer ActiveEngine.freeValue(ctx, n);
            try testing.expect(!external.isExternal(id, n));

            // Plain object
            const obj = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, obj);
            try testing.expect(!external.isExternal(id, obj));

            // getExternal on a non-External returns null
            try testing.expect(external.getExternal(id, s) == null);
            try testing.expect(external.getExternal(id, obj) == null);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 3. Finalizer fires when the wrapper is collected.
//
// Both backends in practice only guarantee finalizers run at context teardown. We mirror jsc_native_tests' pattern: create an External inside a scoped block, drop the native ref, destroy the engine, then observe the counter.
// ---------------------------------------------------------------------------

test "External: finalizer runs on engine teardown" {
    g_finalize_count.store(0, .seq_cst);

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    {
        const ctx = engine.getContext(id) orelse return error.NoContext;
        var payload = Payload{ .tag = 7, .note = undefined };
        const ext = external.newExternal(id, @ptrCast(&payload), countingFinalizer) orelse {
            engine.destroy(id);
            return error.NewExternalFailed;
        };
        // Release the only native ref; the wrapper becomes unreachable.
        ActiveEngine.freeValue(ctx, ext);
    }
    engine.destroy(id);

    try testing.expect(g_finalize_count.load(.seq_cst) >= 1);
}

// ---------------------------------------------------------------------------
// 4. Store in JS, retrieve back via eval, unwrap in native code.
// ---------------------------------------------------------------------------

test "External: JS array roundtrip preserves pointer identity" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            var payload = Payload{ .tag = 0xDEAD_BEEF, .note = undefined };
            const ext = external.newExternal(id, @ptrCast(&payload), null) orelse
                return error.NewExternalFailed;

            // Park the external on globalThis so JS can manipulate it.
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "__ext__", ext);
            // setPropertyStr consumes `ext` on both backends.

            // JS side: stuff it in an array, read it back out.
            try helpers.evalOk(id, "globalThis.__arr__ = [null, __ext__, 'sentinel'];");
            try helpers.evalOk(id, "globalThis.__back__ = __arr__[1];");

            const back = ActiveEngine.getPropertyVal(ctx, global, "__back__") orelse
                return error.NoBack;
            defer ActiveEngine.freeValue(ctx, back);

            try testing.expect(external.isExternal(id, back));
            const got = external.getExternal(id, back) orelse return error.NotExternal;
            try testing.expectEqual(@intFromPtr(&payload), @intFromPtr(got));

            // Clean up globals so this test doesn't leak into others.
            try helpers.evalOk(id,
                \\delete globalThis.__ext__;
                \\delete globalThis.__arr__;
                \\delete globalThis.__back__;
            );
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 5. Two Externals carry independent pointers.
// ---------------------------------------------------------------------------

test "External: two wrappers carry independent pointers" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            var a = Payload{ .tag = 1, .note = undefined };
            var b = Payload{ .tag = 2, .note = undefined };

            const ea = external.newExternal(id, @ptrCast(&a), null) orelse return error.A;
            defer ActiveEngine.freeValue(ctx, ea);
            const eb = external.newExternal(id, @ptrCast(&b), null) orelse return error.B;
            defer ActiveEngine.freeValue(ctx, eb);

            const pa = external.getExternal(id, ea) orelse return error.GetA;
            const pb = external.getExternal(id, eb) orelse return error.GetB;

            try testing.expect(@intFromPtr(pa) != @intFromPtr(pb));
            try testing.expectEqual(@intFromPtr(&a), @intFromPtr(pa));
            try testing.expectEqual(@intFromPtr(&b), @intFromPtr(pb));
        }
    }.run);
}
