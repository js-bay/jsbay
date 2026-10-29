//! Tests for the bytecode cache API (src/script/bytecode.zig).
//!
//! Covers:
//!   1. compile + runBytecode round-trip (happy path)
//!   2. filename propagates into runtime stack traces
//! 3. functional determinism — compile the same source twice, both roundtrip-run to the same result
//!   4. syntax errors return an error CompileResult with no bytes
//!   5. JSC backend returns the "not supported" sentinel
//!   6. runBytecode on corrupt bytes returns an error (not a crash)
//!
//! Tests 1-4 + 6 run on both backends (on JSC the roundtrip/determinism tests assert that the "not supported" sentinel is returned, matching the stub).

const std = @import("std");
const testing = std.testing;

const helpers = @import("test_helpers.zig");
const bytecode = @import("../script/bytecode.zig");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");

const jsc_err_sentinel: []const u8 =
    "bytecode cache is not supported on JSC backend (use QuickJS)";

// ---------------------------------------------------------------------------
// 1. Round-trip: compile "1 + 2" → bytes → run → "3"
// ---------------------------------------------------------------------------

test "bytecode: compile + runBytecode roundtrips a simple expression" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const cr = bytecode.compile(id, "1 + 2", "<roundtrip>");
            defer bytecode.freeCompileResult(cr);

            if (backend.active_backend == .jsc) {
                try testing.expect(cr.bytes == null);
                try testing.expect(cr.err != null);
                try testing.expectEqualStrings(jsc_err_sentinel, cr.err.?);
                return;
            }

            try testing.expect(cr.err == null);
            const bytes = cr.bytes orelse return error.NoBytes;
            try testing.expect(bytes.len > 0);

            const res = bytecode.runBytecode(id, bytes);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);
            const s = res.result orelse return error.NoResult;
            try testing.expectEqualStrings("3", s);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 2. Filename ends up in runtime stack traces.
// ---------------------------------------------------------------------------

test "bytecode: runtime errors include the original filename" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const src =
                \\function boom() { throw new Error("kaboom"); }
                \\boom();
            ;
            const cr = bytecode.compile(id, src, "my-module.js");
            defer bytecode.freeCompileResult(cr);

            if (backend.active_backend == .jsc) {
                try testing.expect(cr.bytes == null);
                try testing.expect(cr.err != null);
                return;
            }

            try testing.expect(cr.err == null);
            const bytes = cr.bytes orelse return error.NoBytes;

            const res = bytecode.runBytecode(id, bytes);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err != null);
            const msg = res.err.?;
            // Should contain the error message and the filename.
            try testing.expect(std.mem.indexOf(u8, msg, "kaboom") != null);
            try testing.expect(std.mem.indexOf(u8, msg, "my-module.js") != null);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 3. Functional determinism: compiling the same source twice yields bytes that both run to the same result. (We don't assert exact byte-equality because QuickJS may embed minor diffs e.g. timestamps or ordering.)
// ---------------------------------------------------------------------------

test "bytecode: same source runs to the same result across compiles" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const src = "({ x: 42, y: 'hi', z: [1,2,3] })";
            const a = bytecode.compile(id, src, "<a>");
            defer bytecode.freeCompileResult(a);
            const b = bytecode.compile(id, src, "<b>");
            defer bytecode.freeCompileResult(b);

            if (backend.active_backend == .jsc) {
                try testing.expect(a.bytes == null and b.bytes == null);
                try testing.expect(a.err != null and b.err != null);
                return;
            }

            const ba = a.bytes orelse return error.NoBytesA;
            const bb = b.bytes orelse return error.NoBytesB;

            const ra = bytecode.runBytecode(id, ba);
            defer helpers.freeEvalResult(ra);
            const rb = bytecode.runBytecode(id, bb);
            defer helpers.freeEvalResult(rb);

            try testing.expect(ra.err == null);
            try testing.expect(rb.err == null);
            const sa = ra.result orelse return error.NoResultA;
            const sb = rb.result orelse return error.NoResultB;
            try testing.expectEqualStrings(sa, sb);
            // Sanity-check the shape.
            try testing.expect(std.mem.indexOf(u8, sa, "\"x\":42") != null);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 4. Syntax errors return a clean error, no crash.
// ---------------------------------------------------------------------------

test "bytecode: syntax error surfaces cleanly" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            // Missing closing brace.
            const bad = "function oops() { return 1 ";
            const cr = bytecode.compile(id, bad, "bad.js");
            defer bytecode.freeCompileResult(cr);

            try testing.expect(cr.bytes == null);
            try testing.expect(cr.err != null);

            if (backend.active_backend == .jsc) {
                try testing.expectEqualStrings(jsc_err_sentinel, cr.err.?);
                return;
            }

            // QJS should surface a SyntaxError. The exact wording varies across QJS versions; assert on the error-class substring.
            const msg = cr.err.?;
            try testing.expect(
                std.mem.indexOf(u8, msg, "SyntaxError") != null or
                    std.mem.indexOf(u8, msg, "unexpected") != null or
                    std.mem.indexOf(u8, msg, "expecting") != null,
            );
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 5. JSC backend only — stub returns the expected sentinel.
// ---------------------------------------------------------------------------

test "bytecode: JSC backend returns not-supported sentinel" {
    if (backend.active_backend != .jsc) return error.SkipZigTest;

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const cr = bytecode.compile(id, "1+1", "<x>");
            defer bytecode.freeCompileResult(cr);
            try testing.expect(cr.bytes == null);
            try testing.expect(cr.err != null);
            try testing.expectEqualStrings(jsc_err_sentinel, cr.err.?);

            // Also exercise runBytecode directly with arbitrary bytes — must return the same sentinel without touching the backend.
            const dummy = [_]u8{ 0, 1, 2, 3 };
            const res = bytecode.runBytecode(id, &dummy);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err != null);
            try testing.expectEqualStrings(jsc_err_sentinel, res.err.?);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 6. runBytecode on corrupt bytes errors cleanly (no abort).
// ---------------------------------------------------------------------------

test "bytecode: runBytecode on corrupt bytes returns an error" {
    if (backend.active_backend == .jsc) return error.SkipZigTest;

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02 };
            const res = bytecode.runBytecode(id, &garbage);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err != null);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 7. Empty bytecode slice fails cleanly.
// ---------------------------------------------------------------------------

test "bytecode: runBytecode on empty slice returns an error" {
    if (backend.active_backend == .jsc) return error.SkipZigTest;

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const empty: []const u8 = &.{};
            const res = bytecode.runBytecode(id, empty);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err != null);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 8. Decode failures (corrupt/stale payload) are flagged `decode_failed` so a cache consumer can safely delete & rebuild, distinct from a live script's runtime exception that must never be re-run.
// ---------------------------------------------------------------------------

test "bytecode: corrupt payload reports decode_failed=true" {
    if (backend.active_backend == .jsc) return error.SkipZigTest;

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02 };
            const res = bytecode.runBytecode(id, &garbage);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err != null);
            // Must be flagged so the cache layer rebuilds (not surfaces).
            try testing.expect(res.decode_failed);
        }
    }.run);
}

test "bytecode: valid payload whose script throws reports decode_failed=false" {
    if (backend.active_backend == .jsc) return error.SkipZigTest;

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const src =
                \\throw new Error("userland boom");
            ;
            const cr = bytecode.compile(id, src, "<throwing>");
            defer bytecode.freeCompileResult(cr);
            try testing.expect(cr.err == null);
            const bytes = cr.bytes orelse return error.NoBytes;

            const res = bytecode.runBytecode(id, bytes);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err != null);
            // Runtime exception: NOT a decode problem — must not be rebuilt.
            try testing.expect(!res.decode_failed);
        }
    }.run);
}

// Compiled bytes are an immutable artifact: running them again repeats the script's effects each time, in the same engine and in a different one, and never changes what the bytes do.
test "bytecode: the same compiled bytes run again in the same and in another engine" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const src = "globalThis.__bytecode_runs = (globalThis.__bytecode_runs || 0) + 1; globalThis.__bytecode_runs";
            const cr = bytecode.compile(id, src, "<reuse>");
            defer bytecode.freeCompileResult(cr);

            if (backend.active_backend == .jsc) {
                try testing.expect(cr.bytes == null);
                try testing.expect(cr.err != null);
                return;
            }
            const bytes = cr.bytes orelse return error.NoBytes;

            const first = bytecode.runBytecode(id, bytes);
            defer helpers.freeEvalResult(first);
            const second = bytecode.runBytecode(id, bytes);
            defer helpers.freeEvalResult(second);
            try testing.expect(first.err == null and second.err == null);
            try testing.expectEqualStrings("1", first.result orelse return error.NoFirstResult);
            try testing.expectEqualStrings("2", second.result orelse return error.NoSecondResult);

            const other = helpers.nextInstanceId();
            try testing.expect(engine.create(other, .{}));
            defer engine.destroy(other);
            const elsewhere = bytecode.runBytecode(other, bytes);
            defer helpers.freeEvalResult(elsewhere);
            try testing.expect(elsewhere.err == null);
            try testing.expectEqualStrings("1", elsewhere.result orelse return error.NoElsewhereResult);
        }
    }.run);
}
