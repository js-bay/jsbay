//! Public module surface tests. These deliberately import root.zig instead of backend.zig so a consumer cannot rely on an internal module path.

const std = @import("std");
const testing = std.testing;
const js_bay = @import("../root.zig");

test "public module: qjs is the active QuickJS C module" {
    if (comptime @hasDecl(js_bay.qjs, "JSContext")) {
        const context: ?*js_bay.qjs.JSContext = null;
        try testing.expect(context == null);
    } else {
        try testing.expect(@sizeOf(js_bay.qjs) == 0);
    }
}

test "public module: event loops expose lifecycle controls without manual clock driving" {
    inline for (.{ "js_bay_engine_attach_loop", "js_bay_engine_detach_loop", "js_bay_engine_run_loop", "js_bay_engine_stop_loop", "js_bay_engine_loop_status" }) |name| {
        try testing.expect(@hasDecl(js_bay.c_api, name));
    }
    try testing.expect(!@hasDecl(js_bay.c_api, "js_bay_engine_tick"));
    try testing.expect(!@hasDecl(js_bay.c_api, "js_bay_engine_set_wake_handler"));
}

test "public module: Zig helpers submit work but cannot drive a turn" {
    inline for (.{ "NativeTask", "InstanceToken", "DispatchArg", "postTask", "captureInstanceToken", "postTaskWithToken", "callGlobalRetained", "callGlobalRetainedArgs", "emitGlobal", "releaseTasksForOwner", "isRunningTaskForOwner" }) |name| {
        try testing.expect(@hasDecl(js_bay.dispatch, name));
    }
    inline for (.{ "runOneTask", "tickInstance", "DispatchTurn", "TaskCompletion", "NativeTaskQueue", "setPostCheckedHookForTesting", "failNextQueueAllocationForTesting" }) |name| {
        try testing.expect(!@hasDecl(js_bay.dispatch, name));
    }
    inline for (.{ "TsfnHandle", "acquire", "call", "release" }) |name| {
        try testing.expect(@hasDecl(js_bay.tsfn, name));
    }
    inline for (.{ "runOne", "drainPending", "releaseAllForInstance" }) |name| {
        try testing.expect(!@hasDecl(js_bay.tsfn, name));
    }
    try testing.expect(!@hasDecl(js_bay, "instance_map"));
    try testing.expect(!@hasDecl(js_bay, "timers"));
}
