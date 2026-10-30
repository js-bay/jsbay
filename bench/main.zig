//! js-bay benchmark harness.
//!
//! This self-contained binary prints an ops/sec table. Both backends share the same source; the active backend is selected at build time via `-Dbackend=quickjs_ng|quickjs|jsc`.
//!
//! Reference cases: ScriptX `PressureTest`.
//!
//! Workloads (see `workloads` array below):
//!   1. eval_throughput            — hot-loop `1+1`
//!   2. eval_complex               — larger expression / function body
//!   3. native_fn_call             — JS calling a Zig native function in a loop
//!   4. js_fn_call                 — native calling a JS function N times
//!   5. string_roundtrip           — 100-char string into JS, length back
//!   6. json_parse_stringify       — JSON.stringify(obj) in a loop
//!   7. typedarray_roundtrip       — Uint8Array(1024) summed natively
//!   8. promise_resolve            — create + resolve a Promise (drain microtasks)
//!
//! Harness:
//!   - Warmup: 100 iterations (discarded).
//!   - Timed run: auto-tuned N so each workload takes 0.5–3 s.
//!   - Timer: std.Io.Clock (.awake, monotonic, ns precision).
//!
//! Output:
//!   - Default: aligned plain-text table.
//!   - `--json`: one JSON line per workload for CI consumption.

const std = @import("std");
const zjs = @import("js_bay_tools");
const comma_format = @import("comma_format.zig");

const engine = zjs.engine;
const value = zjs.value;
const backend = zjs.backend;
const promise = zjs.promise;
const reference = zjs.reference;
const types = zjs.types;

const ActiveEngine = backend.ActiveEngine;

// ----------------------------------------------------------------------
// Config
// ----------------------------------------------------------------------

const WARMUP_ITERS: usize = 100;
/// Target wall-clock time per workload (ns). Auto-tuning picks N to hit this.
const TARGET_NS_PER_WORKLOAD: u64 = 1_000_000_000; // 1 s
const MIN_ITERS: usize = 1_000;
/// Upper bound on per-workload iteration count. Chosen generously so the auto-tuner can reach the 1 s target even for very cheap ops (single-digit ns per operation).
const MAX_ITERS: usize = 200_000_000;

// ----------------------------------------------------------------------
// Shared state (workloads are top-level fns so they can be referenced from a comptime table; globals are the simplest way to keep them stateless).
// ----------------------------------------------------------------------

var g_engine_id: i32 = 0;

// ----------------------------------------------------------------------
// Native handlers used by workloads.
// ----------------------------------------------------------------------

fn nativeAdd(_: i32, args: value.NativeArgs) value.NativeResult {
    const a = args.toFloat64(0) orelse 0;
    const b = args.toFloat64(1) orelse 0;
    return .{ .number = a + b };
}

fn nativeNoop(_: i32, _: value.NativeArgs) value.NativeResult {
    return .{ .number = 0 };
}

fn nativeStringLen(_: i32, args: value.NativeArgs) value.NativeResult {
    const s = args.toString(0) orelse return .{ .number = -1 };
    defer value.freeString(s);
    return .{ .number = @floatFromInt(s.len) };
}

fn nativeSumTypedArray(_: i32, args: value.NativeArgs) value.NativeResult {
    const view = args.getTypedArray(0) orelse return .{ .number = -1 };
    const slice = view.asSlice(u8) orelse return .{ .number = -2 };
    var sum: u64 = 0;
    for (slice) |b| sum += b;
    return .{ .number = @floatFromInt(sum) };
}

// ----------------------------------------------------------------------
// Workload contract
// ----------------------------------------------------------------------

/// A workload runs `iters` operations against the engine identified by `instance_id`. Setup / teardown around iterations (warmup, timing) is handled by the harness. On failure, return an error.
const WorkloadFn = *const fn (instance_id: i32, iters: usize) anyerror!void;

const Workload = struct {
    name: []const u8,
    /// Runs at most once before `run` is called (used for script/native function registration). Safe to be null.
    setup: ?*const fn (instance_id: i32) anyerror!void = null,
    run: WorkloadFn,
};

// ----------------------------------------------------------------------
// Workload implementations
// ----------------------------------------------------------------------

fn setupEval(_: i32) !void {}

fn runEvalThroughput(id: i32, iters: usize) !void {
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const res = engine.evalScript(id, "1+1", "<bench>");
        freeRes(res);
        if (res.err != null) return error.JsException;
    }
}

fn runEvalComplex(id: i32, iters: usize) !void {
    const script =
        \\(function() {
        \\  let s = 0;
        \\  for (let i = 0; i < 20; i++) {
        \\    s += Math.sqrt(i * 3.1415) + Math.sin(i);
        \\  }
        \\  return s|0;
        \\})()
    ;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const res = engine.evalScript(id, script, "<bench>");
        freeRes(res);
        if (res.err != null) return error.JsException;
    }
}

fn setupNativeFn(id: i32) !void {
    value.registerFunction(id, null, "nativeAdd", nativeAdd);
    value.registerFunction(id, null, "nativeNoop", nativeNoop);
}

fn runNativeFnCall(id: i32, iters: usize) !void {
    // Use a single eval per outer loop iteration; inside JS we do a batch of calls. That gives us JS->native dispatch throughput with minimal eval overhead.
    const batch: usize = 1_000;
    const total_inner = batch;
    var outer: usize = 0;
    const outer_count = (iters + batch - 1) / batch;
    while (outer < outer_count) : (outer += 1) {
        // Use JS-side loop of `batch` calls per script invocation.
        var buf: [256]u8 = undefined;
        const script = try std.fmt.bufPrint(
            &buf,
            "(function(){{let s=0;for(let i=0;i<{d};i++)s+=nativeAdd(i,1);return s|0;}})()",
            .{total_inner},
        );
        const res = engine.evalScript(id, script, "<bench>");
        freeRes(res);
        if (res.err != null) return error.JsException;
    }
}

fn setupJsFn(id: i32) !void {
    // Install a function on globalThis we can call from native.
    const install = engine.evalScript(
        id,
        "globalThis.bench_js_fn = function(x){ return x + 1; };",
        "<bench>",
    );
    freeRes(install);
    if (install.err != null) return error.JsException;
}

fn runJsFnCall(id: i32, iters: usize) !void {
    const ctx = engine.getContext(id) orelse return error.NoContext;

    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);

    const fn_val = ActiveEngine.getPropertyVal(ctx, global, "bench_js_fn") orelse return error.NoFn;
    defer ActiveEngine.freeValue(ctx, fn_val);

    const undef = ActiveEngine.newUndefinedVal(ctx);
    defer ActiveEngine.freeValue(ctx, undef);

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const arg = ActiveEngine.newInt32Val(ctx, @intCast(@as(i32, @truncate(@as(i64, @intCast(i % 1_000_000))))));
        defer ActiveEngine.freeValue(ctx, arg);
        const args = [_]ActiveEngine.Value{arg};
        const result = ActiveEngine.callFunction(ctx, fn_val, undef, args[0..]) orelse return error.CallFailed;
        ActiveEngine.freeValue(ctx, result);
    }
}

fn setupStringRoundtrip(id: i32) !void {
    value.registerFunction(id, null, "nativeStringLen", nativeStringLen);
    const install = engine.evalScript(id,
        \\globalThis.__bench_str = 'a'.repeat(100);
    , "<bench>");
    freeRes(install);
    if (install.err != null) return error.JsException;
}

fn runStringRoundtrip(id: i32, iters: usize) !void {
    const batch: usize = 1_000;
    var outer: usize = 0;
    const outer_count = (iters + batch - 1) / batch;
    while (outer < outer_count) : (outer += 1) {
        var buf: [320]u8 = undefined;
        const script = try std.fmt.bufPrint(
            &buf,
            "(function(){{let s=0;for(let i=0;i<{d};i++)s+=nativeStringLen(__bench_str);return s|0;}})()",
            .{batch},
        );
        const res = engine.evalScript(id, script, "<bench>");
        freeRes(res);
        if (res.err != null) return error.JsException;
    }
}

fn setupConsoleLog(_: i32) !void {}

fn runConsoleLog(id: i32, iters: usize) !void {
    const batch: usize = 100;
    var outer: usize = 0;
    const outer_count = (iters + batch - 1) / batch;
    while (outer < outer_count) : (outer += 1) {
        var buf: [256]u8 = undefined;
        const script = try std.fmt.bufPrint(
            &buf,
            "(function(){{for(let i=0;i<{d};i++)console.log('console-bench',i);}})()",
            .{batch},
        );
        const res = engine.evalScript(id, script, "<bench>");
        freeRes(res);
        if (res.err != null) return error.JsException;
    }
}

fn setupJson(id: i32) !void {
    // ~200-byte object for the stringify target.
    const install = engine.evalScript(id,
        \\globalThis.__bench_obj = {
        \\  name: "bench", id: 12345, active: true,
        \\  tags: ["red", "green", "blue", "alpha", "beta"],
        \\  nested: { a: 1, b: 2.5, c: "hello world", d: [10, 20, 30, 40] },
        \\  flags: [true, false, true, false, true]
        \\};
    , "<bench>");
    freeRes(install);
    if (install.err != null) return error.JsException;
}

fn runJsonParseStringify(id: i32, iters: usize) !void {
    const batch: usize = 500;
    var outer: usize = 0;
    const outer_count = (iters + batch - 1) / batch;
    while (outer < outer_count) : (outer += 1) {
        var buf: [256]u8 = undefined;
        const script = try std.fmt.bufPrint(
            &buf,
            "(function(){{let n=0;for(let i=0;i<{d};i++)n+=JSON.stringify(__bench_obj).length;return n|0;}})()",
            .{batch},
        );
        const res = engine.evalScript(id, script, "<bench>");
        freeRes(res);
        if (res.err != null) return error.JsException;
    }
}

fn setupTypedArray(id: i32) !void {
    value.registerFunction(id, null, "nativeSumTypedArray", nativeSumTypedArray);
    const install = engine.evalScript(id,
        \\globalThis.__bench_ta = new Uint8Array(1024);
        \\for (let i = 0; i < 1024; i++) globalThis.__bench_ta[i] = (i * 7) & 0xff;
    , "<bench>");
    freeRes(install);
    if (install.err != null) return error.JsException;
}

fn runTypedArrayRoundtrip(id: i32, iters: usize) !void {
    const batch: usize = 500;
    var outer: usize = 0;
    const outer_count = (iters + batch - 1) / batch;
    while (outer < outer_count) : (outer += 1) {
        var buf: [320]u8 = undefined;
        const script = try std.fmt.bufPrint(
            &buf,
            "(function(){{let s=0;for(let i=0;i<{d};i++)s+=nativeSumTypedArray(__bench_ta);return s|0;}})()",
            .{batch},
        );
        const res = engine.evalScript(id, script, "<bench>");
        freeRes(res);
        if (res.err != null) return error.JsException;
    }
}

fn setupPromise(id: i32) !void {
    // Install a .then side-effect receiver so the workload exercises the full microtask drain rather than pure function-call cost.
    const install = engine.evalScript(id,
        \\globalThis.__bench_promise_x = 0;
    , "<bench>");
    freeRes(install);
    if (install.err != null) return error.JsException;
}

fn runPromiseResolve(id: i32, iters: usize) !void {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var d = promise.create(id) orelse return error.NoDeferred;
        defer d.deinit();

        // Attach a then handler that bumps a global so microtask drain is observable. We re-install per iteration via JS by assigning the fresh promise to __p and evaluating the chain.
        const promise_dup = ActiveEngine.dupValue(ctx, d.promise);
        ActiveEngine.setPropertyStr(ctx, global, "__p", promise_dup);

        const chain = engine.evalScript(
            id,
            "__p.then(v => { globalThis.__bench_promise_x = v; });",
            "<bench>",
        );
        freeRes(chain);
        if (chain.err != null) return error.JsException;

        const val = ActiveEngine.newInt32Val(ctx, @intCast(@as(i32, @truncate(@as(i64, @intCast(i % 1_000_000))))));
        defer ActiveEngine.freeValue(ctx, val);
        if (!d.resolve(val)) return error.ResolveFailed;
    }
}

// ----------------------------------------------------------------------
// Workload table
// ----------------------------------------------------------------------

const workloads = [_]Workload{
    .{ .name = "eval_throughput", .setup = setupEval, .run = runEvalThroughput },
    .{ .name = "eval_complex", .setup = setupEval, .run = runEvalComplex },
    .{ .name = "native_fn_call", .setup = setupNativeFn, .run = runNativeFnCall },
    .{ .name = "js_fn_call", .setup = setupJsFn, .run = runJsFnCall },
    .{ .name = "string_roundtrip", .setup = setupStringRoundtrip, .run = runStringRoundtrip },
    .{ .name = "console_log", .setup = setupConsoleLog, .run = runConsoleLog },
    .{ .name = "json_parse_stringify", .setup = setupJson, .run = runJsonParseStringify },
    .{ .name = "typedarray_roundtrip", .setup = setupTypedArray, .run = runTypedArrayRoundtrip },
    .{ .name = "promise_resolve", .setup = setupPromise, .run = runPromiseResolve },
};

// ----------------------------------------------------------------------
// Harness
// ----------------------------------------------------------------------

const BenchResult = struct {
    name: []const u8,
    iters: usize,
    elapsed_ns: u64,
    skipped: bool = false,
    skip_reason: []const u8 = "",

    pub fn opsPerSec(self: BenchResult) f64 {
        if (self.elapsed_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.iters)) /
            (@as(f64, @floatFromInt(self.elapsed_ns)) / 1e9);
    }

    pub fn nsPerOp(self: BenchResult) f64 {
        if (self.iters == 0) return 0;
        return @as(f64, @floatFromInt(self.elapsed_ns)) /
            @as(f64, @floatFromInt(self.iters));
    }
};

fn freeRes(res: types.EvalResult) void {
    if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
    if (res.err_is_heap) {
        if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
    }
}

/// Run a workload once with `iters` iterations, measuring total elapsed time.
///
/// This bench uses `std.Io.Clock` with `.awake` for monotonic timing that excludes suspend time. This bench binary has no embedder-supplied `Io`, so it uses the same process-wide single-threaded default the library itself falls back to (see `src/platform/io.zig`).
fn timeOnce(wl: Workload, id: i32, iters: usize) !u64 {
    const bench_io = std.Io.Threaded.global_single_threaded.io();
    const start = std.Io.Clock.Timestamp.now(bench_io, .awake);
    try wl.run(id, iters);
    const end = std.Io.Clock.Timestamp.now(bench_io, .awake);
    const elapsed = start.durationTo(end);
    return @intCast(elapsed.raw.nanoseconds);
}

/// Auto-tune: start with `MIN_ITERS`, scale up until elapsed >= `TARGET_NS_PER_WORKLOAD / 4` (cheap measurement of per-op cost), then compute a final iteration count that targets `TARGET_NS_PER_WORKLOAD`.
fn autoTuneIters(wl: Workload, id: i32) !usize {
    // Grow `probe` geometrically until a probe run is long enough to give a stable per-op estimate, then extrapolate to `TARGET_NS_PER_WORKLOAD`.
    var probe: usize = MIN_ITERS;
    const threshold_ns = TARGET_NS_PER_WORKLOAD / 8;
    while (true) {
        const elapsed = try timeOnce(wl, id, probe);
        if (elapsed >= threshold_ns or probe >= MAX_ITERS) {
            if (elapsed == 0) return MAX_ITERS;
            const per_op_ns = @as(f64, @floatFromInt(elapsed)) /
                @as(f64, @floatFromInt(probe));
            const target_ns: f64 = @floatFromInt(TARGET_NS_PER_WORKLOAD);
            var next: usize = @intFromFloat(target_ns / per_op_ns);
            if (next < MIN_ITERS) next = MIN_ITERS;
            if (next > MAX_ITERS) next = MAX_ITERS;
            return next;
        }
        probe *= 4;
        if (probe > MAX_ITERS) probe = MAX_ITERS;
    }
}

fn runWorkload(wl: Workload, allocator: std.mem.Allocator) !BenchResult {
    _ = allocator;

    // Fresh engine per workload: isolates measurement from accumulated side-state (e.g. JSON object pinned on globalThis by an earlier run).
    const id: i32 = g_engine_id;
    g_engine_id += 1;

    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    if (wl.setup) |s| try s(id);

    // Warmup.
    try wl.run(id, WARMUP_ITERS);

    // Auto-tune.
    const iters = try autoTuneIters(wl, id);

    // Timed run.
    const elapsed = try timeOnce(wl, id, iters);

    return .{ .name = wl.name, .iters = iters, .elapsed_ns = elapsed };
}

// ----------------------------------------------------------------------
// Output
// ----------------------------------------------------------------------

fn printHumanHeader(backend_name: []const u8, optimize_mode: []const u8) void {
    std.debug.print(
        \\
        \\js-bay bench — backend={s}, optimize={s}
        \\
    , .{ backend_name, optimize_mode });
    std.debug.print("{s:<26}  {s:<8}  {s:>14}  {s:>12}  {s:>8}\n", .{
        "Benchmark", "Backend", "Ops/sec", "ns/op", "Total",
    });
    std.debug.print("{s:<26}  {s:<8}  {s:>14}  {s:>12}  {s:>8}\n", .{
        "--------------------------",
        "--------",
        "--------------",
        "------------",
        "--------",
    });
}

fn printHumanRow(r: BenchResult, backend_name: []const u8) void {
    if (r.skipped) {
        std.debug.print("{s:<26}  {s:<8}  {s:>14}  {s:>12}  {s:>8}  ({s})\n", .{
            r.name,
            backend_name,
            "SKIPPED",
            "-",
            "-",
            r.skip_reason,
        });
        return;
    }
    var ops_buf: [32]u8 = undefined;
    const ops_str = comma_format.formatCommas(&ops_buf, @intFromFloat(r.opsPerSec())) catch "?";
    const ns_per_op = r.nsPerOp();
    const total_s = @as(f64, @floatFromInt(r.elapsed_ns)) / 1e9;

    std.debug.print("{s:<26}  {s:<8}  {s:>14}  {d:>12.1}  {d:>6.2}s\n", .{
        r.name,
        backend_name,
        ops_str,
        ns_per_op,
        total_s,
    });
}

fn printJsonRow(r: BenchResult, backend_name: []const u8) void {
    if (r.skipped) {
        std.debug.print(
            "{{\"name\":\"{s}\",\"backend\":\"{s}\",\"skipped\":true,\"reason\":\"{s}\"}}\n",
            .{ r.name, backend_name, r.skip_reason },
        );
        return;
    }
    std.debug.print(
        "{{\"name\":\"{s}\",\"backend\":\"{s}\",\"iters\":{d},\"elapsed_ns\":{d},\"ops_per_sec\":{d:.2},\"ns_per_op\":{d:.2}}}\n",
        .{ r.name, backend_name, r.iters, r.elapsed_ns, r.opsPerSec(), r.nsPerOp() },
    );
}

// ----------------------------------------------------------------------
// Entry point
// ----------------------------------------------------------------------

pub fn main(proc_init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Flags
    var json_mode = false;
    var filter: ?[]const u8 = null;
    {
        var args = try proc_init.args.iterateAllocator(allocator);
        defer args.deinit();
        _ = args.next(); // exe
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--json")) {
                json_mode = true;
            } else if (std.mem.startsWith(u8, a, "--filter=")) {
                filter = try allocator.dupe(u8, a["--filter=".len..]);
            } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
                std.debug.print(
                    \\Usage: bench [--json] [--filter=<substring>]
                    \\
                , .{});
                return;
            }
        }
    }
    defer if (filter) |f| allocator.free(@constCast(f));

    const backend_name: []const u8 = switch (backend.active_backend) {
        .quickjs_ng => "quickjs_ng",
        .quickjs => "quickjs",
        .jsc => "jsc",
        .escargot => "escargot",
        .hermes => "hermes",
    };

    const optimize_mode = comptime switch (@import("builtin").mode) {
        .Debug => "Debug",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseSmall => "ReleaseSmall",
    };

    if (!json_mode) printHumanHeader(backend_name, optimize_mode);

    g_engine_id = 100_000; // avoid collision with any ambient tests

    var had_error = false;
    for (workloads) |wl| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, wl.name, f) == null) continue;
        }
        const result = runWorkload(wl, allocator) catch |err| {
            std.debug.print("[!] workload {s} failed: {s}\n", .{ wl.name, @errorName(err) });
            had_error = true;
            continue;
        };
        if (json_mode) printJsonRow(result, backend_name) else printHumanRow(result, backend_name);
    }

    if (had_error) std.process.exit(1);
}
