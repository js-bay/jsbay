//! Host-side WebKit Inspector Relay to Chrome DevTools Protocol bridge for JSC targets.
//!
//! The bridge connects to the local or simulator `webinspectord` relay socket, attaches to a
//! JavaScript target, and exposes a loopback CDP endpoint. It never runs inside the inspected
//! process; the target only enables the system JSC remote inspector.

const std = @import("std");
const plist = @import("plist.zig");
const wir = @import("wir.zig");
const zev = @import("zev");
const cdp = @import("cdp.zig");

test {
    _ = plist;
    _ = wir;
    _ = cdp;
    _ = @import("cdp_test.zig");
}

const Options = struct {
    socket: ?[]const u8 = null,
    application: ?[]const u8 = null,
    target: ?[]const u8 = null,
    port: u16 = 9229,
    probe: bool = false,
    trace: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    const options = parseOptions(argv[1..]) catch {
        try usage(init);
        return error.Usage;
    };
    if (options.socket == null) {
        try usage(init);
        return error.Usage;
    }

    wir.trace_enabled = options.trace;
    var client = try wir.Client.connect(allocator, init.io, options.socket.?);
    defer client.deinit();

    const target = try wir.attach(client, options.application, options.target, 10_000);
    try print(init, "attached: application={s} page={d} title={s}\n", .{ target.application_name, target.page, target.title });

    if (options.probe) {
        var probe_target = target;
        defer probe_target.deinit(allocator);
        try probe(init, allocator, client, &probe_target);
        return;
    }

    const bridge = try cdp.Bridge.start(allocator, init.io, client, target, options.port);
    try print(init, "CDP endpoint: http://127.0.0.1:{d}/json/list\n", .{bridge.boundPort()});
    try bridge.pump();
}

fn probe(init: std.process.Init, allocator: std.mem.Allocator, client: *wir.Client, target: *const wir.Target) !void {
    try client.sendSocketData(target, "{\"id\":1,\"method\":\"Runtime.enable\"}");
    const deadline = zev.monotonicMilliseconds() + 5_000;
    while (zev.monotonicMilliseconds() < deadline) {
        var message = (try client.next(500)) orelse continue;
        defer message.deinit(allocator);
        const data = switch (message.info.get("WIRMessageDataKey") orelse continue) {
            .data => |bytes| bytes,
            else => continue,
        };
        try print(init, "relay data: {s}\n", .{data});
        if (std.mem.indexOf(u8, data, "\"id\":1") != null) return;
    }
    return error.ProbeTimeout;
}

fn parseOptions(argv: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--probe")) {
            options.probe = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--trace")) {
            options.trace = true;
            continue;
        }
        if (index + 1 >= argv.len) return error.InvalidArguments;
        const value = argv[index + 1];
        if (std.mem.eql(u8, arg, "--socket")) options.socket = value else if (std.mem.eql(u8, arg, "--application")) options.application = value else if (std.mem.eql(u8, arg, "--target")) options.target = value else if (std.mem.eql(u8, arg, "--port")) options.port = try std.fmt.parseInt(u16, value, 10) else return error.InvalidArguments;
        index += 1;
    }
    return options;
}

fn usage(init: std.process.Init) !void {
    try print(init,
        \\usage: jsbay-inspector-bridge --socket <path> [--application <name>] [--target <name>] [--port <port>]
        \\
        \\  --socket       webinspectord relay socket (RWI_LISTEN_SOCKET from a booted simulator), or tcp://host:port
        \\  --application  application name shown by the relay; defaults to the first application
        \\  --target       JavaScript target title; defaults to the first JavaScript target
        \\  --port         CDP listener port; 0 selects an ephemeral port
        \\  --probe        attach, enable Runtime, print the relay traffic, then exit
        \\  --trace        dump relay frames on stderr
        \\
    , .{});
}

fn print(init: std.process.Init, comptime format: []const u8, args: anytype) !void {
    var writer: std.Io.Writer.Allocating = .init(init.arena.allocator());
    try writer.writer.print(format, args);
    try std.Io.File.stdout().writeStreamingAll(init.io, writer.written());
}
