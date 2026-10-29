//! Combined churn of native references, finalizers and ordinary JS garbage.
//!
//! Many short-lived objects use Global and Weak handles and finalizer registrations while scripts allocate garbage and collection runs repeatedly. Engine destruction must account for the entire population.
//!
//! The default suite runs a reduced population; `-Dstress-tests=true` (which selects tests with "stress" in the name) enlarges it.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const build_options = @import("build_options");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const reference = @import("../value/reference.zig");
const weakcb = @import("../value/weakcb.zig");

const ActiveEngine = backend.ActiveEngine;
const Global = reference.Global(reference.Local);
const Weak = reference.Weak(reference.Local);

const rounds: usize = if (build_options.stress_tests) 40 else 6;
const per_round: usize = if (build_options.stress_tests) 1000 else 64;
const total: usize = rounds * per_round;

var g_finalized: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn countFinalized(_: ?*anyopaque) callconv(.c) void {
    _ = g_finalized.fetchAdd(1, .seq_cst);
}

const Population = struct {
    globals: []Global,
    weaks: []Weak,
    /// True while the Global at that index is still held, so its object is rooted.
    rooted: []bool,
    has_weak: []bool,
    created: usize = 0,

    fn init(allocator: std.mem.Allocator, id: i32) !Population {
        const globals = try allocator.alloc(Global, total);
        errdefer allocator.free(globals);
        const weaks = try allocator.alloc(Weak, total);
        errdefer allocator.free(weaks);
        const rooted = try allocator.alloc(bool, total);
        errdefer allocator.free(rooted);
        const has_weak = try allocator.alloc(bool, total);
        for (globals) |*g| g.* = Global.initEmpty(id);
        for (weaks) |*w| w.* = Weak.initEmpty(id);
        @memset(rooted, false);
        @memset(has_weak, false);
        return .{ .globals = globals, .weaks = weaks, .rooted = rooted, .has_weak = has_weak };
    }

    fn deinit(self: *Population, allocator: std.mem.Allocator) void {
        for (self.globals) |*g| g.deinit();
        for (self.weaks) |*w| w.deinit();
        allocator.free(self.globals);
        allocator.free(self.weaks);
        allocator.free(self.rooted);
        allocator.free(self.has_weak);
    }

    /// Objects are created in a helper frame of their own so no stale native reference to them survives on this thread's stack.
    noinline fn spawnBatch(self: *Population, id: i32, rng: *std.Random.DefaultPrng) !void {
        const ctx = engine.getContext(id) orelse return error.NoContext;
        var k: usize = 0;
        while (k < per_round) : (k += 1) {
            const i = self.created;
            const obj = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, obj);
            const marker = ActiveEngine.newInt32Val(ctx, @intCast(i));
            ActiveEngine.setPropertyStr(ctx, obj, "n", marker);

            try testing.expect(weakcb.attachFinalizer(id, obj, null, countFinalized));
            // 0: Global only, 1: Weak only, 2: both, 3: neither beyond the finalizer.
            const kind = rng.random().uintLessThan(u8, 4);
            if (kind == 0 or kind == 2) {
                self.globals[i] = Global.init(id, obj);
                self.rooted[i] = true;
            }
            if (kind == 1 or kind == 2) {
                self.weaks[i] = Weak.init(id, obj);
                self.has_weak[i] = true;
            }
            self.created += 1;
        }
    }

    /// Drop every third still-held Global so rooted and unrooted objects keep interleaving across rounds.
    fn releaseSome(self: *Population) void {
        var i: usize = 0;
        while (i < self.created) : (i += 3) {
            if (self.rooted[i]) {
                self.globals[i].deinit();
                self.rooted[i] = false;
            }
        }
    }

    fn unrootedCount(self: *const Population) u32 {
        var n: u32 = 0;
        for (self.rooted[0..self.created]) |held| {
            if (!held) n += 1;
        }
        return n;
    }

    fn expectRootedAlive(self: *const Population, id: i32) !void {
        const ctx = engine.getContext(id) orelse return error.NoContext;
        for (0..self.created) |i| {
            if (!self.rooted[i]) continue;
            try testing.expect(!self.globals[i].isEmpty());
            // get() hands back an owned duplicate.
            const held = self.globals[i].get() orelse return error.RootedObjectLost;
            ActiveEngine.freeValue(ctx, held);
            if (self.has_weak[i]) try testing.expect(!self.weaks[i].isEmpty());
        }
    }
};

test "reference stress: Global, Weak and finalizer churn is fully accounted for at destroy" {
    g_finalized.store(0, .seq_cst);
    var rng = std.Random.DefaultPrng.init(0x5eed_0001);

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var destroyed = false;
    defer if (!destroyed) engine.destroy(id);

    var population = try Population.init(testing.allocator, id);
    defer population.deinit(testing.allocator);

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        try population.spawnBatch(id, &rng);
        // Ordinary script garbage between the native-handled objects.
        try helpers.evalOk(id,
            \\for (var i = 0; i < 200; i++) globalThis.__junk = { i: i, list: [i, 'x'.repeat(16)] };
        );
        population.releaseSome();
        engine.runGc(id);

        try population.expectRootedAlive(id);
        const finalized = g_finalized.load(.seq_cst);
        try testing.expect(finalized <= population.unrootedCount());
        // The precise collector reclaims exactly the unrooted objects; the conservative JSC one may keep some until teardown.
        if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
            try testing.expectEqual(population.unrootedCount(), finalized);
            for (0..population.created) |i| {
                if (!population.rooted[i] and population.has_weak[i]) try testing.expect(population.weaks[i].isEmpty());
            }
        }
    }

    try helpers.expectEvalEquals(id, "1 + 1", "2");
    engine.destroy(id);
    destroyed = true;

    // Nothing leaked, nothing finalized twice, and no handle points into the dead runtime.
    try testing.expectEqual(@as(u32, total), g_finalized.load(.seq_cst));
    for (0..total) |i| {
        try testing.expect(population.globals[i].isEmpty());
        try testing.expect(population.globals[i].get() == null);
        try testing.expect(population.weaks[i].isEmpty());
        try testing.expect(population.weaks[i].get() == null);
    }
}
