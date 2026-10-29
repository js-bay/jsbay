//! Tests for the reference lifecycle module (Local / Global / Weak / Scope / StackFrameScope). Both backends must pass these.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const reference = @import("../value/reference.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");

const ActiveEngine = backend.ActiveEngine;

// ---- Global round-trip ----

test "Global.init + get returns dup'd value with original content" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            // Build a JS string Local, hand it to a Global, then verify get() returns a value whose stringification matches.
            const s = ActiveEngine.newStringVal(ctx, "hello-global");
            var g = reference.Global(reference.Local).init(id, s);
            // The Global dup'd it; release our own ref.
            ActiveEngine.freeValue(ctx, s);

            try testing.expect(!g.isEmpty());
            const got = g.get() orelse return error.GetReturnedNull;
            defer ActiveEngine.freeValue(ctx, got);

            const text = ActiveEngine.valueToStringVal(ctx, got) orelse return error.NoText;
            defer std.heap.c_allocator.free(@constCast(text));
            try testing.expectEqualStrings("hello-global", text);

            g.deinit();
            try testing.expect(g.isEmpty());
        }
    }.run);
}

test "Global.reset clears isEmpty" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const s = ActiveEngine.newStringVal(ctx, "x");
            var g = reference.Global(reference.Local).init(id, s);
            ActiveEngine.freeValue(ctx, s);
            try testing.expect(!g.isEmpty());

            g.reset();
            try testing.expect(g.isEmpty());
            try testing.expect(g.get() == null);
        }
    }.run);
}

test "Global survives unrelated eval and still yields its content" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const s = ActiveEngine.newStringVal(ctx, "persists");
            var g = reference.Global(reference.Local).init(id, s);
            defer g.deinit();
            ActiveEngine.freeValue(ctx, s);

            // Run other JS that allocates memory and triggers GC heuristics.
            try helpers.evalOk(id, "var arr = []; for (var i=0;i<1000;i++) arr.push({n:i});");
            // Trigger GC explicitly on QuickJS; no-op on JSC.
            const inst_runtime = (instance_map.getInstance(id) orelse return error.NoInstance).runtime;
            ActiveEngine.runGc(inst_runtime);

            const got = g.get() orelse return error.GetReturnedNull;
            defer ActiveEngine.freeValue(ctx, got);
            const text = ActiveEngine.valueToStringVal(ctx, got) orelse return error.NoText;
            defer std.heap.c_allocator.free(@constCast(text));
            try testing.expectEqualStrings("persists", text);
        }
    }.run);
}

test "Two Globals are independent" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const a = ActiveEngine.newStringVal(ctx, "alpha");
            const b = ActiveEngine.newStringVal(ctx, "beta");
            var ga = reference.Global(reference.Local).init(id, a);
            var gb = reference.Global(reference.Local).init(id, b);
            defer ga.deinit();
            defer gb.deinit();
            ActiveEngine.freeValue(ctx, a);
            ActiveEngine.freeValue(ctx, b);

            const va = ga.get() orelse return error.NoA;
            defer ActiveEngine.freeValue(ctx, va);
            const vb = gb.get() orelse return error.NoB;
            defer ActiveEngine.freeValue(ctx, vb);

            const ta = ActiveEngine.valueToStringVal(ctx, va) orelse return error.NoTextA;
            defer std.heap.c_allocator.free(@constCast(ta));
            const tb = ActiveEngine.valueToStringVal(ctx, vb) orelse return error.NoTextB;
            defer std.heap.c_allocator.free(@constCast(tb));

            try testing.expectEqualStrings("alpha", ta);
            try testing.expectEqualStrings("beta", tb);
        }
    }.run);
}

test "Global.deinit is idempotent" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const s = ActiveEngine.newStringVal(ctx, "once");
            var g = reference.Global(reference.Local).init(id, s);
            ActiveEngine.freeValue(ctx, s);

            g.deinit();
            // Calling reset/deinit again must be a no-op, not a crash.
            g.deinit();
            g.reset();
            try testing.expect(g.isEmpty());
        }
    }.run);
}

// ---- Weak ----

test "Weak stores a value and reports correct isEmpty" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const s = ActiveEngine.newStringVal(ctx, "weak-val");
            // Park the value on the global so we don't dangle when we immediately freeValue our local copy.
            const global = ActiveEngine.getGlobalObject(ctx);
            ActiveEngine.setPropertyStr(ctx, global, "__weak__", ActiveEngine.dupValue(ctx, s));
            ActiveEngine.freeValue(ctx, global);

            var w = reference.Weak(reference.Local).init(id, s);
            // We retained on the global, so freeing our own local copy is fine.
            ActiveEngine.freeValue(ctx, s);

            try testing.expect(!w.isEmpty());
            const got = w.get() orelse return error.GetReturnedNull;
            // Weak does not dup; do not freeValue here.
            const text = ActiveEngine.valueToStringVal(ctx, got) orelse return error.NoText;
            defer std.heap.c_allocator.free(@constCast(text));
            try testing.expectEqualStrings("weak-val", text);

            w.deinit();
            try testing.expect(w.isEmpty());
            try testing.expect(w.get() == null);
        }
    }.run);
}

test "Weak.reset clears" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const s = ActiveEngine.newStringVal(ctx, "x");
            const global = ActiveEngine.getGlobalObject(ctx);
            ActiveEngine.setPropertyStr(ctx, global, "__weak2__", ActiveEngine.dupValue(ctx, s));
            ActiveEngine.freeValue(ctx, global);

            var w = reference.Weak(reference.Local).init(id, s);
            ActiveEngine.freeValue(ctx, s);
            w.reset();
            try testing.expect(w.isEmpty());
        }
    }.run);
}

// ---- Scope ----

test "Scope.enter / exit round-trips currentInstanceId" {
    const id1: i32 = 9_001;
    const id2: i32 = 9_002;

    try testing.expect(reference.currentInstanceId() == null);

    var s1 = reference.Scope.enter(id1);
    reference.activate(&s1);
    try testing.expectEqual(@as(?i32, id1), reference.currentInstanceId());

    var s2 = reference.Scope.enter(id2);
    reference.activate(&s2);
    try testing.expectEqual(@as(?i32, id2), reference.currentInstanceId());

    s2.exit();
    try testing.expectEqual(@as(?i32, id1), reference.currentInstanceId());

    s1.exit();
    try testing.expect(reference.currentInstanceId() == null);
}

// The same instance can be entered recursively, and each exit restores one scope level.
test "Scope: the same instance can be re-entered and unwinds one level at a time" {
    const id1: i32 = 9_011;
    const id2: i32 = 9_012;

    try testing.expect(reference.currentInstanceId() == null);

    var outer = reference.Scope.enter(id1);
    reference.activate(&outer);
    var other = reference.Scope.enter(id2);
    reference.activate(&other);
    var again = reference.Scope.enter(id1);
    reference.activate(&again);

    try testing.expectEqual(@as(?i32, id1), reference.currentInstanceId());
    try testing.expect(reference.Scope.current() == &again);
    try testing.expect(again.prev == &other);

    again.exit();
    try testing.expectEqual(@as(?i32, id2), reference.currentInstanceId());
    try testing.expect(reference.Scope.current() == &other);

    other.exit();
    try testing.expectEqual(@as(?i32, id1), reference.currentInstanceId());
    try testing.expect(reference.Scope.current() == &outer);

    outer.exit();
    try testing.expect(reference.currentInstanceId() == null);
    try testing.expect(reference.Scope.current() == null);
}

const ScopeProbe = struct {
    saw_no_scope: bool = false,
    saw_own_scope: bool = false,
    left_clean: bool = false,

    fn run(self: *ScopeProbe, own_id: i32) void {
        self.saw_no_scope = reference.currentInstanceId() == null;
        var scope = reference.Scope.enter(own_id);
        reference.activate(&scope);
        self.saw_own_scope = reference.currentInstanceId() == own_id;
        scope.exit();
        self.left_clean = reference.currentInstanceId() == null;
    }
};

test "Scope: another thread does not see the current thread's scope" {
    const main_id: i32 = 9_021;
    const worker_id: i32 = 9_022;

    var scope = reference.Scope.enter(main_id);
    reference.activate(&scope);

    var probe = ScopeProbe{};
    var thread = try std.Thread.spawn(.{}, ScopeProbe.run, .{ &probe, worker_id });
    thread.join();

    // The worker started without a scope, its own scope stayed local to it, and ours was not disturbed.
    try testing.expect(probe.saw_no_scope);
    try testing.expect(probe.saw_own_scope);
    try testing.expect(probe.left_clean);
    try testing.expectEqual(@as(?i32, main_id), reference.currentInstanceId());

    scope.exit();
    try testing.expect(reference.currentInstanceId() == null);
}

// ---- StackFrameScope ----

test "StackFrameScope.returnValue keeps a value alive past frame exit" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            // Inside an inner block, allocate a value, returnValue it, exit the StackFrameScope. The returned value should still be valid afterwards.
            const escaped: reference.Local = blk: {
                var frame = reference.StackFrameScope.enter(id);
                defer frame.exit();
                const inner = ActiveEngine.newStringVal(ctx, "escapes");
                defer ActiveEngine.freeValue(ctx, inner);
                break :blk frame.returnValue(inner);
            };
            defer ActiveEngine.freeValue(ctx, escaped);

            const text = ActiveEngine.valueToStringVal(ctx, escaped) orelse return error.NoText;
            defer std.heap.c_allocator.free(@constCast(text));
            try testing.expectEqualStrings("escapes", text);
        }
    }.run);
}

// ---- Engine teardown with live Global ----

test "Engine destroy with live Global does not crash or leak" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));

    const ctx = engine.getContext(id) orelse return error.NoContext;
    const s = ActiveEngine.newStringVal(ctx, "outlives-engine");
    // Intentionally do NOT call deinit BEFORE destroy; rely on the engine's bookkeeping walk to release the retained JS value before the runtime is torn down. Post-destroy, we still deinit to reclaim the small heap cell the Global owns.
    var g = reference.Global(reference.Local).init(id, s);
    ActiveEngine.freeValue(ctx, s);
    try testing.expect(!g.isEmpty());

    engine.destroy(id);

    // After destroy, the bookkeeping walk should have reset our Global.
    try testing.expect(g.isEmpty());
    // Calling deinit post-destroy must be safe (no double-free, no UAF).
    g.deinit();
    try testing.expect(g.isEmpty());
}

test "Engine destroy with live Weak does not crash" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));

    const ctx = engine.getContext(id) orelse return error.NoContext;
    const s = ActiveEngine.newStringVal(ctx, "weak-on-teardown");
    const global = ActiveEngine.getGlobalObject(ctx);
    ActiveEngine.setPropertyStr(ctx, global, "__w__", ActiveEngine.dupValue(ctx, s));
    ActiveEngine.freeValue(ctx, global);

    var w = reference.Weak(reference.Local).init(id, s);
    ActiveEngine.freeValue(ctx, s);
    try testing.expect(!w.isEmpty());

    engine.destroy(id);
    try testing.expect(w.isEmpty());
    w.deinit();
    try testing.expect(w.isEmpty());
}

// ----------------------------------------------------------------------
// True-weak semantics — objects get collected, Weak.get() returns null.
//
// Determinism notes:
// - QuickJS: one `engine.runGc` call is sufficient. We also null the slot we parked the target on before running GC so the target is genuinely unreachable.
// - JSC: we route through `engine.runGc` which calls `JSSynchronousGarbageCollectForDebugging`, the symbol WebKit's own tests use. Still, the collector runs in passes; we drain with two calls to cover weak-handle finalisation slots.
// ----------------------------------------------------------------------

/// Allocate a plain object in JS, park it on the global under `prop`, and install a `Weak` pointing at it. The object handle never leaves this function — returning it on the stack would let JSC's conservative stack scanner keep the target alive (!). Instead we construct the Weak here and return that.
///
/// Post-conditions: the ONLY strong reference to the target is the `globalThis.<prop>` slot. Deleting that property and forcing GC will cause `weak.get() == null`.
fn makeParkAndWeak(id: i32, prop: []const u8) !reference.Weak(reference.Local) {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    var buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&buf, "globalThis.{s} = {{}}; undefined;", .{prop});
    try helpers.evalOk(id, script);

    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const name_buf = try std.fmt.bufPrintSentinel(&buf, "{s}", .{prop}, 0);
    const obj = ActiveEngine.getPropertyVal(ctx, global, name_buf.ptr) orelse
        return error.NoProperty;

    const w = reference.Weak(reference.Local).init(id, obj);
    // Release our extracted protect/refcount so the property slot is the only strong reference. (Weak does not dup on object-kind targets; it only holds a weak ref.)
    ActiveEngine.freeValue(ctx, obj);
    return w;
}

/// Clear globalThis[prop] so the target becomes unreachable. The prop name is interpolated directly into a `delete globalThis.<name>;` script, so it must contain only identifier characters.
fn unparkFromGlobal(id: i32, prop: []const u8) !void {
    var buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&buf, "delete globalThis.{s};", .{prop});
    try helpers.evalOk(id, script);
}

test "Weak: strong ref + weak ref — weak.get() returns the value" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var w = try makeParkAndWeak(id, "__wobj1__");
            defer w.deinit();

            try testing.expect(!w.isEmpty());
            try testing.expect(w.get() != null);
        }
    }.run);
}

/// Run several GC passes, interspersed with JS allocation pressure so JSC's incremental collector actually walks the weak table. Tests that expect collection should call this, not plain runGc.
///
/// Collection behavior:
/// - QuickJS: one `JS_RunGC` already clears everything; the loop below is harmless.
/// - JSC: two full `JSSynchronousGarbageCollectForDebugging` calls with allocation pressure in between are required — weak-handle finalisation runs in a separate phase of the collector.
fn forceCollect(id: i32) !void {
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        try helpers.evalOk(id, "for (var __i=0; __i<5000; __i++) ({a:__i, b:[1,2,3]});");
        engine.runGc(id);
    }
}

test "Weak: drop strong + GC — weak.get() returns null" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var w = try makeParkAndWeak(id, "__wobj2__");
            try testing.expect(!w.isEmpty());

            // Drop the only strong ref and force aggressive collection.
            try unparkFromGlobal(id, "__wobj2__");
            try forceCollect(id);

            try testing.expect(w.get() == null);
            try testing.expect(w.isEmpty());
            w.deinit();
        }
    }.run);
}

/// Construct two Weak handles on the same JS object, returning both. Like `makeParkAndWeak`, the target Value handle never leaves the function so JSC's conservative stack scan can't accidentally root it.
noinline fn makeParkAndTwoWeaks(id: i32, prop: []const u8) !struct {
    a: reference.Weak(reference.Local),
    b: reference.Weak(reference.Local),
} {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    var buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&buf, "globalThis.{s} = {{}}; undefined;", .{prop});
    try helpers.evalOk(id, script);

    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const name_buf = try std.fmt.bufPrintSentinel(&buf, "{s}", .{prop}, 0);
    const obj = ActiveEngine.getPropertyVal(ctx, global, name_buf.ptr) orelse
        return error.NoProperty;

    const a = reference.Weak(reference.Local).init(id, obj);
    const b = reference.Weak(reference.Local).init(id, obj);
    ActiveEngine.freeValue(ctx, obj);
    return .{ .a = a, .b = b };
}

/// Run the live-state assertions for the two-weaks test, then return. Isolating this in a separate function ensures any JSValueRef that `w2.get()` returned is no longer on the caller's stack by the time we drop the strong reference + GC. JSC uses conservative stack scanning, so stray pointers in the active frame would otherwise root the target and stop the weak from clearing.
noinline fn assertTwoWeaksLive(w1: *reference.Weak(reference.Local), w2: *reference.Weak(reference.Local)) !void {
    try testing.expect(!w1.isEmpty());
    try testing.expect(!w2.isEmpty());
    w1.deinit();
    try testing.expect(w1.isEmpty());
    try testing.expect(!w2.isEmpty());
    try testing.expect(w2.get() != null);
}

test "Weak: two weaks on same target behave independently" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const pair = try makeParkAndTwoWeaks(id, "__wobj3__");
            var w1 = pair.a;
            var w2 = pair.b;

            try assertTwoWeaksLive(&w1, &w2);

            // Collect and observe that w2 goes empty.
            try unparkFromGlobal(id, "__wobj3__");
            try forceCollect(id);
            try testing.expect(w2.isEmpty());
            try testing.expect(w2.get() == null);
            w2.deinit();
        }
    }.run);
}

test "Weak over a primitive is strong-ish (never clears)" {
    // Policy: non-object values (numbers, strings, booleans) are not GC-eligible in the same way objects are. `Weak.init` dup's them and behaves like a lightweight Global — never spontaneously clearing. Consumers that want "null after GC" must wrap in an object first. See src/value/reference.zig module docs.
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const num = ActiveEngine.newInt32Val(ctx, 42);

            var w = reference.Weak(reference.Local).init(id, num);
            ActiveEngine.freeValue(ctx, num);
            defer w.deinit();

            try testing.expect(!w.isEmpty());
            try testing.expect(w.get() != null);

            // Forcing GC must not clear a primitive Weak.
            try forceCollect(id);
            try testing.expect(!w.isEmpty());
            try testing.expect(w.get() != null);

            // Verify we can still extract the integer.
            const got = w.get() orelse return error.GetReturnedNull;
            const n = ActiveEngine.toInt32(ctx, got) orelse return error.NotAnInt;
            try testing.expectEqual(@as(i32, 42), n);
        }
    }.run);
}
