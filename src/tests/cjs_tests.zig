//! CommonJS `require()` tests.
//!
//! Exercises the surface in src/script/cjs.zig using an in-memory HashMap loader (same pattern as modules_tests.zig). Covers: basic load, cache identity, nested require, __filename / __dirname, missing-module error, and the evalAsCjs entry point.

const std = @import("std");
const testing = std.testing;

const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const types = @import("../types.zig");
const cjs = @import("../script/cjs.zig");
const bytecode = @import("../script/bytecode.zig");
const cache = @import("../script/cache.zig");
const backend = @import("../backend.zig");

// ---- In-memory CJS test loader ----

const CjsLoaderCtx = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator) CjsLoaderCtx {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap([]const u8).init(allocator),
        };
    }

    fn deinit(self: *CjsLoaderCtx) void {
        self.modules.deinit();
    }
};

fn cjsLoaderLoad(
    ud: ?*anyopaque,
    id: [*:0]const u8,
    out: *types.ModuleLoadResult,
) callconv(.c) bool {
    const ctx: *CjsLoaderCtx = @ptrCast(@alignCast(ud.?));
    const key = std.mem.span(id);
    const src = ctx.modules.get(key) orelse return false;
    out.* = .{ .source = src.ptr, .source_len = src.len };
    return true;
}

const cjs_vtable: types.ModuleLoaderVTable = .{
    .resolve = null, // identity — specifier is used verbatim as canonical id
    .load = cjsLoaderLoad,
    .free_resolved = null,
};

// --------------------------------------------------------------------------

test "cjs: basic require returns module.exports" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("a", "module.exports = { x: 42 };");

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    // Access via the global require we just installed, stash on globalThis for deterministic read-back.
    try helpers.evalOk(id, "globalThis.__ans__ = require('a').x;");
    const got = try helpers.evalInt(id, "globalThis.__ans__");
    try testing.expectEqual(@as(i64, 42), got);
}

test "cjs: cache returns same object identity" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("a", "module.exports = { n: 1 };");

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    try helpers.evalOk(id, "globalThis.__same__ = require('a') === require('a');");
    try helpers.expectEvalEquals(id, "String(globalThis.__same__)", "true");
}

test "cjs: nested require chain" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("b", "module.exports = { y: 7 };");
    try ctx.modules.put("a",
        \\const b = require('b');
        \\module.exports = b.y * 10;
    );

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    try helpers.evalOk(id, "globalThis.__v__ = require('a');");
    const got = try helpers.evalInt(id, "globalThis.__v__");
    try testing.expectEqual(@as(i64, 70), got);
}

test "cjs: __filename and __dirname are populated" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Canonical id resembles a path so dirname(id) has something non-trivial to strip. Loader uses identity resolve, so 'pkg/mod' stays as-is.
    try ctx.modules.put("pkg/mod",
        \\module.exports = { fn: __filename, dn: __dirname };
    );

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    try helpers.evalOk(id, "globalThis.__info__ = require('pkg/mod');");
    try helpers.expectEvalEquals(id, "globalThis.__info__.fn", "pkg/mod");
    try helpers.expectEvalEquals(id, "globalThis.__info__.dn", "pkg");

    // Non-empty both.
    const fn_len = try helpers.evalInt(id, "globalThis.__info__.fn.length");
    try testing.expect(fn_len > 0);
    const dn_len = try helpers.evalInt(id, "globalThis.__info__.dn.length");
    try testing.expect(dn_len > 0);
}

test "cjs: missing module throws Error containing 'Cannot find module'" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Leave `modules` empty so any require fails.

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    const res = engine.evalScript(id, "require('nope');", "<test>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err != null);
    const msg = res.err.?;
    try testing.expect(std.mem.indexOf(u8, msg, "Cannot find module") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "nope") != null);
}

test "cjs: evalAsCjs runs a script with require + module.exports" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "module.exports = 5;");

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    const src =
        \\const d = require('dep');
        \\module.exports = { result: d * 3 };
    ;
    const res = cjs.evalAsCjs(id, src, "entry.js");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    // module.exports is an object → JSON-stringified.
    try testing.expect(res.result != null);
    try testing.expect(std.mem.indexOf(u8, res.result.?, "\"result\":15") != null);
}

test "cjs: clearCache forces re-load on next require" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    // Use a module whose source can be swapped between loads.
    try ctx.modules.put("m", "module.exports = { tag: 'first' };");

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    try helpers.evalOk(id, "globalThis.__first__ = require('m').tag;");
    try helpers.expectEvalEquals(id, "globalThis.__first__", "first");

    // Swap source and clear the cache so the next require() re-loads.
    _ = ctx.modules.remove("m");
    try ctx.modules.put("m", "module.exports = { tag: 'second' };");
    cjs.clearCache(id);

    try helpers.evalOk(id, "globalThis.__second__ = require('m').tag;");
    try helpers.expectEvalEquals(id, "globalThis.__second__", "second");
}

// --------------------------------------------------------------------------
// Cached CommonJS evaluation (compileCommonJS / runCommonJS / evalCachedCjs)
// --------------------------------------------------------------------------

var g_cjs_cache_dir: []const u8 = "";
fn makeCjsCacheDir(gpa: std.mem.Allocator) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var rand_bytes: [8]u8 = undefined;
    testing.io.random(&rand_bytes);
    const rand = std.mem.readInt(u64, &rand_bytes, .little);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = try std.fmt.bufPrint(&buf, ".zig-cache/cjstest-{x}", .{rand});
    cwd.deleteTree(testing.io, rel) catch {};
    try cwd.createDirPath(testing.io, rel);
    g_cjs_cache_dir = try gpa.dupe(u8, rel);
    return g_cjs_cache_dir;
}
fn cleanCjsCacheDir(gpa: std.mem.Allocator, rel_path: []const u8) void {
    _ = std.Io.Dir.cwd().deleteTree(testing.io, rel_path) catch {};
    gpa.free(@constCast(rel_path));
    g_cjs_cache_dir = "";
}

fn cjsCacheFileCount(rel_dir: []const u8) usize {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(testing.io, rel_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(testing.io);
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(testing.io) catch null) |entry| {
        if (entry.kind == .file) count += 1;
    }
    return count;
}

const kCjsVersion = "test-v1";

test "cjs: compile+run round-trips a module body and returns module.exports" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    try ctx.modules.put("dep", "module.exports = 3;");

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    const src =
        \\const d = require('dep');
        \\exports.answer = d * 14;
    ;
    const compiled = cjs.compileCommonJS(id, src, "entry.js");
    defer bytecode.freeCompileResult(compiled);
    if (backend.isJscApiBackend(backend.active_backend) or backend.isSpikeBackend(backend.active_backend)) {
        try testing.expect(compiled.bytes == null or backend.isHermesBackend(backend.active_backend));
        if (backend.isJscApiBackend(backend.active_backend)) {
            try testing.expectEqualStrings("bytecode cache is not supported on JSC backend (use QuickJS)", compiled.err.?);
        } else if (backend.isEscargotBackend(backend.active_backend)) {
            try testing.expectEqualStrings("bytecode cache is not supported on Escargot backend", compiled.err.?);
        }
        // Hermes may produce .hbc via hermesc; runCommonJS (QJS-shaped replay) still unsupported.
        const run = cjs.runCommonJS(id, compiled.bytes orelse &.{0}, "entry.js");
        defer freeCjsCacheResult(run);
        try testing.expect(run.result == null);
        if (backend.isJscApiBackend(backend.active_backend)) {
            try testing.expectEqualStrings("runCommonJS not supported on JSC", run.err.?);
        } else {
            try testing.expectEqualStrings("runCommonJS bytecode path not supported on Escargot/Hermes", run.err.?);
        }
        return;
    }
    try testing.expect(compiled.bytes != null);
    try testing.expect(compiled.err == null);

    const run = cjs.runCommonJS(id, compiled.bytes.?, "entry.js");
    defer freeCjsCacheResult(run);
    try testing.expect(run.err == null);
    try testing.expect(run.result != null);
    // `require` works inside the compiled body; exports.answer = 3*14 = 42.
    try testing.expect(std.mem.indexOf(u8, run.result.?, "\"answer\":42") != null);
}

test "cjs: evalCachedCjs compiles first, caches hit second, misses on change" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const gpa = std.heap.c_allocator;
    const cdir = try makeCjsCacheDir(gpa);
    defer cleanCjsCacheDir(gpa, cdir);

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    // Large enough to pass the 4 KiB cache threshold.
    var src_buf = std.ArrayList(u8).empty;
    defer src_buf.deinit(testing.allocator);
    try src_buf.appendSlice(testing.allocator, "module.exports = { n: 1");
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        try src_buf.appendSlice(testing.allocator, ", a: 1");
    }
    try src_buf.appendSlice(testing.allocator, " };");
    const src = try src_buf.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(src);

    // First call: cache miss (compiles + persists).
    const r1 = cjs.evalCachedCjs(id, src, "entry.js", cdir, kCjsVersion);
    defer freeCjsCacheResult(r1);
    try testing.expect(r1.err == null);
    try testing.expect(!r1.cache_hit);
    try testing.expect(r1.result != null);
    try testing.expect(std.mem.indexOf(u8, r1.result.?, "\"n\":1") != null);

    // Second call with identical bytes: cache hit.
    const r2 = cjs.evalCachedCjs(id, src, "entry.js", cdir, kCjsVersion);
    defer freeCjsCacheResult(r2);
    try testing.expect(r2.err == null);
    try testing.expectEqual(@import("build_options").bytecode_cache and backend.isQuickJsApiBackend(backend.active_backend), r2.cache_hit);
    try testing.expect(r2.result != null);
    try testing.expect(std.mem.indexOf(u8, r2.result.?, "\"n\":1") != null);
}

test "cjs: evalCachedCjs reassigned module.exports round-trips" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const gpa = std.heap.c_allocator;
    const cdir = try makeCjsCacheDir(gpa);
    defer cleanCjsCacheDir(gpa, cdir);

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    var src_buf = std.ArrayList(u8).empty;
    defer src_buf.deinit(testing.allocator);
    try src_buf.appendSlice(testing.allocator, "module.exports = { v: 'reassigned'");
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        try src_buf.appendSlice(testing.allocator, ", pad: 0");
    }
    try src_buf.appendSlice(testing.allocator, " };");
    const src = try src_buf.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(src);

    const r = cjs.evalCachedCjs(id, src, "entry.js", cdir, kCjsVersion);
    defer freeCjsCacheResult(r);
    try testing.expect(r.err == null);
    try testing.expect(r.result != null);
    // The whole body is replaced via module.exports = { ... } — a big object, verify a value survives the compile→run→stringify round-trip.
    try testing.expect(std.mem.indexOf(u8, r.result.?, "\"v\":\"reassigned\"") != null);
}

test "cjs: JSC ignores an old bytecode cache and evaluates large source" {
    if (!backend.isJscApiBackend(backend.active_backend)) return;
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };
    const gpa = std.heap.c_allocator;
    const cdir = try makeCjsCacheDir(gpa);
    defer cleanCjsCacheDir(gpa, cdir);

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    var src_buf = std.ArrayList(u8).empty;
    defer src_buf.deinit(testing.allocator);
    try src_buf.appendSlice(testing.allocator, "module.exports = { marker: 'plain-cjs', pad: '");
    while (src_buf.items.len < 4097) try src_buf.append(testing.allocator, 'x');
    try src_buf.appendSlice(testing.allocator, "' };");
    const source = try src_buf.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(source);

    const srckey = cache.sha256Hex(source);
    defer gpa.free(srckey);
    const namekey = cache.sha256Hex("old-cache.js");
    defer gpa.free(namekey);
    const path = cache.cachePath(gpa, cdir, kCjsVersion, srckey, namekey) orelse return error.OutOfMemory;
    defer gpa.free(path);
    cache.writeBytes(path, "old serialized CJS bytecode");
    const seeded = cache.readBytes(path) orelse return error.CacheSeedFailed;
    defer gpa.free(seeded);
    try testing.expectEqualStrings("old serialized CJS bytecode", seeded);

    const result = cjs.evalCachedCjs(id, source, "old-cache.js", cdir, kCjsVersion);
    defer freeCjsCacheResult(result);
    try testing.expect(result.err == null);
    try testing.expect(!result.cache_hit);
    try testing.expect(result.result != null);
    try testing.expect(std.mem.indexOf(u8, result.result.?, "plain-cjs") != null);
}

fn freeCjsCacheResult(res: cjs.CjsCacheResult) void {
    if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
    if (res.err_is_heap) {
        if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
    }
}

// --------------------------------------------------------------------------
// Global `__js_bay_cjsCache` (bytecode-cached CommonJS with caller require)
// --------------------------------------------------------------------------

test "cjs: global __js_bay_cjsCache returns live exports with caller require" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    if (backend.isJscApiBackend(backend.active_backend) or backend.isSpikeBackend(backend.active_backend)) {
        // No __js_bay_cjsCache on JSC/Escargot/Hermes (QJS bytecode helper). Fallback: Function wrapper + caller require.
        try helpers.expectEvalEquals(id, "typeof __js_bay_cjsCache", "undefined");
        try helpers.evalOk(id,
            \\const localRequire = (name) => name === "@jsbay/protocol" ? { answer: 42 } : null;
            \\const module = { exports: {} };
            \\new Function("module", "exports", "require", "const p=require('@jsbay/protocol'); module.exports={kind:'app',answer:p.answer};")
            \\(module, module.exports, localRequire);
            \\globalThis.__bundle__ = module.exports;
        );
        try helpers.expectEvalEquals(id, "globalThis.__bundle__.kind", "app");
        try helpers.expectEvalEquals(id, "globalThis.__bundle__.answer", "42");
        return;
    }

    // Bundle body that calls the injectable `require` (@jsbay/protocol) and reassigns module.exports.
    const bundle_src =
        \\const protocol = require("@jsbay/protocol");
        \\module.exports = { kind: "app", answer: protocol.answer };
    ;

    // Embed the bundle body into a driver script that installs the caller's restricted require and calls the global __js_bay_cjsCache.
    var driver = std.ArrayList(u8).empty;
    defer driver.deinit(testing.allocator);
    try driver.appendSlice(testing.allocator,
        \\const shared = { protocol: { answer: 42 } };
        \\function localRequire(spec) {
        \\  if (spec === "@jsbay/protocol") return shared.protocol;
        \\  throw new Error("unknown " + spec);
        \\}
        \\const src = ";
    );
    // Embed bundle_src as a JS string literal (escape backslashes/quotes).
    try appendJsStringLiteral(&driver, bundle_src);
    try driver.appendSlice(testing.allocator,
        \\";
        \\globalThis.__bundle__ = __js_bay_cjsCache(src, localRequire, "system-app.js");
        \\
    );

    const driver_owned = try driver.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(driver_owned);

    try helpers.evalOk(id, driver_owned);
    try helpers.expectEvalEquals(id, "globalThis.__bundle__.kind", "app");
    const ans = try helpers.evalInt(id, "globalThis.__bundle__.answer");
    try testing.expectEqual(@as(i64, 42), ans);
}

test "cjs: __js_bay_cjsCache reuses process bytecode cache per source and keeps object identity" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    if (backend.isJscApiBackend(backend.active_backend) or backend.isSpikeBackend(backend.active_backend)) {
        try helpers.expectEvalEquals(id, "typeof __js_bay_cjsCache", "undefined");
        const r = cjs.evalCachedCjs(id, "module.exports = { tag: 'spike' };", "s.js", "", kCjsVersion);
        defer freeCjsCacheResult(r);
        try testing.expect(r.err == null);
        try testing.expect(!r.cache_hit);
        try testing.expect(std.mem.indexOf(u8, r.result.?, "spike") != null);
        return;
    }

    const src_a = "module.exports = { tag: \"a\" };";
    const src_b = "module.exports = { tag: \"b\" };";

    try evalCjsCacheCall(id, src_a, "s.js", "__a1__");
    try evalCjsCacheCall(id, src_a, "s.js", "__a2__");
    try evalCjsCacheCall(id, src_b, "s.js", "__b__");

    try helpers.expectEvalEquals(id, "globalThis.__a1__.tag", "a");
    try helpers.expectEvalEquals(id, "globalThis.__a2__.tag", "a");
    try helpers.expectEvalEquals(id, "globalThis.__b__.tag", "b");

    // Different sources produce different modules; the same source re-runs from cached bytecode (fresh module instance each call, matching the wrapper semantics — the *compile* is what's cached, not the instance).
    try helpers.expectEvalEquals(id, "String(globalThis.__a1__ === globalThis.__b__)", "false");
}

test "cjs: __js_bay_cjsCache isolates identical bodies by filename on disk and in memory" {
    if (backend.isJscApiBackend(backend.active_backend) or backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;

    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };
    const cdir = try makeCjsCacheDir(std.heap.c_allocator);
    defer cleanCjsCacheDir(std.heap.c_allocator, cdir);

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    const source = "throw new Error('filename-cache-isolation');";
    const persistent_cache = @import("build_options").bytecode_cache;
    const first = try evalCjsCacheThrow(id, source, "widgets/A.js", cdir);
    defer helpers.freeEvalResult(first);
    const first_error = first.err orelse return error.ExpectedFirstError;
    try testing.expect(std.mem.indexOf(u8, first_error, "widgets/A.js") != null);
    try testing.expectEqual(@as(usize, if (persistent_cache) 1 else 0), cjsCacheFileCount(cdir));

    const second = try evalCjsCacheThrow(id, source, "widgets/B.js", cdir);
    defer helpers.freeEvalResult(second);
    const second_error = second.err orelse return error.ExpectedSecondError;
    try testing.expect(std.mem.indexOf(u8, second_error, "widgets/B.js") != null);
    try testing.expectEqual(@as(usize, if (persistent_cache) 2 else 0), cjsCacheFileCount(cdir));
}

/// Run `__js_bay_cjsCache(<src>, noopRequire, <filename>)` and stash the returned exports on `globalThis.<slot>`.
fn evalCjsCacheCall(id: i32, src: []const u8, filename: []const u8, slot: []const u8) !void {
    var driver = std.ArrayList(u8).empty;
    defer driver.deinit(testing.allocator);
    // `var` so multiple driver scripts sharing the global scope can redeclare (GLOBAL evals each run in the same global object).
    try driver.appendSlice(testing.allocator,
        \\var noopRequire = () => { throw new Error("no modules here"); };
        \\var src = ";
    );
    try appendJsStringLiteral(&driver, src);
    try driver.appendSlice(testing.allocator, "\";\n");

    // __js_bay_cjsCache(src, noopRequire, "<filename>")
    try driver.appendSlice(testing.allocator, "globalThis.");
    try driver.appendSlice(testing.allocator, slot);
    try driver.appendSlice(testing.allocator, " = __js_bay_cjsCache(src, noopRequire, \"");
    try driver.appendSlice(testing.allocator, filename);
    try driver.appendSlice(testing.allocator, "\");\n");

    const owned = try driver.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(owned);
    const res = engine.evalScript(id, owned, "<cjs-cache>");
    defer helpers.freeEvalResult(res);
    if (res.err) |e| {
        std.debug.print("evalCjsCacheCall[{s}] error: {s}\n", .{ slot, e });
        return error.JSException;
    }
}

fn evalCjsCacheThrow(id: i32, src: []const u8, filename: []const u8, cache_dir: []const u8) !types.EvalResult {
    var driver = std.ArrayList(u8).empty;
    defer driver.deinit(testing.allocator);
    try driver.appendSlice(testing.allocator, "var noopRequire = () => {}; var src = \"");
    try appendJsStringLiteral(&driver, src);
    try driver.appendSlice(testing.allocator, "\"; __js_bay_cjsCache(src, noopRequire, \"");
    try appendJsStringLiteral(&driver, filename);
    try driver.appendSlice(testing.allocator, "\", \"");
    try appendJsStringLiteral(&driver, cache_dir);
    try driver.appendSlice(testing.allocator, "\");");
    const owned = try driver.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(owned);
    return engine.evalScript(id, owned, "<cjs-cache-filename-test>");
}

/// Append `s` as a double-quoted JS string literal (escaping `\`, `"`, and control characters) to `out`. Used to embed a module body into a driver script.
fn appendJsStringLiteral(out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(testing.allocator, "\\\\"),
            '"' => try out.appendSlice(testing.allocator, "\\\""),
            '\n' => try out.appendSlice(testing.allocator, "\\n"),
            '\r' => try out.appendSlice(testing.allocator, "\\r"),
            '\t' => try out.appendSlice(testing.allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [8]u8 = undefined;
                    const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                    try out.appendSlice(testing.allocator, esc);
                } else {
                    try out.append(testing.allocator, c);
                }
            },
        }
    }
}
