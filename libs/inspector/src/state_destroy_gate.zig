pub fn Gate(comptime Host: type) type {
    return struct {
        pub const HostType = Host;
        pub const EngineGenerationKey = struct { instance_id: i32, generation: u64 };
        pub const DestroyLease = struct {
            key: EngineGenerationKey = .{ .instance_id = 0, .generation = 0 },
            next: ?*DestroyLease = null,
            active: bool = false,
        };
        pub var destroying_leases: ?*DestroyLease = null;
    };
}

pub fn isDestroying(comptime GateType: type, key: GateType.EngineGenerationKey) bool {
    var lease = GateType.destroying_leases;
    while (lease) |current| : (lease = current.next) {
        if (current.key.instance_id == key.instance_id and current.key.generation == key.generation) return true;
    }
    return false;
}

pub fn begin(
    comptime GateType: type,
    mutex: anytype,
    instance_id: i32,
    generation: u64,
    lease: *GateType.DestroyLease,
) bool {
    const key = GateType.EngineGenerationKey{ .instance_id = instance_id, .generation = generation };
    mutex.lock();
    defer mutex.unlock();
    if (isDestroying(GateType, key)) return false;
    lease.* = .{ .key = key, .next = GateType.destroying_leases, .active = true };
    GateType.destroying_leases = lease;
    return true;
}

pub fn end(comptime GateType: type, mutex: anytype, changed: anytype, lease: *GateType.DestroyLease) void {
    mutex.lock();
    defer mutex.unlock();
    if (!lease.active) return;
    var cursor = &GateType.destroying_leases;
    while (cursor.*) |current| {
        if (current == lease) {
            cursor.* = current.next;
            lease.next = null;
            lease.active = false;
            break;
        }
        cursor = &current.next;
    }
    std.debug.assert(!lease.active);
    changed.broadcast();
}
