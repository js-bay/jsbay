//! Tests for the finalizer-callback API (src/value/weakcb.zig).
//!
//! Both backends must pass. The API attaches a user-supplied finalizer to an arbitrary JS object; when the object is garbage-collected or the engine is destroyed, the callback fires with its `user_data`.
//!
//! GC timing is non-deterministic in general. We validate correctness by a mix of:
//!   - `runtime_control.runGc` to poke the collector where it's effective
//! - engine teardown, which is the one point both backends guarantee to flush any remaining finalizers.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const weakcb = @import("../value/weakcb.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");
const runtime_control = @import("../runtime/runtime_control.zig");

const native_handle = switch (backend.active_backend) {
    .quickjs, .quickjs_ng => @import("../value/native_handle.zig"),
    .jsc => @import("../backend/jsc/native_handle.zig"),
};

const ActiveEngine = backend.ActiveEngine;

// ---- Shared finalizer state -------------------------------------------------

const Counters = struct {
    a: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    b: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_user_data: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn reset(self: *Counters) void {
        self.a.store(0, .seq_cst);
        self.b.store(0, .seq_cst);
        self.last_user_data.store(0, .seq_cst);
    }
};

var g_counters: Counters = .{};

fn bumpA(user_data: ?*anyopaque) callconv(.c) void {
    _ = g_counters.a.fetchAdd(1, .seq_cst);
    g_counters.last_user_data.store(@intFromPtr(user_data), .seq_cst);
}

fn bumpB(user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    _ = g_counters.b.fetchAdd(1, .seq_cst);
}

// A marker value we can use as `user_data` without heap allocation. Its address is stable across the test process.
var g_marker_a: u32 = 0xAAAA_AAAA;
var g_marker_b: u32 = 0xBBBB_BBBB;

// Poke the collector. On QJS this flushes all pending finalizers because the runtime's mark-and-sweep is synchronous. On JSC we rely on engine teardown.
fn kickGc(id: i32) void {
    _ = runtime_control.runGc(id);
}

// ---------------------------------------------------------------------------
// 1. Attach to a plain JS object; force GC; callback fires with user_data.
// ---------------------------------------------------------------------------

test "weakcb: finalizer fires for GC'd plain object" {
    g_counters.reset();

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;

    {
        const ctx = engine.getContext(id) orelse {
            engine.destroy(id);
            return error.NoContext;
        };
        const obj = ActiveEngine.newObject(ctx);
        const ok = weakcb.attachFinalizer(id, obj, @ptrCast(&g_marker_a), bumpA);
        try testing.expect(ok);
        // Release the only native reference. On QJS this drops the refcount to zero and the next runGc collects it. On JSC the object becomes unreachable and will be collected at engine destroy (at latest).
        ActiveEngine.freeValue(ctx, obj);
    }

    kickGc(id);
    // Engine teardown guarantees any remaining finalizers run on both backends, which is the one point JSC's collector will flush for us.
    engine.destroy(id);

    try testing.expect(g_counters.a.load(.seq_cst) >= 1);
    try testing.expectEqual(@intFromPtr(&g_marker_a), g_counters.last_user_data.load(.seq_cst));
}

// ---------------------------------------------------------------------------
// 2. Attach to a NativeHandle instance; finalizer fires when the instance dies.
// ---------------------------------------------------------------------------

test "weakcb: finalizer fires for NativeHandle instance on teardown" {
    g_counters.reset();

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;

    const instance = instance_map.getInstance(id) orelse {
        engine.destroy(id);
        return error.NoInstance;
    };
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => native_handle.init(instance.runtime),
        .jsc => native_handle.init(),
    }

    {
        const ctx = engine.getContext(id) orelse {
            engine.destroy(id);
            return error.NoContext;
        };
        const handle = native_handle.create(ctx, .{});
        const ok = weakcb.attachFinalizer(id, handle, @ptrCast(&g_marker_b), bumpB);
        try testing.expect(ok);

        const global = ActiveEngine.getGlobalObject(ctx);
        defer ActiveEngine.freeValue(ctx, global);
        ActiveEngine.setPropertyStr(ctx, global, "__probe", handle);
    }

    // Engine teardown drops the last ref to globalThis.__probe and runs every finalizer in the runtime.
    engine.destroy(id);

    try testing.expect(g_counters.b.load(.seq_cst) >= 1);
}

// ---------------------------------------------------------------------------
// 3. Attaching to a primitive returns false, does not crash, does not invoke the callback.
// ---------------------------------------------------------------------------

test "weakcb: attaching to primitives is a no-op returning false" {
    g_counters.reset();

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const n = ActiveEngine.newInt32Val(ctx, 42);
            defer ActiveEngine.freeValue(ctx, n);
            try testing.expect(!weakcb.attachFinalizer(id, n, null, bumpA));

            const s = ActiveEngine.newStringVal(ctx, "hello");
            defer ActiveEngine.freeValue(ctx, s);
            try testing.expect(!weakcb.attachFinalizer(id, s, null, bumpA));
        }
    }.run);

    // No callback should have been invoked.
    try testing.expectEqual(@as(u32, 0), g_counters.a.load(.seq_cst));
}

// ---------------------------------------------------------------------------
// 4. Multiple finalizers on the same object — all fire.
// ---------------------------------------------------------------------------

test "weakcb: multiple finalizers on same object all fire" {
    g_counters.reset();

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;

    {
        const ctx = engine.getContext(id) orelse {
            engine.destroy(id);
            return error.NoContext;
        };
        const obj = ActiveEngine.newObject(ctx);
        try testing.expect(weakcb.attachFinalizer(id, obj, null, bumpA));
        try testing.expect(weakcb.attachFinalizer(id, obj, null, bumpB));
        try testing.expect(weakcb.attachFinalizer(id, obj, null, bumpA));
        ActiveEngine.freeValue(ctx, obj);
    }

    kickGc(id);
    engine.destroy(id);

    try testing.expect(g_counters.a.load(.seq_cst) >= 2);
    try testing.expect(g_counters.b.load(.seq_cst) >= 1);
}

// ---------------------------------------------------------------------------
// 5. Engine destroy flushes un-fired finalizers so native resources don't leak even if the user never drops their JS reference before destroy.
// ---------------------------------------------------------------------------

test "weakcb: engine destroy flushes pending finalizers" {
    g_counters.reset();

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;

    {
        const ctx = engine.getContext(id) orelse {
            engine.destroy(id);
            return error.NoContext;
        };
        // Keep the target ALIVE in JS via globalThis — no drop before destroy. The runtime still has to finalize everything at shutdown. Use eval to install the reference so we don't have to juggle the QJS-consumes / JSC-doesn't-consume asymmetry of setPropertyStr.
        try helpers.evalOk(id, "globalThis.__keep = {};");
        const global = ActiveEngine.getGlobalObject(ctx);
        defer ActiveEngine.freeValue(ctx, global);
        const keep = ActiveEngine.getPropertyVal(ctx, global, "__keep") orelse
            return error.NoKeep;
        defer ActiveEngine.freeValue(ctx, keep);
        const ok = weakcb.attachFinalizer(id, keep, null, bumpA);
        try testing.expect(ok);
    }

    // No GC yet; callback must NOT have fired (object is reachable via globalThis.__keep).
    try testing.expectEqual(@as(u32, 0), g_counters.a.load(.seq_cst));

    engine.destroy(id);

    try testing.expect(g_counters.a.load(.seq_cst) >= 1);
}
