//! Engine-facing CDP inspector facade.
const std = @import("std");
const backend = @import("../backend.zig");
const inspector_package = @import("inspector");
const inspector_transport = if (@import("build_options").inspector_transport) @import("inspector_transport") else struct {};
const Host = @import("inspector_host.zig").InspectorHost;
const Core = inspector_package.Inspector(Host);

pub const Transport = inspector_package.Transport;
pub const SessionId = inspector_package.SessionId;
pub const EventKind = inspector_package.EventKind;
pub const Event = inspector_package.Event;
pub const EventHandler = inspector_package.EventHandler;
pub const DiscoveryTarget = inspector_package.DiscoveryTarget;
pub const modules = inspector_package.modules;
pub const state = modules.state(Host);
pub const object_table = modules.object_table(Host);
pub const json_writer = modules.json_writer(Host);
pub const remote_object = modules.remote_object(Host);
pub const request_box = modules.request_box(Host);
pub const runtime_eval = modules.runtime_eval(Host);
pub const runtime_objects = modules.runtime_objects(Host);
pub const console = modules.console(Host);
pub const dispatcher = modules.dispatcher(Host);
pub const debugger_cdp = modules.debugger_cdp(Host);
pub const await_promise = modules.await_promise(Host);
pub const profiler = modules.profiler(Host);
pub const exceptions = modules.exceptions(Host);
pub const heap = modules.heap(Host);
pub const performance = modules.performance(Host);

pub const Handle = Core.Handle;
pub const StartError = Core.StartError;
pub const TestAllocationFailureStage = Core.TestAllocationFailureStage;
pub const testFailAllocationOnce = Core.testFailAllocationOnce;
pub const setStartHooksForTesting = Core.setStartHooksForTesting;
pub const stop = Core.stop;
pub const dropInstance = Core.dropInstance;
pub const drainRetired = Core.drainRetired;
pub const liveConsoleEntries = Core.liveConsoleEntries;

pub const StartOptions = struct {
    port: u16 = 9229,
    title: []const u8 = "js-bay",
    url: []const u8 = "file:///js-bay",
    target_id: ?[]const u8 = null,
};

/// Calling this transfers `transport` to the inspector, even if startup fails. Its `deinit` must safely stop partial message delivery.
pub fn startWithTransport(instance_id: i32, transport: *Transport, opts: struct {
    title: []const u8 = "js-bay",
    url: []const u8 = "file:///js-bay",
    target_id: ?[]const u8 = null,
}) StartError!*Handle {
    return Core.start(instance_id, .{
        .transport = transport,
        .title = opts.title,
        .url = opts.url,
        .target_id = opts.target_id,
    });
}

/// Convenience API backed by the optional HTTP/WebSocket package.
pub fn start(instance_id: i32, opts: StartOptions) StartError!*Handle {
    if (comptime !@import("build_options").inspector_transport) return error.UnsupportedFeature;
    if (comptime @import("builtin").os.tag == .windows) return error.UnsupportedPlatform;
    const endpoint = inspector_transport.Transport.init(std.heap.c_allocator, opts.port) catch return error.OutOfMemory;
    endpoint.setProtocolJson(protocolJson());
    return startWithTransport(instance_id, endpoint.asTransport(), .{
        .title = opts.title,
        .url = opts.url,
        .target_id = opts.target_id,
    });
}

pub fn boundPort(handle: *Handle) u16 {
    return Core.boundPort(handle);
}

pub fn protocolJson() []const u8 {
    const active: inspector_package.ProtocolBackend = switch (backend.active_backend) {
        .quickjs_ng => .quickjs_ng,
        .quickjs => .quickjs,
        .jsc => .jsc,
        .escargot => .escargot,
        .hermes => .hermes,
    };
    return inspector_package.protocolJson(active, @import("build_options").heap_snapshot);
}
