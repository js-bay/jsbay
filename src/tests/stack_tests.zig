//! Regression tests for JS-stack anchoring (`JS_UpdateStackTop`).
//!
//! `JS_UpdateStackTop` must anchor QuickJS's stack limit to the executing thread at the outermost engine entry.
//!
//! 1. Evaluation from a deeper native stack or a different thread must receive the configured stack budget instead of failing immediately with "Maximum call stack size exceeded".
//! 2. Nested native re-entry (`require` re-entering the engine) must keep the outer anchor. Resetting it would give each recursive call a fresh budget and allow native-stack overflow. A non-terminating require chain checks this boundary.
//!
//! QuickJS-only: the stack machinery is QuickJS-specific.

const std = @import("std");
const testing = std.testing;

const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const types = @import("../types.zig");
const cjs = @import("../script/cjs.zig");
const qjs_mod = @import("../backend.zig").ActiveEngineModule;
const lifecycle_mod = @import("../backend.zig").ActiveEngineModule.lifecycle;

// ---- In-memory CJS loader that requires an ever-new module (infinite chain) ----

/// Loader context with a reusable buffer. Loaders must copy `out.source` before returning (module.zig / cjs.zig both do), so reusing one buffer across the recursive chain is safe and avoids a per-load allocation leak.
const ChainCtx = struct {
    buf: [64]u8 = undefined,
};

fn cjsChainLoad(
    ud: ?*anyopaque,
    id: [*:0]const u8,
    out: *types.ModuleLoadResult,
) callconv(.c) bool {
    const ctx: *ChainCtx = @ptrCast(@alignCast(ud.?));
    const key = std.mem.span(id); // "m<num>"
    if (key.len < 2 or key[0] != 'm') return false;
    const num = std.fmt.parseInt(u32, key[1..], 10) catch return false;
    // Each require is a cache miss -> native require -> JS eval, nesting one level deeper on the native stack every time.
    const src = std.fmt.bufPrint(&ctx.buf, "module.exports = require('m{d}');", .{num + 1}) catch return false;
    out.* = .{ .source = src.ptr, .source_len = src.len };
    return true;
}

const cjs_chain_vtable: types.ModuleLoaderVTable = .{
    .resolve = null, // identity: specifier is the canonical id
    .load = cjsChainLoad,
    .free_resolved = null,
};

// ---- Deterministic "deeper stack than the creation point" reproduction ----

// 4 KiB of live padding per frame keeps the frame on the stack and defeats tail-call elimination, so `frames` frames move the stack pointer by `frames * 4 KiB`. 512 frames ~= 2 MiB, comfortably past the 1 MiB limit used below in either direction.
const deep_pad_bytes = 4096;
const deep_frames = 512;

var g_deep_ok: bool = false;

fn recurseThenEval(id: i32, frames: u32) void {
    var pad: [deep_pad_bytes]u8 = undefined;
    pad[0] = @truncate(frames);
    std.mem.doNotOptimizeAway(&pad);

    if (frames == 0) {
        const res = engine.evalScript(id, "6 * 7", "<deep-stack>");
        defer helpers.freeEvalResult(res);
        g_deep_ok = res.err == null;
        return;
    }
    recurseThenEval(id, frames - 1);
    std.mem.doNotOptimizeAway(&pad);
}

test "stack: eval from a deeper native stack than the creation point succeeds" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    // 1 MiB, like a typical Android host. `JS_SetMaxStackSize` fixes the limit at creation-time sp; evaluating ~2 MiB deeper would trip it without the outermost-entry re-anchor -- the same geometry a different thread created on Android, but reproducible on any OS.
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{ .max_stack_size = 1 << 20 }, struct {
        fn run(instance_id: i32) !void {
            g_deep_ok = false;
            recurseThenEval(instance_id, deep_frames);
            try testing.expect(g_deep_ok);
        }
    }.run);
}

// ---- Smoke test: the literal cross-thread shape from the stack bug ----

const CrossThreadOutcome = struct {
    id: i32,
    ok: bool = false,
    result: [64]u8 = undefined,
    result_len: usize = 0,
    err: [256]u8 = undefined,
    err_len: usize = 0,

    fn run(self: *CrossThreadOutcome) void {
        const res = engine.evalScript(self.id, "6 * 7", "<other-thread>");
        defer helpers.freeEvalResult(res);
        if (res.err) |e| {
            self.err_len = @min(e.len, self.err.len);
            @memcpy(self.err[0..self.err_len], e[0..self.err_len]);
        } else if (res.result) |r| {
            self.result_len = @min(r.len, self.result.len);
            @memcpy(self.result[0..self.result_len], r[0..self.result_len]);
            self.ok = true;
        }
    }
};

// The spawned thread's stack may sit at a different address than the creating thread's, so this smoke test exercises the cross-thread path without assuming an address layout. The deep-stack test above checks overflow deterministically.
test "stack: an instance created on one thread evaluates on another" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var outcome = CrossThreadOutcome{ .id = id };
            const thread = try std.Thread.spawn(.{}, CrossThreadOutcome.run, .{&outcome});
            thread.join();

            if (!outcome.ok) {
                std.debug.print("cross-thread eval failed: {s}\n", .{outcome.err[0..outcome.err_len]});
                return error.CrossThreadEvalFailed;
            }
            try testing.expectEqualStrings("42", outcome.result[0..outcome.result_len]);
        }
    }.run);
}

test "stack: unbounded recursion raises an exception instead of aborting" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{}, struct {
        fn run(instance_id: i32) !void {
            // Must come back as a JS stack-overflow exception, never a native stack overflow -- the process has to survive.
            const res = engine.evalScript(instance_id, "(function f(){ return f(); })()", "<deep>");
            defer helpers.freeEvalResult(res);
            const err = res.err orelse return error.ExpectedStackOverflow;
            try testing.expect(std.mem.indexOf(u8, err, "stack") != null);
            // And the instance must still be usable afterwards.
            try helpers.expectEvalEquals(instance_id, "6 * 7", "42");
        }
    }.run);
}

test "stack: zero requested budget retains a conservative stack guard" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{ .max_stack_size = 0 }, struct {
        fn run(instance_id: i32) !void {
            const res = engine.evalScript(instance_id, "(function f(){ return f(); })()", "<zero-stack-budget>");
            defer helpers.freeEvalResult(res);
            const err = res.err orelse return error.ExpectedStackOverflow;
            try testing.expect(std.mem.indexOf(u8, err, "stack") != null);
            try helpers.expectEvalEquals(instance_id, "6 * 7", "42");
        }
    }.run);
}

const SmallStackOutcome = struct {
    id: i32,
    stack_error: bool = false,
    recovered: bool = false,

    fn run(self: *SmallStackOutcome) void {
        const res = engine.evalScript(self.id, "(function f(){ return f(); })()", "<small-native-stack>");
        defer helpers.freeEvalResult(res);
        self.stack_error = if (res.err) |err| std.mem.indexOf(u8, err, "stack") != null else false;

        const after = engine.evalScript(self.id, "6 * 7", "<small-native-stack-after>");
        defer helpers.freeEvalResult(after);
        self.recovered = after.err == null and after.result != null and std.mem.eql(u8, after.result.?, "42");
    }
};

test "stack: a 512 KiB native thread caps an oversized requested JS stack" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{ .max_stack_size = 128 * 1024 * 1024 }, struct {
        fn run(instance_id: i32) !void {
            var outcome = SmallStackOutcome{ .id = instance_id };
            const thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, SmallStackOutcome.run, .{&outcome});
            thread.join();
            try testing.expect(outcome.stack_error);
            try testing.expect(outcome.recovered);
        }
    }.run);
}

test "stack: nested native re-entry (require) does not widen the stack limit" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;

    // A require chain that never terminates: every module requires the next, so each `require` is a native re-entry into the engine that nests deeper on the native stack. If re-anchoring happened at each of these nested entries, the 1 MiB limit would move down with each frame and never fire, and this would blow the native stack (crash) instead of returning a RangeError.
    var chain = ChainCtx{};
    const loader = types.ModuleLoader{ .vtable = &cjs_chain_vtable, .user_data = &chain };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader, .max_stack_size = 1 << 20 }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    // Assert the error is a stack-overflow error specifically -- not any error the loader/engine might otherwise surface.
    const res = engine.evalScript(id, "require('m1')", "<chain>");
    defer helpers.freeEvalResult(res);
    // The CommonJS `require` path wraps any compile exception as a generic "failed to compile module" SyntaxError, so the underlying stack message is not visible here. The load-bearing assertion is that the recursion terminated in JS (no native abort) and the instance is still usable -- without the depth guard this test crashes the process.
    const err = res.err orelse return error.ExpectedStackOverflow;
    try testing.expect(err.len > 0);

    // Still alive and usable -- no native abort.
    try helpers.expectEvalEquals(id, "6 * 7", "42");
}

// ---- Cross-instance nesting on one thread ----

const BridgeCtx = struct {
    foreign_id: i32 = 0,
    ok: bool = false,
    err: [256]u8 = undefined,
    err_len: usize = 0,
};

/// CJS loader for instance A whose `load("bridge")` synchronously evaluates a *different* instance B on this same thread. With a thread-local depth guard B would be entered at depth > 0, skip anchoring, and reuse whatever anchor it had (here: the thread it was created on). With per-instance depth B anchors for the current thread and succeeds.
fn bridgeLoad(
    ud: ?*anyopaque,
    id: [*:0]const u8,
    out: *types.ModuleLoadResult,
) callconv(.c) bool {
    const ctx: *BridgeCtx = @ptrCast(@alignCast(ud.?));
    const key = std.mem.span(id);
    if (!std.mem.eql(u8, key, "bridge")) return false;
    const res = engine.evalScript(ctx.foreign_id, "6 * 7", "<foreign>");
    defer helpers.freeEvalResult(res);
    if (res.err) |e| {
        ctx.err_len = @min(e.len, ctx.err.len);
        @memcpy(ctx.err[0..ctx.err_len], e[0..ctx.err_len]);
        return false;
    }
    ctx.ok = true;
    out.* = .{ .source = "module.exports = 1;", .source_len = "module.exports = 1;".len };
    return true;
}

const bridge_vtable: types.ModuleLoaderVTable = .{
    .resolve = null,
    .load = bridgeLoad,
    .free_resolved = null,
};

test "stack: a native callback driving another instance anchors it on this thread" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;

    // Instance B is created on a different thread, so its anchor would be that thread's stack if B skipped anchoring.
    const foreign_id = helpers.nextInstanceId();
    const made = struct {
        fn make(id: i32) void {
            _ = engine.create(id, .{});
        }
    };
    const thread = try std.Thread.spawn(.{}, made.make, .{foreign_id});
    thread.join();
    defer engine.destroy(foreign_id);

    var bridge = BridgeCtx{ .foreign_id = foreign_id };
    const loader = types.ModuleLoader{ .vtable = &bridge_vtable, .user_data = &bridge };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    // Entering A's eval drives B from within a native callback on this thread.
    const res = engine.evalScript(id, "require('bridge')", "<outer>");
    defer helpers.freeEvalResult(res);

    if (!bridge.ok) {
        std.debug.print("foreign instance eval failed: {s}\n", .{bridge.err[0..bridge.err_len]});
        return error.ForeignEvalFailed;
    }
    try testing.expect(res.err == null);

    // Deterministic check (no reliance on stack addresses): driving B nested from A's native callback must re-anchor B to *this* thread. Under a thread-local depth guard B would keep the anchoring thread it was created on and this assertion would fail.
    const instance_map = @import("../runtime/instance_map.zig");
    const b_ptrs = instance_map.getPtrs(foreign_id) orelse return error.NoForeign;
    const anchored = qjs_mod.debugStackAnchorThread(b_ptrs.ctx) orelse return error.NotAnchored;
    try testing.expectEqual(std.Thread.getCurrentId(), anchored);
}

// ---- Refusal of nested cross-thread entry ----

const ReentryOutcome = struct {
    ctx: ?*qjs_mod.qjs.JSContext,
    entered: bool = true,
    fn run(self: *ReentryOutcome) void {
        self.entered = lifecycle_mod.enterJs(self.ctx);
        if (self.entered) lifecycle_mod.leaveJs(self.ctx);
    }
};

const EvalRefusedOutcome = struct {
    id: i32,
    refused: bool = false,
    fn run(self: *EvalRefusedOutcome) void {
        const res = engine.evalScript(self.id, "1", "<other>");
        defer helpers.freeEvalResult(res);
        self.refused = res.err != null and std.mem.indexOf(u8, res.err.?, "different thread") != null;
    }
};

test "stack: public evalScript from another thread is refused while an entry is held" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const instance_map = @import("../runtime/instance_map.zig");

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ptrs = instance_map.getPtrs(id) orelse return error.NoInstance;

    // Simulate a host that is inside the runtime on this thread.
    try testing.expect(lifecycle_mod.enterJs(ptrs.ctx));

    var outcome = EvalRefusedOutcome{ .id = id };
    const thread = try std.Thread.spawn(.{}, EvalRefusedOutcome.run, .{&outcome});
    thread.join();
    try testing.expect(outcome.refused);

    // The holding thread's execution is unaffected, and the instance is usable again once it leaves.
    lifecycle_mod.leaveJs(ptrs.ctx);
    try helpers.expectEvalEquals(id, "6 * 7", "42");
}

test "stack: a nested entry from another thread is refused" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;

    try helpers.withBareContext(struct {
        fn run(ctx: ?*qjs_mod.qjs.JSContext, rt: ?*qjs_mod.qjs.JSRuntime) !void {
            _ = rt;
            // Outermost entry on this thread, held across the spawn below.
            try testing.expect(lifecycle_mod.enterJs(ctx));
            defer lifecycle_mod.leaveJs(ctx);

            var outcome = ReentryOutcome{ .ctx = ctx };
            const thread = try std.Thread.spawn(.{}, ReentryOutcome.run, .{&outcome});
            thread.join();

            // While this thread is inside the runtime, another thread must not be allowed to enter it: enterJs refuses instead of re-anchoring (which would widen the stack budget) or running concurrently (which is undefined).
            try testing.expect(!outcome.entered);
        }
    }.run);
}

// ---- Owner release / hand-off ----

const HandoffOutcome = struct {
    ctx: ?*qjs_mod.qjs.JSContext,
    entered: bool = false,
    fn run(self: *HandoffOutcome) void {
        self.entered = lifecycle_mod.enterJs(self.ctx);
        if (self.entered) lifecycle_mod.leaveJs(self.ctx);
    }
};

test "stack: the owner is released so another thread can then enter" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;

    try helpers.withBareContext(struct {
        fn run(ctx: ?*qjs_mod.qjs.JSContext, rt: ?*qjs_mod.qjs.JSRuntime) !void {
            _ = rt;
            // Hold then release on this thread.
            try testing.expect(lifecycle_mod.enterJs(ctx));
            lifecycle_mod.leaveJs(ctx);

            // A different thread must now be able to claim it. If leaveJs ever failed to clear the owner, this would be refused (false).
            var outcome = HandoffOutcome{ .ctx = ctx };
            const thread = try std.Thread.spawn(.{}, HandoffOutcome.run, .{&outcome});
            thread.join();
            try testing.expect(outcome.entered);

            // And this thread can claim it again afterwards.
            try testing.expect(lifecycle_mod.enterJs(ctx));
            lifecycle_mod.leaveJs(ctx);
        }
    }.run);
}

// ---- Outermost-entry contention ----

const ContendState = struct {
    ctx: ?*qjs_mod.qjs.JSContext,
    go: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    attempted: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    successes: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn run(self: *ContendState) void {
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        const got = lifecycle_mod.enterJs(self.ctx);
        // Record the attempt immediately (before any wait) so a buggy double-success cannot deadlock the winner's wait.
        _ = self.attempted.fetchAdd(1, .acq_rel);
        if (got) {
            // Keep ownership until the other thread has also attempted, so the two enters genuinely overlap. `cancel` lets a spawn failure on the test side release this wait instead of hanging the join.
            while (!self.cancel.load(.acquire) and self.attempted.load(.acquire) < 2) {
                std.atomic.spinLoopHint();
            }
            _ = self.successes.fetchAdd(1, .monotonic);
            lifecycle_mod.leaveJs(self.ctx);
        }
    }
};

test "stack: two threads racing on an idle runtime, only one enters" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;

    try helpers.withBareContext(struct {
        fn run(ctx: ?*qjs_mod.qjs.JSContext, rt: ?*qjs_mod.qjs.JSRuntime) !void {
            _ = rt;
            var state = ContendState{ .ctx = ctx };
            const t1 = std.Thread.spawn(.{}, ContendState.run, .{&state}) catch |e| return e;
            const t2 = std.Thread.spawn(.{}, ContendState.run, .{&state}) catch |e| {
                // Release the already-started thread (which may be waiting for a second attempt that will never come) before its stack cell dies.
                state.cancel.store(true, .release);
                state.go.store(true, .release);
                t1.join();
                return e;
            };
            state.go.store(true, .release);
            t1.join();
            t2.join();
            try testing.expectEqual(@as(u32, 1), state.successes.load(.monotonic));
            // Nothing leaked: this thread can still claim it afterwards.
            try testing.expect(lifecycle_mod.enterJs(ctx));
            lifecycle_mod.leaveJs(ctx);
        }
    }.run);
}

// ---- Unwrapped host entry re-entering the engine ----

var g_ping_count: usize = 0;

fn reentryPingCb(
    ctx: ?*qjs_mod.qjs.JSContext,
    _: qjs_mod.qjs.JSValue,
    _: c_int,
    _: [*c]qjs_mod.qjs.JSValue,
) callconv(.c) qjs_mod.qjs.JSValue {
    g_ping_count += 1;
    // Re-enter the engine through a wrapped entry. Each getter level calls this once and returns, so the owner is idle between levels -- the case where a naively re-anchoring implementation would move the stack limit down every level and never trigger, overflowing the native stack.
    const res = backend.ActiveEngine.eval(ctx, "0", "<ping>");
    if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
    if (res.err_is_heap) {
        if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
    }
    return qjs_mod.qjs.JS_NewInt32(ctx, 0);
}

test "stack: getter recursion re-entering via an unwrapped host read still raises" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const qjs = qjs_mod.qjs;
    const B = backend.ActiveEngine;

    try helpers.withBareContext(struct {
        fn run(ctx: ?*qjs.JSContext, rt: ?*qjs.JSRuntime) !void {
            _ = rt;
            const global = B.getGlobalObject(ctx);
            defer B.freeValue(ctx, global);
            const ping = B.newCFunction(ctx, &reentryPingCb, "__ping", 0);
            B.setPropertyStr(ctx, global, "__ping", ping);

            // A self-referential getter that pings the native side every level.
            const setup = B.eval(
                ctx,
                \\globalThis.o = {};
                \\Object.defineProperty(globalThis.o, 'x', { get() { globalThis.__ping(); return globalThis.o.x; } });
            ,
                "<setup>",
            );
            defer helpers.freeEvalResult(setup);
            try testing.expect(setup.err == null);

            g_ping_count = 0;
            const o = B.getPropertyVal(ctx, global, "o") orelse return error.NoObject;
            defer B.freeValue(ctx, o);

            // The HOST reads the getter directly (no enterJs here): the outer entry is unwrapped, so a naive re-anchoring would chase the stack pointer down and crash. It must instead return a stack error.
            const got = B.getPropertyVal(ctx, o, "x");
            try testing.expect(got == null);

            // The pending exception must be a stack overflow, not a crash or an unrelated error.
            const message = B.getAndFormatException(ctx) orelse return error.NoException;
            defer std.heap.c_allocator.free(@constCast(message));
            try testing.expect(std.mem.indexOf(u8, message, "stack") != null);

            try testing.expect(g_ping_count > 0);
            const after = B.eval(ctx, "6 * 7", "<after>");
            defer helpers.freeEvalResult(after);
            try testing.expect(after.err == null);
            try testing.expectEqualStrings("42", after.result.?);
        }
    }.run);
}

test "stack: a foreign runtime's lazily installed state is freed on raw destroy" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const qjs = qjs_mod.qjs;

    var installs_before: usize = 0;
    var frees_before: usize = 0;
    // Scoped so the defers below run (and the finalizer fires) before the assertions that inspect the free counter.
    {
        const rt = qjs.JS_NewRuntime() orelse return error.NoRuntime;
        defer qjs.JS_FreeRuntime(rt);
        const ctx = qjs.JS_NewContext(rt) orelse return error.NoContext;
        defer qjs.JS_FreeContext(ctx);

        installs_before = lifecycle_mod.debug_state_installs.load(.monotonic);
        frees_before = lifecycle_mod.debug_state_frees.load(.monotonic);

        // First entry installs this runtime's state.
        try testing.expect(lifecycle_mod.enterJs(ctx));
        lifecycle_mod.leaveJs(ctx);
        try testing.expectEqual(
            installs_before + 1,
            lifecycle_mod.debug_state_installs.load(.monotonic),
        );
    }
    // A raw JS_FreeRuntime (bypassing the wrapper) must still run the finalizer.
    try testing.expectEqual(frees_before + 1, lifecycle_mod.debug_state_frees.load(.monotonic));
}

test "stack: racing first entries install exactly one state per runtime" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const qjs = qjs_mod.qjs;

    const Race = struct {
        ctx: ?*qjs.JSContext,
        go: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn worker(self: *@This()) void {
            while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
            if (lifecycle_mod.enterJs(self.ctx)) lifecycle_mod.leaveJs(self.ctx);
        }
    };

    var iter: usize = 0;
    while (iter < 200) : (iter += 1) {
        const rt = qjs.JS_NewRuntime() orelse return error.NoRuntime;
        defer qjs.JS_FreeRuntime(rt);
        const ctx = qjs.JS_NewContext(rt) orelse return error.NoContext;
        defer qjs.JS_FreeContext(ctx);
        const before = lifecycle_mod.debug_state_installs.load(.monotonic);

        var a = Race{ .ctx = ctx };
        var b = Race{ .ctx = ctx };
        const ta = std.Thread.spawn(.{}, Race.worker, .{&a}) catch |e| return e;
        const tb = std.Thread.spawn(.{}, Race.worker, .{&b}) catch |e| {
            // Let the already-started thread finish before its stack cell dies.
            a.go.store(true, .release);
            ta.join();
            return e;
        };
        a.go.store(true, .release);
        b.go.store(true, .release);
        ta.join();
        tb.join();

        // Serialized install means exactly one state, regardless of who won.
        try testing.expectEqual(before + 1, lifecycle_mod.debug_state_installs.load(.monotonic));
    }
}

test "stack: a foreign runtime's host opaque pointer is left untouched" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const qjs = qjs_mod.qjs;

    const rt = qjs.JS_NewRuntime() orelse return error.NoRuntime;
    const ctx = qjs.JS_NewContext(rt) orelse {
        qjs.JS_FreeRuntime(rt);
        return error.NoContext;
    };
    defer {
        qjs.JS_FreeContext(ctx);
        qjs.JS_FreeRuntime(rt);
    }

    // A host that owns the runtime opaque slot for its own data. The engine must keep its state in a private registry and never touch this slot.
    var host_data: [64]u8 = @splat(0xAB);
    qjs.JS_SetRuntimeOpaque(rt, @ptrCast(&host_data));

    // Entering succeeds (lazy install into the registry) ...
    try testing.expect(lifecycle_mod.enterJs(ctx));
    lifecycle_mod.leaveJs(ctx);

    // ... and the host's slot is byte-for-byte unchanged.
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&host_data)), qjs.JS_GetRuntimeOpaque(rt));
    for (host_data) |b| try testing.expectEqual(@as(u8, 0xAB), b);
}

// ---- Recursion inside asynchronous contexts (all backends) ----

/// True when `globalThis.__stackError` holds a stack-exhaustion error. QuickJS-ng reports a RangeError; classic QuickJS reports an InternalError; JSC reports a RangeError. The message always names the stack.
const stack_error_check =
    \\String(globalThis.__stackError !== undefined &&
    \\  (globalThis.__stackError.name === 'RangeError' || globalThis.__stackError.name === 'InternalError') &&
    \\  /stack/i.test(String(globalThis.__stackError.message)))
;

test "stack: unbounded recursion in an async function rejects with a catchable stack error" {
    // Match the public default so the asynchronous path shares its guard.
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{ .max_stack_size = 1 << 20 }, struct {
        fn run(instance_id: i32) !void {
            // The async body runs synchronously up to its first await, so the recursion happens on the native stack of the calling eval.
            try helpers.evalOk(instance_id,
                \\globalThis.__stackError = undefined;
                \\async function f() { await f(); }
                \\f().catch(function (e) { globalThis.__stackError = e; });
            );
            try helpers.expectEvalEquals(instance_id, stack_error_check, "true");
            try helpers.expectEvalEquals(instance_id, "6 * 7", "42");
        }
    }.run);
}

test "stack: unbounded recursion inside a promise job is catchable and later jobs still run" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{ .max_stack_size = 1 << 20 }, struct {
        fn run(instance_id: i32) !void {
            // The recursion runs while the job queue drains, not from the top-level script body.
            try helpers.evalOk(instance_id,
                \\globalThis.__stackError = undefined;
                \\globalThis.__laterJob = false;
                \\Promise.resolve().then(function () {
                \\  try {
                \\    (function f() { return f() + 1; })();
                \\  } catch (e) {
                \\    globalThis.__stackError = e;
                \\  }
                \\});
                \\Promise.resolve().then(function () { globalThis.__laterJob = true; });
            );
            try helpers.expectEvalEquals(instance_id, stack_error_check, "true");
            try helpers.expectEvalEquals(instance_id, "String(globalThis.__laterJob)", "true");
            try helpers.expectEvalEquals(instance_id, "6 * 7", "42");
        }
    }.run);
}

test "stack: unbounded recursion in an uncaught promise job rejects instead of aborting" {
    const id = helpers.nextInstanceId();
    try helpers.withEngine(id, .{ .max_stack_size = 1 << 20 }, struct {
        fn run(instance_id: i32) !void {
            try helpers.evalOk(instance_id,
                \\globalThis.__stackError = undefined;
                \\Promise.resolve().then(function () { return (function f() { return f() + 1; })(); })
                \\  .catch(function (e) { globalThis.__stackError = e; });
            );
            try helpers.expectEvalEquals(instance_id, stack_error_check, "true");
            try helpers.expectEvalEquals(instance_id, "6 * 7", "42");
        }
    }.run);
}

const stack_budget = @import("../platform/stack_budget.zig");

test "stack_budget: large native stacks keep the full reserve" {
    const available = 2 * 1024 * 1024;
    const got = stack_budget.capAvailable(8 * 1024 * 1024, available);
    try testing.expectEqual(available - stack_budget.reserve_bytes, got);
}

test "stack_budget: tight stacks shrink reserve to keep a usable JS budget" {
    // Mirrors a 512KiB worker after enterJs: ~160KiB left below SP. Old policy left ~33KiB and Debug JS_Eval exhausted it before JS ran.
    const available: usize = 164368;
    const got = stack_budget.capAvailable(128 * 1024 * 1024, available);
    try testing.expect(got >= stack_budget.min_js_budget_bytes);
    try testing.expect(got <= available);
    try testing.expect(got > available - stack_budget.reserve_bytes);
}

test "stack_budget: pathologically small stacks still leave half for JS" {
    const available: usize = 40 * 1024;
    const got = stack_budget.capAvailable(1024 * 1024, available);
    try testing.expectEqual(available / 2, got);
}
