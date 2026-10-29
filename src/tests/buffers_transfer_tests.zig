//! Transferring an ArrayBuffer that wraps caller-owned memory.
//!
//! `ArrayBuffer.prototype.transfer` detaches the source and gives JS a buffer over the same contents. The caller's finalizer must still run exactly once for the original `(user_data, bytes, len)`, however the backend moves ownership of the store between the two buffer objects.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const buffers = @import("../value/buffers.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const runtime_control = @import("../runtime/runtime_control.zig");

const ActiveEngine = backend.ActiveEngine;

var g_fin_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var g_last_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var g_last_ptr: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var g_last_user: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

// Records the call only; it must not touch the engine because it runs inside the collector.
fn countingFinalizer(user_data: ?*anyopaque, bytes: [*]u8, len: usize) callconv(.c) void {
    _ = g_fin_count.fetchAdd(1, .seq_cst);
    g_last_len.store(len, .seq_cst);
    g_last_ptr.store(@intFromPtr(bytes), .seq_cst);
    if (user_data) |u| g_last_user.store(@intFromPtr(u), .seq_cst);
}

test "Buffers: transferring an external ArrayBuffer fires its finalizer exactly once" {
    g_fin_count.store(0, .seq_cst);
    g_last_len.store(0, .seq_cst);
    g_last_ptr.store(0, .seq_cst);
    g_last_user.store(0, .seq_cst);

    var data: [32]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    var user_marker: u32 = 0xBEEF0001;

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    {
        const ctx = engine.getContext(id) orelse {
            engine.destroy(id);
            return error.NoContext;
        };
        const ab = buffers.newArrayBufferFromBytes(id, &data, data.len, countingFinalizer, @ptrCast(&user_marker)) orelse {
            engine.destroy(id);
            return error.NewAbFailed;
        };
        const global = ActiveEngine.getGlobalObject(ctx);
        ActiveEngine.setPropertyStr(ctx, global, "__ab__", ab);
        ActiveEngine.freeValue(ctx, global);
    }

    // transfer() detaches the source and hands JS a buffer with the same contents; the contents must survive even though the original store is released.
    helpers.evalOk(id,
        \\globalThis.__moved__ = __ab__.transfer();
        \\if (__ab__.detached !== true || __ab__.byteLength !== 0) throw new Error('source not detached');
        \\if (__moved__.byteLength !== 32 || new Uint8Array(__moved__)[31] !== 31) throw new Error('contents lost');
        \\delete globalThis.__ab__;
    ) catch |err| {
        engine.destroy(id);
        return err;
    };
    _ = runtime_control.runGc(id);
    _ = runtime_control.runGc(id);
    helpers.evalOk(id, "delete globalThis.__moved__;") catch |err| {
        engine.destroy(id);
        return err;
    };
    _ = runtime_control.runGc(id);
    engine.destroy(id);

    try testing.expectEqual(@as(u32, 1), g_fin_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, 32), g_last_len.load(.seq_cst));
    try testing.expectEqual(@intFromPtr(&data), g_last_ptr.load(.seq_cst));
    try testing.expectEqual(@intFromPtr(&user_marker), g_last_user.load(.seq_cst));
}

fn resetFinalizerRecord() void {
    g_fin_count.store(0, .seq_cst);
    g_last_len.store(0, .seq_cst);
    g_last_ptr.store(0, .seq_cst);
    g_last_user.store(0, .seq_cst);
}

// When the wrapper cannot be created, the caller still gets its finalizer call exactly once with the original arguments.
test "Buffers: wrapping on a missing instance returns null and fires the finalizer once" {
    resetFinalizerRecord();
    var data: [16]u8 = @splat(0xA5);
    var user_marker: u32 = 0xBEEF0002;

    const id = helpers.nextInstanceId();
    try testing.expect(engine.getContext(id) == null);
    try testing.expect(buffers.newArrayBufferFromBytes(id, &data, data.len, countingFinalizer, @ptrCast(&user_marker)) == null);
    try testing.expectEqual(@as(u32, 1), g_fin_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, 16), g_last_len.load(.seq_cst));
    try testing.expectEqual(@intFromPtr(&data), g_last_ptr.load(.seq_cst));
    try testing.expectEqual(@intFromPtr(&user_marker), g_last_user.load(.seq_cst));

    // Same after the instance existed and was destroyed.
    resetFinalizerRecord();
    try testing.expect(engine.create(id, .{}));
    engine.destroy(id);
    try testing.expect(buffers.newArrayBufferFromBytes(id, &data, data.len, countingFinalizer, @ptrCast(&user_marker)) == null);
    try testing.expectEqual(@as(u32, 1), g_fin_count.load(.seq_cst));
    try testing.expectEqual(@intFromPtr(&data), g_last_ptr.load(.seq_cst));
}

// Sweep the headroom under a memory cap so that wrapper creation fails at the different allocation points inside the backend. Whatever the outcome of an attempt, its finalizer accounts for the caller's memory exactly once.
test "Buffers: wrapping under a tight memory cap accounts for the finalizer exactly once" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(runtime_control.init(id));
    defer _ = runtime_control.deinit(id);

    var data: [64]u8 = @splat(0x5A);
    var user_marker: u32 = 0xBEEF0003;
    var refused: u32 = 0;
    var created: u32 = 0;

    var headroom: u64 = 0;
    while (headroom <= 4096) : (headroom += 128) {
        resetFinalizerRecord();
        const usage = runtime_control.getMemoryUsage(id) orelse return error.NoUsage;
        try testing.expect(runtime_control.setMemoryLimit(id, usage.malloc_size + headroom));

        const maybe = buffers.newArrayBufferFromBytes(id, &data, data.len, countingFinalizer, @ptrCast(&user_marker));
        try testing.expect(runtime_control.setMemoryLimit(id, 0));
        if (maybe) |value| {
            created += 1;
            // Still alive: the finalizer must not have run early.
            try testing.expectEqual(@as(u32, 0), g_fin_count.load(.seq_cst));
            const ctx = engine.getContext(id) orelse return error.NoContext;
            ActiveEngine.freeValue(ctx, value);
            _ = runtime_control.runGc(id);
        } else {
            refused += 1;
        }
        try testing.expectEqual(@as(u32, 1), g_fin_count.load(.seq_cst));
        try testing.expectEqual(@intFromPtr(&data), g_last_ptr.load(.seq_cst));
        try testing.expectEqual(@intFromPtr(&user_marker), g_last_user.load(.seq_cst));
        // The engine is clean after every attempt.
        try helpers.expectEvalEquals(id, "1 + 1", "2");
    }
    // The sweep is only meaningful if it reached both outcomes.
    try testing.expect(created > 0);
    try testing.expect(refused > 0);
}
