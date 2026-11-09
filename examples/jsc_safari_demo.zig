//! Minimal runnable harness for the JSC remote inspector (Safari-attachable).
//!
//! Usage (JSC backend, macOS/iOS only):
//!   zig build safari-demo -Dbackend=jsc
//!   ./zig-out/bin/jsc-safari-demo
//!
//! The process enables JavaScriptCore's built-in WebKit Inspector agent and primes a heartbeat script so there's observable activity. Attach from Safari: Develop menu → [your machine] → "js-bay-demo". Full breakpoint/stepping/scope-inspection support is provided by the framework — the Zig side is a thin enablement shim.
//!
//! Under QJS or on non-Apple platforms this binary is not built (the build step is gated in build.zig). If it somehow runs under QJS it bails out with a helpful message.

const std = @import("std");
const zjs = @import("jsbay_tools");

const engine = zjs.engine;
const SignalStop = @import("signal_stop.zig").SignalStop;
const types = zjs.types;
const backend = zjs.backend;

const AppleRunLoop = opaque {};
const LoopTask = *const fn (?*anyopaque) callconv(.c) void;

extern fn jsbay_apple_run_loop_create() ?*AppleRunLoop;
extern fn jsbay_apple_run_loop_destroy(loop: *AppleRunLoop) void;
extern fn jsbay_apple_run_loop_schedule(loop: ?*anyopaque, delay_ms: u64, task: LoopTask, task_data: ?*anyopaque) callconv(.c) bool;
extern fn jsbay_apple_run_loop_cancel(loop: ?*anyopaque) callconv(.c) void;
extern fn jsbay_apple_run_loop_run(loop: *AppleRunLoop) bool;
extern fn jsbay_apple_run_loop_stop(loop: *AppleRunLoop) void;

var apple_run_loop: ?*AppleRunLoop = null;

fn logHandler(_: i32, level: types.LogLevel, msg: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    const tag = switch (level) {
        .debug => "log",
        .info => "info",
        .warn => "warn",
        .err => "error",
    };
    std.debug.print("[js {s}] {s}\n", .{ tag, std.mem.span(msg) });
}

fn stopDemo(instance_id: i32) void {
    engine.stopEventLoop(instance_id);
    if (apple_run_loop) |loop| jsbay_apple_run_loop_stop(loop);
}

pub fn main() !void {
    std.debug.print("STARTED {d}\n", .{std.c.getpid()});
    if (!backend.isJscApiBackend(backend.active_backend)) {
        std.debug.print(
            "jsc-safari-demo requires -Dbackend=jsc (current: {s}). " ++
                "Use `zig build safari-demo -Dbackend=jsc` on macOS/iOS.\n",
            .{@tagName(backend.active_backend)},
        );
        std.process.exit(2);
    }

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const id: i32 = 1;
    if (!engine.create(id, .{ .log_handler = logHandler })) {
        std.debug.print("engine.create failed\n", .{});
        std.process.exit(1);
    }
    errdefer engine.destroy(id);

    const target_name = "js-bay-demo";
    if (!zjs.jsc_remote_inspector.startAndEnable(id, target_name)) {
        std.debug.print("jsc_remote_inspector.startAndEnable failed\n", .{});
        std.process.exit(1);
    }
    errdefer _ = zjs.jsc_remote_inspector.disable(id);

    const loop = jsbay_apple_run_loop_create() orelse return error.AppleRunLoopCreateFailed;
    errdefer jsbay_apple_run_loop_destroy(loop);
    try engine.attachLoop(id, .{
        .context = loop,
        .schedule = jsbay_apple_run_loop_schedule,
        .cancel = jsbay_apple_run_loop_cancel,
    });
    errdefer engine.detachLoop(id);
    apple_run_loop = loop;
    errdefer apple_run_loop = null;
    var signal_stop: SignalStop = .{};
    try signal_stop.start(id, stopDemo);
    errdefer signal_stop.deinit();

    std.debug.print(
        \\JSC remote inspector enabled as "{s}".
        \\Open Safari → Develop menu → [your machine name] → "{s}" to attach.
        \\(macOS Safari must have "Develop menu" enabled: Safari → Settings → Advanced → Show Develop menu.)
        \\Ctrl-C to exit.
        \\
    , .{ target_name, target_name });

    // Priming: every 1s, emit a heartbeat via console.log so a connected inspector sees something happening even with no user interaction.
    const prime_result = engine.evalScript(id,
        \\setInterval(() => { console.log("heartbeat " + new Date().toISOString()); }, 1000);
    , "<prime>");
    if (prime_result.err) |e| {
        std.debug.print("prime eval error: {s}\n", .{e});
        if (prime_result.err_is_heap) std.heap.c_allocator.free(@constCast(e));
    }
    if (prime_result.result) |r| std.heap.c_allocator.free(@constCast(r));

    std.debug.print("READY {d}\n", .{std.c.getpid()});
    if (!jsbay_apple_run_loop_run(loop)) return error.AppleRunLoopFailed;

    apple_run_loop = null;
    engine.detachLoop(id);
    jsbay_apple_run_loop_destroy(loop);
    _ = zjs.jsc_remote_inspector.disable(id);
    engine.destroy(id);
    signal_stop.deinit();
    std.debug.print("\nshutting down...\n", .{});
    std.debug.print("CLEAN_EXIT\n", .{});
}
