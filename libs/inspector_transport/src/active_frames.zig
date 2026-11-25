pub const Frame = struct {
    transport: *anyopaque,
    previous: ?*Frame = null,
};

threadlocal var active_callback: ?*Frame = null;
threadlocal var active_delivery: ?*Frame = null;

pub fn enterCallback(frame: *Frame, transport: *anyopaque) void {
    frame.* = .{ .transport = transport, .previous = active_callback };
    active_callback = frame;
}

pub fn leaveCallback(frame: *Frame) void {
    active_callback = frame.previous;
}

pub fn enterDelivery(frame: *Frame, transport: *anyopaque) void {
    frame.* = .{ .transport = transport, .previous = active_delivery };
    active_delivery = frame;
}

pub fn leaveDelivery(frame: *Frame) void {
    active_delivery = frame.previous;
}

pub fn hasDelivery(transport: *anyopaque) bool {
    var current = active_delivery;
    while (current) |frame| : (current = frame.previous) {
        if (frame.transport == transport) return true;
    }
    return false;
}

pub fn inCallback(transport: *anyopaque) bool {
    var current = active_callback;
    while (current) |frame| : (current = frame.previous) {
        if (frame.transport == transport) return true;
    }
    return hasDelivery(transport);
}
