// Embeddable Chrome DevTools Protocol inspector core. Hosts inject engine services through `Inspector(Host)`; transports are supplied as `Transport` values and are deliberately independent of HTTP or WebSocket.
pub const Transport = @import("transport.zig").Transport;
pub const SessionId = @import("transport.zig").SessionId;
pub const EventKind = @import("transport.zig").EventKind;
pub const Event = @import("transport.zig").Event;
pub const EventHandler = @import("transport.zig").EventHandler;
pub const DiscoveryTarget = @import("transport.zig").DiscoveryTarget;
pub const protocol = @import("inspector_protocol.zig");

pub const ProtocolBackend = enum { quickjs_ng, quickjs, jsc };

pub fn protocolJson(comptime backend: ProtocolBackend, comptime heap_snapshot: bool) []const u8 {
    return switch (backend) {
        .quickjs_ng => if (heap_snapshot) @embedFile("protocol-quickjs-ng.json") else @embedFile("protocol-quickjs-ng-no-heap.json"),
        .quickjs => if (heap_snapshot) @embedFile("protocol-quickjs.json") else @embedFile("protocol-quickjs-no-heap.json"),
        .jsc => @embedFile("protocol-jsc.json"),
    };
}

pub fn Inspector(comptime Host: type) type {
    return @import("core.zig").Module(Host);
}

pub const modules = struct {
    pub fn state(comptime Host: type) type {
        return @import("state.zig").Module(Host);
    }
    pub fn object_table(comptime Host: type) type {
        return @import("object_table.zig").Module(Host);
    }
    pub fn json_writer(comptime Host: type) type {
        return @import("json_writer.zig").Module(Host);
    }
    pub fn remote_object(comptime Host: type) type {
        return @import("remote_object.zig").Module(Host);
    }
    pub fn request_box(comptime Host: type) type {
        return @import("request_box.zig").Module(Host);
    }
    pub fn runtime_eval(comptime Host: type) type {
        return @import("runtime_eval.zig").Module(Host);
    }
    pub fn runtime_objects(comptime Host: type) type {
        return @import("runtime_objects.zig").Module(Host);
    }
    pub fn console(comptime Host: type) type {
        return @import("console.zig").Module(Host);
    }
    pub fn dispatcher(comptime Host: type) type {
        return @import("dispatcher.zig").Module(Host);
    }
    pub fn debugger_cdp(comptime Host: type) type {
        return @import("debugger_cdp.zig").Module(Host);
    }
    pub fn await_promise(comptime Host: type) type {
        return @import("await_promise.zig").Module(Host);
    }
    pub fn profiler(comptime Host: type) type {
        return @import("profiler.zig").Module(Host);
    }
    pub fn exceptions(comptime Host: type) type {
        return @import("exceptions.zig").Module(Host);
    }
    pub fn heap(comptime Host: type) type {
        return @import("heap.zig").Module(Host);
    }
    pub fn performance(comptime Host: type) type {
        return @import("performance.zig").Module(Host);
    }
};
