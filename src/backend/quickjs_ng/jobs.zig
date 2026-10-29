//! QuickJS job-queue hook. Promise reactions and `queueMicrotask` both become `JS_EnqueueJob` entries. The hook records the scheduling stack when the job is queued and restores it while the job runs.

const std = @import("std");
const async_stack = @import("../../inspector/async_stack.zig");
const sync = @import("zev");
const c = @import("c_api.zig");

const qjs = c.qjs;

const Cleanup = struct {
    instance_id: ?i32 = null,
    hook_armed: bool = false,
};

var cleanup_mutex: sync.Mutex = .{};
var cleanup_by_runtime: std.AutoHashMapUnmanaged(*qjs.JSRuntime, *Cleanup) = .{};

fn initCleanup(cleanup: *Cleanup) void {
    cleanup.* = .{};
}

fn createCleanup(allocator: std.mem.Allocator) !*Cleanup {
    const cleanup = try allocator.create(Cleanup);
    initCleanup(cleanup);
    return cleanup;
}

pub fn install(rt: ?*qjs.JSRuntime) void {
    if (comptime !@import("build_options").inspector) return;
    const runtime = rt orelse return;
    cleanup_mutex.lock();
    defer cleanup_mutex.unlock();
    if (cleanup_by_runtime.contains(runtime)) return;
    cleanup_by_runtime.ensureUnusedCapacity(std.heap.c_allocator, 1) catch return;
    const cleanup = createCleanup(std.heap.c_allocator) catch return;
    if (qjs.JS_AddRuntimeFinalizer(runtime, &runtimeFinalizer, @ptrCast(cleanup)) != 0) {
        std.heap.c_allocator.destroy(cleanup);
        return;
    }
    cleanup_by_runtime.putAssumeCapacity(runtime, cleanup);
}

/// Must run on the runtime's JS owner. Installing the native callback only while CDP has requested async parents keeps ordinary Promise scheduling out of Zig entirely. The native executor caches a phase-1 callback through phase 2, so disabling can immediately stop marking later enqueued jobs.
pub fn setAsyncStackDepth(rt: ?*qjs.JSRuntime, instance_id: i32, requested_depth: u32) void {
    async_stack.setDepth(instance_id, requested_depth);
    if (comptime !@import("build_options").inspector) return;
    const runtime = rt orelse return;
    const enabled = async_stack.depth(instance_id) != 0;
    if (!enabled) {
        // The native queue may contain jobs captured by the previous depth. Invalidate their existing `kind` marker before an enable in the same callback can create a new trace queue.
        qjs.JS_InvalidatePendingJobHooks(runtime);
        async_stack.dropQueuedJobs(instance_id);
    }

    var arm = false;
    var disarm = false;
    cleanup_mutex.lock();
    if (cleanup_by_runtime.get(runtime)) |cleanup| {
        cleanup.instance_id = instance_id;
        if (enabled) {
            if (!cleanup.hook_armed) {
                cleanup.hook_armed = true;
                arm = true;
            }
        } else if (cleanup.hook_armed) {
            cleanup.hook_armed = false;
            disarm = true;
        }
    }
    cleanup_mutex.unlock();
    if (arm) qjs.JS_SetJobHook(runtime, onJob);
    if (disarm) qjs.JS_SetJobHook(runtime, null);
}

const InspectorEnabledTests = if (@import("build_options").inspector) struct {
    test "idle runtime cleanup does not clear another instance async state" {
        const idle_instance_id = 41;
        const active_instance_id = 42;
        async_stack.setDepth(active_instance_id, 1);
        defer async_stack.deinitInstance(active_instance_id);

        const cleanup = try std.heap.c_allocator.create(Cleanup);
        initCleanup(cleanup);
        cleanup.instance_id = idle_instance_id;
        runtimeFinalizer(null, @ptrCast(cleanup));
        try std.testing.expectEqual(@as(u32, 1), async_stack.depth(active_instance_id));
    }
};

comptime {
    _ = InspectorEnabledTests;
}

fn onJob(ctx: ?*qjs.JSContext, phase: c_int, kind: [*c]const u8) callconv(.c) c_int {
    if (ctx == null) return 0;
    const ptr = qjs.JS_GetContextOpaque(ctx);
    const instance_id: i32 = @bitCast(@as(u32, @truncate(@intFromPtr(ptr))));
    @import("../../tests/debug_cold_probe.zig").noteJobHookCallback();
    const label = if (kind != null) std.mem.span(kind) else "";
    return @intFromBool(async_stack.onJob(instance_id, phase, label));
}

fn runtimeFinalizer(rt: ?*qjs.JSRuntime, arg: ?*anyopaque) callconv(.c) void {
    const cleanup: *Cleanup = @ptrCast(@alignCast(arg orelse return));
    cleanup_mutex.lock();
    defer cleanup_mutex.unlock();
    if (rt) |runtime| _ = cleanup_by_runtime.remove(runtime);
    if (cleanup.instance_id) |instance_id| async_stack.deinitInstance(instance_id);
    std.heap.c_allocator.destroy(cleanup);
    if (cleanup_by_runtime.count() == 0) {
        cleanup_by_runtime.deinit(std.heap.c_allocator);
        cleanup_by_runtime = .{};
    }
}
