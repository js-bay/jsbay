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
    // Hermes runs these module-loader tests; return true only when this backend must skip the suite.
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

test "modules: multi-binding export const publishes every name" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("m", "export const a = 1, b = 2;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src = "import { a, b } from 'm';\nglobalThis.__sum__ = a + b;";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__sum__");
    try testing.expectEqual(@as(i64, 3), got);
}

test "modules: imported binding rewritten in ternary consequent" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 9;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src = "import { value } from 'dep';\nexport const result = true ? value : 0;\nglobalThis.__result__ = result;";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 9), got);
}

test "modules: imported binding rewritten in compound ternary consequent" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Colon after a non-boundary operand must not be treated as a label (`1 + value : 0`).
    const src = "import { value } from 'dep';\nexport function read(){ return true ? 1 + value : 0; }\nglobalThis.__result__ = read();";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 43), got);
}

test "modules: named function import calls stay unbound" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Calling an imported function must not bind `this` to the module namespace.
    try ctx.modules.put("dep", "export function getThis() { return this; }");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src = "import { getThis } from 'dep';\nglobalThis.__this__ = getThis();";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    try helpers.expectEvalEquals(id, "globalThis.__this__ === undefined", "true");
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

test "modules: parenthesized arrow param shadows imported binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Parenthesized arrow params must bind before import rewriting (else `(0, ns.value)` in param position is a SyntaxError).
    const src = "import { value } from 'dep';\nexport const result = ((value) => value)(2);\nglobalThis.__result__ = result;";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 2), got);
}

test "modules: object method param shadows imported binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Method params must establish a ParamList scope (else `m((0, ns.value))` is a SyntaxError).
    const src = "import { value } from 'dep';\nexport const result = { m(value) { return value; } }.m(2);\nglobalThis.__result__ = result;";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 2), got);
}

test "modules: arrow body var does not steal imported binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Nested arrow `var` must not register on the enclosing function, or `return value` stops resolving to the import.
    const src = "import { value } from 'dep';\nexport function read() { const f = () => { var value = 2; }; return value; }\nglobalThis.__result__ = read();";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 42), got);
}

test "modules: object method body var does not steal imported binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Object-method `var` is a nested function environment; enclosing `return value` must keep the import.
    const src = "import { value } from 'dep';\nexport function read() { const o = { m() { var value = 2; } }; return value; }\nglobalThis.__result__ = read();";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 42), got);
}

test "modules: for-of iterable rewrites imported binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // for-of without initializer must still rewrite the iterable expression (not swallow it in declarator copy).
    const src = "import { value } from 'dep';\nexport function read(){ for(let x of [value]) { return x; } }\nglobalThis.__result__ = read();";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 42), got);
}

test "modules: imported binding rewritten in computed destructuring key" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Computed key `[value]` is an expression (must rewrite import); binding `x` stays local.
    const src = "import { value } from 'dep';\nexport function read(){ const {[value]: x} = {42: 7}; return x; }\nglobalThis.__result__ = read();";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 7), got);
}

test "modules: for-in right-hand side rewrites imported binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = { a: 7 };");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src = "import { value } from 'dep';\nexport function read(){ for(let k in value) { return value[k]; } }\nglobalThis.__result__ = read();";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 7), got);
}

test "modules: class method param shadows imported binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Class-body methods are Cont::ClassBody (not ObjectLit); params must still open ParamList so `value` is not rewritten to the import.
    const src = "import { value } from 'dep';\nexport const C = class { m(value) { return value; } };\nglobalThis.__result__ = new C().m(2);";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 2), got);
}

test "modules: named class method param shadows imported binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Named class declarations still schedule Cont::ClassBody for the following `{`; method params must open ParamList.
    const src = "import { value } from 'dep';\nclass C { m(value) { return value; } }\nglobalThis.__result__ = new C().m(2);";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 2), got);
}

test "modules: extends class method param shadows imported binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // `class C extends Object {…}` must still treat the body as Cont::ClassBody so method params are not rewritten to the import.
    const src = "import { value } from 'dep';\nclass C extends Object { m(value) { return value; } }\nglobalThis.__result__ = new C().m(2);";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 2), got);
}

test "modules: class method key after preceding method is not rewritten" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Class ASI lets a second method key follow a preceding method's `}` without a semicolon; that key must stay a name, not an import rewrite.
    const src = "import { value } from 'dep';\nexport const C = class { first() {} value() { return 2; } };\nglobalThis.__result__ = new C().value();";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 2), got);
}

test "modules: class field key is not rewritten to import" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Non-computed class field keys are names; only the initializer may reference the import.
    const src = "import {value} from 'dep';\nexport const C = class { value = 7; };\nglobalThis.__result__ = new C().value;";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 7), got);
}

test "modules: object method key after comment trivia is not rewritten" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // A block comment before an object method key must not turn the key into an import rewrite (`{/*c*/ value(){…}}`).
    const src = "import { value } from 'dep';\nexport function read(){ return {/*c*/ value(){ return 7; }}.value(); }\nglobalThis.__result__ = read();";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 7), got);
}

test "modules: compound param default rewrites imported binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Default-value expressions may reference imports throughout, not only the first ident after `=`.
    const src = "import { value } from 'dep';\nexport function read(x = 1 + value) { return x; }\nglobalThis.__result__ = read();";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const got = try helpers.evalInt(id, "globalThis.__result__");
    try testing.expectEqual(@as(i64, 43), got);
}

test "modules: later param shadows import in earlier default (TDZ)" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // All parameter bindings are in scope for every default initializer; `value` here is the later formal, not the import. A correct rewrite leaves `value` unbound until its parameter init (TDZ ReferenceError on engines that enforce it). Rewriting to the import would yield 42 instead.
    const src =
        \\import { value } from 'dep';
        \\export function read(){ return ((a = value, value = 2) => a)(); }
        \\try {
        \\  globalThis.__got__ = read();
        \\  globalThis.__threw__ = false;
        \\} catch (e) {
        \\  globalThis.__threw__ = true;
        \\  globalThis.__ref__ = e instanceof ReferenceError;
        \\}
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    // Native TDZ → ReferenceError; Hermes currently skips that TDZ but must still not resolve the import (42).
    try helpers.expectEvalEquals(id, "globalThis.__threw__ ? globalThis.__ref__ === true : globalThis.__got__ !== 42", "true");
}

test "modules: re-export dependency evaluates before module body" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "globalThis.order.push('dep'); export const value = 1;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "globalThis.order = []");
    // Native ESM loads static re-export deps before the entry body runs.
    const src = "globalThis.order.push('entry'); export { value } from 'dep';";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    try helpers.expectEvalEquals(id, "globalThis.order.join(',')", "dep,entry");
}

test "modules: ambiguous star re-export is omitted from namespace" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("a", "export const shared = 1; export const onlyA = 10;");
    try ctx.modules.put("b", "export const shared = 2; export const onlyB = 20;");
    try ctx.modules.put("barrel", "export * from 'a'; export * from 'b';");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import * as ns from 'barrel';
        \\globalThis.__onlyA__ = ns.onlyA;
        \\globalThis.__onlyB__ = ns.onlyB;
        \\globalThis.__hasShared__ = Object.prototype.hasOwnProperty.call(ns, 'shared');
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    try testing.expectEqual(@as(i64, 10), try helpers.evalInt(id, "globalThis.__onlyA__"));
    try testing.expectEqual(@as(i64, 20), try helpers.evalInt(id, "globalThis.__onlyB__"));
    try helpers.expectEvalEquals(id, "globalThis.__hasShared__", "false");
}

test "modules: function declaration shadows import for earlier references in the same scope" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Native ESM: a same-scope function declaration binds for the whole function body, including closures created before the declarator textually.
    const src =
        \\import { value } from 'dep';
        \\export function read() {
        \\  const before = () => value;
        \\  function value() { return 2; }
        \\  return before()();
        \\}
        \\globalThis.__result__ = read();
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 2), try helpers.evalInt(id, "globalThis.__result__"));
}

test "modules: named function expression does not shadow import in enclosing expression" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Named function expression binds only inside itself; the later `value` must resolve to the import.
    const src =
        \\import { value } from 'dep';
        \\export function read() {
        \\  return [function value() { return 2; }, value][1];
        \\}
        \\globalThis.__result__ = read();
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__result__"));
}

test "modules: named class expression does not shadow import in enclosing expression" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import { value } from 'dep';
        \\export function read() {
        \\  return [class value {}, value][1];
        \\}
        \\globalThis.__result__ = read();
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__result__"));
}

test "modules: regex initializer comma does not invent a local binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // A comma inside `/,value/` must not be treated as a declarator separator that registers `value` locally.
    const src =
        \\import { value } from 'dep';
        \\export function read() {
        \\  const re = /,value/;
        \\  return value;
        \\}
        \\globalThis.__result__ = read();
        \\globalThis.__re__ = String(/,value/);
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__result__"));
}

test "modules: top-level lexical bindings may use CJS wrapper param names" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Factory params must use collision-free internals so these module-body lexicals parse and export.
    const src =
        \\export const module = 42;
        \\export const exports = 7;
        \\export const require = 3;
        \\export const __filename = 11;
        \\export const __dirname = 13;
        \\globalThis.__module__ = module;
        \\globalThis.__exports__ = exports;
        \\globalThis.__require__ = require;
        \\globalThis.__filename_bind__ = __filename;
        \\globalThis.__dirname_bind__ = __dirname;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__module__"));
    try testing.expectEqual(@as(i64, 7), try helpers.evalInt(id, "globalThis.__exports__"));
    try testing.expectEqual(@as(i64, 3), try helpers.evalInt(id, "globalThis.__require__"));
    try testing.expectEqual(@as(i64, 11), try helpers.evalInt(id, "globalThis.__filename_bind__"));
    try testing.expectEqual(@as(i64, 13), try helpers.evalInt(id, "globalThis.__dirname_bind__"));
}

test "modules: exported CJS-param-named bindings are visible to importers" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("mod", "export const module = 42; export const exports = 7;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import { module, exports } from 'mod';
        \\globalThis.__module__ = module;
        \\globalThis.__exports__ = exports;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__module__"));
    try testing.expectEqual(@as(i64, 7), try helpers.evalInt(id, "globalThis.__exports__"));
}

test "modules: destructured param property key does not shadow import" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // `{value: x}` binds `x` only; the property key must not register `value` as a local that blocks the import rewrite.
    const src =
        \\import { value } from 'dep';
        \\export function read({ value: x }) { return value; }
        \\globalThis.__result__ = read({ value: 1 });
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__result__"));
}

test "modules: export quoted destructure key does not redefine binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    try withEmptyLoaderEngine(struct {
        fn run(id: i32, ctx: *TestLoaderCtx) !void {
            // Quoted key `"value"` is not a binding; only the binding after `:` is exported once (native ESM exports 42).
            try ctx.modules.put("m", "export const {\"value\": value} = {value: 42};");
            const res = engine.evalModule(id,
                \\import { value } from 'm';
                \\globalThis.__qv = value;
            , "<entry>");
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);
            try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__qv"));
        }
    }.run);
}

test "modules: export async function declaration" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("m", "export async function read(){ return 42; }");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import { read } from 'm';
        \\globalThis.__v__ = await read();
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__v__"));
}

test "modules: export default async function declaration" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("m", "export default async function read(){ return 7; }");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import read from 'm';
        \\globalThis.__v__ = await read();
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 7), try helpers.evalInt(id, "globalThis.__v__"));
}

test "modules: export binding named Object does not break export registration" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Generated export helpers must use a captured pristine Object.defineProperty, not a module-local `Object`.
    const src =
        \\export const Object = 42;
        \\globalThis.__object__ = Object;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__object__"));
}

test "modules: static import after same-line statement is extracted" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Top-level import after another statement on the same physical line must still be hoisted out of the generated wrapper body.
    const src = "const local = 1; import { value } from 'dep'; export const answer = local + value;\nglobalThis.__result__ = answer;";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 43), try helpers.evalInt(id, "globalThis.__result__"));
}

test "modules: static import after same-line block declaration is extracted" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Top-level import after a same-line closed function/class declaration must still be collected (no required `;`/newline before `import`).
    const src = "export function read(){return value;} import {value} from 'dep';\nglobalThis.__result__ = read();";
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__result__"));
}

test "modules: regex literal after braced if-statement is not rewritten as import" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // After `if (…) {}`, `/value/` must stay a RegExp (not become an import member reference).
    const src =
        \\import { value } from 'dep';
        \\export function read() {
        \\  let hit = false;
        \\  if (true) {}
        \\  /value/.test('value') && (hit = true);
        \\  return hit && value === 42;
        \\}
        \\globalThis.__result__ = read();
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try helpers.expectEvalEquals(id, "globalThis.__result__", "true");
}

test "modules: regex initializer does not publish a ghost export name" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    try ctx.modules.put("mod", "export const pattern = /,ghost/;");
    const src =
        \\import * as ns from 'mod';
        \\globalThis.__hasPattern__ = Object.prototype.hasOwnProperty.call(ns, 'pattern');
        \\globalThis.__hasGhost__ = Object.prototype.hasOwnProperty.call(ns, 'ghost');
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try helpers.expectEvalEquals(id, "globalThis.__hasPattern__", "true");
    try helpers.expectEvalEquals(id, "globalThis.__hasGhost__", "false");
}

test "modules: diamond star re-export keeps a shared originating binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("base", "export const shared = 7;");
    try ctx.modules.put("a", "export * from 'base';");
    try ctx.modules.put("b", "export * from 'base';");
    try ctx.modules.put("barrel", "export * from 'a'; export * from 'b';");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import * as ns from 'barrel';
        \\globalThis.__shared__ = ns.shared;
        \\globalThis.__hasShared__ = Object.prototype.hasOwnProperty.call(ns, 'shared');
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try helpers.expectEvalEquals(id, "globalThis.__hasShared__", "true");
    try testing.expectEqual(@as(i64, 7), try helpers.evalInt(id, "globalThis.__shared__"));
}

test "modules: diamond named re-export keeps a shared originating binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("base", "export const value = 42;");
    try ctx.modules.put("left", "export { value } from 'base';");
    try ctx.modules.put("right", "export { value } from 'base';");
    try ctx.modules.put("hub", "export * from 'left'; export * from 'right';");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import * as ns from 'hub';
        \\globalThis.__value__ = ns.value;
        \\globalThis.__hasValue__ = Object.prototype.hasOwnProperty.call(ns, 'value');
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try helpers.expectEvalEquals(id, "globalThis.__hasValue__", "true");
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__value__"));
}

test "modules: diamond import-then-export keeps a shared originating binding" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Branches import a named binding then re-export it locally.
    //
    // Hermes, bellard QuickJS, and JSC track leaf origin across import-then-export so star-merge keeps the shared binding.
    //
    // ECMA-262 ResolveExport for LocalExportEntries returns {module: exporter, bindingName: local} without following import provenance, so quickjs_ng treats the diamond as ambiguous and omits the name.
    try ctx.modules.put("base", "export const value = 42;");
    try ctx.modules.put("left", "import { value } from 'base'; export { value };");
    try ctx.modules.put("right", "import { value } from 'base'; export { value };");
    try ctx.modules.put("hub", "export * from 'left'; export * from 'right';");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import * as ns from 'hub';
        \\globalThis.__value__ = ns.value;
        \\globalThis.__hasValue__ = Object.prototype.hasOwnProperty.call(ns, 'value');
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);

    const keeps_shared_binding = comptime switch (backend.active_backend) {
        // Hermes leaf-origin WeakMap; bellard QuickJS and JSC follow import provenance for star ambiguity.
        .hermes, .quickjs, .jsc => true,
        // Spec-shaped LocalExportEntries identity: exporter module, so the diamond is ambiguous.
        else => false,
    };
    if (keeps_shared_binding) {
        try helpers.expectEvalEquals(id, "globalThis.__hasValue__", "true");
        try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__value__"));
    } else {
        try helpers.expectEvalEquals(id, "globalThis.__hasValue__", "false");
    }
}

test "modules: named import alias accepts newline around as" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Newline (and not only a single space) may separate the imported name from `as`.
    const src =
        \\import {value
        \\as local} from 'dep';
        \\export function read(){return local;}
        \\globalThis.__read__ = read();
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__read__"));
}

test "modules: named import skips comments inside specifier list" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Default + named: dep must export both; this path is what exercises comment trivia in `{…}`.
    try ctx.modules.put("dep", "export default 7; export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Comment trivia inside `{…}` must not become part of the binding name (default+named path too).
    const src =
        \\import def, { /* comment */ value } from 'dep';
        \\export function read(){return value;}
        \\globalThis.__read__ = read();
        \\globalThis.__def__ = def;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__read__"));
    try testing.expectEqual(@as(i64, 7), try helpers.evalInt(id, "globalThis.__def__"));
}

test "modules: member access after comment is not rewritten as import" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 1;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // `obj./*c*/value` is a property access; `value` must not become the import binding rewrite.
    const src =
        \\import { value } from 'dep';
        \\const obj = { value: 7 };
        \\export function read(){ return obj./*c*/value; }
        \\globalThis.__read__ = read();
        \\globalThis.__import__ = value;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 7), try helpers.evalInt(id, "globalThis.__read__"));
    try testing.expectEqual(@as(i64, 1), try helpers.evalInt(id, "globalThis.__import__"));
}

test "modules: semicolon-free export const respects ASI between declarations" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // First `export const` must not swallow `c` from the next declaration's declarator list.
    const src =
        \\export const a = 1
        \\export const b = 2, c = 3;
        \\globalThis.__a__ = a;
        \\globalThis.__b__ = b;
        \\globalThis.__c__ = c;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 1), try helpers.evalInt(id, "globalThis.__a__"));
    try testing.expectEqual(@as(i64, 2), try helpers.evalInt(id, "globalThis.__b__"));
    try testing.expectEqual(@as(i64, 3), try helpers.evalInt(id, "globalThis.__c__"));
}

test "modules: ASI across block comment with LineTerminator between export consts" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // LineTerminator inside `/*…*/` still ends the first declarator list for ASI; `c` belongs to the second declaration.
    const src =
        \\export const a=1/*
        \\*/export const b=2,c=3;
        \\globalThis.__a__ = a;
        \\globalThis.__b__ = b;
        \\globalThis.__c__ = c;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 1), try helpers.evalInt(id, "globalThis.__a__"));
    try testing.expectEqual(@as(i64, 2), try helpers.evalInt(id, "globalThis.__b__"));
    try testing.expectEqual(@as(i64, 3), try helpers.evalInt(id, "globalThis.__c__"));
}

test "modules: generated import ns name avoids colliding with module bindings" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const value = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // User binding `__jsbay_ns0` must not clash with the transform's first import namespace local.
    const src =
        \\import {value} from 'dep';
        \\const __jsbay_ns0 = 7;
        \\export const result = value + __jsbay_ns0;
        \\globalThis.__result__ = result;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 49), try helpers.evalInt(id, "globalThis.__result__"));
}

test "modules: diamond renamed re-exports of distinct bindings stay ambiguous" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Same source module, different leaf bindings forwarded under one export name must omit that name (native ESM).
    try ctx.modules.put("base", "export const a = 1; export const b = 2;");
    try ctx.modules.put("left", "export { a as value } from 'base';");
    try ctx.modules.put("right", "export { b as value } from 'base';");
    try ctx.modules.put("hub", "export * from 'left'; export * from 'right';");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import * as ns from 'hub';
        \\globalThis.__hasValue__ = Object.prototype.hasOwnProperty.call(ns, 'value');
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try helpers.expectEvalEquals(id, "globalThis.__hasValue__", "false");
}

test "modules: star re-export forwards renamed named re-export" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Lookup must use the immediate star source (left.renamed), not the leaf provenance namespace (base.renamed).
    try ctx.modules.put("base", "export const original = 42;");
    try ctx.modules.put("left", "export { original as renamed } from 'base';");
    try ctx.modules.put("hub", "export * from 'left';");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import * as ns from 'hub';
        \\globalThis.__renamed__ = ns.renamed;
        \\globalThis.__hasRenamed__ = Object.prototype.hasOwnProperty.call(ns, 'renamed');
        \\globalThis.__hasOriginal__ = Object.prototype.hasOwnProperty.call(ns, 'original');
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try helpers.expectEvalEquals(id, "globalThis.__hasRenamed__", "true");
    try helpers.expectEvalEquals(id, "globalThis.__hasOriginal__", "false");
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__renamed__"));
}

test "modules: default export named generator function" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("m", "export default function* gen(){ yield 42; }");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import g from 'm';
        \\globalThis.__v__ = g().next().value;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__v__"));
}

test "modules: default export anonymous generator function" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("m", "export default function*(){ yield 7; }");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import g from 'm';
        \\globalThis.__v__ = g().next().value;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 7), try helpers.evalInt(id, "globalThis.__v__"));
}

test "modules: circular imports do not deadlock" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Classic A↔B cycle. Escargot leaves the reverse *named* import of a function in TDZ even after evaluation, so bPlusA must not call aFn — the unused import still establishes the cycle; aPlusB proves the forward cross-call. Calls run after evalModule (top-level calls during linking hit TDZ).
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

test "modules: top-level await settles setTimeout(0) promise" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    // Hermes-only: sync TLA host-progress pump must arm+dispatch timers; other backends settle TLA via their own event-loop drain.
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try withEmptyLoaderEngine(struct {
        fn run(id: i32, ctx: *TestLoaderCtx) !void {
            _ = ctx;
            // Host timer must arm+dispatch during sync TLA pump (not only drain an empty ready queue).
            const res = engine.evalModule(id,
                \\globalThis.__tla_timer = 'before';
                \\await new Promise(function (resolve) { setTimeout(resolve, 0); });
                \\globalThis.__tla_timer = 'done';
            , "<entry>");
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);
            try helpers.expectEvalEquals(id, "globalThis.__tla_timer", "done");
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

test "modules: circular lexical export visible during cycle" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // A reads get() from B while still evaluating; B reads A's lexical `x` mid-init. Native ESM yields y=42.
    try ctx.modules.put("a",
        \\import {get} from 'b';
        \\export const x = 42;
        \\export const y = get();
    );
    try ctx.modules.put("b",
        \\import {x} from 'a';
        \\export function get(){ return x; }
    );

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const res = engine.evalModule(id, "import {y} from 'a'; globalThis.__y__ = y;", "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__y__"));
}

test "modules: object method named import is not rewritten as dynamic import" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\export const o = { import(name){ return name; } };
        \\globalThis.__v__ = o.import('ok');
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try helpers.expectEvalEquals(id, "globalThis.__v__", "ok");
}

test "modules: dynamic import specifier evaluates in original context" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Relative form so JSC accepts a runtime-computed specifier (bare names fail its built-in check before the loader runs). Register both keys: QuickJS keeps "./first"; JSC resolves URL-relative to "first".
    const first_src = "export const value = 1;";
    const second_src = "export const value = 2;";
    try ctx.modules.put("./first", first_src);
    try ctx.modules.put("first", first_src);
    try ctx.modules.put("./second", second_src);
    try ctx.modules.put("second", second_src);

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Specifier must be captured when import() runs, not when the deferred require runs.
    //
    // Use "./…" rather than a bare name: JSC has no public resolve hook, so only relative/absolute runtime specifiers reach the module loader.
    const src =
        \\let name = './first';
        \\const p = import(name);
        \\name = './second';
        \\const mod = await p;
        \\globalThis.__v__ = mod.value;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 1), try helpers.evalInt(id, "globalThis.__v__"));
}

test "modules: ESM factory uses captured Object when global Object is replaced" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const answer = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Replace page Object before loading a module that registers exports via Object.defineProperty.
    _ = engine.evalScript(id, "globalThis.Object = function(){};", "patch-object.js");
    const res = engine.evalModule(id, "import {answer} from 'dep'; globalThis.__v__ = answer;", "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__v__"));
}

test "modules: ESM factory uses captured defineProperty when Object.defineProperty is replaced" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const answer = 42;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    // Poison only Object.defineProperty; the constructor object remains but its method slot is replaced.
    _ = engine.evalScript(id, "Object.defineProperty = function(){};", "patch-defineProperty.js");
    const res = engine.evalModule(id, "import {answer} from 'dep'; globalThis.__v__ = answer;", "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__v__"));
}

test "modules: user export named __jsbay_star_origin does not break star re-export" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    // Hermes-only: star provenance must not live on the export namespace under a reserved string key.
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const x = 7;");
    try ctx.modules.put("mid", "export const __jsbay_star_origin = 1; export * from 'dep';");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const src =
        \\import * as ns from 'mid';
        \\globalThis.__x__ = ns.x;
        \\globalThis.__origin_export__ = ns.__jsbay_star_origin;
    ;
    const res = engine.evalModule(id, src, "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 7), try helpers.evalInt(id, "globalThis.__x__"));
    try testing.expectEqual(@as(i64, 1), try helpers.evalInt(id, "globalThis.__origin_export__"));
}

test "modules: local export-list is visible to cyclic importer" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    // Hermes-only: ESM→CJS transform must hoist local `export {f}` like `export function f` for cyclic importers.
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // `export {f}` must hoist like `export function f` so B can call f while A is still evaluating.
    try ctx.modules.put("a", "import 'b'; function f(){ return 42; } export { f };");
    try ctx.modules.put("b", "import { f } from 'a'; globalThis.__cyclic_f__ = f();");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const res = engine.evalModule(id, "import 'a';", "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.__cyclic_f__"));
}

test "modules: missing named import is rejected before importer body" {
    if (hermesModulesUnsupported()) return error.SkipZigTest;
    // Hermes-only: transform must SyntaxError missing named imports during link, before the importer body runs.
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    var ctx = TestLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "export const present = 1;");

    const loader = types.ModuleLoader{ .vtable = &test_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);

    const res = engine.evalModule(id, "import { missing } from 'dep'; globalThis.__ran__ = 1;", "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err != null);
    const err = res.err.?;
    try testing.expect(std.mem.indexOf(u8, err, "missing") != null);
    // Importer body must not run after a failed named-import link.
    try testing.expectEqual(@as(i64, 0), try helpers.evalInt(id, "globalThis.__ran__ === 1 ? 1 : 0"));
}
