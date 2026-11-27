pub const OutboundKind = enum { text, pong, close };

pub const Outbound = struct {
    kind: OutboundKind,
    bytes: []u8,
    delivery_token: u64 = 0,
};
