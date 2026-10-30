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

fn logHandler(_: i32, level: types.LogLevel, msg: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    const tag = switch (level) {
        .debug => "log",
        .info => "info",
        .warn => "warn",
        .err => "error",
    };
    std.debug.print("[js {s}] {s}\n", .{ tag, std.mem.span(msg) });
}

pub fn main() !void {
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
    defer engine.destroy(id);
    var signal_stop: SignalStop = .{};
    try signal_stop.start(id, engine.stopEventLoop);
    defer signal_stop.deinit();

    const target_name = "js-bay-demo";
    if (!zjs.jsc_remote_inspector.startAndEnable(id, target_name)) {
        std.debug.print("jsc_remote_inspector.startAndEnable failed\n", .{});
        std.process.exit(1);
    }
    defer _ = zjs.jsc_remote_inspector.disable(id);

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

    engine.runEventLoop(id);

    std.debug.print("\nshutting down...\n", .{});
}
