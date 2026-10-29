//! A finalizer registration runs once.
//!
//! Duktape's heap-destruction case: after a collection has already called the finalizer, destroying the runtime must not call it again. The same registration is also not re-entered while its callback is on the stack. Two different callbacks on one object are not that case; each still runs.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const io = @import("../platform/io.zig");
const reference = @import("../value/reference.zig");
const weakcb = @import("../value/weakcb.zig");
const qjs_backend = @import("../backend.zig").ActiveEngineModule;

const ActiveEngine = backend.ActiveEngine;

const Slot = struct {
    hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    depth: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    reentered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn countOnce(user_data: ?*anyopaque) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(user_data orelse return));
    const depth = slot.depth.fetchAdd(1, .seq_cst);
    if (depth != 0) slot.reentered.store(true, .seq_cst);
    _ = slot.hits.fetchAdd(1, .seq_cst);
    _ = slot.depth.fetchSub(1, .seq_cst);
}

test "finalizer contract: a callback that already ran is not run again on destroy" {
    var slot = Slot{};

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;

    try helpers.evalOk(id,
        \\globalThis.obj1 = {};
        \\globalThis.obj2 = {};
        \\globalThis.obj1.ref = globalThis.obj2;
        \\globalThis.obj2.ref = globalThis.obj1;
    );

    {
        const ctx = engine.getContext(id) orelse return error.NoContext;
        const global = ActiveEngine.getGlobalObject(ctx);
        defer ActiveEngine.freeValue(ctx, global);
        const obj = ActiveEngine.getPropertyVal(ctx, global, "obj1") orelse return error.NoObj;
        defer ActiveEngine.freeValue(ctx, obj);
        try testing.expect(weakcb.attachFinalizer(id, obj, @ptrCast(&slot), countOnce));
    }

    try helpers.evalOk(id,
        \\globalThis.obj1 = null;
        \\globalThis.obj2 = null;
    );
    engine.runGc(id);
    const mid = slot.hits.load(.seq_cst);

    engine.destroy(id);
    const end = slot.hits.load(.seq_cst);

    try testing.expect(!slot.reentered.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), end);
    // If collection already ran the callback, destroy must not add another.
    try testing.expect(mid == 0 or mid == end);
}

test "finalizer contract: distinct callbacks on one object each run once" {
    var slot_a = Slot{};
    var slot_b = Slot{};

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;

    {
        const ctx = engine.getContext(id) orelse return error.NoContext;
        const obj = ActiveEngine.newObject(ctx);
        try testing.expect(weakcb.attachFinalizer(id, obj, @ptrCast(&slot_a), countOnce));
        try testing.expect(weakcb.attachFinalizer(id, obj, @ptrCast(&slot_b), countOnce));
        ActiveEngine.freeValue(ctx, obj);
    }

    engine.runGc(id);
    engine.destroy(id);

    try testing.expect(!slot_a.reentered.load(.seq_cst));
    try testing.expect(!slot_b.reentered.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), slot_a.hits.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), slot_b.hits.load(.seq_cst));
}

test "finalizer contract: a failed attach never invokes a freed dispatch" {
    var slot = Slot{};
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try helpers.evalOk(id, "globalThis.noFinalizerSlot = Object.preventExtensions({});");
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const target = ActiveEngine.getPropertyVal(ctx, global, "noFinalizerSlot") orelse return error.NoObj;
    try testing.expect(!weakcb.attachFinalizer(id, target, @ptrCast(&slot), countOnce));
    ActiveEngine.freeValue(ctx, target);

    var round: u32 = 0;
    while (round < 4) : (round += 1) engine.runGc(id);
    try testing.expectEqual(@as(u32, 0), slot.hits.load(.seq_cst));
}

test "finalizer contract: QuickJS rejects a Proxy that accepts without storing a holder" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    var slot = Slot{};
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try helpers.evalOk(id,
        \\globalThis.proxyWithoutStorage = new Proxy({}, {
        \\  set(_target, _key, _value) { return true; }
        \\});
    );
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const proxy = ActiveEngine.getPropertyVal(ctx, global, "proxyWithoutStorage") orelse return error.NoProxy;
    defer ActiveEngine.freeValue(ctx, proxy);
    try testing.expect(!weakcb.attachFinalizer(id, proxy, @ptrCast(&slot), countOnce));

    try helpers.evalOk(id, "globalThis.proxyWithoutStorage = null;");
    var round: u32 = 0;
    while (round < 4) : (round += 1) engine.runGc(id);
    try testing.expectEqual(@as(u32, 0), slot.hits.load(.seq_cst));
}

test "finalizer contract: QuickJS defines holder as own property past a Proxy prototype" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    var slot = Slot{};
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try helpers.evalOk(id,
        \\globalThis.proxyPrototype = new Proxy({}, {
        \\  set(_target, _key, _value) { return true; }
        \\});
        \\globalThis.targetWithProxyPrototype = Object.create(proxyPrototype);
    );
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    {
        const target = ActiveEngine.getPropertyVal(ctx, global, "targetWithProxyPrototype") orelse return error.NoTarget;
        defer ActiveEngine.freeValue(ctx, target);
        try testing.expect(weakcb.attachFinalizer(id, target, @ptrCast(&slot), countOnce));
        try testing.expectEqual(@as(u32, 0), slot.hits.load(.seq_cst));
    }

    try helpers.evalOk(id, "globalThis.targetWithProxyPrototype = null; globalThis.proxyPrototype = null;");
    var round: u32 = 0;
    while (round < 4) : (round += 1) engine.runGc(id);
    try testing.expectEqual(@as(u32, 1), slot.hits.load(.seq_cst));
}

test "finalizer contract: QuickJS holder definition bypasses an inherited setter" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    var slot = Slot{};
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    const key_number = qjs_backend.qjsWeakNextFinalizerKeyForTesting();
    const setup = try std.fmt.allocPrint(
        testing.allocator,
        "globalThis.setterPrototype = {{}}; Object.defineProperty(setterPrototype, \"__$jsbay_qjs_Finalizer${d}$__\", {{ set(_value) {{ globalThis.setterHits++; }} }}); globalThis.setterTarget = Object.create(setterPrototype); globalThis.setterHits = 0;",
        .{key_number},
    );
    defer testing.allocator.free(setup);
    try helpers.evalOk(id, setup);
    const setter_probe = try std.fmt.allocPrint(
        testing.allocator,
        "setterTarget[\"__$jsbay_qjs_Finalizer${d}$__\"] = 1; if (setterHits !== 1) throw new Error('test setter was not reached'); if (Object.prototype.hasOwnProperty.call(setterTarget, \"__$jsbay_qjs_Finalizer${d}$__\")) throw new Error('setter probe stored an own property'); setterHits = 0;",
        .{ key_number, key_number },
    );
    defer testing.allocator.free(setter_probe);
    try helpers.evalOk(id, setter_probe);
    const assert_holder = try std.fmt.allocPrint(
        testing.allocator,
        "if (!Object.prototype.hasOwnProperty.call(setterTarget, \"__$jsbay_qjs_Finalizer${d}$__\")) throw new Error('finalizer holder is not an own property');",
        .{key_number},
    );
    defer testing.allocator.free(assert_holder);
    const assert_setter = "if (setterHits !== 0) throw new Error('attach invoked an inherited setter');";

    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    {
        const target = ActiveEngine.getPropertyVal(ctx, global, "setterTarget") orelse return error.NoTarget;
        defer ActiveEngine.freeValue(ctx, target);
        try testing.expect(weakcb.attachFinalizer(id, target, @ptrCast(&slot), countOnce));
        try testing.expectEqual(@as(u32, 0), slot.hits.load(.seq_cst));
        try helpers.evalOk(id, assert_holder);
        try helpers.evalOk(id, assert_setter);
    }

    try helpers.evalOk(id, "globalThis.setterTarget = null; globalThis.setterPrototype = null;");
    var round: u32 = 0;
    while (round < 4) : (round += 1) engine.runGc(id);
    try testing.expectEqual(@as(u32, 1), slot.hits.load(.seq_cst));
    try helpers.evalOk(id, "if (setterHits !== 0) throw new Error('inherited setter ran');");
}

const DestroySlot = struct {
    hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    saw_false: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    saw_true: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn noteDestroying(user_data: ?*anyopaque, destroying: bool) callconv(.c) void {
    const slot: *DestroySlot = @ptrCast(@alignCast(user_data orelse return));
    if (destroying) {
        slot.saw_true.store(true, .seq_cst);
    } else {
        slot.saw_false.store(true, .seq_cst);
    }
    _ = slot.hits.fetchAdd(1, .seq_cst);
}

noinline fn armCollected(id: i32, slot: *DestroySlot) bool {
    const ctx = engine.getContext(id) orelse return false;
    const obj = ActiveEngine.newObject(ctx);
    const ok = weakcb.attachDestroyingFinalizer(id, obj, @ptrCast(slot), noteDestroying);
    ActiveEngine.freeValue(ctx, obj);
    return ok;
}

test "finalizer contract: ordinary collection reports destroying false and engine destroy reports true" {
    var slot_gc = DestroySlot{};
    var slot_keep = DestroySlot{};

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try helpers.evalOk(id, "globalThis.keep = {};");
    {
        const ctx = engine.getContext(id) orelse return error.NoContext;
        const global = ActiveEngine.getGlobalObject(ctx);
        defer ActiveEngine.freeValue(ctx, global);
        const keep = ActiveEngine.getPropertyVal(ctx, global, "keep") orelse return error.NoObj;
        defer ActiveEngine.freeValue(ctx, keep);
        try testing.expect(weakcb.attachDestroyingFinalizer(id, keep, @ptrCast(&slot_keep), noteDestroying));
    }

    try testing.expect(armCollected(id, &slot_gc));
    var round: u32 = 0;
    while (round < 4) : (round += 1) engine.runGc(id);

    const gc_before = slot_gc.hits.load(.seq_cst);
    try testing.expectEqual(@as(u32, 0), slot_keep.hits.load(.seq_cst));

    engine.destroy(id);

    try testing.expectEqual(@as(u32, 1), slot_keep.hits.load(.seq_cst));
    try testing.expect(slot_keep.saw_true.load(.seq_cst));
    try testing.expect(!slot_keep.saw_false.load(.seq_cst));

    try testing.expectEqual(@as(u32, 1), slot_gc.hits.load(.seq_cst));
    if (gc_before != 0) {
        // Collected before destroy: Duktape's ordinary finalizer argument is false.
        try testing.expect(slot_gc.saw_false.load(.seq_cst));
        try testing.expect(!slot_gc.saw_true.load(.seq_cst));
    } else {
        // This backend did not run the callback until destroy. Do not invent false.
        try testing.expect(slot_gc.saw_true.load(.seq_cst));
        try testing.expect(!slot_gc.saw_false.load(.seq_cst));
    }
}

const ConcurrentDestroy = struct {
    id: i32,
    start: *std.atomic.Value(bool),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ConcurrentDestroy) void {
        while (!self.start.load(.seq_cst)) std.Thread.yield() catch {};
        engine.destroy(self.id);
        self.done.store(true, .seq_cst);
    }
};

test "finalizer contract: concurrent destroy frees an instance once" {
    var slot = DestroySlot{};
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    var destroyed = false;
    defer if (!destroyed) engine.destroy(id);

    try helpers.evalOk(id, "globalThis.keptForConcurrentDestroy = {};");
    {
        const ctx = engine.getContext(id) orelse return error.NoContext;
        const global = ActiveEngine.getGlobalObject(ctx);
        defer ActiveEngine.freeValue(ctx, global);
        const keep = ActiveEngine.getPropertyVal(ctx, global, "keptForConcurrentDestroy") orelse return error.NoObject;
        try testing.expect(weakcb.attachDestroyingFinalizer(id, keep, @ptrCast(&slot), noteDestroying));
        ActiveEngine.freeValue(ctx, keep);
    }

    var start = std.atomic.Value(bool).init(false);
    var first = ConcurrentDestroy{ .id = id, .start = &start };
    var second = ConcurrentDestroy{ .id = id, .start = &start };
    const t1 = try std.Thread.spawn(.{}, ConcurrentDestroy.run, .{&first});
    const t2 = try std.Thread.spawn(.{}, ConcurrentDestroy.run, .{&second});
    start.store(true, .seq_cst);
    t1.join();
    t2.join();
    destroyed = true;

    try testing.expect(first.done.load(.seq_cst));
    try testing.expect(second.done.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), slot.hits.load(.seq_cst));
}

const DestroyOtherInstance = struct {
    other_id: i32,
    returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn finalize(user_data: ?*anyopaque) callconv(.c) void {
        const self: *DestroyOtherInstance = @ptrCast(@alignCast(user_data.?));
        engine.destroy(self.other_id);
        self.returned.store(true, .seq_cst);
    }
};

const DestroyInstanceTask = struct {
    id: i32,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *DestroyInstanceTask) void {
        engine.destroy(self.id);
        self.done.store(true, .seq_cst);
    }
};

test "finalizer contract: destroying another instance with a colliding teardown gate returns" {
    var callback = DestroyOtherInstance{ .other_id = helpers.nextInstanceId() };
    const id = callback.other_id -% 64;
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    if (!engine.create(callback.other_id, .{})) return error.OtherEngineCreateFailed;
    var destroyed_a = false;
    var destroyed_b = false;
    defer {
        if (!destroyed_a) engine.destroy(id);
        if (!destroyed_b) engine.destroy(callback.other_id);
    }

    try helpers.evalOk(id, "globalThis.destroyOtherOnTeardown = {};");
    {
        const ctx = engine.getContext(id) orelse return error.NoContext;
        const global = ActiveEngine.getGlobalObject(ctx);
        defer ActiveEngine.freeValue(ctx, global);
        const target = ActiveEngine.getPropertyVal(ctx, global, "destroyOtherOnTeardown") orelse return error.NoTarget;
        try testing.expect(weakcb.attachFinalizer(id, target, @ptrCast(&callback), DestroyOtherInstance.finalize));
        ActiveEngine.freeValue(ctx, target);
    }

    var destroy = DestroyInstanceTask{ .id = id };
    const thread = try std.Thread.spawn(.{}, DestroyInstanceTask.run, .{&destroy});
    var watchdog_ticks: usize = 0;
    while (!destroy.done.load(.seq_cst)) : (watchdog_ticks += 1) {
        if (watchdog_ticks >= 3000) {
            std.debug.print("nested destroy of a colliding instance did not return\n", .{});
            std.process.exit(1);
        }
        io.sleepMs(1);
    }
    thread.join();
    destroyed_a = true;
    destroyed_b = true;

    try testing.expect(callback.returned.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);
    try testing.expect(engine.getContext(callback.other_id) == null);
}

const DeferredSlot = struct {
    instance_id: i32,
    ran: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    in_finalizer: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    eval_two: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn deferredUser(user_data: ?*anyopaque) callconv(.c) void {
    const slot: *DeferredSlot = @ptrCast(@alignCast(user_data orelse return));
    slot.in_finalizer.store(weakcb.inFinalizer(), .seq_cst);
    const res = engine.evalScript(slot.instance_id, "1+1", "<deferred>");
    const two = if (res.err != null) false else blk: {
        const text = res.result orelse break :blk false;
        break :blk std.mem.eql(u8, text, "2");
    };
    helpers.freeEvalResult(res);
    slot.eval_two.store(two, .seq_cst);
    slot.ran.store(true, .seq_cst);
}

noinline fn armDeferred(id: i32, slot: *DeferredSlot) bool {
    const ctx = engine.getContext(id) orelse return false;
    const obj = ActiveEngine.newObject(ctx);
    const ok = weakcb.attachDeferredFinalizer(id, obj, @ptrCast(slot), deferredUser);
    ActiveEngine.freeValue(ctx, obj);
    return ok;
}

test "finalizer contract: deferred finalizer runs off the finalizer stack and can eval" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    var slot = DeferredSlot{ .instance_id = id };
    try testing.expect(armDeferred(id, &slot));
    // The GC callback only enqueues. The user function has not run yet.
    try testing.expect(!slot.ran.load(.seq_cst));

    var round: u32 = 0;
    while (round < 8 and !slot.ran.load(.seq_cst)) : (round += 1) {
        engine.runGc(id);
        engine.runEventLoopOnce(id);
        if (engine.getContext(id)) |ctx| ActiveEngine.processPendingJobs(ctx);
    }

    try testing.expect(slot.ran.load(.seq_cst));
    try testing.expect(!slot.in_finalizer.load(.seq_cst));
    try testing.expect(slot.eval_two.load(.seq_cst));
}

// A native Global is a strong root. The object it holds is collected only when the runtime is torn down, and the finalizer must still run exactly once, with the destroy flag set, after the Global has been force-reset.
noinline fn armGlobalHeld(id: i32, slot: *DestroySlot, held: *reference.Global(reference.Local)) bool {
    const ctx = engine.getContext(id) orelse return false;
    const obj = ActiveEngine.newObject(ctx);
    held.* = reference.Global(reference.Local).init(id, obj);
    const ok = weakcb.attachDestroyingFinalizer(id, obj, @ptrCast(slot), noteDestroying);
    ActiveEngine.freeValue(ctx, obj);
    return ok;
}

test "finalizer contract: an object held by a native Global is finalized once by destroy" {
    var slot = DestroySlot{};
    var held = reference.Global(reference.Local).initEmpty(0);
    defer held.deinit();

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    var destroyed = false;
    defer if (!destroyed) engine.destroy(id);

    try testing.expect(armGlobalHeld(id, &slot, &held));
    try testing.expect(!held.isEmpty());

    var round: u32 = 0;
    while (round < 4) : (round += 1) engine.runGc(id);
    // Still rooted: no collection may have finalized it.
    try testing.expectEqual(@as(u32, 0), slot.hits.load(.seq_cst));
    try testing.expect(!held.isEmpty());

    engine.destroy(id);
    destroyed = true;

    try testing.expectEqual(@as(u32, 1), slot.hits.load(.seq_cst));
    try testing.expect(slot.saw_true.load(.seq_cst));
    try testing.expect(!slot.saw_false.load(.seq_cst));
    try testing.expect(held.isEmpty());
    try testing.expect(held.get() == null);
}

const MassSlot = struct {
    hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn countMass(user_data: ?*anyopaque) callconv(.c) void {
    const slot: *MassSlot = @ptrCast(@alignCast(user_data orelse return));
    _ = slot.hits.fetchAdd(1, .seq_cst);
}

noinline fn armMass(id: i32, slot: *MassSlot, count: usize) !void {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obj = ActiveEngine.newObject(ctx);
        defer ActiveEngine.freeValue(ctx, obj);
        try testing.expect(weakcb.attachFinalizer(id, obj, @ptrCast(slot), countMass));
    }
}

// Every registration is accounted for exactly once however the collector batches them. The conservative JSC collector may keep some garbage alive until teardown, so the exact total is asserted after destroy on every backend and before destroy only where collection is precise.
test "finalizer contract: a large batch of unreachable objects finalizes exactly once each" {
    const count = 512;
    var slot = MassSlot{};

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    var destroyed = false;
    defer if (!destroyed) engine.destroy(id);

    try armMass(id, &slot, count);
    var round: u32 = 0;
    while (round < 4) : (round += 1) engine.runGc(id);
    const before_destroy = slot.hits.load(.seq_cst);
    try testing.expect(before_destroy <= count);
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        try testing.expectEqual(@as(u32, count), before_destroy);
    }

    engine.destroy(id);
    destroyed = true;
    try testing.expectEqual(@as(u32, count), slot.hits.load(.seq_cst));
}

const FnPair = struct {
    target_hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    bound_hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

const FnPairSide = struct {
    pair: *FnPair,
    bound: bool,
};

fn countFnSide(user_data: ?*anyopaque) callconv(.c) void {
    const side: *FnPairSide = @ptrCast(@alignCast(user_data orelse return));
    const counter = if (side.bound) &side.pair.bound_hits else &side.pair.target_hits;
    _ = counter.fetchAdd(1, .seq_cst);
}

noinline fn armFnCycle(id: i32, target_side: *FnPairSide, bound_side: *FnPairSide) !void {
    try helpers.evalOk(id,
        \\globalThis.__fnTarget = function target() { return 1; };
        \\globalThis.__fnBound = __fnTarget.bind(null);
        \\__fnTarget.self = __fnTarget;
        \\__fnTarget.bound = __fnBound;
        \\__fnBound.target = __fnTarget;
        \\__fnTarget.prototype.owner = __fnTarget;
    );
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const target = ActiveEngine.getPropertyVal(ctx, global, "__fnTarget") orelse return error.NoTarget;
    defer ActiveEngine.freeValue(ctx, target);
    const bound = ActiveEngine.getPropertyVal(ctx, global, "__fnBound") orelse return error.NoBound;
    defer ActiveEngine.freeValue(ctx, bound);
    try testing.expect(weakcb.attachFinalizer(id, target, @ptrCast(target_side), countFnSide));
    try testing.expect(weakcb.attachFinalizer(id, bound, @ptrCast(bound_side), countFnSide));
}

// A function that references itself through its own properties and its prototype, together with a bound copy that points back, is one cycle. The collector must reclaim it and run each registration once.
test "finalizer contract: a self-referencing function and its bound copy finalize once each" {
    var pair = FnPair{};
    var target_side = FnPairSide{ .pair = &pair, .bound = false };
    var bound_side = FnPairSide{ .pair = &pair, .bound = true };

    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    var destroyed = false;
    defer if (!destroyed) engine.destroy(id);

    try armFnCycle(id, &target_side, &bound_side);
    try helpers.evalOk(id, "globalThis.__fnTarget = null; globalThis.__fnBound = null;");
    var round: u32 = 0;
    while (round < 4) : (round += 1) engine.runGc(id);
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        try testing.expectEqual(@as(u32, 1), pair.target_hits.load(.seq_cst));
        try testing.expectEqual(@as(u32, 1), pair.bound_hits.load(.seq_cst));
    }

    engine.destroy(id);
    destroyed = true;
    try testing.expectEqual(@as(u32, 1), pair.target_hits.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), pair.bound_hits.load(.seq_cst));
}

const GcInDeferred = struct {
    id: i32,
    hits: [8]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(0)),
    evals_ok: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

const GcInDeferredItem = struct {
    owner: *GcInDeferred,
    index: usize,
};

// Runs a collection from inside a deferred callback. That is allowed because the callback is outside the finalizer frame; finalizers the nested collection produces are queued and run in the same drain.
fn collectInDeferred(user_data: ?*anyopaque) callconv(.c) void {
    const item: *GcInDeferredItem = @ptrCast(@alignCast(user_data orelse return));
    const owner = item.owner;
    _ = owner.hits[item.index].fetchAdd(1, .seq_cst);
    engine.runGc(owner.id);
    const res = engine.evalScript(owner.id, "6 * 7", "<deferred-gc>");
    if (res.err == null) {
        if (res.result) |text| {
            if (std.mem.eql(u8, text, "42")) _ = owner.evals_ok.fetchAdd(1, .seq_cst);
        }
    }
    helpers.freeEvalResult(res);
}

noinline fn armDeferredBatch(id: i32, items: []GcInDeferredItem) !void {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    for (items) |*item| {
        const obj = ActiveEngine.newObject(ctx);
        defer ActiveEngine.freeValue(ctx, obj);
        try testing.expect(weakcb.attachDeferredFinalizer(id, obj, @ptrCast(item), collectInDeferred));
    }
}

test "finalizer contract: deferred finalizers may run a collection and each run once" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    var destroyed = false;
    defer if (!destroyed) engine.destroy(id);

    var owner = GcInDeferred{ .id = id };
    var items: [8]GcInDeferredItem = undefined;
    for (&items, 0..) |*item, i| item.* = .{ .owner = &owner, .index = i };
    try armDeferredBatch(id, &items);

    var round: u32 = 0;
    while (round < 16) : (round += 1) {
        engine.runGc(id);
        engine.runEventLoopOnce(id);
        if (engine.getContext(id)) |ctx| ActiveEngine.processPendingJobs(ctx);
    }

    var total: u32 = 0;
    for (&owner.hits) |*hit| {
        const n = hit.load(.seq_cst);
        // No registration may ever run twice, even though the nested collections kept refilling the queue.
        try testing.expect(n <= 1);
        total += n;
    }
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        try testing.expectEqual(@as(u32, 8), total);
    } else {
        try testing.expect(total >= 1);
    }
    try testing.expectEqual(total, owner.evals_ok.load(.seq_cst));

    // Jobs still queued at destroy are dropped, not run, so the counts cannot grow.
    engine.destroy(id);
    destroyed = true;
    var after: u32 = 0;
    for (&owner.hits) |*hit| after += hit.load(.seq_cst);
    try testing.expectEqual(total, after);
}
