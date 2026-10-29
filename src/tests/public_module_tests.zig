//! Public module surface tests. These deliberately import root.zig instead of backend.zig so a consumer cannot rely on an internal module path.

const std = @import("std");
const testing = std.testing;
const jsbay = @import("../root.zig");

test "public module: qjs is the active QuickJS C module" {
    if (comptime @hasDecl(jsbay.qjs, "JSContext")) {
        const context: ?*jsbay.qjs.JSContext = null;
        try testing.expect(context == null);
    } else {
        try testing.expect(@sizeOf(jsbay.qjs) == 0);
    }
}

test "public module: event loops expose lifecycle controls without manual clock driving" {
    inline for (.{ "jsbay_engine_attach_loop", "jsbay_engine_detach_loop", "jsbay_engine_run_loop", "jsbay_engine_stop_loop", "jsbay_engine_suspend", "jsbay_engine_resume", "jsbay_engine_is_suspended", "jsbay_engine_loop_status" }) |name| {
        try testing.expect(@hasDecl(jsbay.c_api, name));
    }
    try testing.expect(!@hasDecl(jsbay.c_api, "jsbay_engine_tick"));
    try testing.expect(!@hasDecl(jsbay.c_api, "jsbay_engine_set_wake_handler"));
}

test "public module: resource limit C surface is re-exported" {
    inline for (.{ "ResourceLimitsC", "ResourceUsageC", "ResourceGlobalUsageC", "jsbay_engine_create_with_limits", "jsbay_engine_set_resource_limits", "jsbay_engine_get_resource_usage", "jsbay_resource_global_usage" }) |name| {
        try testing.expect(@hasDecl(jsbay.c_api, name));
    }
}

test "public module: Zig helpers submit work but cannot drive a turn" {
    inline for (.{ "NativeTask", "InstanceToken", "DispatchArg", "postTask", "captureInstanceToken", "postTaskWithToken", "callGlobalRetained", "callGlobalRetainedArgs", "emitGlobal", "releaseTasksForOwner", "isRunningTaskForOwner" }) |name| {
        try testing.expect(@hasDecl(jsbay.dispatch, name));
    }
    inline for (.{ "runOneTask", "tickInstance", "DispatchTurn", "TaskCompletion", "NativeTaskQueue", "setPostCheckedHookForTesting", "failNextQueueAllocationForTesting" }) |name| {
        try testing.expect(!@hasDecl(jsbay.dispatch, name));
    }
    inline for (.{ "TsfnHandle", "acquire", "call", "release" }) |name| {
        try testing.expect(@hasDecl(jsbay.tsfn, name));
    }
    inline for (.{ "runOne", "drainPending", "releaseAllForInstance" }) |name| {
        try testing.expect(!@hasDecl(jsbay.tsfn, name));
    }
    try testing.expect(!@hasDecl(jsbay, "instance_map"));
    try testing.expect(!@hasDecl(jsbay, "timers"));
}
