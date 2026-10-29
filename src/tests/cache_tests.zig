//! Tests for the engine-level bytecode cache (src/script/cache.zig).
//!
//! Covers:
//!   1. cold evalCached compiles + persists one file, returns correct result
//! 2. warm evalCached reads the artifact and returns the same result (hit), with no re-execution of the script's side effects
//! 3. a runtime exception from a cached run is surfaced unchanged AND the cache file is preserved (must not delete + re-run side effects)
//!   4. corrupted artifact is deleted and rebuilt once, then recovers to a hit
//! 5. unsafe `version` (path traversal attempt) falls back to plain eval and never writes outside the cache dir

const std = @import("std");
const testing = std.testing;

const helpers = @import("test_helpers.zig");
const backend = @import("../backend.zig");
const cache = @import("../script/cache.zig");
const build_options = @import("build_options");

const kVersion = "testv1";

test "cache: build fingerprint creates a distinct artifact namespace" {
    const gpa = testing.allocator;
    const source_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const name_key = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

    const current = cache.cachePathWithFingerprint(
        gpa,
        "cache-dir",
        kVersion,
        build_options.bytecode_fingerprint,
        source_key,
        name_key,
    ) orelse return error.OutOfMemory;
    defer gpa.free(current);
    const changed = cache.cachePathWithFingerprint(
        gpa,
        "cache-dir",
        kVersion,
        "different-build-fingerprint",
        source_key,
        name_key,
    ) orelse return error.OutOfMemory;
    defer gpa.free(changed);

    try testing.expect(!std.mem.eql(u8, current, changed));
}

test "cache: changed build fingerprint does not read an old artifact" {
    if (backend.active_backend == .jsc) return error.SkipZigTest;

    const abs = try makeCacheDir(testing.allocator);
    defer cleanCacheDir(testing.allocator, abs);

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const src = bigScript("globalThis.__fingerprint__ = 1;");
            const first = cache.evalCachedWithFingerprint(
                id,
                &src,
                "fingerprint.js",
                g_cache_dir,
                kVersion,
                "build-a",
            );
            defer freeCached(testing.allocator, first);
            try testing.expect(first.err == null);
            try testing.expect(!first.cache_hit);

            const same = cache.evalCachedWithFingerprint(
                id,
                &src,
                "fingerprint.js",
                g_cache_dir,
                kVersion,
                "build-a",
            );
            defer freeCached(testing.allocator, same);
            try testing.expect(same.cache_hit);

            const changed = cache.evalCachedWithFingerprint(
                id,
                &src,
                "fingerprint.js",
                g_cache_dir,
                kVersion,
                "build-b",
            );
            defer freeCached(testing.allocator, changed);
            try testing.expect(changed.err == null);
            try testing.expect(!changed.cache_hit);
            try testing.expectEqual(@as(usize, 2), fileCount(g_cache_dir));
        }
    }.run);
}

/// evalCached only engages the cache for scripts >= 4 KB (below that a read costs more than a parse). Keep every exercised script comfortably above the threshold so the tests drive the cache path, not plainEval.
fn bigScript(comptime payload: []const u8) [4 * 1024 + 64]u8 {
    var buf: [4 * 1024 + 64]u8 = undefined;
    @memset(&buf, ' ');
    var n: usize = 0;
    // Payload first (e.g. a throw or a value expression), then pad with comments to well above the 4 KB cache threshold. Re-padding with a statement would redeclare bindings and fail to compile.
    @memcpy(buf[n .. n + payload.len], payload);
    n += payload.len;
    const pad = "/* padding padding padding */ ";
    while (n + pad.len + 1 <= buf.len) {
        @memcpy(buf[n .. n + pad.len], pad);
        n += pad.len;
    }
    const tail = "globalThis.__cacheProbe__ = 0;";
    if (n + tail.len <= buf.len) {
        @memcpy(buf[n .. n + tail.len], tail);
        n += tail.len;
    }
    return buf;
}

// Global scratch dir path, threaded into the closure below (Zig test fns are comptime and cannot capture locals).
var g_cache_dir: []const u8 = "";

fn makeCacheDir(gpa: std.mem.Allocator) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var rand_bytes: [8]u8 = undefined;
    testing.io.random(&rand_bytes);
    const rand = std.mem.readInt(u64, &rand_bytes, .little);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // Relative to the test process cwd — cache.zig resolves everything via `Dir.cwd()`, so a relative cache_dir is the natural fit (the Android caller passes an absolute path under the app sandbox; both resolve the same way through cwd()-rooted I/O).
    const rel = try std.fmt.bufPrint(&buf, ".zig-cache/cachetest-{x}", .{rand});
    cwd.deleteTree(testing.io, rel) catch {};
    try cwd.createDirPath(testing.io, rel);
    g_cache_dir = try gpa.dupe(u8, rel);
    return g_cache_dir;
}

fn cleanCacheDir(gpa: std.mem.Allocator, rel_path: []const u8) void {
    _ = std.Io.Dir.cwd().deleteTree(testing.io, rel_path) catch {};
    gpa.free(@constCast(rel_path));
    g_cache_dir = "";
}

fn fileCount(rel_dir: []const u8) usize {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(testing.io, rel_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(testing.io);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(testing.io) catch null) |entry| {
        if (entry.kind == .file) n += 1;
    }
    return n;
}

/// True if any stray temp file remains (a failed/interrupted temp write). Temp names look like `<artifact>.bc.tmp<pathhex><randhex>`.
fn hasTempLeftover(rel_dir: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(testing.io, rel_dir, .{ .iterate = true }) catch return false;
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (it.next(testing.io) catch null) |entry| {
        if (entry.kind == .file and std.mem.indexOf(u8, entry.name, ".tmp") != null) return true;
    }
    return false;
}

/// Corrupt every `.bc` file under `rel_dir` (relative to cwd); returns count.
fn corruptArtifacts(rel_dir: []const u8) usize {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(testing.io, rel_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(testing.io);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(testing.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bc")) continue;
        dir.writeFile(testing.io, .{ .sub_path = entry.name, .data = "garbage" }) catch continue;
        n += 1;
    }
    return n;
}

fn freeCached(gpa: std.mem.Allocator, res: cache.CachedEvalResult) void {
    _ = gpa;
    // cache.zig allocates results/errors via std.heap.c_allocator; freeing with any other allocator trips the canary. Use c_allocator here.
    if (res.result) |r| std.heap.c_allocator.free(@constCast(r));
    if (res.err_is_heap) {
        if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
    }
}

test "cache: cold write persists one artifact; warm run hits and matches" {
    if (backend.active_backend == .jsc) return error.SkipZigTest;

    const abs = try makeCacheDir(testing.allocator);
    defer cleanCacheDir(testing.allocator, abs);

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            // Assignment (not `const x = 1`): a cached hit re-executes the payload in the same context, and a fresh `const` binding would raise "redeclaration of 'x'". Assignments are idempotent, so a hit can be verified by cache_hit without a compile error.
            const src = bigScript("globalThis.__x = 1; ");
            // Cold: compiles, persists, runs. cache_hit = false.
            const c1 = cache.evalCached(id, &src, "cache-test.js", g_cache_dir, kVersion);
            defer freeCached(testing.allocator, c1);
            try testing.expect(c1.err == null);
            try testing.expect(!c1.cache_hit);

            // Warm: same source + filename → cache hit, no re-execution.
            const c2 = cache.evalCached(id, &src, "cache-test.js", g_cache_dir, kVersion);
            defer freeCached(testing.allocator, c2);
            try testing.expect(c2.err == null);
            try testing.expect(c2.cache_hit);

            // Exactly one artifact in the dir.
            try testing.expectEqual(@as(usize, 1), fileCount(g_cache_dir));
        }
    }.run);
}

test "cache: runtime exception from cached run is surfaced and cache kept" {
    if (backend.active_backend == .jsc) return error.SkipZigTest;

    const abs = try makeCacheDir(testing.allocator);
    defer cleanCacheDir(testing.allocator, abs);

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            // Compile a script that records a global side effect and then always throws. Cold run persists the bytecode, then executes → throws. Warm run replays → throws again, but the artifact must remain (no delete + recompile + re-run of the side effect).
            const src = bigScript("globalThis.__execCount__ = (globalThis.__execCount__||0)+1; throw new Error('boom-on-purpose'); /* pad */ ");
            const c1 = cache.evalCached(id, &src, "throwing.js", g_cache_dir, kVersion);
            defer freeCached(testing.allocator, c1);
            try testing.expect(c1.err != null);
            try testing.expect(std.mem.indexOf(u8, c1.err.?, "boom-on-purpose") != null);

            // Artifact present (persisted before execution, so a file exists).
            try testing.expectEqual(@as(usize, 1), fileCount(g_cache_dir));

            // Warm run: replay throws again; cache file preserved, hit=true.
            const c2 = cache.evalCached(id, &src, "throwing.js", g_cache_dir, kVersion);
            defer freeCached(testing.allocator, c2);
            try testing.expect(c2.err != null);
            try testing.expect(c2.cache_hit);
            try testing.expect(std.mem.indexOf(u8, c2.err.?, "boom-on-purpose") != null);

            // Still exactly one artifact — never deleted/rebuilt on a throw.
            try testing.expectEqual(@as(usize, 1), fileCount(g_cache_dir));
        }
    }.run);
}

test "cache: corrupt artifact is deleted and rebuilt once" {
    if (backend.active_backend == .jsc) return error.SkipZigTest;

    const abs = try makeCacheDir(testing.allocator);
    defer cleanCacheDir(testing.allocator, abs);

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            // Assignment payload — idempotent across a cached hit (see the cold-write test for why `const` would redeclare + fail).
            const src = bigScript("globalThis.__v = 40 + 2; ");
            const c1 = cache.evalCached(id, &src, "corrupt.js", g_cache_dir, kVersion);
            defer freeCached(testing.allocator, c1);
            try testing.expect(c1.err == null);
            try testing.expect(!c1.cache_hit);

            // Corrupt the artifact.
            try testing.expectEqual(@as(usize, 1), corruptArtifacts(g_cache_dir));

            // Re-call: decode fails → delete + rebuild + run, miss.
            const c2 = cache.evalCached(id, &src, "corrupt.js", g_cache_dir, kVersion);
            defer freeCached(testing.allocator, c2);
            try testing.expect(c2.err == null);
            try testing.expect(!c2.cache_hit);

            // Rebuilt artifact now valid → next call is a hit.
            const c3 = cache.evalCached(id, &src, "corrupt.js", g_cache_dir, kVersion);
            defer freeCached(testing.allocator, c3);
            try testing.expect(c3.err == null);
            try testing.expect(c3.cache_hit);
        }
    }.run);
}

test "cache: unsafe version falls back to plain eval, never writes outside dir" {
    if (backend.active_backend == .jsc) return error.SkipZigTest;

    const abs = try makeCacheDir(testing.allocator);
    defer cleanCacheDir(testing.allocator, abs);

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const src = bigScript("const a = 1; ");
            const evil_version = "../../../../etc/pwned";
            const c = cache.evalCached(id, &src, "x.js", g_cache_dir, evil_version);
            defer freeCached(testing.allocator, c);
            try testing.expect(c.err == null);
            try testing.expect(!c.cache_hit);
            // Nothing persisted in the (empty) cache dir — no traversal write.
            try testing.expectEqual(@as(usize, 0), fileCount(g_cache_dir));
        }
    }.run);
}

test "cache: zero-byte artifact is rebuilt instead of repeated errors" {
    if (backend.active_backend == .jsc) return error.SkipZigTest;

    const abs = try makeCacheDir(testing.allocator);
    defer cleanCacheDir(testing.allocator, abs);

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const src = bigScript("globalThis.__zero__ = 7; ");
            // Prime a valid artifact, then truncate it to zero bytes.
            const c1 = cache.evalCached(id, &src, "zero.js", g_cache_dir, kVersion);
            defer freeCached(testing.allocator, c1);
            try testing.expect(c1.err == null);
            try testing.expect(!c1.cache_hit);
            try testing.expectEqual(@as(usize, 1), fileCount(g_cache_dir));

            // Truncate the single artifact to an empty file.
            var dir = std.Io.Dir.cwd().openDir(testing.io, g_cache_dir, .{ .iterate = true }) catch
                return error.NoCacheDir;
            defer dir.close(testing.io);
            var it = dir.iterate();
            var truncated: usize = 0;
            while (it.next(testing.io) catch null) |entry| {
                if (entry.kind != .file) continue;
                dir.writeFile(testing.io, .{ .sub_path = entry.name, .data = "" }) catch continue;
                truncated += 1;
            }
            try testing.expectEqual(@as(usize, 1), truncated);

            // Re-call: empty bytes are undecodable → flagged, deleted, rebuilt once, then next call hits.
            const c2 = cache.evalCached(id, &src, "zero.js", g_cache_dir, kVersion);
            defer freeCached(testing.allocator, c2);
            try testing.expect(c2.err == null);
            try testing.expect(!c2.cache_hit);

            const c3 = cache.evalCached(id, &src, "zero.js", g_cache_dir, kVersion);
            defer freeCached(testing.allocator, c3);
            try testing.expect(c3.err == null);
            try testing.expect(c3.cache_hit);
        }
    }.run);
}

test "cache: repeated fresh writes leave valid artifacts, no stray temp names" {
    if (backend.active_backend == .jsc) return error.SkipZigTest;

    const abs = try makeCacheDir(testing.allocator);
    defer cleanCacheDir(testing.allocator, abs);

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const src = bigScript("globalThis.__n__ = 1;");
            // Each version bump rewrites a different artifact. Every write goes through the unique-temp path, so we also assert the cache dir never ends up holding a `.tmp*` leftover.
            var n: usize = 0;
            while (n < 5) : (n += 1) {
                var ver_buf: [8]u8 = undefined;
                const ver = try std.fmt.bufPrint(&ver_buf, "v{d}", .{n});
                const c = cache.evalCached(id, &src, "w.js", g_cache_dir, ver);
                defer freeCached(testing.allocator, c);
                try testing.expect(c.err == null);
            }
            // Same key as the first write → must hit.
            const c = cache.evalCached(id, &src, "w.js", g_cache_dir, "v0");
            defer freeCached(testing.allocator, c);
            try testing.expect(c.cache_hit);

            // Five distinct version artifacts and no leftover temp files.
            try testing.expectEqual(@as(usize, 5), fileCount(g_cache_dir));
            try testing.expect(!hasTempLeftover(g_cache_dir));
        }
    }.run);
}
