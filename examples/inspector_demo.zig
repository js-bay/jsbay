//! Minimal runnable harness for the CDP inspector.
//!
//! Usage:
//!   zig build inspector-demo -- [--port 9229]
//!
//! Starts an engine, binds the inspector to a TCP port, evaluates a priming script that registers a setInterval emitting console.log, and drives the event loop forever. Ctrl-C to exit.
//!
//! Pair with `tests/inspector/e2e.cjs` for end-to-end validation.

const std = @import("std");
const zjs = @import("jsbay_tools");

const engine = zjs.engine;
const SignalStop = @import("signal_stop.zig").SignalStop;
const inspector = zjs.inspector;
const types = zjs.types;

fn logHandler(_: i32, level: types.LogLevel, msg: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    const tag = switch (level) {
        .debug => "log",
        .info => "info",
        .warn => "warn",
        .err => "error",
    };
    std.debug.print("[js {s}] {s}\n", .{ tag, std.mem.span(msg) });
}

pub fn main(proc_init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var port: u16 = 9229;
    var args = try proc_init.args.iterateAllocator(alloc);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const v = args.next() orelse {
                std.debug.print("--port requires value\n", .{});
                std.process.exit(2);
            };
            port = std.fmt.parseInt(u16, v, 10) catch {
                std.debug.print("invalid port: {s}\n", .{v});
                std.process.exit(2);
            };
        }
    }

    const id: i32 = 1;
    if (!engine.create(id, .{ .log_handler = logHandler })) {
        std.debug.print("engine.create failed\n", .{});
        std.process.exit(1);
    }
    defer engine.destroy(id);
    var signal_stop: SignalStop = .{};
    try signal_stop.start(id, engine.stopEventLoop);
    defer signal_stop.deinit();

    const handle = inspector.start(id, .{
        .port = port,
        .title = "js-bay demo",
        .url = "file:///examples/inspector_demo.zig",
        .target_id = "jsbay_qjs-demo",
    }) catch |err| {
        std.debug.print("inspector.start failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer inspector.stop(handle);

    const bound = inspector.boundPort(handle);
    std.debug.print("inspector listening on ws://127.0.0.1:{d}/jsbay_qjs-demo\n", .{bound});
    std.debug.print("  chrome://inspect → Configure → add localhost:{d}\n", .{bound});
    std.debug.print("  e2e: node tests/inspector/e2e.cjs --port {d}\n", .{bound});
    std.debug.print("Ctrl-C to exit.\n", .{});

    // Priming: every 1s, emit a heartbeat via console.log so a connected DevTools sees something happening even with no user interaction.
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
