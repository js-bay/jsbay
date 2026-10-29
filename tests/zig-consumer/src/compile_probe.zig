const jsbay = @import("jsbay");

comptime {
    if (@hasDecl(jsbay, "engine") or
        @hasDecl(jsbay.c_api, "jsbay_engine_stop_event_loop") or
        @hasDecl(jsbay.c_api, "failNextSetKeyAllocationForTesting") or
        @hasDecl(jsbay.c_api, "test_only"))
    {
        @compileError("production Zig consumers may use only the typed c_api surface");
    }
    for (.{ "runOneTask", "tickInstance", "DispatchTurn", "TaskCompletion", "NativeTaskQueue", "setPostCheckedHookForTesting", "failNextQueueAllocationForTesting" }) |name| {
        if (@hasDecl(jsbay.dispatch, name)) @compileError("production Zig consumers cannot manually drive dispatch");
    }
    for (.{ "runOne", "drainPending", "releaseAllForInstance" }) |name| {
        if (@hasDecl(jsbay.tsfn, name)) @compileError("production Zig consumers cannot manually drive TSFN delivery");
    }
    if (@hasDecl(jsbay, "instance_map") or @hasDecl(jsbay, "timers")) @compileError("production Zig consumers cannot access loop internals");
}

pub export fn public_consumer_probe() c_int {
    const id = 8123;
    if (!jsbay.c_api.jsbay_engine_create(id, null, null)) return 1;
    defer jsbay.c_api.jsbay_engine_destroy(id);
    var value: u64 = 0;
    var exception: u64 = 0;
    const source = jsbay.c_api.Utf8{ .data = "40+2", .len = 4 };
    const filename = jsbay.c_api.Utf8{ .data = "<compile-probe>", .len = "<compile-probe>".len };
    if (jsbay.c_api.jsbay_engine_evaluate(id, source, filename, null, &value, &exception) != 0) return 2;
    defer _ = jsbay.c_api.jsbay_value_release(value);
    return 0;
}
