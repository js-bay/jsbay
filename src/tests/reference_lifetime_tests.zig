//! Reference lifetime contracts: weak collection, engine teardown, and Rooted.
//!
//! Object handles are created and released inside helpers so a JSC conservative stack scan cannot keep them alive across `engine.runGc`.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const reference = @import("../value/reference.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");
const sync = @import("zev");

const ActiveEngine = backend.ActiveEngine;

const large_count: usize = 16;

const RefDestroyProbe = struct {
    const Event = enum { none, waiting, drained };

    instance_id: i32,
    mutex: sync.Mutex = .{},
    condition: sync.Condition = .init,
    release_entered: bool = false,
    resume_release: bool = false,
    owner_ready: bool = false,
    owner_done: bool = false,
    destroy_done: bool = false,
    resume_drain: bool = false,
    event: Event = .none,
    destroy_from_release: bool = false,
    pause_release: bool = true,
    deinit_after_drain: bool = false,
    request_deinit: bool = false,
    release_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn releaseHook(raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        _ = self.release_count.fetchAdd(1, .seq_cst);
        if (self.destroy_from_release) {
            engine.destroy(self.instance_id);
            return;
        }
        if (!self.pause_release) return;
        self.mutex.lock();
        self.release_entered = true;
        self.condition.broadcast();
        while (!self.resume_release) self.condition.wait(&self.mutex);
        self.mutex.unlock();
    }

    fn waitHook(raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.mutex.lock();
        self.event = .waiting;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    fn drainHook(raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.mutex.lock();
        self.event = .drained;
        self.condition.broadcast();
        while (!self.resume_drain) self.condition.wait(&self.mutex);
        self.mutex.unlock();
    }

    fn ownerThread(self: *@This()) void {
        if (!engine.create(self.instance_id, .{})) return;
        const ctx = engine.getContext(self.instance_id) orelse return;
        const value = ActiveEngine.newObject(ctx);
        var global = reference.Global(reference.Local).init(self.instance_id, value);
        ActiveEngine.freeValue(ctx, value);
        self.mutex.lock();
        self.owner_ready = true;
        self.condition.broadcast();
        while (self.deinit_after_drain and !self.request_deinit) self.condition.wait(&self.mutex);
        self.mutex.unlock();
        if (self.deinit_after_drain) {
            global.deinit();
        } else {
            global.reset();
        }
        self.mutex.lock();
        self.owner_done = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    fn destroyThread(self: *@This()) void {
        engine.destroy(self.instance_id);
        self.mutex.lock();
        self.destroy_done = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    fn waitFor(self: *@This(), predicate: *const fn (*const @This()) bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!predicate(self)) {
            if (self.condition.waitTimeout(&self.mutex, 10_000) == .timed_out) return error.BarrierTimedOut;
        }
    }

    fn releaseReached(self: *const @This()) bool {
        return self.release_entered;
    }

    fn ownerStarted(self: *const @This()) bool {
        return self.owner_ready;
    }

    fn teardownObserved(self: *const @This()) bool {
        return self.event != .none;
    }

    fn ownerFinished(self: *const @This()) bool {
        return self.owner_done;
    }

    fn destroyFinished(self: *const @This()) bool {
        return self.destroy_done;
    }

    fn drainReached(self: *const @This()) bool {
        return self.event == .drained;
    }

    fn resumeOwnerRelease(self: *@This()) void {
        self.mutex.lock();
        self.resume_release = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    fn resumeTeardown(self: *@This()) void {
        self.mutex.lock();
        self.resume_drain = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }
};

fn runGlobalResetDestroyBarrier() !void {
    var probe = RefDestroyProbe{ .instance_id = helpers.nextInstanceId() };
    reference.setGlobalReleaseHookForTesting(RefDestroyProbe.releaseHook, @ptrCast(&probe));
    instance_map.setRefHooksForTesting(RefDestroyProbe.waitHook, RefDestroyProbe.drainHook, @ptrCast(&probe));
    var owner_thread: ?std.Thread = null;
    var destroyer_thread: ?std.Thread = null;
    defer {
        reference.setGlobalReleaseHookForTesting(null, null);
        instance_map.setRefHooksForTesting(null, null, null);
        probe.resumeOwnerRelease();
        probe.resumeTeardown();
        if (owner_thread) |t| t.join();
        if (destroyer_thread) |t| t.join();
        probe.condition.deinit();
        probe.mutex.deinit();
    }

    owner_thread = try std.Thread.spawn(.{}, RefDestroyProbe.ownerThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.ownerStarted);
    try probe.waitFor(RefDestroyProbe.releaseReached);
    destroyer_thread = try std.Thread.spawn(.{}, RefDestroyProbe.destroyThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.teardownObserved);

    const event = probe.event;
    const correct_wait = event == .waiting;
    if (correct_wait) try testing.expect(engine.getContext(probe.instance_id) != null);

    probe.resumeOwnerRelease();
    try probe.waitFor(RefDestroyProbe.ownerFinished);
    if (owner_thread) |t| {
        t.join();
        owner_thread = null;
    }
    try probe.waitFor(RefDestroyProbe.drainReached);
    probe.resumeTeardown();
    try probe.waitFor(RefDestroyProbe.destroyFinished);
    if (destroyer_thread) |t| {
        t.join();
        destroyer_thread = null;
    }

    try testing.expect(correct_wait);
    try testing.expectEqual(@as(u32, 1), probe.release_count.load(.seq_cst));
    try testing.expect(engine.getContext(probe.instance_id) == null);
}

test "Global.reset keeps foreign destroy behind an active reference operation" {
    try runGlobalResetDestroyBarrier();
}

test "Global.reset defers a release callback destroy until its operation exits" {
    var probe = RefDestroyProbe{ .instance_id = helpers.nextInstanceId(), .destroy_from_release = true };
    reference.setGlobalReleaseHookForTesting(RefDestroyProbe.releaseHook, @ptrCast(&probe));
    var owner_thread: ?std.Thread = null;
    defer {
        reference.setGlobalReleaseHookForTesting(null, null);
        probe.resumeOwnerRelease();
        if (owner_thread) |t| t.join();
        probe.condition.deinit();
        probe.mutex.deinit();
    }
    owner_thread = try std.Thread.spawn(.{}, RefDestroyProbe.ownerThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.ownerFinished);
    if (owner_thread) |t| {
        t.join();
        owner_thread = null;
    }
    try testing.expect(engine.getContext(probe.instance_id) == null);
    try testing.expectEqual(@as(u32, 1), probe.release_count.load(.seq_cst));
}

test "Global deinit after teardown release frees the surrendered cell once" {
    var probe = RefDestroyProbe{
        .instance_id = helpers.nextInstanceId(),
        .pause_release = false,
        .deinit_after_drain = true,
    };
    reference.setGlobalReleaseHookForTesting(RefDestroyProbe.releaseHook, @ptrCast(&probe));
    instance_map.setRefHooksForTesting(RefDestroyProbe.waitHook, RefDestroyProbe.drainHook, @ptrCast(&probe));
    var owner_thread: ?std.Thread = null;
    var destroyer_thread: ?std.Thread = null;
    defer {
        reference.setGlobalReleaseHookForTesting(null, null);
        instance_map.setRefHooksForTesting(null, null, null);
        probe.resumeOwnerRelease();
        probe.resumeTeardown();
        if (owner_thread) |t| t.join();
        if (destroyer_thread) |t| t.join();
        probe.condition.deinit();
        probe.mutex.deinit();
    }
    owner_thread = try std.Thread.spawn(.{}, RefDestroyProbe.ownerThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.ownerStarted);
    destroyer_thread = try std.Thread.spawn(.{}, RefDestroyProbe.destroyThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.drainReached);
    probe.mutex.lock();
    probe.request_deinit = true;
    probe.condition.broadcast();
    probe.mutex.unlock();
    try probe.waitFor(RefDestroyProbe.ownerFinished);
    if (owner_thread) |t| {
        t.join();
        owner_thread = null;
    }
    try testing.expect(engine.getContext(probe.instance_id) != null);
    probe.resumeTeardown();
    try probe.waitFor(RefDestroyProbe.destroyFinished);
    if (destroyer_thread) |t| {
        t.join();
        destroyer_thread = null;
    }
    try testing.expectEqual(@as(u32, 1), probe.release_count.load(.seq_cst));
    try testing.expect(engine.getContext(probe.instance_id) == null);
}

test "Global deinit during teardown release frees the surrendered cell once" {
    var probe = RefDestroyProbe{
        .instance_id = helpers.nextInstanceId(),
        .deinit_after_drain = true,
    };
    reference.setGlobalReleaseHookForTesting(RefDestroyProbe.releaseHook, @ptrCast(&probe));
    var owner_thread: ?std.Thread = null;
    var destroyer_thread: ?std.Thread = null;
    defer {
        reference.setGlobalReleaseHookForTesting(null, null);
        probe.resumeOwnerRelease();
        probe.resumeTeardown();
        if (owner_thread) |t| t.join();
        if (destroyer_thread) |t| t.join();
        probe.condition.deinit();
        probe.mutex.deinit();
    }

    owner_thread = try std.Thread.spawn(.{}, RefDestroyProbe.ownerThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.ownerStarted);
    destroyer_thread = try std.Thread.spawn(.{}, RefDestroyProbe.destroyThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.releaseReached);

    probe.mutex.lock();
    probe.request_deinit = true;
    probe.condition.broadcast();
    probe.mutex.unlock();
    try probe.waitFor(RefDestroyProbe.ownerFinished);
    if (owner_thread) |t| {
        t.join();
        owner_thread = null;
    }
    try testing.expect(engine.getContext(probe.instance_id) != null);

    probe.resumeOwnerRelease();
    try probe.waitFor(RefDestroyProbe.destroyFinished);
    if (destroyer_thread) |t| {
        t.join();
        destroyer_thread = null;
    }
    try testing.expectEqual(@as(u32, 1), probe.release_count.load(.seq_cst));
    try testing.expect(engine.getContext(probe.instance_id) == null);
}

test "Global deinit after destroy does not touch an instance that reused its id" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const value = ActiveEngine.newObject(ctx);
    var old_global = reference.Global(reference.Local).init(id, value);
    ActiveEngine.freeValue(ctx, value);

    engine.destroy(id);
    try testing.expect(engine.create(id, .{}));
    old_global.deinit();
    try testing.expect(engine.getContext(id) != null);
    engine.destroy(id);
}

fn forceCollect(id: i32) !void {
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        try helpers.evalOk(id, "for (var __i=0; __i<5000; __i++) ({a:__i, b:[1,2,3]});");
        engine.runGc(id);
    }
}

noinline fn expectWeakLive(w: reference.Weak(reference.Local)) !void {
    try testing.expect(w.get() != null);
}

noinline fn expectWeakDead(w: reference.Weak(reference.Local)) !void {
    try testing.expect(w.get() == null);
}

fn anyWeakCleared(weaks: []const reference.Weak(reference.Local)) bool {
    for (weaks) |w| {
        if (w.get() == null) return true;
    }
    return false;
}

/// Park `{ junk: <large string> }` on `globalThis[name]`, wrap it in a Weak, drop the extracted handle, and delete the property. The returned Weak is the only remaining reference.
fn takeParkedWeak(id: i32, name: [*:0]const u8, delete_script: []const u8) !reference.Weak(reference.Local) {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const obj = ActiveEngine.getPropertyVal(ctx, global, name) orelse return error.NoProperty;
    var w = reference.Weak(reference.Local).init(id, obj);
    errdefer w.deinit();
    ActiveEngine.freeValue(ctx, obj);
    try helpers.evalOk(id, delete_script);
    return w;
}

fn collectLargeObjectWeaks(id: i32) ![large_count]reference.Weak(reference.Local) {
    try helpers.evalOk(id,
        \\var chunk = '.'.repeat(262144);
        \\for (var i = 0; i < 16; i++) globalThis['__lj' + i] = { junk: chunk };
    );
    var out: [large_count]reference.Weak(reference.Local) = undefined;
    var filled: usize = 0;
    errdefer while (filled > 0) {
        filled -= 1;
        out[filled].deinit();
    };
    while (filled < large_count) : (filled += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&name_buf, "__lj{d}", .{filled}, 0) catch return error.Name;
        var script_buf: [64]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf, "delete globalThis.__lj{d};", .{filled}) catch return error.Script;
        out[filled] = try takeParkedWeak(id, name.ptr, script);
    }
    return out;
}

fn holdWithGlobal(id: i32) !struct {
    g: reference.Global(reference.Local),
    w: reference.Weak(reference.Local),
} {
    try helpers.evalOk(id,
        \\var chunk = '.'.repeat(262144);
        \\globalThis.__held = { junk: chunk };
    );
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const obj = ActiveEngine.getPropertyVal(ctx, global, "__held") orelse return error.NoProperty;
    var g = reference.Global(reference.Local).init(id, obj);
    errdefer g.deinit();
    var w = reference.Weak(reference.Local).init(id, obj);
    errdefer w.deinit();
    ActiveEngine.freeValue(ctx, obj);
    try helpers.evalOk(id, "delete globalThis.__held;");
    return .{ .g = g, .w = w };
}

/// `root` twice, `unroot` once, then drop every other strong ref. The value stays protected (count == 1) when this returns.
noinline fn rootTwiceThenDrop(id: i32) !struct {
    rooted: reference.Rooted,
    weak: reference.Weak(reference.Local),
} {
    try helpers.evalOk(id,
        \\var chunk = '.'.repeat(262144);
        \\globalThis.__rt = { junk: chunk };
    );
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const obj = ActiveEngine.getPropertyVal(ctx, global, "__rt") orelse return error.NoProperty;
    var rooted = reference.Rooted.init(id, obj);
    errdefer rooted.deinit();
    rooted.root();
    rooted.root();
    var weak = reference.Weak(reference.Local).init(id, obj);
    errdefer weak.deinit();
    ActiveEngine.freeValue(ctx, obj);
    try helpers.evalOk(id, "delete globalThis.__rt;");
    rooted.unroot();
    return .{ .rooted = rooted, .weak = weak };
}

/// Hold an object in a global, root→unroot to zero, leave the global so a later
/// `root()` can re-protect the still-live value. `noinline` for the same JSC
/// ReleaseSafe stack-scan reason as `makeRootedAndWeak`.
noinline fn makeRerootLiveObject(id: i32) !struct {
    rooted: reference.Rooted,
    weak: reference.Weak(reference.Local),
} {
    try helpers.evalOk(id,
        \\var chunk = '.'.repeat(262144);
        \\globalThis.__rr = { junk: chunk };
    );
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const obj = ActiveEngine.getPropertyVal(ctx, global, "__rr") orelse return error.NoProperty;
    var rooted = reference.Rooted.init(id, obj);
    errdefer rooted.deinit();
    var weak = reference.Weak(reference.Local).init(id, obj);
    errdefer weak.deinit();
    ActiveEngine.freeValue(ctx, obj);

    rooted.root();
    rooted.unroot();
    // Intentionally leave globalThis.__rr so the object stays live for re-root.
    return .{ .rooted = rooted, .weak = weak };
}

/// Same shape as `rootTwiceThenDrop`, but a single `root` and a large-string payload.
/// `noinline` keeps the temporary `Local` off the caller stack so JSC's conservative
/// scan cannot false-retain the object after `unroot` (ReleaseSafe inlines aggressively).
noinline fn makeRootedAndWeak(id: i32) !struct {
    rooted: reference.Rooted,
    weak: reference.Weak(reference.Local),
} {
    try helpers.evalOk(id,
        \\var chunk = '.'.repeat(262144);
        \\globalThis.__gs = { junk: chunk };
    );
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const obj = ActiveEngine.getPropertyVal(ctx, global, "__gs") orelse return error.NoProperty;
    var rooted = reference.Rooted.init(id, obj);
    errdefer rooted.deinit();
    rooted.root();
    var weak = reference.Weak(reference.Local).init(id, obj);
    errdefer weak.deinit();
    ActiveEngine.freeValue(ctx, obj);
    try helpers.evalOk(id, "delete globalThis.__gs;");
    return .{ .rooted = rooted, .weak = weak };
}

test "Weak: at least one large-string object is collected after strong refs drop" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var weaks = try collectLargeObjectWeaks(id);
            defer {
                var i: usize = 0;
                while (i < weaks.len) : (i += 1) weaks[i].deinit();
            }
            try forceCollect(id);
            try testing.expect(anyWeakCleared(weaks[0..]));
        }
    }.run);
}

test "Weak: Global keeps a large-string object alive across GC" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var held = try holdWithGlobal(id);
            defer held.g.deinit();
            defer held.w.deinit();
            try forceCollect(id);
            try expectWeakLive(held.w);
        }
    }.run);
}

test "Weak: number and string values stay non-null across GC" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const num = ActiveEngine.newInt32Val(ctx, 7);
            const text = ActiveEngine.newStringVal(ctx, "hello");
            var wn = reference.Weak(reference.Local).init(id, num);
            var ws = reference.Weak(reference.Local).init(id, text);
            ActiveEngine.freeValue(ctx, num);
            ActiveEngine.freeValue(ctx, text);
            defer wn.deinit();
            defer ws.deinit();

            try forceCollect(id);
            try expectWeakLive(wn);
            try expectWeakLive(ws);
        }
    }.run);
}

test "Global and Weak are empty after engine.destroy" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));

    const ctx = engine.getContext(id) orelse return error.NoContext;
    const num = ActiveEngine.newInt32Val(ctx, 1);
    const text = ActiveEngine.newStringVal(ctx, "kept");

    var globals: [4]reference.Global(reference.Local) = undefined;
    var weaks: [4]reference.Weak(reference.Local) = undefined;
    var i: usize = 0;
    while (i < globals.len) : (i += 1) {
        const obj = ActiveEngine.newObject(ctx);
        globals[i] = reference.Global(reference.Local).init(id, obj);
        weaks[i] = reference.Weak(reference.Local).init(id, obj);
        ActiveEngine.freeValue(ctx, obj);
    }
    var g_num = reference.Global(reference.Local).init(id, num);
    var w_text = reference.Weak(reference.Local).init(id, text);
    ActiveEngine.freeValue(ctx, num);
    ActiveEngine.freeValue(ctx, text);

    defer {
        var j: usize = 0;
        while (j < globals.len) : (j += 1) {
            globals[j].deinit();
            weaks[j].deinit();
        }
        g_num.deinit();
        w_text.deinit();
    }

    engine.destroy(id);

    // Only emptiness queries. Do not read fields off the released JS values.
    i = 0;
    while (i < globals.len) : (i += 1) {
        try testing.expect(globals[i].isEmpty());
        try testing.expect(globals[i].get() == null);
        try testing.expect(weaks[i].isEmpty());
        try testing.expect(weaks[i].get() == null);
    }
    try testing.expect(g_num.isEmpty());
    try testing.expect(g_num.get() == null);
    try testing.expect(w_text.isEmpty());
    try testing.expect(w_text.get() == null);
}

test "Rooted: value stays reachable until unroot returns the count to zero" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var pair = try rootTwiceThenDrop(id);
            defer pair.rooted.deinit();
            defer pair.weak.deinit();

            try testing.expect(!pair.rooted.isEmpty());
            try forceCollect(id);
            try expectWeakLive(pair.weak);

            pair.rooted.unroot();
            try testing.expect(pair.rooted.isEmpty());
            try forceCollect(id);
            try expectWeakDead(pair.weak);
        }
    }.run);
}

test "Rooted: GC stress keeps object live until final unroot" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var pair = try makeRootedAndWeak(id);
            defer pair.rooted.deinit();
            defer pair.weak.deinit();

            // Stress while rooted (mirrors the sibling Rooted test). Also overwrites
            // leftover stack slots from the helper frame so a later death check is not
            // poisoned by JSC conservative roots under ReleaseSafe.
            try forceCollect(id);
            try expectWeakLive(pair.weak);

            pair.rooted.unroot();
            try testing.expect(pair.rooted.isEmpty());
            try forceCollect(id);
            try expectWeakDead(pair.weak);
        }
    }.run);
}

test "Rooted: re-root after count returns to zero keeps a still-live object" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            // Object stays reachable via a global while we unroot→0 then root again.
            // Clearing cell.val on final unroot would make the second root protect a
            // null sentinel: isEmpty becomes false, but the real object is unprotected.
            var pair = try makeRerootLiveObject(id);
            defer pair.rooted.deinit();
            defer pair.weak.deinit();

            try testing.expect(pair.rooted.isEmpty());
            pair.rooted.root();
            try testing.expect(!pair.rooted.isEmpty());

            try helpers.evalOk(id, "delete globalThis.__rr;");
            try forceCollect(id);
            try expectWeakLive(pair.weak);

            pair.rooted.unroot();
            try testing.expect(pair.rooted.isEmpty());
            try forceCollect(id);
            try expectWeakDead(pair.weak);
        }
    }.run);
}

test "Global and Weak interleaved release survives engine.destroy at scale" {
    const count = 128;
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));

    const ctx = engine.getContext(id) orelse return error.NoContext;
    var globals: [count]reference.Global(reference.Local) = undefined;
    var weaks: [count]reference.Weak(reference.Local) = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obj = ActiveEngine.newObject(ctx);
        globals[i] = reference.Global(reference.Local).init(id, obj);
        weaks[i] = reference.Weak(reference.Local).init(id, obj);
        ActiveEngine.freeValue(ctx, obj);
    }

    // i % 4: 0 releases both, 1 releases the Global only, 2 releases the Weak only, 3 keeps both until after destroy.
    i = 0;
    while (i < count) : (i += 1) {
        switch (i % 4) {
            0 => {
                globals[i].deinit();
                weaks[i].deinit();
            },
            1 => globals[i].deinit(),
            2 => weaks[i].deinit(),
            else => {},
        }
    }
    engine.runGc(id);

    // A Global still held keeps its object, and so its Weak, alive across the collection.
    i = 0;
    while (i < count) : (i += 1) {
        switch (i % 4) {
            2 => try testing.expect(!globals[i].isEmpty()),
            3 => {
                try testing.expect(!globals[i].isEmpty());
                try testing.expect(!weaks[i].isEmpty());
            },
            else => {},
        }
    }

    engine.destroy(id);

    // Handles released before destroy stay empty and the rest become empty; none may touch the dead runtime.
    i = 0;
    while (i < count) : (i += 1) {
        try testing.expect(globals[i].isEmpty());
        try testing.expect(globals[i].get() == null);
        try testing.expect(weaks[i].isEmpty());
        try testing.expect(weaks[i].get() == null);
    }

    // Late deinit of every handle, including the ones already deinitialized (deinit is idempotent), frees the cells.
    i = 0;
    while (i < count) : (i += 1) {
        globals[i].deinit();
        weaks[i].deinit();
    }
}
