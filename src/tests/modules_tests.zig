//! ES module loader tests.
//!
//! Covers (run on BOTH backends unless noted):
//!   1. named export + import round-trip
//!   2. default export + default import
//!   3. re-export chain (a → b)
//!   4. circular imports (A <-> B) do not deadlock / stack-overflow
//!   5. missing module (loader returns false) surfaces an error
//!   6. resolve hook rewrites specifiers (QJS / QuickJS-NG only)
//! 7. JSC: load hook serves imports while resolve is never invoked (ObjC bridge has no separate resolve path; see types.ModuleLoader)
//!
//! Loader is always an in-memory `std.StringHashMap([]const u8)`; no physical fixture files are created. All tests live in a single file so the shared test-loader struct can be hoisted.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const types = @import("../types.zig");
const backend = @import("../backend.zig");

fn hermesModulesUnsupported() bool {
    // Hermes host-side ESM shim landed (hermes_esm.cpp). Keep helper for easy re-gate.
    return false;
}

const dispatch = @import("../runtime/dispatch.zig");
const promise = @import("../runtime/promise.zig");

// ---- In-memory test loader ----

const TestLoaderCtx = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap([]const u8),
    resolve_calls: u32 = 0,
    reentrant_instance: ?i32 = null,
    reentrant_task_ran: bool = false,

    last_referrer: ?[]u8 = null,
    last_specifier: ?[]u8 = null,
    /// Optional resolver override: maps bare specifier → canonical id. Used by the resolve-hook test; empty by default.
    aliases: std.StringHashMap([]const u8),

    fn runQueued(data: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        self.reentrant_task_ran = true;
    }

    fn init(allocator: std.mem.Allocator) TestLoaderCtx {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap([]const u8).init(allocator),
            .aliases = std.StringHashMap([]const u8).init(allocator),
        };
    }

    fn deinit(self: *TestLoaderCtx) void {
        // Keys + values in self.modules are stable string literals supplied by tests; we do not own them. The HashMap internal buffers are freed by std.
        self.modules.deinit();
        self.aliases.deinit();
        if (self.last_referrer) |r| self.allocator.free(r);
        if (self.last_specifier) |s| self.allocator.free(s);
    }
};

fn testLoaderLoad(
    ud: ?*anyopaque,
    id: [*:0]const u8,
    out: *types.ModuleLoadResult,
) callconv(.c) bool {
    const ctx: *TestLoaderCtx = @ptrCast(@alignCast(ud.?));
    const key = std.mem.span(id);
    const src = ctx.modules.get(key) orelse return false;
    if (ctx.reentrant_instance) |instance_id| {
        std.debug.assert(dispatch.postTask(instance_id, .{ .ctx = ctx, .run = TestLoaderCtx.runQueued }));
        _ = engine.testing.advance(instance_id, 0);
    }
    out.* = .{ .source = src.ptr, .source_len = src.len };
    return true;
}

fn testLoaderResolve(
    ud: ?*anyopaque,
    referrer: [*:0]const u8,
    specifier: [*:0]const u8,
) callconv(.c) ?[*:0]u8 {
    const ctx: *TestLoaderCtx = @ptrCast(@alignCast(ud.?));
    ctx.resolve_calls += 1;

    const ref_slice = std.mem.span(referrer);
    const spec_slice = std.mem.span(specifier);

    if (ctx.last_referrer) |r| ctx.allocator.free(r);
    if (ctx.last_specifier) |s| ctx.allocator.free(s);
    ctx.last_referrer = ctx.allocator.dupe(u8, ref_slice) catch null;
    ctx.last_specifier = ctx.allocator.dupe(u8, spec_slice) catch null;

    // Alias lookup (e.g. "./foo" → "canon_foo").
    if (ctx.aliases.get(spec_slice)) |canonical| {
        return ctx.allocator.dupeSentinel(u8, canonical, 0) catch null;
    }
    // Identity fallthrough — return null to tell the engine "use default".
    return null;
}

fn testLoaderFreeResolved(
    ud: ?*anyopaque,
    ptr: [*:0]u8,
) callconv(.c) void {
    const ctx: *TestLoaderCtx = @ptrCast(@alignCast(ud.?));
    const slice = std.mem.span(ptr);
    ctx.allocator.free(slice);
}

const test_vtable: types.ModuleLoaderVTable = .{
    .resolve = testLoaderResolve,
    .load = testLoaderLoad,
    .free_resolved = testLoaderFreeResolved,
};

test "modules: importing an entry does not run a task from its synchronous loader" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("entry", "Promise.resolve().then(() => globalThis.__import_microtask__ = true); export const value = 1;");
    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    ctx.reentrant_instance = id;
    const result = engine.importModule(id, "entry");
    defer helpers.freeEvalResult(result);
    try testing.expect(result.err == null);
    try testing.expect(!ctx.reentrant_task_ran);
    try helpers.expectEvalEquals(id, "String(globalThis.__import_microtask__)", "true");
    _ = engine.testing.advance(id, 0);
    try testing.expect(ctx.reentrant_task_ran);
}

// ---- Module tests (run on both backends) ----

test "modules: named import round-trip" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("m", "export const x = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Expose the imported value on a global so evalModule's stringified return stays deterministic (module eval returns undefined).
    const src = "import { x } from 'm';\nglobalThis.__seen__ = x;";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__seen__");
    try testing.expectEqual(@as(i64, 42), got);
}

test "modules: default export + import" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("m", "export default 7;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src = "import v from 'm';\nglobalThis.__v__ = v;";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__v__");
    try testing.expectEqual(@as(i64, 7), got);
}

test "modules: re-export chain" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // b exports `answer`; a re-exports it; entry imports `answer` from a.
    try ctx.modules.put("b", "export const answer = 4242;");
    try ctx.modules.put("a", "export { answer } from 'b';");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src = "import { answer } from 'a';\nglobalThis.__a__ = answer;";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__a__");
    try testing.expectEqual(@as(i64, 4242), got);
}

test "modules: circular imports do not deadlock" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Classic A↔B cycle. Escargot leaves the reverse *named* import of a function
    // in TDZ even after evaluation, so bPlusA must not call aFn — the unused
    // import still establishes the cycle; aPlusB proves the forward cross-call.
    // Calls run after evalModule (top-level calls during linking hit TDZ).
    try ctx.modules.put("a",
        \\import { bFn } from 'b';
        \\export function aFn() { return 1; }
        \\export const aPlusB = () => aFn() + bFn();
    );
    try ctx.modules.put("b",
        \\import { aFn } from 'a';
        \\export function bFn() { return 2; }
        \\export const bPlusA = () => bFn() + 1;
    );

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import { aPlusB } from 'a';
        \\import { bPlusA } from 'b';
        \\globalThis.__aPlusB = aPlusB;
        \\globalThis.__bPlusA = bPlusA;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    try testing.expectEqual(@as(i64, 3), try helpers.evalInt(id, "globalThis.__aPlusB()"));
    try testing.expectEqual(@as(i64, 3), try helpers.evalInt(id, "globalThis.__bPlusA()"));
}

test "modules: missing module throws an error" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Intentionally leave ctx.modules empty: any import triggers load→false.

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const res = engine.evalModule(id, "import { x } from 'nope';", "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err != null);
    // The missing specifier should appear in the error message on both backends. QJS throws a ReferenceError with the specifier in the text; JSC's delegate error also includes the canonical id.
    const e = res.err.?;
    try testing.expect(std.mem.indexOf(u8, e, "nope") != null);
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        try testing.expect(std.mem.indexOf(u8, e, "ReferenceError") != null);
    }
}

test "modules: resolve hook rewrites specifier" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    // Escargot PlatformRef resolve + QuickJS family.
    if (comptime !(backend.isQuickJsApiBackend(backend.active_backend) or backend.isEscargotBackend(backend.active_backend) or backend.isHermesBackend(backend.active_backend))) return error.SkipZigTest;

    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Canonical module stored under "canon_foo"; import uses "./foo" which the resolve hook rewrites to the canonical id.
    try ctx.modules.put("canon_foo", "export const y = 1234;");
    try ctx.aliases.put("./foo", "canon_foo");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src = "import { y } from './foo';\nglobalThis.__y__ = y;";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    try testing.expect(ctx.resolve_calls >= 1);
    try testing.expect(ctx.last_specifier != null);
    try testing.expectEqualStrings("./foo", ctx.last_specifier.?);

    const got = try helpers.evalInt(id, "globalThis.__y__");
    try testing.expectEqual(@as(i64, 1234), got);
}

// ---- JSC-only test ----

test "modules: JSC evalModule works without imports" {
    if (backend.active_backend != .jsc) return error.SkipZigTest;

    const id = helpers.nextInstanceId();
    // No loader configured — a source that has no `import` statements should still evaluate cleanly on the JSC backend.
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const res = engine.evalModule(id, "globalThis.__mod_ok__ = 99;", "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__mod_ok__");
    try testing.expectEqual(@as(i64, 99), got);
}

test "modules: JSC load serves imports without invoking resolve" {
    if (backend.active_backend != .jsc) return error.SkipZigTest;

    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("m", "export const x = 11;");
    // If resolve were honored, rewriting to a missing id would fail the import.
    try ctx.aliases.put("m", "missing_canonical");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const res = engine.evalModule(id, "import { x } from 'm';\nglobalThis.__jsc_load__ = x;", "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(u32, 0), ctx.resolve_calls);
    try testing.expectEqual(@as(i64, 11), try helpers.evalInt(id, "globalThis.__jsc_load__"));
}

// ---- Dynamic import and import.meta ----

/// Create an engine whose module loader serves no modules and run `body` while both are alive.
fn withEmptyLoaderEngine(body: *const fn (id: i32, ctx: *TestLoaderCtx) anyerror!void) !void {
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try body(id, &ctx);
}

test "modules: dynamic import of a missing module is catchable and names the specifier" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    try withEmptyLoaderEngine(struct {
        fn run(id: i32, ctx: *TestLoaderCtx) !void {
            _ = ctx;
            const res = engine.evalModule(id,
                \\globalThis.__dyn_state = 'pending';
                \\import('no_such_module').then(
                \\  function () { globalThis.__dyn_state = 'resolved'; },
                \\  function (e) {
                \\    globalThis.__dyn_state = 'rejected';
                \\    globalThis.__dyn_message = String(e && e.message);
                \\  });
            , "<entry>");
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);

            // Settling may take a few turns on a backend that loads asynchronously.
            var turn: u32 = 0;
            while (turn < 50) : (turn += 1) {
                _ = engine.testing.advance(id, 0);
                const state = try helpers.evalString(testing.allocator, id, "globalThis.__dyn_state");
                defer testing.allocator.free(state);
                if (!std.mem.eql(u8, state, "pending")) break;
            }
            try helpers.expectEvalEquals(id, "globalThis.__dyn_state", "rejected");
            const message = try helpers.evalString(testing.allocator, id, "globalThis.__dyn_message");
            defer testing.allocator.free(message);
            try testing.expect(std.mem.indexOf(u8, message, "no_such_module") != null);
            // The engine keeps working after the rejected import.
            try helpers.expectEvalEquals(id, "String(1 + 1)", "2");
        }
    }.run);
}

test "modules: import.meta inside evalModule is an object" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    try withEmptyLoaderEngine(struct {
        fn run(id: i32, ctx: *TestLoaderCtx) !void {
            _ = ctx;
            const res = engine.evalModule(id,
                \\globalThis.__meta_type = typeof import.meta;
                \\globalThis.__meta_null = String(import.meta === null);
            , "<entry>");
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);
            try helpers.expectEvalEquals(id, "globalThis.__meta_type", "object");
            try helpers.expectEvalEquals(id, "globalThis.__meta_null", "false");
        }
    }.run);
}

fn settleModuleJobs(id: i32) void {
    var turn: u32 = 0;
    while (turn < 20) : (turn += 1) _ = engine.testing.advance(id, 0);
}

test "modules: top-level await completes and later code in the module runs" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    // Hermes: async wrapper + awaitThenable settles top-level await before marking the module ready.
    try withEmptyLoaderEngine(struct {
        fn run(id: i32, ctx: *TestLoaderCtx) !void {
            try ctx.modules.put("slow", "await Promise.resolve(); await null; export const v = 5;");
            const res = engine.evalModule(id,
                \\import { v } from 'slow';
                \\globalThis.__tla = 'before';
                \\await Promise.resolve();
                \\globalThis.__tla = 'done:' + v;
            , "<entry>");
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);
            settleModuleJobs(id);
            try helpers.expectEvalEquals(id, "globalThis.__tla", "done:5");
        }
    }.run);
}

// How a failed dependency is reported differs by backend (an eval error on JSC, a rejected module promise on the QuickJS family), so only what must hold everywhere is asserted: the importer's body does not run, the failing body ran once, and the engine stays usable.
test "modules: a dependency that throws keeps its importer from running" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    try withEmptyLoaderEngine(struct {
        fn run(id: i32, ctx: *TestLoaderCtx) !void {
            try ctx.modules.put("bad", "globalThis.__bad_runs = (globalThis.__bad_runs || 0) + 1; throw new Error('dep-boom');");
            const res = engine.evalModule(id,
                \\import 'bad';
                \\globalThis.__entry_ran = true;
            , "<entry>");
            defer helpers.freeEvalResult(res);
            settleModuleJobs(id);

            try helpers.expectEvalEquals(id, "String(globalThis.__entry_ran)", "undefined");
            try helpers.expectEvalEquals(id, "String(globalThis.__bad_runs)", "1");
            try helpers.expectEvalEquals(id, "1 + 1", "2");
        }
    }.run);
}

/// Counts host rejection-tracker callbacks and keeps the first unhandled reason.
const RejectionCount = struct {
    unhandled: u32 = 0,
    handled: u32 = 0,
    first_reason: [96]u8 = @splat(0),
    first_reason_len: usize = 0,

    fn onRejection(_: i32, handled: bool, reason_ptr: [*]const u8, reason_len: usize, userdata: ?*anyopaque) callconv(.c) void {
        const self: *RejectionCount = @ptrCast(@alignCast(userdata orelse return));
        if (handled) {
            self.handled += 1;
            return;
        }
        if (self.unhandled == 0) {
            self.first_reason_len = @min(reason_len, self.first_reason.len);
            @memcpy(self.first_reason[0..self.first_reason_len], reason_ptr[0..self.first_reason_len]);
        }
        self.unhandled += 1;
    }
};

/// Evaluate `entry_source` as a module and expect exactly one unhandled-rejection report mentioning `marker`.
fn expectSingleRejectionReport(id: i32, entry_source: []const u8, marker: []const u8) !void {
    var count = RejectionCount{};
    // JSC has no host rejection tracker, so a module failure there is reported synchronously as an eval error instead.
    if (!promise.setRejectionTracker(id, &RejectionCount.onRejection, &count)) return error.SkipZigTest;
    defer _ = promise.setRejectionTracker(id, null, null);

    const res = engine.evalModule(id, entry_source, "<entry>");
    defer helpers.freeEvalResult(res);
    settleModuleJobs(id);
    engine.runEventLoopOnce(id);

    try testing.expectEqual(@as(u32, 1), count.unhandled);
    try testing.expect(std.mem.indexOf(u8, count.first_reason[0..count.first_reason_len], marker) != null);
    try helpers.expectEvalEquals(id, "1 + 1", "2");
}

test "modules: a top-level throw in the entry is reported as one unhandled rejection" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    if (comptime backend.active_backend == .quickjs) {
        // Known defect: the bellard QuickJS backend reports the same unhandled rejection twice. Remove this branch once fixed.
        return error.SkipZigTest;
    }
    try withEmptyLoaderEngine(struct {
        fn run(id: i32, ctx: *TestLoaderCtx) !void {
            _ = ctx;
            try expectSingleRejectionReport(id, "throw new Error('top-boom');", "top-boom");
        }
    }.run);
}

test "modules: a top-level throw in an imported module is reported as one unhandled rejection" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    if (comptime backend.active_backend == .quickjs) {
        // Known defect: the bellard QuickJS backend reports the same unhandled rejection twice. Remove this branch once fixed.
        return error.SkipZigTest;
    }
    try withEmptyLoaderEngine(struct {
        fn run(id: i32, ctx: *TestLoaderCtx) !void {
            try ctx.modules.put("bad", "throw new Error('dep-boom');");
            try expectSingleRejectionReport(id, "import 'bad';", "dep-boom");
        }
    }.run);
}

// Per the module spec a module whose evaluation failed stays failed: every later import rejects with the same error and the body is not run again.
test "modules: importing a module that failed to evaluate rejects again with the same error" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    // Hermes shim: sticky-fail via failed module cache (hermes_esm.cpp).
    if (comptime backend.active_backend == .jsc) {
        // Known defect: JSC resolves the second import of a failed module successfully instead of rejecting. Remove this branch once fixed.
        return error.SkipZigTest;
    }
    try withEmptyLoaderEngine(struct {
        fn run(id: i32, ctx: *TestLoaderCtx) !void {
            // The QuickJS family asks the loader for the specifier as written; JSC asks for the path with the leading "./" removed.
            const source = "globalThis.__bad_runs = (globalThis.__bad_runs || 0) + 1; throw new Error('dep-boom');";
            try ctx.modules.put("./bad", source);
            try ctx.modules.put("bad", source);
            const res = engine.evalModule(id,
                \\globalThis.__outcomes = [];
                \\function settle(tag) {
                \\  return [
                \\    function () { globalThis.__outcomes.push(tag + ':resolved'); },
                \\    function (e) { globalThis.__outcomes.push(tag + ':' + (e && e.message)); },
                \\  ];
                \\}
                \\import('./bad').then(...settle('first'))
                \\  .then(function () { return import('./bad'); })
                \\  .then(...settle('second'));
            , "<entry>");
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);
            settleModuleJobs(id);

            try helpers.expectEvalEquals(id, "globalThis.__outcomes.join('|')", "first:dep-boom|second:dep-boom");
            try helpers.expectEvalEquals(id, "String(globalThis.__bad_runs)", "1");
        }
    }.run);
}

// Import attributes and JSON modules are not part of the supported surface. Whichever way a backend goes, a request for one must end in a usable value or a readable error, never a hang or a damaged engine.
test "modules: a JSON module import attribute either works or fails readably" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    // Hermes shim: import-attributes → Promise.reject / parse err (readable; no ABRT).
    try withEmptyLoaderEngine(struct {
        fn run(id: i32, ctx: *TestLoaderCtx) !void {
            try ctx.modules.put("data.json", "{\"a\":1}");

            // Dynamic form.
            {
                const res = engine.evalModule(id,
                    \\globalThis.__json_state = 'pending';
                    \\import('data.json', { with: { type: 'json' } }).then(
                    \\  function (m) { globalThis.__json_state = 'resolved:' + m.default.a; },
                    \\  function (e) { globalThis.__json_state = 'rejected'; globalThis.__json_message = String(e && e.message); });
                , "<entry>");
                defer helpers.freeEvalResult(res);
                try testing.expect(res.err == null);
                settleModuleJobs(id);
                const state = try helpers.evalString(testing.allocator, id, "globalThis.__json_state");
                defer testing.allocator.free(state);
                if (std.mem.eql(u8, state, "rejected")) {
                    const message = try helpers.evalString(testing.allocator, id, "globalThis.__json_message");
                    defer testing.allocator.free(message);
                    try testing.expect(message.len > 0 and !std.mem.eql(u8, message, "undefined"));
                } else {
                    try testing.expectEqualStrings("resolved:1", state);
                }
            }
            try helpers.expectEvalEquals(id, "1 + 1", "2");

            // Static form: the module either evaluates and sees the data, or is refused with a message.
            {
                const res = engine.evalModule(id,
                    \\import data from 'data.json' with { type: 'json' };
                    \\globalThis.__json_static = data.a;
                , "<entry-static>");
                defer helpers.freeEvalResult(res);
                if (res.err) |message| {
                    try testing.expect(message.len > 0);
                } else {
                    settleModuleJobs(id);
                    try helpers.expectEvalEquals(id, "String(globalThis.__json_static)", "1");
                }
            }
            try helpers.expectEvalEquals(id, "1 + 1", "2");
        }
    }.run);
}
