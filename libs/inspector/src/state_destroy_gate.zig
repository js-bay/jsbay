const std = @import("std");

pub fn Gate(comptime Host: type) type {
    return struct {
        pub const HostType = Host;
        pub const EngineGenerationKey = struct { instance_id: i32, generation: u64 };
        pub var destroying_ids: ?std.AutoHashMap(EngineGenerationKey, void) = null;
    };
}
