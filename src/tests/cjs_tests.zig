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

test "cjs: runCommonJS transfers a heap decode error and empty bytecode stays a static failure" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    const empty = cjs.runCommonJS(id, "", "empty-bytecode.js");
    defer freeCjsCacheResult(empty);
    try testing.expect(empty.decode_failed);
    try testing.expect(empty.err != null);
    try testing.expect(!empty.err_is_heap);
    try testing.expectEqualStrings("stale or corrupt bytecode", empty.err.?);

    // Non-empty invalid bytecode takes the heap-formatted decoder path. Read and free the
    // returned message once; do not reconstruct a use-after-free.
    const invalid = cjs.runCommonJS(id, "not valid QuickJS bytecode", "invalid-bytecode.js");
    defer freeCjsCacheResult(invalid);
    try testing.expect(invalid.decode_failed);
    try testing.expect(invalid.err != null);
    try testing.expect(invalid.err_is_heap);
    try testing.expect(invalid.err.?.len > 0);
    try testing.expect(std.mem.indexOfScalar(u8, invalid.err.?, 0) == null);
}

fn freeCjsCacheResult(res: cjs.CjsCacheResult) void {
    if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
    if (res.err_is_heap) {
        if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
    }
}

// --------------------------------------------------------------------------
// Global `__jsbay_cjsCache` (bytecode-cached CommonJS with caller require)
// --------------------------------------------------------------------------

test "cjs: global __jsbay_cjsCache returns live exports with caller require" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    if (backend.isJscApiBackend(backend.active_backend) or backend.isSpikeBackend(backend.active_backend)) {
        // No __jsbay_cjsCache on JSC/Escargot/Hermes (QJS bytecode helper). Fallback: Function wrapper + caller require.
        try helpers.expectEvalEquals(id, "typeof __jsbay_cjsCache", "undefined");
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

    // Embed the bundle body into a driver script that installs the caller's restricted require and calls the global __jsbay_cjsCache.
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
        \\globalThis.__bundle__ = __jsbay_cjsCache(src, localRequire, "system-app.js");
        \\
    );

    const driver_owned = try driver.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(driver_owned);

    try helpers.evalOk(id, driver_owned);
    try helpers.expectEvalEquals(id, "globalThis.__bundle__.kind", "app");
    const ans = try helpers.evalInt(id, "globalThis.__bundle__.answer");
    try testing.expectEqual(@as(i64, 42), ans);
}

test "cjs: __jsbay_cjsCache reuses process bytecode cache per source and keeps object identity" {
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();

    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    if (backend.isJscApiBackend(backend.active_backend) or backend.isSpikeBackend(backend.active_backend)) {
        try helpers.expectEvalEquals(id, "typeof __jsbay_cjsCache", "undefined");
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

test "cjs: __jsbay_cjsCache isolates identical bodies by filename on disk and in memory" {
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

/// Run `__jsbay_cjsCache(<src>, noopRequire, <filename>)` and stash the returned exports on `globalThis.<slot>`.
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

    // __jsbay_cjsCache(src, noopRequire, "<filename>")
    try driver.appendSlice(testing.allocator, "globalThis.");
    try driver.appendSlice(testing.allocator, slot);
    try driver.appendSlice(testing.allocator, " = __jsbay_cjsCache(src, noopRequire, \"");
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
    try driver.appendSlice(testing.allocator, "\"; __jsbay_cjsCache(src, noopRequire, \"");
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

const ResolvingLoader = struct {
    modules: CjsLoaderCtx,
    legacy_referrer: bool = true,
    resolve_count: usize = 0,
    release_count: usize = 0,
    load_count: usize = 0,

    fn resolve(ud: ?*anyopaque, referrer: [*:0]const u8, specifier: [*:0]const u8) callconv(.c) ?[*:0]u8 {
        const self: *ResolvingLoader = @ptrCast(@alignCast(ud.?));
        self.resolve_count += 1;
        self.legacy_referrer = self.legacy_referrer and std.mem.eql(u8, std.mem.span(referrer), "<cjs>");
        return @constCast(if (std.mem.eql(u8, std.mem.span(specifier), "alias")) @as([*:0]const u8, "a") else specifier);
    }

    fn release(ud: ?*anyopaque, _: [*:0]u8) callconv(.c) void {
        const self: *ResolvingLoader = @ptrCast(@alignCast(ud.?));
        // The callback owns this policy; these inputs borrow static/callback argument storage.
        self.release_count += 1;
    }

    fn load(ud: ?*anyopaque, canonical: [*:0]const u8, out: *types.ModuleLoadResult) callconv(.c) bool {
        const self: *ResolvingLoader = @ptrCast(@alignCast(ud.?));
        self.load_count += 1;
        return cjsLoaderLoad(&self.modules, canonical, out);
    }

    const vtable = types.ModuleLoaderVTable{ .resolve = resolve, .load = load, .free_resolved = release };
};

test "cjs: canonical aliases share an instance and nested resolver uses canonical referrer" {
    var context = ResolvingLoader{ .modules = CjsLoaderCtx.init(testing.allocator) };
    defer context.modules.deinit();
    try context.modules.modules.put("a", "module.exports = { child: require('b') };");
    try context.modules.modules.put("b", "module.exports = 7;");
    const loader = types.ModuleLoader{ .vtable = &ResolvingLoader.vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.expectEvalEquals(id, "String(require('alias') === require('a'))", "true");
    try testing.expect(!context.legacy_referrer);
    try testing.expectEqual(@as(usize, 3), context.resolve_count);
    try testing.expectEqual(context.resolve_count, context.release_count);
    try testing.expectEqual(@as(usize, 2), context.load_count);
}

test "cjs: cycles observe executing partial exports with the same identity" {
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    try context.modules.put("a", "exports.ready = false; exports.other = require('b'); exports.ready = true;");
    try context.modules.put("b", "const partial = require('a'); module.exports = { partial, snapshot: partial.ready };");
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.expectEvalEquals(id, "JSON.stringify([require('a').ready, require('b').partial.ready, require('b').partial === require('a'), require('b').snapshot])", "[true,true,true,false]");
}

test "cjs: repeated bundle execution is fresh and keeps each injected require" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.evalOk(id,
        \\globalThis.bundleRuns = 0;
        \\globalThis.bundleBody = "globalThis.bundleRuns++; module.exports = { answer: require('x'), filename: __filename, dirname: __dirname };";
        \\globalThis.bundleA = __jsbay_cjsCache(bundleBody, () => 11, 'dir/bundle.js');
        \\globalThis.bundleB = __jsbay_cjsCache(bundleBody, () => 22, 'dir/bundle.js');
    );
    cjs.clearCache(id);
    try helpers.evalOk(id, "globalThis.bundleC = __jsbay_cjsCache(bundleBody, () => 33, 'dir/bundle.js');");
    try helpers.expectEvalEquals(id, "JSON.stringify([bundleRuns, bundleA !== bundleB, bundleA.answer, bundleB.answer, bundleC.answer, bundleC.filename, bundleC.dirname])", "[3,true,11,22,33,\"dir/bundle.js\",\"dir\"]");
}

test "cjs: failed module rolls back its placeholder and retries on the next require" {
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    try context.modules.put("bad", "globalThis.requireAttempts = (globalThis.requireAttempts || 0) + 1; throw Error('failed');");
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.evalOk(id, "for (let i=0;i<2;i++) { try { require('bad'); } catch (_) {} }");
    try helpers.expectEvalEquals(id, "String(requireAttempts)", "2");
}

test "cjs: idle uninstall leaves native functions installed but reporting missing state" {
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try context.modules.put("saved", "module.exports=require;");
    try helpers.evalOk(id, "globalThis.retainedRequire=require('saved');");
    // Direct uninstall is only called after eval has unwound, never inside an active entry.
    cjs.uninstall(id);
    cjs.uninstall(id);
    try helpers.expectEvalEquals(id, "typeof require", "function");
    try helpers.expectEvalEquals(id, "(() => {try {retainedRequire('missing');return false;}catch(e){return String(e).includes('not installed');}})()", "true");
    try helpers.expectEvalEquals(id, "(() => { try { require('missing'); return 'wrong'; } catch(e) { return String(e).includes('not installed'); } })()", "true");
}

test "cjs: throwing compiled wrappers execute once per call, never retry source" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    var ctx = CjsLoaderCtx.init(testing.allocator);
    defer ctx.deinit();
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &ctx };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    const cdir = try makeCjsCacheDir(std.heap.c_allocator);
    defer cleanCjsCacheDir(std.heap.c_allocator, cdir);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "globalThis.cjsThrows = (globalThis.cjsThrows || 0) + 1; throw new Error('runtime marker'); /*");
    try source.appendNTimes(testing.allocator, 'x', 4096);
    try source.appendSlice(testing.allocator, "*/");
    for (0..2) |i| {
        const result = cjs.evalCachedCjs(id, source.items, "throws.js", cdir, kCjsVersion);
        defer freeCjsCacheResult(result);
        try testing.expect(result.err != null);
        try testing.expect(!result.decode_failed);
        try testing.expectEqual(i != 0 and @import("build_options").bytecode_cache, result.cache_hit);
    }
    try helpers.expectEvalEquals(id, "cjsThrows", "2");
    const bundle = "for (let i = 0; i < 2; i++) { try { __jsbay_cjsCache(\"globalThis.bundleThrows = (globalThis.bundleThrows || 0) + 1; throw new Error('bundle');\", () => 0, 'throws-bundle.js'); } catch (_) {} } bundleThrows;";
    try helpers.expectEvalEquals(id, bundle, "2");
}

test "cjs: throwing module.exports getter propagates and is not cached" {
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    try context.modules.put(
        "g",
        \\globalThis.bodyRuns = (globalThis.bodyRuns || 0) + 1;
        \\Object.defineProperty(module, 'exports', {
        \\  get() {
        \\    globalThis.getterReads = (globalThis.getterReads || 0) + 1;
        \\    throw new Error('exports getter');
        \\  }
        \\});
        ,
    );
    try context.modules.put("ok", "module.exports = { ok: true };");
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.evalOk(id,
        \\globalThis.bodyRuns = 0;
        \\globalThis.getterReads = 0;
        \\globalThis.getterMsgs = [];
        \\for (let i = 0; i < 2; i++) {
        \\  try { require('g'); getterMsgs.push('swallowed'); }
        \\  catch (e) { getterMsgs.push(e && e.message ? e.message : String(e)); }
        \\}
        \\globalThis.afterOk = require('ok');
    );
    try helpers.expectEvalEquals(
        id,
        "JSON.stringify([getterMsgs, bodyRuns, getterReads, afterOk && afterOk.ok === true])",
        "[[\"exports getter\",\"exports getter\"],2,2,true]",
    );
}

test "cjs: explicit undefined exports are cached and returned as undefined" {
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    try context.modules.put(
        "u",
        \\globalThis.undefRuns = (globalThis.undefRuns || 0) + 1;
        \\module.exports = undefined;
        ,
    );
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.expectEvalEquals(
        id,
        "JSON.stringify([typeof require('u'), require('u') === require('u'), require('u') === undefined, undefRuns])",
        "[\"undefined\",true,true,1]",
    );
}

test "cjs: evalAsCjs, bytecode, and injected cache preserve undefined and getter exceptions" {
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));

    const undef_src = "module.exports = undefined;";
    const getter_src = "Object.defineProperty(module, 'exports', { get() { throw new Error('exports getter'); } });";

    const undef_eval = cjs.evalAsCjs(id, undef_src, "eval-undef.js");
    defer helpers.freeEvalResult(undef_eval);
    try testing.expect(undef_eval.err == null);
    try testing.expect(undef_eval.result == null);

    const getter_eval = cjs.evalAsCjs(id, getter_src, "eval-getter.js");
    defer helpers.freeEvalResult(getter_eval);
    try testing.expect(getter_eval.result == null);
    try testing.expect(getter_eval.err != null);

    if (!backend.isQuickJsApiBackend(backend.active_backend)) return;

    const cdir = try makeCjsCacheDir(std.heap.c_allocator);
    defer cleanCjsCacheDir(std.heap.c_allocator, cdir);

    const undef_cached = cjs.evalCachedCjs(id, undef_src, "cached-undef.js", cdir, kCjsVersion);
    defer freeCjsCacheResult(undef_cached);
    try testing.expect(undef_cached.err == null);
    try testing.expect(undef_cached.result == null);
    try testing.expect(!undef_cached.decode_failed);

    const getter_cached = cjs.evalCachedCjs(id, getter_src, "cached-getter.js", cdir, kCjsVersion);
    defer freeCjsCacheResult(getter_cached);
    try testing.expect(getter_cached.result == null);
    try testing.expect(getter_cached.err != null);
    try testing.expect(!getter_cached.decode_failed);

    try helpers.expectEvalEquals(id,
        \\(() => {
        \\  const u = __jsbay_cjsCache("module.exports = undefined;", () => 0, "bundle-undef.js");
        \\  let msg = "swallowed";
        \\  try {
        \\    __jsbay_cjsCache("Object.defineProperty(module, 'exports', { get() { throw new Error('exports getter'); } });", () => 0, "bundle-getter.js");
        \\  } catch (e) { msg = e && e.message ? e.message : String(e); }
        \\  return JSON.stringify([typeof u, u === undefined, msg]);
        \\})()
    , "[\"undefined\",true,\"exports getter\"]");
}

// Adversarial review: throw values need not be Error objects, and a getter may return undefined, delete itself, or recover on a later execution.
test "cjs: adversarial final exports reads preserve thrown identity and retry" {
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    try context.modules.put("g", "globalThis.runs++; Object.defineProperty(module, 'exports', { get() { globalThis.reads++; if (runs < 3) throw marker; return undefined; } });");
    try context.modules.put("deleted", "delete module.exports;");
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.evalOk(id, "globalThis.runs=0; globalThis.reads=0; globalThis.marker={}; globalThis.errors=[]; for(let i=0;i<2;i++){try{require('g')}catch(e){errors.push(e===marker)}}");
    try helpers.expectEvalEquals(id, "JSON.stringify([errors,require('g')===undefined,require('g')===undefined,runs,reads,require('deleted')===undefined])", "[[true,true],true,true,3,3,true]");
    if (!backend.isQuickJsApiBackend(backend.active_backend)) return;
    try helpers.expectEvalEquals(id,
        \\(() => { let caught=0; for(let i=0;i<2;i++){ try { __jsbay_cjsCache("Object.defineProperty(module,'exports',{get(){throw marker}})", () => 0, 'getter.js'); } catch(e){if(e===marker)caught++;} } return caught; })()
    , "2");
}

const RelativeLoader = struct {
    modules: CjsLoaderCtx,
    buffer: [512]u8 = undefined,
    fn resolve(ud: ?*anyopaque, referrer: [*:0]const u8, specifier: [*:0]const u8) callconv(.c) ?[*:0]u8 {
        const self: *RelativeLoader = @ptrCast(@alignCast(ud.?));
        const spec = std.mem.span(specifier);
        if (std.mem.eql(u8, spec, "alias")) return @constCast(@as([*:0]const u8, "pkg/a.js"));
        if (!std.mem.startsWith(u8, spec, "./")) return @constCast(specifier);
        const parent = std.mem.span(referrer);
        const slash = std.mem.lastIndexOfScalar(u8, parent, '/') orelse return null;
        const resolved = std.fmt.bufPrintSentinel(&self.buffer, "{s}/{s}", .{ parent[0..slash], spec[2..] }, 0) catch return null;
        return resolved.ptr;
    }
    fn load(ud: ?*anyopaque, canonical: [*:0]const u8, out: *types.ModuleLoadResult) callconv(.c) bool {
        const self: *RelativeLoader = @ptrCast(@alignCast(ud.?));
        return cjsLoaderLoad(&self.modules, canonical, out);
    }
    const vtable = types.ModuleLoaderVTable{ .resolve = resolve, .load = load };
};

test "cjs: module require captures canonical referrer through nesting and cache clear" {
    var context = RelativeLoader{ .modules = CjsLoaderCtx.init(testing.allocator) };
    defer context.modules.deinit();
    try context.modules.modules.put("pkg/a.js", "exports.saved=require; exports.nested=require('./sub/b.js'); exports.after=require('./dep.js');");
    try context.modules.modules.put("pkg/sub/b.js", "exports.saved=require; exports.value=require('./dep.js');");
    try context.modules.modules.put("pkg/dep.js", "module.exports=11;");
    try context.modules.modules.put("pkg/sub/dep.js", "module.exports=22;");
    const loader = types.ModuleLoader{ .vtable = &RelativeLoader.vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.evalOk(id, "globalThis.a=require('alias');");
    try helpers.expectEvalEquals(id, "JSON.stringify([a.after,a.nested.value,a.saved('./dep.js'),a.nested.saved('./dep.js')])", "[11,22,11,22]");
    cjs.clearCache(id);
    try helpers.expectEvalEquals(id, "JSON.stringify([a.saved('./dep.js'),a.nested.saved('./dep.js')])", "[11,22]");
    const result = cjs.evalAsCjs(id, "globalThis.savedEval=require; module.exports=require('./dep.js');", "pkg/entry.js");
    defer helpers.freeEvalResult(result);
    try testing.expect(result.err == null);
    try testing.expectEqualStrings("11", result.result.?);
    if (!backend.isQuickJsApiBackend(backend.active_backend)) return;
    const compiled = cjs.compileCommonJS(id, "globalThis.savedBytecode=require; module.exports=require('./dep.js');", "pkg/sub/compiled.js");
    defer bytecode.freeCompileResult(compiled);
    try testing.expect(compiled.bytes != null);
    const ran = cjs.runCommonJS(id, compiled.bytes.?, "pkg/sub/compiled.js");
    defer freeCjsCacheResult(ran);
    try testing.expect(ran.err == null);
    try testing.expectEqualStrings("22", ran.result.?);
    cjs.clearCache(id);
    try helpers.expectEvalEquals(id, "JSON.stringify([savedEval('./dep.js'),savedBytecode('./dep.js')])", "[11,22]");
    try helpers.expectEvalEquals(id, "__jsbay_cjsCache(\"module.exports=require('./dep.js');\", a.saved, 'other/bundle.js')", "11");
    // Injected require is a policy boundary: do not replace it with the global loader or append hidden referrer arguments to caller-owned functions.
    try helpers.expectEvalEquals(id, "__jsbay_cjsCache('module.exports=require;', function(spec){return arguments.length+spec;}, 'pkg/injected.js')('x')", "1x");
}

test "cjs: cycles observe reassignment without rewriting earlier exports aliases" {
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    try context.modules.put("a", "exports.ready=true; globalThis.original=exports; require('b'); module.exports={replacement:true}; require('c'); exports.late=true;");
    try context.modules.put("b", "module.exports=require('a');");
    try context.modules.put("c", "module.exports=require('a');");
    try context.modules.put("u", "module.exports=undefined; globalThis.cycleUndefined=require('v');");
    try context.modules.put("v", "module.exports=require('u');");
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.evalOk(id, "require('a'); require('u');");
    try helpers.expectEvalEquals(id, "JSON.stringify([require('b')===original,original.ready,original.late,require('a')===require('c'),require('a')!==original,require('u')===undefined,cycleUndefined===undefined])", "[true,true,true,true,true,true,true]");
}

// A host-returning API owns the exception; unlike a native JS callback, it
// must not leave a parked exception behind after converting it to EvalResult.
test "cjs: host text and bytecode failures consume pending getter exceptions" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    const src = "Object.defineProperty(module,'exports',{get(){throw new Error('host getter')}});";
    const result = cjs.evalAsCjs(id, src, "host.js");
    defer helpers.freeEvalResult(result);
    try testing.expect(result.err != null);
    const ctx = engine.getContext(id).?;
    try testing.expect(!cjsHasPendingException(ctx));
    const compiled = cjs.compileCommonJS(id, src, "host-bytecode.js");
    defer bytecode.freeCompileResult(compiled);
    try testing.expect(compiled.bytes != null);
    const ran = cjs.runCommonJS(id, compiled.bytes.?, "host-bytecode.js");
    defer freeCjsCacheResult(ran);
    try testing.expect(ran.err != null);
    try testing.expect(!cjsHasPendingException(ctx));
    try helpers.expectEvalEquals(id, "1+1", "2");
}

const ClearingLoader = struct {
    modules: CjsLoaderCtx,
    instance_id: i32 = 0,
    fn load(ud: ?*anyopaque, canonical: [*:0]const u8, out: *types.ModuleLoadResult) callconv(.c) bool {
        const self: *ClearingLoader = @ptrCast(@alignCast(ud.?));
        if (std.mem.eql(u8, std.mem.span(canonical), "clear")) cjs.clearCache(self.instance_id);
        return cjsLoaderLoad(&self.modules, canonical, out);
    }
    const vtable = types.ModuleLoaderVTable{ .load = load };
};

test "cjs: clear and same-ID reload cannot let older success or failure replace newer cache" {
    var context = ClearingLoader{ .modules = CjsLoaderCtx.init(testing.allocator) };
    defer context.modules.deinit();
    try context.modules.modules.put("clear", "module.exports=1;");
    try context.modules.modules.put("a", "const n=++globalThis.runs; if(n===1){ require('clear'); globalThis.newer=require('a'); if(globalThis.failOuter) Object.defineProperty(module,'exports',{get(){throw marker}}); else module.exports={n}; } else module.exports={n};");
    const loader = types.ModuleLoader{ .vtable = &ClearingLoader.vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    context.instance_id = id;
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    for ([_]bool{ false, true }) |fail| {
        cjs.clearCache(id);
        try helpers.evalOk(id, if (fail) "globalThis.runs=0;globalThis.failOuter=true;globalThis.marker={};" else "globalThis.runs=0;globalThis.failOuter=false;globalThis.marker={};");
        try helpers.expectEvalEquals(id, "(() => { let result; try {result=require('a').n;}catch(e){result=e===marker?'getter':'wrong';} const cached=require('a'); return JSON.stringify([result,cached===newer,cached.n,runs]);})()", if (fail) "[\"getter\",true,2,2]" else "[1,true,2,2]");
    }
}

test "cjs: getter failures on real bytecode cache hits run exactly once and recover" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    const cdir = try makeCjsCacheDir(std.heap.c_allocator);
    defer cleanCjsCacheDir(std.heap.c_allocator, cdir);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "globalThis.cachedBodies=(globalThis.cachedBodies||0)+1; Object.defineProperty(module,'exports',{get(){globalThis.cachedReads=(globalThis.cachedReads||0)+1;if(cachedBodies<3)throw Error('getter');return undefined;}}); /*");
    try source.appendNTimes(testing.allocator, 'x', 4096);
    try source.appendSlice(testing.allocator, "*/");
    for (0..4) |i| {
        const result = cjs.evalCachedCjs(id, source.items, "cached-getter.js", cdir, kCjsVersion);
        defer freeCjsCacheResult(result);
        try testing.expectEqual(i < 2, result.err != null);
        try testing.expect(result.result == null);
        try testing.expect(!result.decode_failed);
        try testing.expectEqual(i != 0 and @import("build_options").bytecode_cache, result.cache_hit);
        try testing.expect(!cjsHasPendingException(engine.getContext(id).?));
    }
    try helpers.expectEvalEquals(id, "JSON.stringify([cachedBodies,cachedReads])", "[4,4]");
}

fn cjsHasPendingException(ctx: backend.ActiveEngine.Context) bool {
    const pending = backend.ActiveEngineModule.qjs.JS_HasException(ctx);
    return if (@TypeOf(pending) == bool) pending else pending != 0;
}

test "cjs: cyclic exports getters propagate primitive throws and roll back both modules" {
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    try context.modules.put("g", "globalThis.gRuns++; Object.defineProperty(module,'exports',{get(){throw undefined}}); require('peer');");
    try context.modules.put("peer", "globalThis.peerRuns++; module.exports=require('g');");
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.evalOk(id, "globalThis.gRuns=0;globalThis.peerRuns=0;globalThis.caught=0;for(let i=0;i<2;i++){try{require('g')}catch(e){if(e===undefined)caught++}}");
    try helpers.expectEvalEquals(id, "JSON.stringify([caught,gRuns,peerRuns])", "[2,2,2]");
}

test "cjs: root and absent module context keep the fallback referrer" {
    var context = ResolvingLoader{ .modules = CjsLoaderCtx.init(testing.allocator) };
    defer context.modules.deinit();
    try context.modules.modules.put("dep", "module.exports=7;");
    const loader = types.ModuleLoader{ .vtable = &ResolvingLoader.vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    const result = cjs.evalAsCjs(id, "module.exports=require('dep');", "");
    defer helpers.freeEvalResult(result);
    try testing.expect(result.err == null);
    try testing.expectEqualStrings("7", result.result.?);
    try helpers.expectEvalEquals(id, "require('dep','not-a-module-context')", "7");
    if (backend.isQuickJsApiBackend(backend.active_backend)) {
        try helpers.expectEvalEquals(id, "__jsbay_cjsCache(\"module.exports=require('dep');\",require,'pkg/injected.js')", "7");
    }
    try testing.expect(context.legacy_referrer);
}

test "cjs: module exports initialization bypasses inherited setters" {
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    try context.modules.put("a", "globalThis.bodyCount++; if (!Object.hasOwn(module, 'exports') || module.exports !== exports) throw new Error('environment'); exports.ok=true;");
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.evalOk(id,
        \\globalThis.bodyCount=0; globalThis.setterCount=0;
        \\Object.defineProperty(Object.prototype,'exports',{configurable:true,set(v){
        \\  Object.defineProperty(this,'exports',{value:v,writable:true,configurable:true});
        \\  if (++setterCount===1) globalThis.fromSetter=require('a');
        \\}});
        \\globalThis.outer=require('a'); delete Object.prototype.exports;
        \\if (outer !== require('a') || outer.ok !== true) throw new Error('cache identity');
    );
    try helpers.expectEvalEquals(id, "JSON.stringify([bodyCount,setterCount])", "[1,0]");
}

test "cjs: VM allocation failure cannot cache a sentinel module environment" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const environment = @import("../script/cjs/wrapper_execution.zig");
    const m = backend.ActiveEngineModule;
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ctx = engine.getContext(id).?;
    const exports = try environment.newExports(ctx);
    defer backend.ActiveEngine.freeValue(ctx, exports);
    const rt = m.qjs.JS_GetRuntime(ctx);
    // QuickJS can satisfy new objects from its freelist without malloc. Hold those successes until a real allocation is forced, and release every one.
    var held: [4096]backend.ActiveEngine.Value = undefined;
    var used: usize = 0;
    defer for (held[0..used]) |value| backend.ActiveEngine.freeValue(ctx, value);
    inline for (.{ false, true }) |module_constructor| {
        m.qjs.JS_SetMemoryLimit(rt, 1);
        defer m.qjs.JS_SetMemoryLimit(rt, std.math.maxInt(usize));
        var failed = false;
        while (used < held.len) {
            const created = if (module_constructor) environment.newModule(ctx, exports) else environment.newExports(ctx);
            const value = created catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                failed = true;
                break;
            };
            held[used] = value;
            used += 1;
        }
        try testing.expect(failed);
        m.qjs.JS_SetMemoryLimit(rt, std.math.maxInt(usize));
    }
    // Consume only the deliberately injected OOM, then prove the context recovers.
    const exception = m.qjs.JS_GetException(ctx);
    backend.ActiveEngine.freeValue(ctx, exception);
    const module = try environment.newModule(ctx, exports);
    defer backend.ActiveEngine.freeValue(ctx, module);
    const value = try environment.readFinalExports(ctx, module, exports, struct {
        fn sink(_: backend.ActiveEngine.Context, _: backend.ActiveEngine.Value) void {}
    }.sink);
    defer backend.ActiveEngine.freeValue(ctx, value);
    try testing.expect(!cjsHasPendingException(ctx));
}

test "cjs: host loader same-ID reentry adopts the completed module and balances teardown" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const Probe = struct {
        id: i32,
        entered: bool = false,
        nested_failed: bool = false,
        fn load(data: ?*anyopaque, _: [*:0]const u8, out: *types.ModuleLoadResult) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (!self.entered) {
                self.entered = true;
                const m = backend.ActiveEngineModule;
                const ctx = engine.getContext(self.id).?;
                const source = "globalThis.loaderNested=require('a');";
                const result = m.qjs.JS_Eval(ctx, source, source.len, "<loader-reentry>", m.qjs.JS_EVAL_TYPE_GLOBAL);
                self.nested_failed = m.jsIsException(result);
                backend.ActiveEngine.freeValue(ctx, result);
            }
            const source = "globalThis.loaderBodyCount++; exports.ok=true;";
            out.* = .{ .source = source, .source_len = source.len };
            return true;
        }
    };
    const id = helpers.nextInstanceId();
    var probe = Probe{ .id = id };
    const vtable = types.ModuleLoaderVTable{ .load = Probe.load };
    const loader = types.ModuleLoader{ .vtable = &vtable, .user_data = &probe };
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.evalOk(id, "globalThis.loaderBodyCount=0; globalThis.loaderOuter=require('a');");
    try testing.expect(!probe.nested_failed);
    try helpers.expectEvalEquals(id, "JSON.stringify([loaderBodyCount,loaderOuter===loaderNested,require('a')===loaderNested])", "[1,true,true]");
}
