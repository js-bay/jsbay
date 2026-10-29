//! Deterministic, instance-scoped allocation faults in Zig test builds only.
const builtin = @import("builtin");
const sync = @import("zev");

pub const Stage = enum {
    profiler_samples,
    profiler_strings,
    heap_snapshot_chunk,
    session_registration,
    async_depth_reconcile_post,
    debugger_reconcile_post,
    /// Fails one QuickJS phase-0 async metadata enqueue. Test builds only.
    async_job_metadata_enqueue,
};
const Storage = if (builtin.is_test) struct {
    var mutex: sync.Mutex = .{};
    var instance_id: ?i32 = null;
    var stage: Stage = .profiler_samples;
    var consumed: bool = false;
    var consumed_instance_id: ?i32 = null;
} else struct {};

pub fn arm(instance_id: i32, stage: Stage) void {
    if (comptime !builtin.is_test) @compileError("Allocation injection is available only in Zig tests");
    Storage.mutex.lock();
    defer Storage.mutex.unlock();
    Storage.instance_id = instance_id;
    Storage.stage = stage;
    Storage.consumed = false;
    Storage.consumed_instance_id = null;
}

pub fn take(instance_id: i32, stage: Stage) bool {
    if (comptime !builtin.is_test) return false;
    Storage.mutex.lock();
    defer Storage.mutex.unlock();
    if (Storage.instance_id != instance_id or Storage.stage != stage) return false;
    Storage.consumed_instance_id = Storage.instance_id;
    Storage.instance_id = null;
    Storage.consumed = true;
    return true;
}

pub fn wasConsumed(instance_id: i32, stage: Stage) bool {
    if (comptime !builtin.is_test) return false;
    Storage.mutex.lock();
    defer Storage.mutex.unlock();
    return Storage.consumed and Storage.instance_id == null and Storage.consumed_instance_id == instance_id and Storage.stage == stage;
}
