pub const InspectorHost = struct {
    pub const backend = @import("../backend.zig");
    pub const engine = @import("../engine.zig");
    pub const engine_thread = @import("../runtime/engine_thread.zig");
    const root_dispatch = @import("../runtime/dispatch.zig");
    /// Inspector requests are explicit debugger/DevTools control work. The pause loop may execute them to inspect or resume the paused stack, but it never executes ordinary application tasks through this adapter.
    pub const dispatch = struct {
        pub const NativeTask = root_dispatch.NativeTask;
        pub const TaskOwnerFrame = root_dispatch.TaskOwnerFrame;

        pub fn postTask(instance_id: i32, task: NativeTask) bool {
            var control = task;
            control.debugger_control = true;
            return root_dispatch.postTask(instance_id, control);
        }

        pub const enterTaskOwnerFrame = root_dispatch.enterTaskOwnerFrame;
        pub const leaveTaskOwnerFrame = root_dispatch.leaveTaskOwnerFrame;
        pub const isRunningTaskForOwner = root_dispatch.isRunningTaskForOwner;
        pub const releaseTasksForOwner = root_dispatch.releaseTasksForOwner;
        pub const releaseAllTasksForInstance = root_dispatch.releaseAllTasksForInstance;
        pub const tickInstance = root_dispatch.tickInstance;
        pub const failNextQueueAllocationForTesting = root_dispatch.failNextQueueAllocationForTesting;
    };
    pub const debugger = @import("debugger.zig");
    pub const async_stack = @import("async_stack.zig");
    pub const console_tap = @import("console_tap.zig");
    pub const runtime_control = @import("../runtime/runtime_control.zig");
    pub const sample_hook = @import("sample_hook.zig");
    pub const types = @import("../types.zig");
    pub const instance_map = @import("../runtime/instance_map.zig");
    pub const io = @import("../platform/io.zig");
    pub const sync = @import("zev");
    pub const build_options = @import("build_options");
    pub const test_faults = @import("../tests/inspector_test_faults.zig");
    pub const quickjs_jobs = @import("../backend/quickjs/jobs.zig");
    pub const quickjs_ng_jobs = @import("../backend/quickjs_ng/jobs.zig");
    pub const jsc_async_hooks = @import("../backend/jsc/async_hooks.zig");
    pub const quickjs_c_api = @import("../backend/quickjs/c_api.zig");
    pub const quickjs_ng_c_api = @import("../backend/quickjs_ng/c_api.zig");
};
