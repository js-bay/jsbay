const std = @import("std");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const backend = @import("../backend.zig");
const tsfn = @import("../runtime/tsfn.zig");
const ActiveEngine = backend.ActiveEngine;

test "containment limits reject excess live native timers and recover after cancellation" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try helpers.evalOk(id, "globalThis.ids=[];globalThis.rejected=false;try{for(let i=0;i<4097;i++)ids.push(setTimeout(()=>{},2147483647));}catch(e){rejected=true}");
    try std.testing.expectEqual(@as(i64, 1), try helpers.evalInt(id, "Number(rejected)"));
    try helpers.evalOk(id, "ids.forEach(clearTimeout);ids=[];ids.push(setTimeout(()=>{},2147483647));");
    try std.testing.expectEqual(@as(i64, 1), try helpers.evalInt(id, "ids.length"));
}

test "containment limits bound TSFN payloads before copying" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ctx = engine.getContext(id) orelse return error.NoContext;
    try helpers.evalOk(id, "globalThis.cb=()=>{};");
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const cb = ActiveEngine.getPropertyVal(ctx, global, "cb") orelse return error.NoCallback;
    defer ActiveEngine.freeValue(ctx, cb);
    const h = tsfn.acquire(id, cb) orelse return error.NoHandle;
    defer tsfn.release(h);
    const payload = try std.testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    try std.testing.expect(!tsfn.call(h, payload));
    try std.testing.expect(tsfn.call(h, "ok"));
    try std.testing.expectEqual(@as(usize, 1), tsfn.drainPending(id));
}

test "containment limits share TSFN capacity across handles and reclaim it after drain" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(engine.create(id, .{ .resource_limits = .{ .max_pending_calls = 2, .max_pending_bytes = 4, .max_tsfn_handles = 2 } }));
    defer engine.destroy(id);
    const ctx = engine.getContext(id) orelse return error.NoContext;
    try helpers.evalOk(id, "globalThis.cb=()=>{};");
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const cb = ActiveEngine.getPropertyVal(ctx, global, "cb") orelse return error.NoCallback;
    defer ActiveEngine.freeValue(ctx, cb);
    const a = tsfn.acquire(id, cb) orelse return error.NoHandle;
    defer tsfn.release(a);
    const b = tsfn.acquire(id, cb) orelse return error.NoHandle;
    defer tsfn.release(b);
    try std.testing.expect(tsfn.acquire(id, cb) == null);
    try std.testing.expect(tsfn.call(a, "aa"));
    try std.testing.expect(tsfn.call(b, "bb"));
    try std.testing.expect(!tsfn.call(b, ""));
    try std.testing.expectEqual(@as(usize, 2), tsfn.drainPending(id));
    try std.testing.expect(tsfn.call(a, "cccc"));
    try std.testing.expect(!tsfn.call(b, "x"));
    try std.testing.expectEqual(@as(usize, 1), tsfn.drainPending(id));
}

test "containment limits restore timer quota after destroy and instance id reuse" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(engine.create(id, .{ .resource_limits = .{ .max_timers = 1 } }));
    try helpers.evalOk(id, "setTimeout(()=>{},2147483647)");
    try helpers.evalErr(id, "setTimeout(()=>{},2147483647)");
    engine.destroy(id);
    try std.testing.expect(engine.create(id, .{ .resource_limits = .{ .max_timers = 1 } }));
    defer engine.destroy(id);
    try helpers.evalOk(id, "setTimeout(()=>{},2147483647)");
}

test "containment limits bound native task admission and restore capacity after cancellation" {
    const dispatch = @import("../runtime/dispatch.zig");
    const id = helpers.nextInstanceId();
    try std.testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const Task = struct {
        fn run(_: ?*anyopaque) void {}
    };
    for (0..4096) |_| try std.testing.expect(dispatch.postTask(id, .{ .ctx = null, .run = Task.run }));
    try std.testing.expect(!dispatch.postTask(id, .{ .ctx = null, .run = Task.run }));
    dispatch.releaseAllTasksForInstance(id);
    try std.testing.expect(dispatch.postTask(id, .{ .ctx = null, .run = Task.run }));
    try std.testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
}

test "containment limits bound script dispatch and reclaim queue bytes" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(engine.create(id, .{ .resource_limits = .{ .max_pending_tasks = 2 } }));
    defer engine.destroy(id);
    try helpers.evalOk(id, "globalThis.calls=0");
    try std.testing.expect(engine.dispatchTask(id, "calls++"));
    try std.testing.expect(engine.dispatchTask(id, "calls++"));
    try std.testing.expect(!engine.dispatchTask(id, "calls+=100"));
    _ = engine.testing.advance(id, 0);
    _ = engine.testing.advance(id, 0);
    try std.testing.expectEqual(@as(i64, 2), try helpers.evalInt(id, "calls"));
    try std.testing.expect(engine.dispatchTask(id, "calls++"));
    _ = engine.testing.advance(id, 0);
    try std.testing.expectEqual(@as(i64, 3), try helpers.evalInt(id, "calls"));
}

test "containment limits survive interval callback destruction and instance id reuse" {
    const types = @import("../types.zig");
    const Host = struct {
        fn log(id: i32, _: types.LogLevel, _: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
            engine.destroy(id);
        }
    };
    const id = helpers.nextInstanceId();
    try std.testing.expect(engine.create(id, .{ .log_handler = Host.log, .resource_limits = .{ .max_timers = 1 } }));
    try helpers.evalOk(id, "setInterval(()=>console.log('close'),0)");
    _ = engine.testing.advance(id, 0);
    try std.testing.expect(engine.getContext(id) == null);
    try std.testing.expect(engine.create(id, .{ .resource_limits = .{ .max_timers = 1 } }));
    defer engine.destroy(id);
    try helpers.evalOk(id, "setTimeout(()=>{},2147483647)");
    try helpers.expectEvalEquals(id, "6*7", "42");
}

test "containment limits keep direct timer drains alive through callback destruction" {
    const types = @import("../types.zig");
    const timers = @import("../runtime/timers.zig");
    const instances = @import("../runtime/instance_map.zig");
    const Host = struct {
        fn log(id: i32, _: types.LogLevel, _: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
            engine.destroy(id);
        }
    };
    for ([_]bool{ false, true }) |single| {
        const id = helpers.nextInstanceId();
        try std.testing.expect(engine.create(id, .{ .log_handler = Host.log }));
        try helpers.evalOk(id, "setInterval(()=>console.log('close'),0)");
        _ = timers.beginTick(id, 0) orelse return error.NoTimer;
        const instance = instances.getInstance(id) orelse return error.NoInstance;
        @import("js_event_loop").Driver.testing.dispatchEvents(instance.loop, 0);
        timers.endTick(id);
        if (single) {
            try std.testing.expect(timers.fireOneDue(id, 0));
        } else timers.fireDue(id, 0);
        try std.testing.expect(engine.getContext(id) == null);
    }
}

test "containment limits keep direct TSFN drain alive through callback destruction" {
    const types = @import("../types.zig");
    const Host = struct {
        fn log(id: i32, _: types.LogLevel, _: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
            engine.destroy(id);
        }
    };
    const id = helpers.nextInstanceId();
    try std.testing.expect(engine.create(id, .{ .log_handler = Host.log }));
    try helpers.evalOk(id, "globalThis.cb=()=>console.log('close')");
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    const cb = ActiveEngine.getPropertyVal(ctx, global, "cb") orelse return error.NoCallback;
    const h = tsfn.acquire(id, cb) orelse return error.NoHandle;
    ActiveEngine.freeValue(ctx, cb);
    ActiveEngine.freeValue(ctx, global);
    try std.testing.expect(tsfn.call(h, ""));
    try std.testing.expect(tsfn.runOne(id));
    try std.testing.expect(engine.getContext(id) == null);
    try std.testing.expect(!tsfn.call(h, "late"));
}
