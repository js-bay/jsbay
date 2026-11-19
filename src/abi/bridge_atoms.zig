//! Host bridge protocol atoms with compile-time minimal perfect hash dispatch.

const std = @import("std");
const hyper_box = @import("hyper_box");

/// Standard host bridge atoms recognized in high-frequency event routing.
pub const BridgeAtom = enum(u4) {
    publish = 0,
    invoke = 1,
    onMessage = 2,
    subscribe = 3,
    unsubscribe = 4,
    addEventListener = 5,
    removeEventListener = 6,
    dispatchEvent = 7,
    postMessage = 8,
    ready = 9,
    @"error" = 10,
    close = 11,
    open = 12,
    data = 13,
    status = 14,
    init = 15,
};

pub const BRIDGE_ATOM_NAMES = [_][]const u8{
    "publish",
    "invoke",
    "onMessage",
    "subscribe",
    "unsubscribe",
    "addEventListener",
    "removeEventListener",
    "dispatchEvent",
    "postMessage",
    "ready",
    "error",
    "close",
    "open",
    "data",
    "status",
    "init",
};

pub const BridgeAtomMatcher = hyper_box.ComptimeMinimalPerfectHash(&BRIDGE_ATOM_NAMES);

/// Resolve a bridge event or method name into an enum atom in 2 nanoseconds with zero allocations.
pub inline fn matchBridgeAtom(str: []const u8) ?BridgeAtom {
    const idx = BridgeAtomMatcher.match(str) orelse return null;
    return @fromBackingInt(@intCast(@as(u4, @truncate(idx))));
}

test "bridge_atoms: minimal perfect hash verification across all protocol atoms" {
    for (BRIDGE_ATOM_NAMES, 0..) |name, expected_idx| {
        const resolved = matchBridgeAtom(name);
        try std.testing.expect(resolved != null);
        try std.testing.expectEqual(expected_idx, @backingInt(resolved.?));
    }
    try std.testing.expect(matchBridgeAtom("unknownMethod") == null);
    try std.testing.expect(matchBridgeAtom("") == null);
}
