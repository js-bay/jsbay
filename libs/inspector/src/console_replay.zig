pub const Module = struct {
    const std = @import("std");
    const transport_mod = @import("transport.zig");

    pub const console_buffer_cap: usize = 100;
    pub const delivery_bytes_cap: usize = 8 * 1024 * 1024;

    pub const BufferedConsole = struct {
        entries: [][]u8 = &.{},
        owned: bool = false,
        failed: bool = false,
        started: bool = false,
        generation: u64 = 0,
        accounted_bytes: usize = 0,
    };

    pub const RuntimeReplayNext = union(enum) { entry: []u8, done, cancelled };

    pub const Session = struct {
        enabled: bool = false,
        enabling: bool = false,
        replaying: bool = false,
        replay_failed: bool = false,
        generation: u64 = 0,
        events_queued: usize = 0,
        queue: std.ArrayList([]u8) = .empty,
    };

    pub const Account = struct { bytes: usize = 0 };

    pub fn setEnabled(state: anytype, session_id: transport_mod.SessionId, enabled: bool) void {
        state.mutex.lock();
        defer state.mutex.unlock();
        for (state.sessions.items) |*session| {
            if (session.id != session_id) continue;
            session.runtime.enabled = enabled;
            session.runtime.enabling = false;
            session.runtime.replaying = false;
            session.runtime.generation +%= 1;
            session.runtime.events_queued = 0;
            clearQueueLocked(state, session);
            return;
        }
    }

    // Runtime.enable announces its transition before the reply so owner-thread calls in the response/context window enter the shared ring.
    pub fn beginEnable(state: anytype, session_id: transport_mod.SessionId) bool {
        state.mutex.lock();
        defer state.mutex.unlock();
        for (state.sessions.items) |*session| {
            if (session.id != session_id) continue;
            if (session.runtime.enabled or session.runtime.enabling or session.runtime.replaying) return false;
            session.runtime.enabling = true;
            session.runtime.replay_failed = false;
            session.runtime.generation +%= 1;
            return true;
        }
        return false;
    }

    // Snapshot the bounded ring and route later events to a bounded per-session FIFO under the same state lock.
    pub fn beginReplay(state: anytype, session_id: transport_mod.SessionId) BufferedConsole {
        state.mutex.lock();
        defer state.mutex.unlock();
        const session = sessionPtrLocked(state, session_id) orelse return .{};
        if (!session.runtime.enabling) return .{};
        const pending = state.console_entries.items[state.console_entries_head..];
        var snapshot_bytes: usize = 0;
        for (pending) |entry| {
            if (entry.json.len > delivery_bytes_cap - snapshot_bytes) return failEnable(session);
            snapshot_bytes += entry.json.len;
        }
        if (snapshot_bytes > delivery_bytes_cap - state.runtime_delivery.bytes) return failEnable(session);
        const out = state.allocator.alloc([]u8, pending.len) catch return failEnable(session);
        var filled: usize = 0;
        for (pending) |entry| {
            out[filled] = state.allocator.dupe(u8, entry.json) catch {
                for (out[0..filled]) |copy| state.allocator.free(copy);
                state.allocator.free(out);
                return failEnable(session);
            };
            filled += 1;
        }
        for (pending) |entry| {
            state.object_table.grantConsoleLease(session_id, entry.object_ids) catch {
                for (out) |copy| state.allocator.free(copy);
                state.allocator.free(out);
                session.runtime.enabling = false;
                session.runtime.replay_failed = true;
                state.object_table.markConsoleSessionClosed(session_id);
                return .{ .failed = true };
            };
        }
        session.runtime.enabling = false;
        session.runtime.replaying = true;
        session.runtime.events_queued = 0;
        state.runtime_delivery.bytes += snapshot_bytes;
        return .{ .entries = out, .owned = pending.len != 0, .started = true, .generation = session.runtime.generation, .accounted_bytes = snapshot_bytes };
    }

    fn failEnable(session: anytype) BufferedConsole {
        session.runtime.enabling = false;
        session.runtime.replay_failed = true;
        return .{ .failed = true };
    }

    pub fn nextEntry(state: anytype, session_id: transport_mod.SessionId, generation: u64) RuntimeReplayNext {
        state.mutex.lock();
        defer state.mutex.unlock();
        const session = sessionPtrLocked(state, session_id) orelse return .cancelled;
        if (session.runtime.generation != generation or !session.runtime.replaying or session.runtime.replay_failed) return .cancelled;
        if (session.runtime.queue.items.len != 0) return .{ .entry = session.runtime.queue.orderedRemove(0) };
        session.runtime.replaying = false;
        session.runtime.enabled = true;
        session.runtime.events_queued = 0;
        return .done;
    }

    pub fn failReplay(state: anytype, session_id: transport_mod.SessionId, generation: ?u64) void {
        state.mutex.lock();
        for (state.sessions.items) |*session| {
            if (session.id != session_id) continue;
            if (generation) |expected| {
                if (session.runtime.generation != expected) {
                    state.mutex.unlock();
                    return;
                }
            }
            session.runtime.enabled = false;
            session.runtime.enabling = false;
            session.runtime.replaying = false;
            session.runtime.replay_failed = true;
            session.runtime.generation +%= 1;
            session.runtime.events_queued = 0;
            clearQueueLocked(state, session);
            break;
        }
        state.mutex.unlock();
        state.object_table.markConsoleSessionClosed(session_id);
    }

    // Called under state.mutex. The transport close is deferred until after that lock is released.
    pub fn queueEventLocked(state: anytype, session: anytype, json: []const u8, object_ids: []const u64) void {
        if (session.runtime.queue.items.len >= console_buffer_cap or
            session.runtime.events_queued >= console_buffer_cap or
            json.len > delivery_bytes_cap - state.runtime_delivery.bytes)
        {
            failReplayLocked(state, session);
            return;
        }
        const queued = state.allocator.dupe(u8, json) catch {
            failReplayLocked(state, session);
            return;
        };
        session.runtime.queue.ensureTotalCapacity(state.allocator, session.runtime.queue.items.len + 1) catch {
            state.allocator.free(queued);
            failReplayLocked(state, session);
            return;
        };
        state.object_table.grantConsoleLease(session.id, object_ids) catch {
            state.allocator.free(queued);
            failReplayLocked(state, session);
            return;
        };
        session.runtime.queue.appendAssumeCapacity(queued);
        session.runtime.events_queued += 1;
        state.runtime_delivery.bytes += json.len;
    }

    fn failReplayLocked(state: anytype, session: anytype) void {
        session.runtime.enabled = false;
        session.runtime.enabling = false;
        session.runtime.replaying = false;
        session.runtime.replay_failed = true;
        session.runtime.generation +%= 1;
        session.runtime.events_queued = 0;
        clearQueueLocked(state, session);
        state.object_table.markConsoleSessionClosed(session.id);
    }

    pub fn closeFailedSessions(state: anytype) void {
        while (true) {
            state.mutex.lock();
            var failed_id: ?transport_mod.SessionId = null;
            for (state.sessions.items) |*session| {
                if (!session.runtime.replay_failed) continue;
                session.runtime.replay_failed = false;
                failed_id = session.id;
                break;
            }
            state.mutex.unlock();
            const session_id = failed_id orelse return;
            state.object_table.markConsoleSessionClosed(session_id);
            state.transport.closeSession(session_id);
        }
    }

    pub fn clearQueueLocked(state: anytype, session: anytype) void {
        for (session.runtime.queue.items) |entry| {
            state.runtime_delivery.bytes -= entry.len;
            state.allocator.free(entry);
        }
        session.runtime.queue.clearRetainingCapacity();
    }

    pub fn deinitQueue(state: anytype, session: anytype) void {
        clearQueueLocked(state, session);
        session.runtime.queue.deinit(state.allocator);
    }

    fn sessionPtrLocked(state: anytype, session_id: transport_mod.SessionId) ?*std.meta.Child(@TypeOf(state.sessions.items)) {
        for (state.sessions.items) |*session| if (session.id == session_id) return session;
        return null;
    }

    pub fn freeBuffered(state: anytype, buffered: BufferedConsole) void {
        if (buffered.accounted_bytes != 0) {
            state.mutex.lock();
            state.runtime_delivery.bytes -= buffered.accounted_bytes;
            state.mutex.unlock();
        }
        if (!buffered.owned) return;
        for (buffered.entries) |entry| state.allocator.free(entry);
        state.allocator.free(buffered.entries);
    }

    pub fn freeEntry(state: anytype, entry: []u8) void {
        state.mutex.lock();
        state.runtime_delivery.bytes -= entry.len;
        state.mutex.unlock();
        state.allocator.free(entry);
    }
};
