const jsbay = @import("jsbay");

fn runQuickJs() !void {
    const runtime = jsbay.qjs.JS_NewRuntime() orelse return error.RuntimeCreationFailed;
    defer jsbay.qjs.JS_FreeRuntime(runtime);
    const context = jsbay.qjs.JS_NewContext(runtime) orelse return error.ContextCreationFailed;
    defer jsbay.qjs.JS_FreeContext(context);

    const Host = struct {
        fn answer(
            ctx: ?*jsbay.qjs.JSContext,
            _: jsbay.qjs.JSValue,
            _: c_int,
            _: [*c]jsbay.qjs.JSValue,
        ) callconv(.c) jsbay.qjs.JSValue {
            return jsbay.qjs.JS_NewInt32(ctx, 42);
        }
    };
    jsbay.quickjs_host.installGlobalFunctions(context, &.{
        .{ .name = "hostAnswer", .func = Host.answer, .argc = 0 },
    });
    const answer = try jsbay.quickjs_host.evalInt32(context, "hostAnswer()", "<external-consumer>");
    if (answer != 42) return error.WrongQuickJsAnswer;
}

const StopProbe = struct {
    calls: usize = 0,

    fn stop(instance_id: i32, user_data: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
        const self: *StopProbe = @ptrCast(@alignCast(user_data orelse return 1));
        self.calls += 1;
        out_value.* = 0;
        out_exception.* = 0;
        _ = jsbay.c_api.jsbay_engine_stop_loop(instance_id);
        return 0;
    }
};

fn runEngine() !void {
    const id: i32 = 987_654;
    if (!jsbay.c_api.jsbay_engine_create(id, null, null)) return error.EngineCreateFailed;
    defer jsbay.c_api.jsbay_engine_destroy(id);

    var value: u64 = 0;
    var exception: u64 = 0;
    const source = jsbay.c_api.Utf8{ .data = "40 + 2", .len = 6 };
    const filename = jsbay.c_api.Utf8{ .data = "<external-consumer>", .len = "<external-consumer>".len };
    if (jsbay.c_api.jsbay_engine_evaluate(id, source, filename, null, &value, &exception) != 0) return error.EngineEvalFailed;
    defer _ = jsbay.c_api.jsbay_value_release(value);
    var number: f64 = 0;
    if (jsbay.c_api.jsbay_value_to_number(value, &number) != 0 or number != 42) return error.WrongEngineAnswer;

    var probe: StopProbe = .{};
    var function: u64 = 0;
    var bind_exception: u64 = 0;
    const name = jsbay.c_api.Utf8{ .data = "__stopExternalConsumerLoop", .len = "__stopExternalConsumerLoop".len };
    if (jsbay.c_api.jsbay_engine_bind(id, name, StopProbe.stop, &probe, null, &function, &bind_exception) != 0) return error.EngineBindFailed;
    defer _ = jsbay.c_api.jsbay_value_release(function);
    defer {
        if (bind_exception != 0) _ = jsbay.c_api.jsbay_value_release(bind_exception);
    }

    const timer_source = jsbay.c_api.Utf8{ .data = "setTimeout(__stopExternalConsumerLoop, 1)", .len = "setTimeout(__stopExternalConsumerLoop, 1)".len };
    var timer_value: u64 = 0;
    var timer_exception: u64 = 0;
    if (jsbay.c_api.jsbay_engine_evaluate(id, timer_source, filename, null, &timer_value, &timer_exception) != 0) return error.TimerScheduleFailed;
    defer {
        if (timer_value != 0) _ = jsbay.c_api.jsbay_value_release(timer_value);
    }
    defer {
        if (timer_exception != 0) _ = jsbay.c_api.jsbay_value_release(timer_exception);
    }
    if (jsbay.c_api.jsbay_engine_run_loop(id) != 0) return error.EngineLoopFailed;
    if (probe.calls != 1) return error.TimerDidNotStopLoop;
}

pub fn main() !void {
    if (comptime @hasDecl(jsbay.qjs, "JSContext")) {
        try runQuickJs();
    }
    try runEngine();
}
