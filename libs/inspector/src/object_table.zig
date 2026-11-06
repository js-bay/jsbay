pub fn Module(comptime Host: type) type {
    // ObjectTable — retains raw JS values so DevTools can later expand, invoke methods on, or release them.
    //
    // Thread-safety model:
    // - A single per-instance mutex guards `next_id`, `entries`, and `groups`. All three operations are cheap (hash-map ops + a dupValue call), so the extra granularity of per-field locks isn't worth the complexity.
    // - `retain` increments the stored ref (JSC: JSValueProtect via dupValue; QJS: +1 refcount), so the table owns its own handle independently of whatever produced the value.
    // - `get` returns a borrowed Value under the lock — callers use it only until they drop their reference to the entry. If a concurrent `release` invalidates the id mid-read, the caller sees the stale pointer; we don't attempt to defend against that because DevTools issues a single command per objectId at a time.
    // - `release` and `releaseGroup` call `freeValue` which pairs with the `dupValue` performed in `retain` — on JSC this is the matching JSValueUnprotect, so the value can finally be collected.
    // - `deinit` drains every outstanding entry. Must be called on the JS thread because `freeValue` touches the context.

    return struct {
        const std = @import("std");
        const sync = Host.sync;
        const backend = Host.backend;

        const ActiveEngine = backend.ActiveEngine;

        const GroupOwner = enum { public, console };

        const Group = struct {
            name: []const u8,
            owner: GroupOwner,
        };

        pub const ObjectTable = struct {
            /// Never issued by `retain`. Callers use it as "no object".
            pub const invalid_id: u64 = 0;

            const ConsoleLeaseSet = struct {
                ids: std.AutoHashMap(u64, void),
                closed: bool = false,
            };

            mutex: sync.Mutex = .{},
            next_id: u64 = invalid_id + 1,
            entries: std.AutoHashMap(u64, ActiveEngine.Value),
            /// objectId -> group metadata. Names are allocator-owned copies.
            groups: std.AutoHashMap(u64, Group),
            console_cache: std.AutoHashMap(u64, void),
            // Every console-derived object, including children created while expanding one.
            console_objects: std.AutoHashMap(u64, void),
            console_leases: std.AutoHashMap(u64, ConsoleLeaseSet),
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator) ObjectTable {
                return .{
                    .entries = std.AutoHashMap(u64, ActiveEngine.Value).init(allocator),
                    .groups = std.AutoHashMap(u64, Group).init(allocator),
                    .console_cache = std.AutoHashMap(u64, void).init(allocator),
                    .console_objects = std.AutoHashMap(u64, void).init(allocator),
                    .console_leases = std.AutoHashMap(u64, ConsoleLeaseSet).init(allocator),
                    .allocator = allocator,
                };
            }

            /// Retain `value` and return its freshly allocated objectId. The caller must still own/free its own reference to `value` (retain dups).
            pub fn retain(self: *ObjectTable, ctx: ActiveEngine.Context, value: ActiveEngine.Value, group: ?[]const u8) ?u64 {
                return self.retainOwned(ctx, value, group, .public);
            }

            /// Console events use an internal group namespace that CDP clients cannot release through Runtime.releaseObjectGroup.
            pub fn retainConsole(self: *ObjectTable, ctx: ActiveEngine.Context, value: ActiveEngine.Value, group: ?[]const u8) ?u64 {
                const id = self.retainOwned(ctx, value, group, .console) orelse return null;
                self.mutex.lock();
                defer self.mutex.unlock();
                self.console_objects.put(id, {}) catch {
                    self.releaseLocked(ctx, id);
                    return null;
                };
                self.console_cache.put(id, {}) catch {
                    _ = self.console_objects.remove(id);
                    self.releaseLocked(ctx, id);
                    return null;
                };
                return id;
            }

            /// Retain a child of a console object for one session only. Such children are never replayed.
            pub fn retainConsoleChild(self: *ObjectTable, ctx: ActiveEngine.Context, session_id: u64, value: ActiveEngine.Value) ?u64 {
                const id = self.retainOwned(ctx, value, null, .console) orelse return null;
                self.mutex.lock();
                defer self.mutex.unlock();
                self.console_objects.put(id, {}) catch {
                    self.releaseLocked(ctx, id);
                    return null;
                };
                self.grantConsoleLeaseLocked(session_id, &.{id}) catch {
                    _ = self.console_objects.remove(id);
                    self.releaseLocked(ctx, id);
                    return null;
                };
                return id;
            }

            fn retainOwned(self: *ObjectTable, ctx: ActiveEngine.Context, value: ActiveEngine.Value, group: ?[]const u8, owner: GroupOwner) ?u64 {
                self.mutex.lock();
                defer self.mutex.unlock();
                const id = self.next_id;
                const duped = ActiveEngine.dupValue(ctx, value);
                self.entries.put(id, duped) catch {
                    ActiveEngine.freeValue(ctx, duped);
                    return null;
                };
                if (group) |g| {
                    if (g.len != 0) {
                        const copy = self.allocator.dupe(u8, g) catch {
                            _ = self.entries.remove(id);
                            ActiveEngine.freeValue(ctx, duped);
                            return null;
                        };
                        self.groups.put(id, .{ .name = copy, .owner = owner }) catch {
                            self.allocator.free(copy);
                            _ = self.entries.remove(id);
                            ActiveEngine.freeValue(ctx, duped);
                            return null;
                        };
                    }
                }
                self.next_id += 1;
                return id;
            }

            /// Borrow the stored Value for an id. Returns null if the id isn't registered (or was released). The caller must NOT freeValue the returned handle — the table still owns it.
            pub fn get(self: *ObjectTable, id: u64) ?ActiveEngine.Value {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.entries.get(id);
            }

            pub fn getForSession(self: *ObjectTable, session_id: u64, id: u64) ?ActiveEngine.Value {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.console_objects.contains(id)) {
                    const leases = self.console_leases.get(session_id) orelse return null;
                    if (leases.closed or !leases.ids.contains(id)) return null;
                }
                return self.entries.get(id);
            }

            pub fn grantConsoleLease(self: *ObjectTable, session_id: u64, object_ids: []const u64) !void {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.grantConsoleLeaseLocked(session_id, object_ids);
            }

            fn grantConsoleLeaseLocked(self: *ObjectTable, session_id: u64, object_ids: []const u64) !void {
                var gop = try self.console_leases.getOrPut(session_id);
                if (!gop.found_existing) gop.value_ptr.* = .{ .ids = std.AutoHashMap(u64, void).init(self.allocator) };
                if (gop.value_ptr.closed) return error.SessionClosed;
                var additional: usize = 0;
                for (object_ids) |id| {
                    if (self.console_objects.contains(id) and !gop.value_ptr.ids.contains(id)) additional += 1;
                }
                try gop.value_ptr.ids.ensureTotalCapacity(@intCast(gop.value_ptr.ids.count() + additional));
                for (object_ids) |id| {
                    if (self.console_objects.contains(id)) gop.value_ptr.ids.putAssumeCapacity(id, {});
                }
            }

            pub fn releaseConsoleCache(self: *ObjectTable, ctx: ActiveEngine.Context, object_ids: []const u64) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                for (object_ids) |id| {
                    _ = self.console_cache.remove(id);
                    self.dropConsoleIfUnleasedLocked(ctx, id);
                }
            }

            pub fn discardConsole(self: *ObjectTable, ctx: ActiveEngine.Context) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                var objects = self.console_objects.keyIterator();
                while (objects.next()) |id| self.releaseLocked(ctx, id.*);
                var session_it = self.console_leases.valueIterator();
                while (session_it.next()) |leases| leases.ids.deinit();
                self.console_leases.clearRetainingCapacity();
                self.console_cache.clearRetainingCapacity();
                self.console_objects.clearRetainingCapacity();
            }

            pub fn releaseConsoleSession(self: *ObjectTable, ctx: ActiveEngine.Context, session_id: u64) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                var leases = (self.console_leases.fetchRemove(session_id) orelse return).value;
                defer leases.ids.deinit();
                var ids = leases.ids.keyIterator();
                while (ids.next()) |id| self.dropConsoleIfUnleasedLocked(ctx, id.*);
            }

            pub fn releaseConsoleLease(self: *ObjectTable, ctx: ActiveEngine.Context, session_id: u64, id: u64) bool {
                self.mutex.lock();
                defer self.mutex.unlock();
                const leases = self.console_leases.getPtr(session_id) orelse return false;
                if (!leases.ids.remove(id)) return false;
                self.dropConsoleIfUnleasedLocked(ctx, id);
                return true;
            }

            pub fn isConsole(self: *ObjectTable, id: u64) bool {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.console_objects.contains(id);
            }

            pub fn markConsoleSessionClosed(self: *ObjectTable, session_id: u64) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.console_leases.getPtr(session_id)) |leases| leases.closed = true;
            }

            // A close may arrive on the transport thread, where freeing a JS value is invalid. The next JS-owner turn drains marked sets.
            pub fn drainClosedConsoleSessions(self: *ObjectTable, ctx: ActiveEngine.Context) void {
                while (true) {
                    self.mutex.lock();
                    var closed: ?u64 = null;
                    var sessions = self.console_leases.iterator();
                    while (sessions.next()) |entry| {
                        if (entry.value_ptr.closed) {
                            closed = entry.key_ptr.*;
                            break;
                        }
                    }
                    self.mutex.unlock();
                    self.releaseConsoleSession(ctx, closed orelse return);
                }
            }

            fn consoleHasLeaseLocked(self: *ObjectTable, id: u64) bool {
                var sessions = self.console_leases.valueIterator();
                while (sessions.next()) |leases| if (leases.ids.contains(id)) return true;
                return false;
            }

            fn dropConsoleIfUnleasedLocked(self: *ObjectTable, ctx: ActiveEngine.Context, id: u64) void {
                if (self.console_cache.contains(id) or self.consoleHasLeaseLocked(id)) return;
                _ = self.console_objects.remove(id);
                self.releaseLocked(ctx, id);
            }

            fn releaseLocked(self: *ObjectTable, ctx: ActiveEngine.Context, id: u64) void {
                if (self.entries.fetchRemove(id)) |entry| ActiveEngine.freeValue(ctx, entry.value);
                if (self.groups.fetchRemove(id)) |group| self.allocator.free(@constCast(group.value.name));
            }

            /// Release a single id. Returns true if the id existed.
            pub fn release(self: *ObjectTable, ctx: ActiveEngine.Context, id: u64) bool {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.console_objects.contains(id)) return false;
                const exists = self.entries.contains(id);
                self.releaseLocked(ctx, id);
                return exists;
            }

            /// Release every entry tagged with `group_name`. Returns the count of entries released.
            pub fn releaseGroup(self: *ObjectTable, ctx: ActiveEngine.Context, group_name: []const u8) usize {
                return self.releaseGroupOwned(ctx, group_name, .public);
            }

            pub fn releaseConsoleGroup(self: *ObjectTable, ctx: ActiveEngine.Context, group_name: []const u8) usize {
                return self.releaseGroupOwned(ctx, group_name, .console);
            }

            fn releaseGroupOwned(self: *ObjectTable, ctx: ActiveEngine.Context, group_name: []const u8, owner: GroupOwner) usize {
                self.mutex.lock();
                defer self.mutex.unlock();
                var released: usize = 0;
                while (true) {
                    const id = blk: {
                        var it = self.groups.iterator();
                        while (it.next()) |kv| {
                            if (kv.value_ptr.*.owner == owner and std.mem.eql(u8, kv.value_ptr.*.name, group_name)) break :blk kv.key_ptr.*;
                        }
                        break :blk null;
                    } orelse break;
                    if (self.entries.fetchRemove(id)) |e_kv| {
                        ActiveEngine.freeValue(ctx, e_kv.value);
                    }
                    if (self.groups.fetchRemove(id)) |g_kv| {
                        self.allocator.free(@constCast(g_kv.value.name));
                    }
                    released += 1;
                }
                return released;
            }

            /// Drop every stored value. Called from inspector teardown — must run while the JS context is still live (freeValue on JSC unprotects; QJS decrements the refcount). If `ctx` is null the engine has already been torn down: the runtime is gone, so we drain the maps but skip freeValue (the backing memory is already reclaimed).
            pub fn deinit(self: *ObjectTable, ctx: ?ActiveEngine.Context) void {
                defer self.mutex.deinit();
                self.mutex.lock();
                defer self.mutex.unlock();
                if (ctx) |c| {
                    var it = self.entries.iterator();
                    while (it.next()) |kv| {
                        ActiveEngine.freeValue(c, kv.value_ptr.*);
                    }
                }
                self.entries.deinit();
                var leases = self.console_leases.valueIterator();
                while (leases.next()) |session| session.ids.deinit();
                self.console_leases.deinit();
                self.console_cache.deinit();
                self.console_objects.deinit();
                var gi = self.groups.iterator();
                while (gi.next()) |kv| {
                    self.allocator.free(@constCast(kv.value_ptr.*.name));
                }
                self.groups.deinit();
            }
        };

        pub const TestCases = if (@import("builtin").is_test) struct {
            pub fn publicAndConsoleGroupsWithSameNameReleaseIndependently() !void {
                if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
                const testing = std.testing;
                const engine = Host.engine;
                const instance_id: i32 = 61_799;
                try testing.expect(engine.create(instance_id, .{}));
                defer engine.destroy(instance_id);
                const ctx = engine.getContext(instance_id).?;
                const value = ActiveEngine.getGlobalObject(ctx);
                defer ActiveEngine.freeValue(ctx, value);

                var table = ObjectTable.init(testing.allocator);
                defer table.deinit(ctx);
                const public_id = table.retain(ctx, value, "same-name").?;
                const console_id = table.retainConsole(ctx, value, "same-name").?;
                try testing.expectEqual(@as(usize, 1), table.releaseGroup(ctx, "same-name"));
                try testing.expect(table.get(public_id) == null);
                try testing.expect(table.get(console_id) != null);
                var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
                table.allocator = failing.allocator();
                try testing.expectEqual(@as(usize, 1), table.releaseConsoleGroup(ctx, "same-name"));
                try testing.expect(table.get(console_id) == null);
                table.allocator = testing.allocator;
                const retained_public_id = table.retain(ctx, value, "same-name").?;
                _ = table.retainConsole(ctx, value, "same-name").?;
                try testing.expectEqual(@as(usize, 1), table.releaseConsoleGroup(ctx, "same-name"));
                try testing.expect(table.get(retained_public_id) != null);
                try testing.expectEqual(@as(usize, 1), table.releaseGroup(ctx, "same-name"));
            }

            pub fn closedConsoleSessionRemainsIsolatedWhenCloseCannotAllocate() !void {
                if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
                const testing = std.testing;
                const engine = Host.engine;
                const instance_id: i32 = 61_800;
                const closed_session: u64 = 701;
                const active_session: u64 = 702;
                try testing.expect(engine.create(instance_id, .{}));
                defer engine.destroy(instance_id);
                const ctx = engine.getContext(instance_id).?;
                const value = ActiveEngine.getGlobalObject(ctx);
                defer ActiveEngine.freeValue(ctx, value);

                var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = std.math.maxInt(usize), .resize_fail_index = std.math.maxInt(usize) });
                var table = ObjectTable.init(failing.allocator());
                defer table.deinit(ctx);
                const closed_id = table.retainConsoleChild(ctx, closed_session, value).?;
                const active_id = table.retainConsoleChild(ctx, active_session, value).?;
                try testing.expect(table.getForSession(closed_session, closed_id) != null);
                try testing.expect(table.getForSession(active_session, active_id) != null);

                const allocations_before_close = failing.alloc_index;
                const resizes_before_close = failing.resize_index;
                failing.fail_index = failing.alloc_index;
                failing.resize_fail_index = failing.resize_index;
                table.markConsoleSessionClosed(closed_session);
                try testing.expectEqual(allocations_before_close, failing.alloc_index);
                try testing.expectEqual(resizes_before_close, failing.resize_index);
                try testing.expect(table.getForSession(closed_session, closed_id) == null);
                try testing.expect(table.getForSession(active_session, active_id) != null);
                try testing.expect(table.get(closed_id) != null);

                failing.fail_index = std.math.maxInt(usize);
                failing.resize_fail_index = std.math.maxInt(usize);
                table.drainClosedConsoleSessions(ctx);
                try testing.expect(table.get(closed_id) == null);
                try testing.expect(table.getForSession(active_session, active_id) != null);
            }
        } else struct {};
    };
}
