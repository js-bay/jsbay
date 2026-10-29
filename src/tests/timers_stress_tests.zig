const std = @import("std");
const io = @import("../platform/io.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const helpers = @import("test_helpers.zig");

const ActiveEngine = backend.ActiveEngine;
const quickjs_api = backend.ActiveEngineModule;
const qjs = quickjs_api.qjs;
const timer_count: u32 = 50_000;
const canceled_count: u32 = timer_count / 2;

var fired_count: std.atomic.Value(u32) = .init(0);
var fired_by_id: [timer_count]u8 = undefined;
var invalid_callback_ids: std.atomic.Value(u32) = .init(0);

fn jsCountTimer(ctx: ?*qjs.JSContext, this_value: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = this_value;
    var timer_index: i32 = -1;
    if (ctx) |nonnull_ctx| {
        if (argc == 1 and qjs.JS_ToInt32(nonnull_ctx, &timer_index, argv[0]) == 0 and timer_index >= 0 and timer_index < @as(i32, timer_count)) {
            fired_by_id[@intCast(timer_index)] +%= 1;
        } else {
            _ = invalid_callback_ids.fetchAdd(1, .seq_cst);
        }
    } else {
        _ = invalid_callback_ids.fetchAdd(1, .seq_cst);
    }
    _ = fired_count.fetchAdd(1, .seq_cst);
    return quickjs_api.mkval(qjs.JS_TAG_UNDEFINED);
}

fn installStressCallback(id: i32) void {
    const ctx = engine.getContext(id) orelse return;
    const global = ActiveEngine.getGlobalObject(ctx);
    ActiveEngine.setPropertyStr(
        ctx,
        global,
        "__stressBump__",
        ActiveEngine.newCFunction(ctx, &jsCountTimer, "__stressBump__", 0),
    );
    ActiveEngine.freeValue(ctx, global);
}

test "timers stress: schedule, cancel, and fire fifty thousand timers" {
    const testing = std.testing;
    fired_count.store(0, .seq_cst);
    invalid_callback_ids.store(0, .seq_cst);
    @memset(&fired_by_id, 0);
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .resource_limits = .{ .max_timers = timer_count } }));
    defer engine.destroy(id);
    installStressCallback(id);

    const schedule_started = @import("zev").monotonicMilliseconds();
    try helpers.evalOk(
        id,
        "var __stressIds__=[];" ++
            "for(var i=0;i<50000;i++) __stressIds__.push(setTimeout((function(n){return function(){__stressBump__(n)}})(i),i%4<2?5:60000));" ++
            "for(var i=0;i<__stressIds__.length;i+=2) clearTimeout(__stressIds__[i]);",
    );
    const schedule_ms = @import("zev").monotonicMilliseconds() - schedule_started;

    const fire_started = @import("zev").monotonicMilliseconds();
    var iterations: u32 = 0;
    const near_timer_count = timer_count / 4;
    // A loop turn runs one task, so draining N due timers takes N turns; only idle turns (nothing due yet) need to wait.
    const iteration_limit = near_timer_count + 3000;
    while (fired_count.load(.seq_cst) < near_timer_count and iterations < iteration_limit) : (iterations += 1) {
        const fired_before = fired_count.load(.seq_cst);
        engine.runEventLoopOnce(id);
        if (fired_count.load(.seq_cst) == fired_before) io.sleepMs(1);
    }
    const near_fire_ms = @import("zev").monotonicMilliseconds() - fire_started;

    try testing.expectEqual(near_timer_count, fired_count.load(.seq_cst));
    try helpers.evalOk(id, "for(var i=3;i<__stressIds__.length;i+=4) clearTimeout(__stressIds__[i]);");

    const late_check_started = @import("zev").monotonicMilliseconds();
    while (@import("zev").monotonicMilliseconds() - late_check_started < 80) {
        engine.runEventLoopOnce(id);
        io.sleepMs(1);
    }

    try testing.expectEqual(near_timer_count, fired_count.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), invalid_callback_ids.load(.seq_cst));
    for (fired_by_id, 0..) |count, index| {
        const expected: u8 = if (index % 4 == 1) 1 else 0;
        try testing.expectEqual(expected, count);
    }
    std.debug.print(
        "timer stress: scheduled={d} canceled={d} near_fired={d} far_canceled={d} schedule_ms={d} near_fire_ms={d} late_check_ms=80\n",
        .{ timer_count, canceled_count, near_timer_count, near_timer_count, schedule_ms, near_fire_ms },
    );
}
