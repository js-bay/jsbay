const backend = @import("../backend.zig");
const dispatch = @import("dispatch.zig");
const instance_map = @import("instance_map.zig");
const timers = @import("timers.zig");
const ActiveEngine = backend.ActiveEngine;

/// Free the scheduler and JS runtime for an instance after its engine thread and admitted calls have stopped.
pub fn destroyRuntimeGeneration(instance_id: i32, generation: u64) void {
    if (instance_map.generationOf(instance_id) != generation) return;
    const inspector_state = @import("../inspector/root.zig").state;
    if (!inspector_state.beginEngineDestroy(instance_id, generation)) @panic("engine generation teardown already active");
    defer inspector_state.endEngineDestroy(instance_id, generation);

    if (!dispatch.closeInstanceTasks(instance_id)) return;
    @import("../abi/api_async.zig").cancelForInstance(@import("../types.zig").InstanceId.fromInt(instance_id));
    @import("js_event_loop").host_wake.drop(instance_id);
    instance_map.waitForControlOps(instance_id);
    const instance = instance_map.getInstance(instance_id) orelse return;
    instance.loop.detach();
    dispatch.waitForInstanceTasks(instance_id);
    instance.task_mutex.lock();
    for (instance.task_queue.pendingSlice()) |task| {
        instance.allocator.free(task);
        instance.resources.release(.script_task, task.len);
    }
    instance.task_queue.clear(instance.allocator);
    instance.task_mutex.unlock();

    @import("../inspector/root.zig").dropInstance(instance_id);
    timers.cancelAll(instance);
    @import("../abi/api_bind.zig").dropInstance(instance_id);
    @import("../abi/api_value.zig").dropInstance(instance_id);
    @import("../abi/packed_api_value.zig").dropInstance(instance_id);
    @import("tsfn.zig").releaseAllForInstance(instance_id);
    @import("../script/cjs.zig").uninstall(instance_id);
    _ = @import("runtime_control.zig").deinit(instance_id);
    forceResetBookkeeping(&instance.ref_bookkeeping);
    @import("../backend/console_timers.zig").deinitInstance(instance_id);

    @import("../inspector/debugger.zig").detach(instance_id);
    switch (instance.engine_handles) {
        .mono => |m| {
            if (m.ctx != null and m.runtime != null) {
                ActiveEngine.runGc(m.runtime);
                ActiveEngine.freeContext(m.ctx);
                ActiveEngine.runGc(m.runtime);
                ActiveEngine.freeRuntime(m.runtime);
            }
        },
        .packed_alt => |a| @import("../backend_dispatch.zig").destroyPacked(a.tag, .{ .runtime_addr = a.runtime_addr, .ctx_addr = a.ctx_addr }),
    }
    @import("../inspector/async_stack.zig").deinitInstance(instance_id);

    var timer_reg = instance.timers;
    timer_reg.deinit();
    const removed = instance_map.removeGeneration(instance_id, generation) orelse
        @panic("engine generation changed during owned teardown");
    if (removed.execution_cpu) |ledger| ledger.close();
    removed.resources.deinit();
    removed.loop.destroy();
    removed.deinitSynchronization();
    removed.allocator.destroy(removed);
}

fn forceResetBookkeeping(book: *@import("instance_map.zig").RefBookkeeping) void {
    while (true) {
        book.mutex.lock();
        const entry = book.head orelse {
            book.mutex.unlock();
            break;
        };
        book.head = entry.next;
        if (book.head) |h| h.prev = null;
        entry.prev = null;
        entry.next = null;
        book.mutex.unlock();
        entry.reset_fn(entry);
    }
}
