//! Tests for the zero-copy Buffer API (src/value/buffers.zig).
//!
//! Both backends must pass.  Verifies:
//!   1. ArrayBuffer-from-bytes round-trip via JS Uint8Array indexing
//!   2. Uint8Array-from-bytes convenience path
//!   3. getBufferView on a JS-created Uint8Array returns real ptr+len
//!   4. finalizer fires (on engine destroy, which both backends guarantee)
//!   5. getBufferView on a non-buffer returns null

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const buffers = @import("../value/buffers.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const runtime_control = @import("../runtime/runtime_control.zig");

const ActiveEngine = backend.ActiveEngine;

// ---------------------------------------------------------------------------
// Shared finalizer state.  Each test resets before use.
// ---------------------------------------------------------------------------

var g_fin_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var g_last_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var g_last_ptr: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var g_last_user: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

fn countingFinalizer(user_data: ?*anyopaque, bytes: [*]u8, len: usize) callconv(.c) void {
    _ = g_fin_count.fetchAdd(1, .seq_cst);
    g_last_len.store(len, .seq_cst);
    g_last_ptr.store(@intFromPtr(bytes), .seq_cst);
    if (user_data) |u| g_last_user.store(@intFromPtr(u), .seq_cst);
}

// Finalizer that frees the buffer via `std.heap.c_allocator`. The user_data carries the original length so we can reconstruct the slice.
fn cAllocFreeFinalizer(user_data: ?*anyopaque, bytes: [*]u8, len: usize) callconv(.c) void {
    _ = user_data;
    std.heap.c_allocator.free(bytes[0..len]);
    _ = g_fin_count.fetchAdd(1, .seq_cst);
}

// ---------------------------------------------------------------------------
// 1. ArrayBuffer round-trip: wrap [0..16), verify Uint8Array[5] === 5 in JS.
// ---------------------------------------------------------------------------

test "Buffers: newArrayBufferFromBytes round-trips via Uint8Array" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            // Owned by the test: lives on the stack for the duration.
            var data: [16]u8 = undefined;
            for (&data, 0..) |*b, i| b.* = @intCast(i);

            const ab = buffers.newArrayBufferFromBytes(
                id,
                &data,
                data.len,
                null, // no finalizer — stack-owned
                null,
            ) orelse return error.NewAbFailed;

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "__ab__", ab);

            // byteLength correct
            try helpers.expectEvalEquals(id, "String(__ab__.byteLength)", "16");
            // Element at index 5 is 5
            try helpers.expectEvalEquals(id, "String(new Uint8Array(__ab__)[5])", "5");
            // Element at index 15 is 15
            try helpers.expectEvalEquals(id, "String(new Uint8Array(__ab__)[15])", "15");

            try helpers.evalOk(id, "delete globalThis.__ab__;");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 2. Uint8Array convenience path.
// ---------------------------------------------------------------------------

test "Buffers: newUint8ArrayFromBytes exposes bytes as typed view" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            var data: [8]u8 = .{ 10, 20, 30, 40, 50, 60, 70, 80 };

            const u8a = buffers.newUint8ArrayFromBytes(
                id,
                &data,
                data.len,
                null,
                null,
            ) orelse return error.NewU8aFailed;

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "__u8a__", u8a);

            try helpers.expectEvalEquals(id, "String(__u8a__.length)", "8");
            try helpers.expectEvalEquals(id, "String(__u8a__[0])", "10");
            try helpers.expectEvalEquals(id, "String(__u8a__[7])", "80");
            try helpers.expectEvalEquals(
                id,
                "String(__u8a__ instanceof Uint8Array)",
                "true",
            );

            try helpers.evalOk(id, "delete globalThis.__u8a__;");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 3. getBufferView on a JS-created Uint8Array returns real ptr+len.
// ---------------------------------------------------------------------------

test "Buffers: getBufferView reads a JS-created Uint8Array" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            // Create the Uint8Array from JS; fetch the reference back.
            try helpers.evalOk(id,
                \\globalThis.__u8a__ = new Uint8Array(16);
                \\for (let i = 0; i < 16; i++) globalThis.__u8a__[i] = i * 2;
            );
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const u8a = ActiveEngine.getPropertyVal(ctx, global, "__u8a__") orelse
                return error.NoU8a;
            defer ActiveEngine.freeValue(ctx, u8a);

            const view = buffers.getBufferView(id, u8a) orelse return error.NoView;
            try testing.expectEqual(@as(usize, 16), view.len);

            // Read every byte through the native pointer and compare with the expected sequence written in JS.
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                try testing.expectEqual(@as(u8, @intCast(i * 2)), view.ptr[i]);
            }

            try helpers.evalOk(id, "delete globalThis.__u8a__;");
        }
    }.run);
}

// Additional round-trip: getBufferView on an ArrayBuffer we created ourselves.
test "Buffers: getBufferView reads our own ArrayBuffer" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            var data: [4]u8 = .{ 0xAA, 0xBB, 0xCC, 0xDD };
            const ab = buffers.newArrayBufferFromBytes(id, &data, data.len, null, null) orelse
                return error.NewAbFailed;
            defer ActiveEngine.freeValue(ctx, ab);

            const view = buffers.getBufferView(id, ab) orelse return error.NoView;
            try testing.expectEqual(@as(usize, 4), view.len);
            // ArrayBuffer-from-bytes should expose the same backing store.
            try testing.expectEqual(@intFromPtr(&data), @intFromPtr(view.ptr));
            try testing.expectEqual(@as(u8, 0xAA), view.ptr[0]);
            try testing.expectEqual(@as(u8, 0xDD), view.ptr[3]);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 4. Finalizer fires. Both backends reliably fire finalizers at engine teardown even if they don't at mid-run GC, so we drive the test from that trigger (same approach as external_tests "finalizer runs on engine teardown").
// ---------------------------------------------------------------------------

test "Buffers: finalizer runs on engine teardown" {
    g_fin_count.store(0, .seq_cst);
    g_last_len.store(0, .seq_cst);
    g_last_user.store(0, .seq_cst);

    // Allocate owned bytes on the c_allocator so the finalizer can free.
    const owned = try std.heap.c_allocator.alloc(u8, 32);
    for (owned, 0..) |*b, i| b.* = @intCast(i);

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) {
        std.heap.c_allocator.free(owned);
        return error.EngineCreateFailed;
    }
    var sentinel: u32 = 0xCAFEBABE;
    {
        const ctx = engine.getContext(id) orelse {
            engine.destroy(id);
            std.heap.c_allocator.free(owned);
            return error.NoContext;
        };
        const ab = buffers.newArrayBufferFromBytes(
            id,
            owned.ptr,
            owned.len,
            cAllocFreeFinalizer,
            @ptrCast(&sentinel),
        ) orelse {
            engine.destroy(id);
            std.heap.c_allocator.free(owned);
            return error.NewAbFailed;
        };
        // Drop the only native reference; the wrapper is now GC-reachable only while the JS runtime holds it.
        ActiveEngine.freeValue(ctx, ab);
    }

    // Force GC first (harmless if the wrapper is already unreachable) — under QuickJS this fires the finalizer mid-run; under JSC it is advisory but does not hurt.
    _ = runtime_control.runGc(id);

    // Engine teardown is the hard guarantee — both backends fire live finalizers at runtime/group release.
    engine.destroy(id);

    try testing.expect(g_fin_count.load(.seq_cst) >= 1);
    // cAllocFreeFinalizer called free(owned) for us — do NOT free again.
}

test "Buffers: finalizer receives original length and user_data" {
    g_fin_count.store(0, .seq_cst);
    g_last_len.store(0, .seq_cst);
    g_last_user.store(0, .seq_cst);

    // Static memory — don't actually free in the finalizer.
    var data: [24]u8 = undefined;
    var user_marker: u32 = 0xF00DBEEF;

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    {
        const ctx = engine.getContext(id) orelse {
            engine.destroy(id);
            return error.NoContext;
        };
        const ab = buffers.newArrayBufferFromBytes(
            id,
            &data,
            data.len,
            countingFinalizer,
            @ptrCast(&user_marker),
        ) orelse {
            engine.destroy(id);
            return error.NewAbFailed;
        };
        ActiveEngine.freeValue(ctx, ab);
    }
    _ = runtime_control.runGc(id);
    engine.destroy(id);

    try testing.expect(g_fin_count.load(.seq_cst) >= 1);
    try testing.expectEqual(@as(usize, 24), g_last_len.load(.seq_cst));
    try testing.expectEqual(@intFromPtr(&user_marker), g_last_user.load(.seq_cst));
}

// ---------------------------------------------------------------------------
// 5. getBufferView on a non-buffer returns null.
// ---------------------------------------------------------------------------

test "Buffers: getBufferView returns null for non-buffer values" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            // Plain object
            const obj = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, obj);
            try testing.expect(buffers.getBufferView(id, obj) == null);

            // Plain string
            const s = ActiveEngine.newStringVal(ctx, "not a buffer");
            defer ActiveEngine.freeValue(ctx, s);
            try testing.expect(buffers.getBufferView(id, s) == null);

            // Number
            const n = ActiveEngine.newInt32Val(ctx, 123);
            defer ActiveEngine.freeValue(ctx, n);
            try testing.expect(buffers.getBufferView(id, n) == null);

            // Array (not a TypedArray)
            try helpers.evalOk(id, "globalThis.__arr__ = [1, 2, 3];");
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const arr = ActiveEngine.getPropertyVal(ctx, global, "__arr__") orelse
                return error.NoArr;
            defer ActiveEngine.freeValue(ctx, arr);
            try testing.expect(buffers.getBufferView(id, arr) == null);
            try helpers.evalOk(id, "delete globalThis.__arr__;");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 6. Two-way visibility and offset views over caller-owned memory.
//
// ---------------------------------------------------------------------------

fn globalValue(id: i32, name: [*:0]const u8) !ActiveEngine.Value {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    return ActiveEngine.getPropertyVal(ctx, global, name) orelse error.NoValue;
}

test "Buffers: host writes reach JS and JS writes reach the host through one ArrayBuffer" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var data: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
            const ab = buffers.newArrayBufferFromBytes(id, &data, data.len, null, null) orelse return error.NewAbFailed;
            defer ActiveEngine.freeValue(ctx, ab);
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "__ab__", ActiveEngine.dupValue(ctx, ab));
            try helpers.evalOk(id, "globalThis.__view__ = new Uint8Array(__ab__);");

            // Host -> JS: a write after the wrapper exists is observed, so the bytes are shared and not snapshotted.
            data[2] = 0xEE;
            try helpers.expectEvalEquals(id, "String(__view__[2])", "238");

            // JS -> host: writes land in the caller's memory.
            try helpers.evalOk(id, "__view__[0] = 0xAB; __view__.fill(0x7F, 5);");
            try testing.expectEqual(@as(u8, 0xAB), data[0]);
            try testing.expectEqual(@as(u8, 0xEE), data[2]);
            try testing.expectEqualSlices(u8, &.{ 0x7F, 0x7F, 0x7F }, data[5..8]);

            // The pointer reported by the view is the caller's memory, not a copy.
            const view = buffers.getBufferView(id, ab) orelse return error.NoView;
            try testing.expectEqual(@intFromPtr(&data), @intFromPtr(view.ptr));

            try helpers.evalOk(id, "delete globalThis.__ab__; delete globalThis.__view__;");
        }
    }.run);
}

test "Buffers: newUint8ArrayFromBytes shares memory with the host in both directions" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var data: [4]u8 = .{ 10, 20, 30, 40 };
            const u8a = buffers.newUint8ArrayFromBytes(id, &data, data.len, null, null) orelse return error.NewU8aFailed;
            defer ActiveEngine.freeValue(ctx, u8a);
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "__u8a__", ActiveEngine.dupValue(ctx, u8a));

            data[1] = 99;
            try helpers.expectEvalEquals(id, "String(__u8a__[1])", "99");
            try helpers.evalOk(id, "__u8a__[3] = 200;");
            try testing.expectEqual(@as(u8, 200), data[3]);

            const view = buffers.getBufferView(id, u8a) orelse return error.NoView;
            try testing.expectEqual(@intFromPtr(&data), @intFromPtr(view.ptr));
            try testing.expectEqual(@as(usize, 4), view.len);

            try helpers.evalOk(id, "delete globalThis.__u8a__;");
        }
    }.run);
}

test "Buffers: getBufferView on an offset typed array reports pointer offset and byte length" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var data: [16]u8 = undefined;
            for (&data, 0..) |*b, i| b.* = @intCast(i);
            const ab = buffers.newArrayBufferFromBytes(id, &data, data.len, null, null) orelse return error.NewAbFailed;
            defer ActiveEngine.freeValue(ctx, ab);
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "__ab__", ActiveEngine.dupValue(ctx, ab));
            try helpers.evalOk(id,
                \\globalThis.__i16__ = new Int16Array(__ab__, 4, 3);
                \\globalThis.__sub__ = new Uint8Array(__ab__).subarray(9, 13);
            );

            // Int16Array(ab, 4, 3): 3 elements * 2 bytes starting at byte 4.
            const wide = try globalValue(id, "__i16__");
            defer ActiveEngine.freeValue(ctx, wide);
            const i16_view = buffers.getBufferView(id, wide) orelse return error.NoView;
            try testing.expectEqual(@intFromPtr(&data) + 4, @intFromPtr(i16_view.ptr));
            try testing.expectEqual(@as(usize, 6), i16_view.len);
            try testing.expectEqual(@as(u8, 4), i16_view.ptr[0]);
            try testing.expectEqual(@as(u8, 9), i16_view.ptr[5]);

            // subarray(9, 13): 4 bytes starting at byte 9.
            const sub = try globalValue(id, "__sub__");
            defer ActiveEngine.freeValue(ctx, sub);
            const sub_view = buffers.getBufferView(id, sub) orelse return error.NoView;
            try testing.expectEqual(@intFromPtr(&data) + 9, @intFromPtr(sub_view.ptr));
            try testing.expectEqual(@as(usize, 4), sub_view.len);

            // The whole buffer is still reported at offset zero.
            const whole = buffers.getBufferView(id, ab) orelse return error.NoView;
            try testing.expectEqual(@intFromPtr(&data), @intFromPtr(whole.ptr));
            try testing.expectEqual(@as(usize, 16), whole.len);

            try helpers.evalOk(id, "delete globalThis.__ab__; delete globalThis.__i16__; delete globalThis.__sub__;");
        }
    }.run);
}
