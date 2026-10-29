//! Tests for the TSFN (thread-safe function) API (src/runtime/tsfn.zig).
//!
//! Both backends must pass. TSFN pins a JS callback and lets any thread enqueue a call against it; the JS thread drains the queue via `drainPending`.
//!
//! Coverage:
//!   1. Same-thread: acquire + call + drain dispatches the callback.
//! 2. Cross-thread: a worker thread enqueues N calls; main thread drains and observes all of them in order.
//!   3. Release while queue has pending entries: dropped, not dispatched.
//!   4. Invalid handle id: `call` returns false without crashing.
//!   5. Two handles on one instance: no crosstalk.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const tsfn = @import("../runtime/tsfn.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const value = @import("../value/root.zig");
const weakcb = @import("../value/weakcb.zig");
const io = @import("../platform/io.zig");

const ActiveEngine = backend.ActiveEngine;

var release_from_microtask_handle: tsfn.TsfnHandle = .{ .id = 0 };
var release_from_microtask_count: usize = 0;
var repost_handle: tsfn.TsfnHandle = .{ .id = 0 };
var repost_count: usize = 0;

fn releaseFromMicrotask(_: i32, _: value.NativeArgs) value.NativeResult {
    tsfn.release(release_from_microtask_handle);
    release_from_microtask_count += 1;
    return .undefined_val;
}

fn repostFromCallback(_: i32, _: value.NativeArgs) value.NativeResult {
    if (repost_count == 0) {
        repost_count += 1;
        _ = tsfn.call(repost_handle, "again");
    }
    return .undefined_val;
}

/// Install a JS callback that appends each received payload to a global array. Returns the ActiveEngine.Value for the function (caller must pass it to `acquire`, which dups it; caller then frees the local).
fn installAccumulator(
    instance_id: i32,
    js_global_name: []const u8,
    accumulator_name: []const u8,
) !ActiveEngine.Value {
    const ctx = engine.getContext(instance_id) orelse return error.NoContext;

    // Make the accumulator and callback. Using setup+eval so the test doesn't have to thread QuickJS C-function pointers through JSC.
    var buf: [512]u8 = undefined;
    const src = try std.fmt.bufPrint(
        &buf,
        \\globalThis.{s} = [];
        \\globalThis.{s} = (payload) => {{ globalThis.{s}.push(payload); }};
    ,
        .{ accumulator_name, js_global_name, accumulator_name },
    );
    const res = engine.evalScript(instance_id, src, "<tsfn-test>");
    defer helpers.freeEvalResult(res);
    if (res.err != null) return error.JSException;

    // Retrieve the function value.
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);

    const name_z = try std.heap.c_allocator.dupeSentinel(u8, js_global_name, 0);
    defer std.heap.c_allocator.free(name_z);
    const func = ActiveEngine.getPropertyVal(ctx, global, name_z.ptr) orelse
        return error.CallbackMissing;
    return func;
}

/// Return the current length of `globalThis.<name>` as a plain integer.
fn accumulatorLen(instance_id: i32, name: []const u8) !i64 {
    var buf: [128]u8 = undefined;
    const expr = try std.fmt.bufPrint(&buf, "globalThis.{s}.length", .{name});
    return helpers.evalInt(instance_id, expr);
}

/// Read the accumulator entry at `idx` as a JS string.
fn accumulatorGet(
    allocator: std.mem.Allocator,
    instance_id: i32,
    name: []const u8,
    idx: usize,
) ![]u8 {
    var buf: [128]u8 = undefined;
    const expr = try std.fmt.bufPrint(&buf, "globalThis.{s}[{d}]", .{ name, idx });
    return helpers.evalString(allocator, instance_id, expr);
}

// ---------------------------------------------------------------------------
// 1. Same-thread: acquire + call + drainPending dispatches.
// ---------------------------------------------------------------------------

test "TSFN: same-thread acquire/call/drain delivers payload" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const cb = try installAccumulator(id, "__tsfn_cb__", "__tsfn_log__");
            defer ActiveEngine.freeValue(ctx, cb);

            const h = tsfn.acquire(id, cb) orelse return error.AcquireFailed;
            defer tsfn.release(h);

            try testing.expect(tsfn.call(h, "hello-world"));
            try testing.expectEqual(@as(i64, 0), try accumulatorLen(id, "__tsfn_log__"));

            const dispatched = tsfn.drainPending(id);
            try testing.expectEqual(@as(usize, 1), dispatched);

            try testing.expectEqual(@as(i64, 1), try accumulatorLen(id, "__tsfn_log__"));
            const got = try accumulatorGet(std.testing.allocator, id, "__tsfn_log__", 0);
            defer std.testing.allocator.free(got);
            try testing.expectEqualStrings("hello-world", got);

            // Cleanup globals.
            try helpers.evalOk(id,
                \\delete globalThis.__tsfn_cb__;
                \\delete globalThis.__tsfn_log__;
            );
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 2. Cross-thread: worker enqueues N, join, drain on main thread.
// ---------------------------------------------------------------------------

const WorkerArgs = struct {
    handle: tsfn.TsfnHandle,
    count: usize,
    base_label: []const u8,
};

fn worker(args: WorkerArgs) void {
    var i: usize = 0;
    var buf: [64]u8 = undefined;
    while (i < args.count) : (i += 1) {
        const msg = std.fmt.bufPrint(&buf, "{s}-{d}", .{ args.base_label, i }) catch return;
        _ = tsfn.call(args.handle, msg);
    }
}

test "TSFN: cross-thread call enqueues and drain delivers in order" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const cb = try installAccumulator(id, "__tsfn_cb2__", "__tsfn_log2__");
            defer ActiveEngine.freeValue(ctx, cb);

            const h = tsfn.acquire(id, cb) orelse return error.AcquireFailed;
            defer tsfn.release(h);

            const count: usize = 5;
            const thread = try std.Thread.spawn(.{}, worker, .{WorkerArgs{
                .handle = h,
                .count = count,
                .base_label = "msg",
            }});
            thread.join();

            // Nothing should have fired yet — dispatch happens on the JS thread via drainPending.
            try testing.expectEqual(@as(i64, 0), try accumulatorLen(id, "__tsfn_log2__"));

            const dispatched = tsfn.drainPending(id);
            try testing.expectEqual(count, dispatched);

            try testing.expectEqual(@as(i64, @intCast(count)), try accumulatorLen(id, "__tsfn_log2__"));

            var i: usize = 0;
            while (i < count) : (i += 1) {
                const got = try accumulatorGet(std.testing.allocator, id, "__tsfn_log2__", i);
                defer std.testing.allocator.free(got);
                var exp_buf: [64]u8 = undefined;
                const expected = try std.fmt.bufPrint(&exp_buf, "msg-{d}", .{i});
                try testing.expectEqualStrings(expected, got);
            }

            try helpers.evalOk(id,
                \\delete globalThis.__tsfn_cb2__;
                \\delete globalThis.__tsfn_log2__;
            );
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 3. Release drops pending, subsequent drain is a no-op for that handle.
// ---------------------------------------------------------------------------

test "TSFN: release while pending calls drops them" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const cb = try installAccumulator(id, "__tsfn_cb3__", "__tsfn_log3__");
            defer ActiveEngine.freeValue(ctx, cb);

            const h = tsfn.acquire(id, cb) orelse return error.AcquireFailed;
            try testing.expect(tsfn.call(h, "A"));
            try testing.expect(tsfn.call(h, "B"));

            // Release BEFORE drain — both pending calls must be dropped.
            tsfn.release(h);

            const dispatched = tsfn.drainPending(id);
            try testing.expectEqual(@as(usize, 0), dispatched);
            try testing.expectEqual(@as(i64, 0), try accumulatorLen(id, "__tsfn_log3__"));

            // Call on a released handle returns false.
            try testing.expect(!tsfn.call(h, "C"));

            try helpers.evalOk(id,
                \\delete globalThis.__tsfn_cb3__;
                \\delete globalThis.__tsfn_log3__;
            );
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 4. Invalid handle ids: no crash, `call` returns false.
// ---------------------------------------------------------------------------

test "TSFN: invalid handle id returns false" {
    // These do not require a live engine.
    try testing.expect(!tsfn.call(.{ .id = 0 }, "nope"));
    try testing.expect(!tsfn.call(.{ .id = std.math.maxInt(u64) }, "nope"));
    // Release of unknown handle is a no-op.
    tsfn.release(.{ .id = 0 });
    tsfn.release(.{ .id = std.math.maxInt(u64) });
}

test "TSFN: engine destroy releases unreleased handles" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const callback = try installAccumulator(id, "__tsfn_destroy_cb__", "__tsfn_destroy_log__");
    const handle = tsfn.acquire(id, callback) orelse return error.AcquireFailed;
    ActiveEngine.freeValue(ctx, callback);
    try testing.expect(tsfn.call(handle, "queued-before-destroy"));

    // No explicit release: destroy owns the final cleanup while the context is still live. A late foreign completion must be rejected afterwards.
    engine.destroy(id);
    try testing.expect(!tsfn.call(handle, "late"));

    // Reusing the numeric id must not let an old handle release or enqueue against the new context.
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const new_ctx = engine.getContext(id) orelse return error.NoContext;
    const new_callback = try installAccumulator(id, "__tsfn_destroy_cb2__", "__tsfn_destroy_log2__");
    defer ActiveEngine.freeValue(new_ctx, new_callback);
    const new_handle = tsfn.acquire(id, new_callback) orelse return error.AcquireFailed;
    defer tsfn.release(new_handle);
    tsfn.release(handle);
    try testing.expect(tsfn.call(new_handle, "new"));
    try testing.expectEqual(@as(usize, 1), tsfn.drainPending(id));
    try testing.expectEqual(@as(i64, 1), try accumulatorLen(id, "__tsfn_destroy_log2__"));
}

const ConcurrentDestroyCaller = struct {
    handle: tsfn.TsfnHandle,
    started: *std.atomic.Value(bool),
    keep_calling: *std.atomic.Value(bool),

    fn run(self: @This()) void {
        self.started.store(true, .seq_cst);
        while (self.keep_calling.load(.seq_cst)) _ = tsfn.call(self.handle, "race");
    }
};

test "TSFN: foreign calls racing destroy are rejected after teardown" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const callback = try installAccumulator(id, "__tsfn_race_cb__", "__tsfn_race_log__");
    const handle = tsfn.acquire(id, callback) orelse return error.AcquireFailed;
    ActiveEngine.freeValue(ctx, callback);

    var started = std.atomic.Value(bool).init(false);
    var keep_calling = std.atomic.Value(bool).init(true);
    const caller_thread = try std.Thread.spawn(.{}, ConcurrentDestroyCaller.run, .{ConcurrentDestroyCaller{
        .handle = handle,
        .started = &started,
        .keep_calling = &keep_calling,
    }});
    const deadline = io.monotonicMilliseconds() + 1_000;
    while (!started.load(.seq_cst)) {
        if (io.monotonicMilliseconds() >= deadline) return error.WorkerDidNotStart;
        std.Thread.yield() catch {};
    }
    engine.destroy(id);
    keep_calling.store(false, .seq_cst);
    caller_thread.join();
    try testing.expect(!tsfn.call(handle, "late"));
}

const FinalizerAcquireProbe = struct {
    instance_id: i32,
    callback: ActiveEngine.Value,
    called: std.atomic.Value(bool) = .init(false),
    rejected: std.atomic.Value(bool) = .init(false),

    fn finalize(raw: ?*anyopaque, destroying: bool) callconv(.c) void {
        const self: *FinalizerAcquireProbe = @ptrCast(@alignCast(raw.?));
        self.called.store(true, .seq_cst);
        if (destroying) self.rejected.store(tsfn.acquire(self.instance_id, self.callback) == null, .seq_cst);
    }
};

test "TSFN: destroy finalizer cannot acquire a new handle" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const callback = try installAccumulator(id, "__tsfn_finalizer_cb__", "__tsfn_finalizer_log__");
    // The callback remains a raw VM value only until destroy invokes the finalizer; acquire must reject before dereferencing it.
    var probe = FinalizerAcquireProbe{ .instance_id = id, .callback = callback };
    try helpers.evalOk(id, "globalThis.__tsfn_finalizer_target__ = {};");
    const global = ActiveEngine.getGlobalObject(ctx);
    const target = ActiveEngine.getPropertyVal(ctx, global, "__tsfn_finalizer_target__") orelse return error.NoTarget;
    try testing.expect(weakcb.attachDestroyingFinalizer(id, target, &probe, FinalizerAcquireProbe.finalize));
    ActiveEngine.freeValue(ctx, target);
    ActiveEngine.freeValue(ctx, global);
    // `probe.callback` is intentionally only an opaque stale bit-pattern. The finalizer path must reject before looking at it, while this balances the caller-owned value returned by installAccumulator.
    ActiveEngine.freeValue(ctx, callback);
    engine.destroy(id);
    try testing.expect(probe.called.load(.seq_cst));
    try testing.expect(probe.rejected.load(.seq_cst));
}

// ---------------------------------------------------------------------------
// 5. Two handles on one instance — independent queues, no crosstalk.
// ---------------------------------------------------------------------------

test "TSFN: two handles on one instance route independently" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const cb_a = try installAccumulator(id, "__tsfn_a_cb__", "__tsfn_a_log__");
            defer ActiveEngine.freeValue(ctx, cb_a);
            const cb_b = try installAccumulator(id, "__tsfn_b_cb__", "__tsfn_b_log__");
            defer ActiveEngine.freeValue(ctx, cb_b);

            const ha = tsfn.acquire(id, cb_a) orelse return error.AcquireA;
            defer tsfn.release(ha);
            const hb = tsfn.acquire(id, cb_b) orelse return error.AcquireB;
            defer tsfn.release(hb);

            try testing.expect(tsfn.call(ha, "to-a-1"));
            try testing.expect(tsfn.call(hb, "to-b-1"));
            try testing.expect(tsfn.call(ha, "to-a-2"));

            // Each owner tick starts one TSFN callback, while preserving the enqueue order across handles.
            try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
            try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
            try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));

            try testing.expectEqual(@as(i64, 2), try accumulatorLen(id, "__tsfn_a_log__"));
            try testing.expectEqual(@as(i64, 1), try accumulatorLen(id, "__tsfn_b_log__"));

            const a0 = try accumulatorGet(std.testing.allocator, id, "__tsfn_a_log__", 0);
            defer std.testing.allocator.free(a0);
            try testing.expectEqualStrings("to-a-1", a0);

            const a1 = try accumulatorGet(std.testing.allocator, id, "__tsfn_a_log__", 1);
            defer std.testing.allocator.free(a1);
            try testing.expectEqualStrings("to-a-2", a1);

            const b0 = try accumulatorGet(std.testing.allocator, id, "__tsfn_b_log__", 0);
            defer std.testing.allocator.free(b0);
            try testing.expectEqualStrings("to-b-1", b0);

            try helpers.evalOk(id,
                \\delete globalThis.__tsfn_a_cb__;
                \\delete globalThis.__tsfn_a_log__;
                \\delete globalThis.__tsfn_b_cb__;
                \\delete globalThis.__tsfn_b_log__;
            );
        }
    }.run);
}

test "TSFN: explicit drain preserves enqueue order across handles" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__tsfn_bulk_trace__ = [];
                \\globalThis.__tsfn_bulk_a__ = () => __tsfn_bulk_trace__.push('A');
                \\globalThis.__tsfn_bulk_b__ = () => __tsfn_bulk_trace__.push('B');
            );
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const a_name: [:0]const u8 = "__tsfn_bulk_a__";
            const b_name: [:0]const u8 = "__tsfn_bulk_b__";
            const a_callback = ActiveEngine.getPropertyVal(ctx, global, a_name.ptr) orelse return error.CallbackMissing;
            defer ActiveEngine.freeValue(ctx, a_callback);
            const b_callback = ActiveEngine.getPropertyVal(ctx, global, b_name.ptr) orelse return error.CallbackMissing;
            defer ActiveEngine.freeValue(ctx, b_callback);
            const a = tsfn.acquire(id, a_callback) orelse return error.AcquireA;
            defer tsfn.release(a);
            const b = tsfn.acquire(id, b_callback) orelse return error.AcquireB;
            defer tsfn.release(b);
            try testing.expect(tsfn.call(b, "first"));
            try testing.expect(tsfn.call(a, "second"));
            try testing.expectEqual(@as(usize, 2), tsfn.drainPending(id));
            try helpers.expectEvalEquals(id, "__tsfn_bulk_trace__.join('')", "BA");
        }
    }.run);
}

test "TSFN: explicit drain stops at calls pending when it started" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            repost_handle = .{ .id = 0 };
            repost_count = 0;
            value.registerFunction(id, null, "__tsfn_repost__", &repostFromCallback);
            try helpers.evalOk(id,
                \\globalThis.__tsfn_repost_log__ = [];
                \\globalThis.__tsfn_repost_cb__ = (payload) => {
                \\  __tsfn_repost_log__.push(payload);
                \\  if (payload === 'first') __tsfn_repost__();
                \\};
            );
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const name: [:0]const u8 = "__tsfn_repost_cb__";
            const callback = ActiveEngine.getPropertyVal(ctx, global, name.ptr) orelse return error.CallbackMissing;
            defer ActiveEngine.freeValue(ctx, callback);
            const handle = tsfn.acquire(id, callback) orelse return error.AcquireFailed;
            defer tsfn.release(handle);
            repost_handle = handle;
            try testing.expect(tsfn.call(handle, "first"));
            try testing.expectEqual(@as(usize, 1), tsfn.drainPending(id));
            try helpers.expectEvalEquals(id, "__tsfn_repost_log__.join(',')", "first");
            try testing.expectEqual(@as(usize, 1), tsfn.drainPending(id));
            try helpers.expectEvalEquals(id, "__tsfn_repost_log__.join(',')", "first,again");
        }
    }.run);
}

test "TSFN: a callback microtask can release a later snapshot handle" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            release_from_microtask_handle = .{ .id = 0 };
            release_from_microtask_count = 0;
            value.registerFunction(id, null, "__tsfn_release_b__", &releaseFromMicrotask);

            try helpers.evalOk(id,
                \\globalThis.__tsfn_release_log__ = [];
                \\globalThis.__tsfn_a__ = (payload) => {
                \\  __tsfn_release_log__.push('A:' + payload);
                \\  Promise.resolve().then(() => __tsfn_release_b__());
                \\};
                \\globalThis.__tsfn_b__ = (payload) => __tsfn_release_log__.push('B:' + payload);
            );
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const a_name: [:0]const u8 = "__tsfn_a__";
            const b_name: [:0]const u8 = "__tsfn_b__";
            const a_callback = ActiveEngine.getPropertyVal(ctx, global, a_name.ptr) orelse return error.CallbackMissing;
            const a = tsfn.acquire(id, a_callback) orelse {
                ActiveEngine.freeValue(ctx, a_callback);
                return error.AcquireA;
            };
            ActiveEngine.freeValue(ctx, a_callback);
            defer tsfn.release(a);
            const b_callback = ActiveEngine.getPropertyVal(ctx, global, b_name.ptr) orelse return error.CallbackMissing;
            const b = tsfn.acquire(id, b_callback) orelse {
                ActiveEngine.freeValue(ctx, b_callback);
                return error.AcquireB;
            };
            ActiveEngine.freeValue(ctx, b_callback);
            defer tsfn.release(b);
            release_from_microtask_handle = b;

            try helpers.evalOk(id,
                \\delete globalThis.__tsfn_a__;
                \\delete globalThis.__tsfn_b__;
            );
            try testing.expect(tsfn.call(a, "one"));
            try testing.expect(tsfn.call(b, "two"));
            try testing.expectEqual(@as(usize, 1), tsfn.drainPending(id));
            try testing.expectEqual(@as(usize, 1), release_from_microtask_count);
            try testing.expect(!tsfn.call(b, "late"));
            try helpers.expectEvalEquals(id, "__tsfn_release_log__.join(',')", "A:one");
            try helpers.evalOk(id,
                \\delete globalThis.__tsfn_release_log__;
                \\delete globalThis.__tsfn_release_b__;
            );
        }
    }.run);
}

test "TSFN: a callback microtask can release itself with more queued calls" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            release_from_microtask_handle = .{ .id = 0 };
            release_from_microtask_count = 0;
            value.registerFunction(id, null, "__tsfn_release_self__", &releaseFromMicrotask);

            try helpers.evalOk(id,
                \\globalThis.__tsfn_self_log__ = [];
                \\globalThis.__tsfn_self__ = (payload) => {
                \\  __tsfn_self_log__.push(payload);
                \\  Promise.resolve().then(() => __tsfn_release_self__());
                \\};
            );
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const callback_name: [:0]const u8 = "__tsfn_self__";
            const callback = ActiveEngine.getPropertyVal(ctx, global, callback_name.ptr) orelse return error.CallbackMissing;
            const handle = tsfn.acquire(id, callback) orelse {
                ActiveEngine.freeValue(ctx, callback);
                return error.AcquireFailed;
            };
            ActiveEngine.freeValue(ctx, callback);
            defer tsfn.release(handle);
            release_from_microtask_handle = handle;
            try helpers.evalOk(id, "delete globalThis.__tsfn_self__;");

            try testing.expect(tsfn.call(handle, "first"));
            try testing.expect(tsfn.call(handle, "second"));
            try testing.expectEqual(@as(usize, 1), tsfn.drainPending(id));
            try testing.expectEqual(@as(usize, 1), release_from_microtask_count);
            try testing.expect(!tsfn.call(handle, "late"));
            try helpers.expectEvalEquals(id, "__tsfn_self_log__.join(',')", "first");
            try helpers.evalOk(id,
                \\delete globalThis.__tsfn_self_log__;
                \\delete globalThis.__tsfn_release_self__;
            );
        }
    }.run);
}
