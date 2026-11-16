//! Canonical-ID instance registry and loading transactions, not a dependency graph. The owner serializes access on the VM thread; no mutex is held across loader callbacks or execution.
const std = @import("std");
const types = @import("loader.zig");
const loader_bridge = @import("loader.zig");

pub const ExecutionError = error{ OutOfMemory, Compile, CallFailed };
pub const RequireError = error{ NotFound, CompileFailed, CallFailed, OutOfMemory };

/// Ops supplies typed values, newExports/newModule/readExports and retain/release. execute evaluates one wrapper; resolving, loading, caching and rollback remain here.
pub fn Registry(comptime Ops: type) type {
    return struct {
        const Self = @This();
        const Entry = struct { id: []const u8, exports: Ops.Value, loading: bool = false, generation: usize };
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        entries: std.StringHashMap(Entry),
        in_flight: usize = 0,
        pending_clear: bool = false,
        generation: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator), .entries = std.StringHashMap(Entry).init(allocator) };
        }

        fn recycleArenaIfIdle(self: *Self) void {
            if (self.in_flight != 0 or self.entries.count() != 0) return;
            self.pending_clear = false;
            _ = self.arena.reset(.retain_capacity);
        }

        /// Releases cached exports immediately. Arena keys used by an in-flight require stay valid until that transaction finishes; the arena is reset only when idle and empty.
        pub fn clear(self: *Self, ctx: Ops.Context) void {
            var it = self.entries.iterator();
            while (it.next()) |entry| Ops.release(ctx, entry.value_ptr.exports);
            self.entries.clearRetainingCapacity();
            if (self.in_flight == 0) {
                self.recycleArenaIfIdle();
            } else {
                self.pending_clear = true;
            }
        }

        /// After clear, allowing the adapter to release its separate compile cache before destroying this storage.
        pub fn deinitStorage(self: *Self) void {
            self.entries.deinit();
            self.arena.deinit();
        }

        pub fn require(self: *Self, ctx: Ops.Context, source_allocator: std.mem.Allocator, loader: *const types.Loader, execute: *const fn (Ops.Context, std.mem.Allocator, []const u8, []const u8, []const u8, Ops.Value, Ops.Value) ExecutionError!Ops.Value, specifier: []const u8, referrer: []const u8) RequireError!Ops.Value {
            self.in_flight += 1;
            defer {
                self.in_flight -= 1;
                if (self.pending_clear) self.recycleArenaIfIdle();
            }
            // Step 1: resolve → canonical id. resolve() may be null on the loader; fall back to specifier as-is.
            const canonical = loader_bridge.resolveSpecifier(source_allocator, loader, specifier, referrer) catch return error.OutOfMemory;
            // Canonical is either a borrowed specifier or an allocator-owned resolved copy. The cache interns a separate key.
            defer canonical.deinit();

            // Step 2: cache lookup by canonical id.
            if (self.entries.get(canonical.id)) |cached| {
                return if (cached.loading) Ops.readExports(ctx, cached.exports) catch return error.CallFailed else Ops.retain(ctx, cached.exports);
            }

            // Step 3: load via the user vtable.
            const loaded = loader_bridge.loadSource(source_allocator, loader, canonical.id) catch return error.OutOfMemory;
            defer if (loaded) |src| source_allocator.free(src);
            // A host loader may finish a nested require of this very ID. Adopt that transaction, even if this outer callback returned no source.
            if (self.entries.get(canonical.id)) |cached| {
                return if (cached.loading) Ops.readExports(ctx, cached.exports) catch return error.CallFailed else Ops.retain(ctx, cached.exports);
            }
            const src = loaded orelse return error.NotFound;

            // Step 4: intern canonical id so it outlives this call as the cache key.
            const interned_id = self.arena.allocator().dupe(u8, canonical.id) catch return error.OutOfMemory;

            // The loading cache holds the live module object. Cycles read its current exports (including reassignment), not a detached snapshot.
            const initial_exports = try Ops.newExports(ctx);
            defer Ops.release(ctx, initial_exports);
            if (self.entries.get(canonical.id)) |cached| {
                return if (cached.loading) Ops.readExports(ctx, cached.exports) catch return error.CallFailed else Ops.retain(ctx, cached.exports);
            }
            const module = try Ops.newModule(ctx, initial_exports);
            defer Ops.release(ctx, module);
            // Constructors may also finish a nested transaction. Never replace it with a second loading module (or drop its cache-owned retain).
            if (self.entries.get(canonical.id)) |cached| {
                return if (cached.loading) Ops.readExports(ctx, cached.exports) catch return error.CallFailed else Ops.retain(ctx, cached.exports);
            }
            self.generation +%= 1;
            const generation = self.generation;
            const pinned_module = Ops.retain(ctx, module);
            self.entries.put(interned_id, .{ .id = interned_id, .exports = pinned_module, .loading = true, .generation = generation }) catch {
                Ops.release(ctx, pinned_module);
                return error.OutOfMemory;
            };

            // Step 5: wrap and evaluate.
            const dirname = loader_bridge.dirnameOf(interned_id);
            const exports_value = execute(ctx, self.allocator, src, interned_id, dirname, initial_exports, module) catch |e| {
                // Evict the placeholder so a retry doesn't return a stale empty object.
                if (self.entries.get(interned_id)) |entry| {
                    if (entry.generation == generation) {
                        _ = self.entries.remove(interned_id);
                        Ops.release(ctx, entry.exports);
                    }
                }
                return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.Compile => error.CompileFailed,
                    error.CallFailed => error.CallFailed,
                };
            };

            // Step 6: update cache with the final module.exports.
            const final_pinned = Ops.retain(ctx, exports_value);
            if (self.entries.getPtr(interned_id)) |entry_ptr| {
                if (entry_ptr.generation == generation) {
                    Ops.release(ctx, entry_ptr.exports);
                    entry_ptr.exports = final_pinned;
                    entry_ptr.loading = false;
                } else {
                    // clear + reload installed a newer transaction for this ID.
                    Ops.release(ctx, final_pinned);
                }
            } else {
                // A reentrant clear dropped the placeholder. The just-finished exports are still cached under the surviving interned key.
                self.entries.put(interned_id, .{ .id = interned_id, .exports = final_pinned, .generation = generation }) catch {
                    Ops.release(ctx, final_pinned);
                };
            }

            // The result is caller-owned; the cache holds an independent retained reference.
            return exports_value;
        }
    };
}

const TestOps = struct {
    const Cell = struct { refs: usize = 0, exports: ?*Cell = null };
    const Probe = struct {
        cells: [32]Cell = @splat(.{}),
        used: usize = 0,
        calls: usize = 0,
        fail_execution: bool = false,
        registry: ?*Registry(TestOps) = null,
        clear_during_execute: bool = false,
        inspect_cycle: bool = false,
        reload_during_execute: bool = false,
        fail_after_reload: bool = false,
        newest: ?Value = null,
        reentry: enum { none, exports, module, load } = .none,
        missing_after_reentry: bool = false,
        fail_exports: bool = false,
        fail_module: bool = false,
    };
    pub const Context = *Probe;
    pub const Value = *Cell;

    pub fn newExports(ctx: Context) error{OutOfMemory}!Value {
        if (ctx.fail_exports) return error.OutOfMemory;
        if (ctx.reentry == .exports) try reenter(ctx);
        const cell = &ctx.cells[ctx.used];
        ctx.used += 1;
        cell.refs = 1;
        return cell;
    }
    pub fn retain(_: Context, value: Value) Value {
        value.refs += 1;
        return value;
    }
    pub fn release(ctx: Context, value: Value) void {
        std.debug.assert(value.refs > 0);
        value.refs -= 1;
        if (value.refs == 0) {
            if (value.exports) |exports| release(ctx, exports);
        }
    }
    pub fn newModule(ctx: Context, exports: Value) error{OutOfMemory}!Value {
        if (ctx.fail_module) return error.OutOfMemory;
        if (ctx.reentry == .module) try reenter(ctx);
        const module = try newExports(ctx);
        module.exports = retain(ctx, exports);
        return module;
    }
    pub fn readExports(ctx: Context, module: Value) error{CallFailed}!Value {
        return retain(ctx, module.exports.?);
    }
    fn execute(ctx: Context, _: std.mem.Allocator, _: []const u8, id: []const u8, _: []const u8, initial: Value, module: Value) ExecutionError!Value {
        std.debug.assert(module.exports.? == initial);
        ctx.calls += 1;
        if (ctx.inspect_cycle) {
            ctx.inspect_cycle = false;
            const vtable = types.LoaderVTable{ .load = load };
            const loader = types.Loader{ .vtable = &vtable };
            const partial = ctx.registry.?.require(ctx, std.testing.allocator, &loader, execute, id, id) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            std.debug.assert(partial == initial);
            release(ctx, partial);
        }
        if (ctx.reload_during_execute) {
            ctx.reload_during_execute = false;
            ctx.registry.?.clear(ctx);
            const vtable = types.LoaderVTable{ .load = load };
            const loader = types.Loader{ .vtable = &vtable };
            const newer = ctx.registry.?.require(ctx, std.testing.allocator, &loader, execute, id, id) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            ctx.newest = newer;
            release(ctx, newer);
            if (ctx.fail_after_reload) return error.CallFailed;
        }
        if (ctx.clear_during_execute) {
            // The interned key must remain readable across this reentrant clear.
            std.debug.assert(std.mem.eql(u8, id, "module"));
            ctx.registry.?.clear(ctx);
        }
        if (ctx.fail_execution) return error.Compile;
        return newExports(ctx);
    }
    fn reenter(ctx: Context) error{OutOfMemory}!void {
        ctx.reentry = .none;
        const vtable = types.LoaderVTable{ .load = load };
        const loader = types.Loader{ .vtable = &vtable, .user_data = ctx };
        const value = ctx.registry.?.require(ctx, std.testing.allocator, &loader, execute, "module", "parent") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        ctx.newest = value;
        release(ctx, value);
    }
    fn load(data: ?*anyopaque, _: [*:0]const u8, out: *types.LoadResult) callconv(.c) bool {
        if (data) |ptr| {
            const ctx: Context = @ptrCast(@alignCast(ptr));
            if (ctx.reentry == .load) {
                reenter(ctx) catch unreachable;
                if (ctx.missing_after_reentry) return false;
            }
        }
        out.* = .{ .source = "source", .source_len = 6 };
        return true;
    }
};

test "cjs registry: hits retain a typed value and failed execution rolls back the placeholder" {
    const allocator = std.testing.allocator;
    var registry = Registry(TestOps).init(allocator);
    defer registry.deinitStorage();
    var ctx = TestOps.Probe{};
    const vtable = types.LoaderVTable{ .load = TestOps.load };
    const loader = types.Loader{ .vtable = &vtable };
    const first = try registry.require(&ctx, allocator, &loader, TestOps.execute, "module", "<cjs>");
    TestOps.release(&ctx, first);
    const second = try registry.require(&ctx, allocator, &loader, TestOps.execute, "module", "<cjs>");
    try std.testing.expect(first == second);
    TestOps.release(&ctx, second);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
    registry.clear(&ctx);
    ctx.fail_execution = true;
    try std.testing.expectError(error.CompileFailed, registry.require(&ctx, allocator, &loader, TestOps.execute, "module", "<cjs>"));
    try std.testing.expectEqual(@as(usize, 0), registry.entries.count());
    for (ctx.cells[0..ctx.used]) |cell| try std.testing.expectEqual(@as(usize, 0), cell.refs);
}

test "cjs registry: clear resets arena storage without protecting in-flight keys" {
    const allocator = std.testing.allocator;
    var registry = Registry(TestOps).init(allocator);
    defer registry.deinitStorage();
    var ctx = TestOps.Probe{};
    const old_key = try registry.arena.allocator().dupe(u8, "canonical-a");
    const old_address = @intFromPtr(old_key.ptr);
    registry.clear(&ctx);
    const replacement = try registry.arena.allocator().dupe(u8, "canonical-b");
    // Compare addresses only, never dereference an invalidated key or run a module transaction after active clear.
    try std.testing.expectEqual(old_address, @intFromPtr(replacement.ptr));
    try std.testing.expectEqualStrings("canonical-b", replacement);
}

test "cjs registry: allocation failures balance placeholder and final typed references" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var ctx = TestOps.Probe{};
            defer for (ctx.cells[0..ctx.used]) |cell| std.debug.assert(cell.refs == 0);
            var registry = Registry(TestOps).init(allocator);
            defer registry.deinitStorage();
            defer registry.clear(&ctx);
            const vtable = types.LoaderVTable{ .load = TestOps.load };
            const loader = types.Loader{ .vtable = &vtable };
            // Fail only registry storage allocations, not the separately-owned source copy.
            const value = try registry.require(&ctx, std.testing.allocator, &loader, TestOps.execute, "module", "<cjs>");
            TestOps.release(&ctx, value);
        }
    }.run, .{});
}

test "cjs registry: reentrant clear keeps interned keys valid and recaches finished exports" {
    const allocator = std.testing.allocator;
    var registry = Registry(TestOps).init(allocator);
    defer registry.deinitStorage();
    var ctx = TestOps.Probe{ .registry = &registry, .clear_during_execute = true };
    const vtable = types.LoaderVTable{ .load = TestOps.load };
    const loader = types.Loader{ .vtable = &vtable };
    const value = try registry.require(&ctx, allocator, &loader, TestOps.execute, "module", "<cjs>");
    TestOps.release(&ctx, value);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
    try std.testing.expectEqual(@as(usize, 1), registry.entries.count());
    try std.testing.expectEqual(@as(usize, 0), registry.in_flight);
    const cached = try registry.require(&ctx, allocator, &loader, TestOps.execute, "module", "<cjs>");
    try std.testing.expect(cached == value);
    TestOps.release(&ctx, cached);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
    registry.clear(&ctx);
    try std.testing.expectEqual(@as(usize, 0), registry.entries.count());
    for (ctx.cells[0..ctx.used]) |cell| try std.testing.expectEqual(@as(usize, 0), cell.refs);
}

test "cjs registry: loading aliases and same-ID reload generations balance references" {
    for ([_]bool{ false, true }) |fail| {
        var registry = Registry(TestOps).init(std.testing.allocator);
        defer registry.deinitStorage();
        var ctx = TestOps.Probe{ .registry = &registry, .inspect_cycle = true, .reload_during_execute = true, .fail_after_reload = fail };
        const vtable = types.LoaderVTable{ .load = TestOps.load };
        const loader = types.Loader{ .vtable = &vtable };
        if (fail) {
            try std.testing.expectError(error.CallFailed, registry.require(&ctx, std.testing.allocator, &loader, TestOps.execute, "module", "<cjs>"));
        } else {
            const older = try registry.require(&ctx, std.testing.allocator, &loader, TestOps.execute, "module", "<cjs>");
            try std.testing.expect(older != ctx.newest.?);
            TestOps.release(&ctx, older);
        }
        const cached = try registry.require(&ctx, std.testing.allocator, &loader, TestOps.execute, "module", "<cjs>");
        try std.testing.expect(cached == ctx.newest.?);
        TestOps.release(&ctx, cached);
        try std.testing.expectEqual(@as(usize, 2), ctx.calls);
        registry.clear(&ctx);
        for (ctx.cells[0..ctx.used]) |cell| try std.testing.expectEqual(@as(usize, 0), cell.refs);
    }
}

test "cjs registry: allocation failures during clear-reload release every live module" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var registry = Registry(TestOps).init(allocator);
            defer registry.deinitStorage();
            var ctx = TestOps.Probe{ .registry = &registry, .inspect_cycle = true, .reload_during_execute = true };
            defer for (ctx.cells[0..ctx.used]) |cell| std.debug.assert(cell.refs == 0);
            defer registry.clear(&ctx);
            const vtable = types.LoaderVTable{ .load = TestOps.load };
            const loader = types.Loader{ .vtable = &vtable };
            const value = try registry.require(&ctx, std.testing.allocator, &loader, TestOps.execute, "module", "<cjs>");
            TestOps.release(&ctx, value);
        }
    }.run, .{});
}

test "cjs registry: source-copy allocation failures are not missing modules" {
    var registry = Registry(TestOps).init(std.testing.allocator);
    defer registry.deinitStorage();
    var ctx = TestOps.Probe{};
    defer registry.clear(&ctx);
    const vtable = types.LoaderVTable{ .load = TestOps.load };
    const loader = types.Loader{ .vtable = &vtable };
    for (0..2) |failure| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure });
        try std.testing.expectError(error.OutOfMemory, registry.require(&ctx, failing.allocator(), &loader, TestOps.execute, "module", "parent"));
        try std.testing.expectEqual(@as(usize, 0), registry.entries.count());
    }
    try std.testing.expectEqual(@as(usize, 0), ctx.used);
}

test "cjs registry: pre-placeholder callbacks adopt nested entries without executing or retaining twice" {
    const phases = .{ .exports, .module, .load };
    inline for (phases) |phase| {
        for ([_]bool{ false, true }) |missing| {
            var registry = Registry(TestOps).init(std.testing.allocator);
            defer registry.deinitStorage();
            var ctx = TestOps.Probe{ .registry = &registry, .reentry = phase, .missing_after_reentry = missing };
            const vtable = types.LoaderVTable{ .load = TestOps.load };
            const loader = types.Loader{ .vtable = &vtable, .user_data = &ctx };
            const value = try registry.require(&ctx, std.testing.allocator, &loader, TestOps.execute, "module", "parent");
            try std.testing.expect(value == ctx.newest.?);
            try std.testing.expectEqual(@as(usize, 1), ctx.calls);
            TestOps.release(&ctx, value);
            registry.clear(&ctx);
            for (ctx.cells[0..ctx.used]) |cell| try std.testing.expectEqual(@as(usize, 0), cell.refs);
        }
    }
}

test "cjs registry: environment constructor failure never installs a cache entry or leaks exports" {
    for ([_]bool{ false, true }) |module| {
        var registry = Registry(TestOps).init(std.testing.allocator);
        defer registry.deinitStorage();
        var ctx = TestOps.Probe{ .fail_exports = !module, .fail_module = module };
        const vtable = types.LoaderVTable{ .load = TestOps.load };
        const loader = types.Loader{ .vtable = &vtable };
        try std.testing.expectError(error.OutOfMemory, registry.require(&ctx, std.testing.allocator, &loader, TestOps.execute, "module", "parent"));
        try std.testing.expectEqual(@as(usize, 0), registry.entries.count());
        try std.testing.expectEqual(@as(usize, 0), ctx.calls);
        for (ctx.cells[0..ctx.used]) |cell| try std.testing.expectEqual(@as(usize, 0), cell.refs);
    }
}

test "cjs registry: allocation failures during constructor reentry balance both transactions" {
    inline for (.{ .exports, .module }) |phase| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
            fn run(allocator: std.mem.Allocator) !void {
                var registry = Registry(TestOps).init(allocator);
                defer registry.deinitStorage();
                var ctx = TestOps.Probe{ .registry = &registry, .reentry = phase };
                defer for (ctx.cells[0..ctx.used]) |cell| std.debug.assert(cell.refs == 0);
                defer registry.clear(&ctx);
                const vtable = types.LoaderVTable{ .load = TestOps.load };
                const loader = types.Loader{ .vtable = &vtable, .user_data = &ctx };
                const value = try registry.require(&ctx, std.testing.allocator, &loader, TestOps.execute, "module", "parent");
                TestOps.release(&ctx, value);
            }
        }.run, .{});
    }
}
