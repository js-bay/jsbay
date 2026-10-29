//! Async parent stacks for timer callbacks.
//!
//! `Debugger.setAsyncCallStackDepth` stores how many parents to keep. `setTimeout` captures the scheduling stack. While that callback runs, console events append it as `stackTrace.parent` and pauses append it as `asyncStackTrace`. Depth zero captures nothing.

const std = @import("std");
const debugger_mod = @import("debugger.zig");
const sync = @import("zev");

pub const Frame = struct {
    name: []u8,
    url: []u8,
    line: i32,
    column: i32,
    /// Cloned frames keep one owner for all copied strings. Frames created by the JSC adapter leave this empty and own each string separately.
    storage: []u8 = &.{},
};

pub const Trace = struct {
    frames: []Frame,
    /// Active async parents copied when this trace was scheduled. They are restored before the trace's own scheduling frame when it eventually runs, so a nested Promise/timer chain keeps all requested ancestors.
    parents: []Link = &.{},
};

const Link = struct {
    description: []const u8,
    frames: []Frame,
};

const max_links = 8;

const Slot = struct {
    depth: u32 = 0,
    links: [max_links]Link = undefined,
    len: u8 = 0,
};

var mutex: sync.Mutex = .{};
var slots: ?std.AutoHashMap(i32, Slot) = null;
/// A zero value lets timer and Promise scheduling avoid taking the global bookkeeping mutex while no Inspector client has requested async parents. It is only a fast rejection: positive values still take `mutex` and read the per-instance slot, so one engine enabling stacks cannot make another engine retain a trace.
var enabled_instance_count: std.atomic.Value(u32) = .init(0);

fn map() *std.AutoHashMap(i32, Slot) {
    if (slots == null) slots = std.AutoHashMap(i32, Slot).init(std.heap.c_allocator);
    return &slots.?;
}

/// Caller holds `mutex`.
fn existingSlot(instance_id: i32) ?*Slot {
    if (slots) |*all_slots| return all_slots.getPtr(instance_id);
    return null;
}

pub fn setDepth(instance_id: i32, max_depth: u32) void {
    if (comptime !@import("build_options").inspector) return;
    mutex.lock();
    defer mutex.unlock();
    const slot = existingSlot(instance_id) orelse {
        if (max_depth == 0) return;
        map().put(instance_id, .{ .depth = max_depth }) catch return;
        _ = enabled_instance_count.fetchAdd(1, .release);
        return;
    };
    if (slot.depth == 0 and max_depth != 0) {
        _ = enabled_instance_count.fetchAdd(1, .release);
    } else if (slot.depth != 0 and max_depth == 0) {
        _ = enabled_instance_count.fetchSub(1, .release);
    }
    slot.depth = max_depth;
    if (slot.len > max_depth) slot.len = @intCast(max_depth);
    if (max_depth == 0 and !hasEnteredInstance(instance_id)) removeIdleSlot(instance_id);
}

pub fn depth(instance_id: i32) u32 {
    if (comptime !@import("build_options").inspector) return 0;
    if (enabled_instance_count.load(.acquire) == 0) return 0;
    mutex.lock();
    defer mutex.unlock();
    const slot = existingSlot(instance_id) orelse return 0;
    return slot.depth;
}

/// Test-only observation for cold lifecycle contracts. A depth-zero Inspector must not create an otherwise empty per-instance slot.
pub fn hasSlotForTesting(instance_id: i32) bool {
    if (comptime !@import("builtin").is_test) return false;
    mutex.lock();
    defer mutex.unlock();
    return if (slots) |*all_slots| all_slots.contains(instance_id) else false;
}

pub fn capture(instance_id: i32) ?Trace {
    if (comptime !@import("build_options").inspector) return null;
    if (enabled_instance_count.load(.acquire) == 0) return null;
    const max_depth = depth(instance_id);
    if (max_depth == 0) return null;
    const raw = debugger_mod.copyDebugStack(instance_id);
    defer {
        for (raw) |frame| {
            if (frame.name.len != 0) std.heap.c_allocator.free(frame.name);
            if (frame.url.len != 0) std.heap.c_allocator.free(frame.url);
        }
        if (raw.len != 0) std.heap.c_allocator.free(raw);
    }
    const frames = cloneFrames(raw) orelse return null;
    const parents = snapshotParents(instance_id, max_depth - 1) orelse {
        freeFrames(frames);
        return null;
    };
    if (frames.len == 0 and parents.len == 0) return null;
    return .{ .frames = frames, .parents = parents };
}

fn cloneFrames(raw: []const debugger_mod.DebugFrame) ?[]Frame {
    if (raw.len == 0) return &.{};
    const frames = std.heap.c_allocator.alloc(Frame, raw.len) catch return null;
    var storage_len: usize = 0;
    for (raw) |frame| {
        storage_len = std.math.add(usize, storage_len, frame.name.len) catch {
            std.heap.c_allocator.free(frames);
            return null;
        };
        storage_len = std.math.add(usize, storage_len, frame.url.len) catch {
            std.heap.c_allocator.free(frames);
            return null;
        };
    }
    const storage = std.heap.c_allocator.alloc(u8, storage_len) catch {
        std.heap.c_allocator.free(frames);
        return null;
    };
    var offset: usize = 0;
    for (raw, 0..) |frame, i| {
        const name = storage[offset..][0..frame.name.len];
        @memcpy(name, frame.name);
        offset += frame.name.len;
        const url = storage[offset..][0..frame.url.len];
        @memcpy(url, frame.url);
        offset += frame.url.len;
        frames[i] = .{
            .name = name,
            .url = url,
            .line = if (frame.line > 0) frame.line - 1 else 0,
            .column = frame.column,
            .storage = if (i == 0) storage else &.{},
        };
    }
    return frames;
}

fn cloneStoredFrames(raw: []const Frame) ?[]Frame {
    if (raw.len == 0) return &.{};
    const frames = std.heap.c_allocator.alloc(Frame, raw.len) catch return null;
    var storage_len: usize = 0;
    for (raw) |frame| {
        storage_len = std.math.add(usize, storage_len, frame.name.len) catch {
            std.heap.c_allocator.free(frames);
            return null;
        };
        storage_len = std.math.add(usize, storage_len, frame.url.len) catch {
            std.heap.c_allocator.free(frames);
            return null;
        };
    }
    const storage = std.heap.c_allocator.alloc(u8, storage_len) catch {
        std.heap.c_allocator.free(frames);
        return null;
    };
    var offset: usize = 0;
    for (raw, 0..) |frame, i| {
        const name = storage[offset..][0..frame.name.len];
        @memcpy(name, frame.name);
        offset += frame.name.len;
        const url = storage[offset..][0..frame.url.len];
        @memcpy(url, frame.url);
        offset += frame.url.len;
        frames[i] = .{
            .name = name,
            .url = url,
            .line = frame.line,
            .column = frame.column,
            .storage = if (i == 0) storage else &.{},
        };
    }
    return frames;
}

fn snapshotParents(instance_id: i32, limit: u32) ?[]Link {
    if (limit == 0) return &.{};
    mutex.lock();
    defer mutex.unlock();
    const slot = existingSlot(instance_id) orelse return &.{};
    const count: usize = @min(slot.len, @as(usize, limit));
    if (count == 0) return &.{};
    const parents = std.heap.c_allocator.alloc(Link, count) catch return null;
    const start: usize = @as(usize, slot.len) - count;
    for (slot.links[start..][0..count], 0..) |link, i| {
        parents[i] = .{
            .description = link.description,
            .frames = cloneStoredFrames(link.frames) orelse {
                for (parents[0..i]) |parent| freeFrames(parent.frames);
                std.heap.c_allocator.free(parents);
                return null;
            },
        };
    }
    return parents;
}

pub fn freeTrace(trace: Trace) void {
    freeFrames(trace.frames);
    for (trace.parents) |parent| freeFrames(parent.frames);
    if (trace.parents.len != 0) std.heap.c_allocator.free(trace.parents);
}

fn freeFrames(frames: []Frame) void {
    var storage: []u8 = &.{};
    for (frames) |frame| {
        if (frame.storage.len != 0) {
            storage = frame.storage;
            break;
        }
    }
    if (storage.len != 0) {
        std.heap.c_allocator.free(storage);
    } else {
        for (frames) |frame| {
            if (frame.name.len != 0) std.heap.c_allocator.free(frame.name);
            if (frame.url.len != 0) std.heap.c_allocator.free(frame.url);
        }
    }
    if (frames.len != 0) std.heap.c_allocator.free(frames);
}

const Entered = struct {
    instance_id: i32,
    count: u8,
};

threadlocal var entered: [32]Entered = undefined;
threadlocal var entered_len: u8 = 0;

pub fn enter(instance_id: i32, description: []const u8, trace: Trace) bool {
    mutex.lock();
    defer mutex.unlock();
    const slot = existingSlot(instance_id) orelse return false;
    if (slot.depth == 0 or entered_len == entered.len) return false;
    const capacity: usize = @min(slot.depth, max_links) -| slot.len;
    if (capacity == 0) return false;
    const parent_count: usize = @min(trace.parents.len, capacity - 1);
    const parent_start = trace.parents.len - parent_count;
    for (trace.parents[parent_start..]) |parent| {
        slot.links[slot.len] = parent;
        slot.len += 1;
    }
    slot.links[slot.len] = .{ .description = description, .frames = trace.frames };
    slot.len += 1;
    entered[entered_len] = .{ .instance_id = instance_id, .count = @intCast(parent_count + 1) };
    entered_len += 1;
    return true;
}

pub fn leave(instance_id: i32) void {
    mutex.lock();
    defer mutex.unlock();
    if (entered_len == 0) return;
    const marker = entered[entered_len - 1];
    if (marker.instance_id != instance_id) return;
    entered_len -= 1;
    const slot = existingSlot(instance_id) orelse return;
    slot.len -|= marker.count;
    if (slot.depth == 0 and !hasEnteredInstance(instance_id)) removeIdleSlot(instance_id);
}

pub fn writeParents(instance_id: i32, w: anytype) !void {
    try writeChain(instance_id, w, "parent");
}

pub fn writeAsyncStackTrace(instance_id: i32, w: anytype) !void {
    try writeChain(instance_id, w, "asyncStackTrace");
}

fn writeChain(instance_id: i32, w: anytype, field: []const u8) !void {
    mutex.lock();
    defer mutex.unlock();
    const slot = existingSlot(instance_id) orelse return;
    if (slot.len == 0) return;
    try writeLink(w, field, slot.links[0..slot.len], slot.len - 1);
}

fn writeLink(w: anytype, field: []const u8, links: []const Link, index: usize) !void {
    const link = links[index];
    try w.writeAll(",\"");
    try w.writeAll(field);
    try w.writeAll("\":{\"description\":");
    try writeJsonString(w, link.description);
    try w.writeAll(",\"callFrames\":[");
    var wrote = false;
    for (link.frames) |frame| {
        if (frame.url.len == 0 and frame.name.len == 0) continue;
        if (wrote) try w.writeByte(',');
        wrote = true;
        try w.writeAll("{\"functionName\":");
        try writeJsonString(w, frame.name);
        try w.writeAll(",\"url\":");
        try writeJsonString(w, frame.url);
        try w.print(",\"lineNumber\":{d},\"columnNumber\":{d}}}", .{ frame.line, frame.column });
    }
    try w.writeByte(']');
    if (index > 0) try writeLink(w, "parent", links, index - 1);
    try w.writeByte('}');
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

const Pending = struct {
    kind: []const u8,
    trace: ?Trace,
};

const PendingQueue = struct {
    items: std.ArrayList(Pending) = .empty,
    head: usize = 0,

    fn append(self: *PendingQueue, item: Pending) !void {
        self.compactIfNeeded();
        try self.items.append(std.heap.c_allocator, item);
    }

    fn pop(self: *PendingQueue) ?Pending {
        if (self.head == self.items.items.len) return null;
        const item = self.items.items[self.head];
        self.head += 1;
        if (self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        } else {
            self.compactIfNeeded();
        }
        return item;
    }

    fn compactIfNeeded(self: *PendingQueue) void {
        if (self.head < 64 or self.head * 2 < self.items.items.len) return;
        const remaining = self.items.items.len - self.head;
        var write: usize = 0;
        while (write < remaining) : (write += 1) {
            self.items.items[write] = self.items.items[self.head + write];
        }
        self.items.shrinkRetainingCapacity(remaining);
        self.head = 0;
    }

    fn deinit(self: *PendingQueue) void {
        self.items.deinit(std.heap.c_allocator);
        self.* = .{};
    }
};

const ActiveJob = struct {
    instance_id: i32,
    trace: ?Trace,
    entered: bool,
};

var job_queues: ?std.AutoHashMap(i32, PendingQueue) = null;
threadlocal var active_jobs: [32]ActiveJob = undefined;
threadlocal var active_job_len: u8 = 0;

fn hasEnteredInstance(instance_id: i32) bool {
    for (entered[0..entered_len]) |marker| if (marker.instance_id == instance_id) return true;
    return false;
}

/// Caller holds `mutex` and has already moved this slot to depth zero.
fn removeIdleSlot(instance_id: i32) void {
    const all_slots = if (slots) |*value| value else return;
    _ = all_slots.remove(instance_id);
    if (all_slots.count() == 0) {
        all_slots.deinit();
        slots = null;
    }
}

fn jobQueues() *std.AutoHashMap(i32, PendingQueue) {
    if (job_queues == null) job_queues = std.AutoHashMap(i32, PendingQueue).init(std.heap.c_allocator);
    return &job_queues.?;
}

/// Test-only observation: a depth-zero runtime must not retain a per-instance job queue solely for debugger bookkeeping.
pub fn hasJobQueueForTesting(instance_id: i32) bool {
    if (comptime !@import("builtin").is_test) return false;
    mutex.lock();
    defer mutex.unlock();
    return if (job_queues) |*queues| queues.contains(instance_id) else false;
}

/// `phase` 0 queues `kind` with the current stack. 1 enters that parent. 2 leaves it. Called around every QuickJS job so Promise reactions and `queueMicrotask` keep the scheduling stack.
pub fn onJob(instance_id: i32, phase: i32, kind: []const u8) bool {
    return switch (phase) {
        // The native hook can remain installed in an inspector-capable build, but depth zero must not allocate a queue or leave placeholder entries for every Promise job.
        0 => if (depth(instance_id) != 0) enqueueJob(instance_id, if (kind.len == 0) "Promise" else kind) else false,
        1 => if (depth(instance_id) != 0) beforeJob(instance_id) else false,
        2 => blk: {
            afterJob();
            break :blk true;
        },
        else => true,
    };
}

/// Discard queued Promise parents when CDP turns async stacks off. A job that is already executing owns its parent in thread-local `active_jobs` and is released by phase 2, so it must not be touched here.
pub fn dropQueuedJobs(instance_id: i32) void {
    mutex.lock();
    defer mutex.unlock();
    const queues = if (job_queues) |*value| value else return;
    if (queues.fetchRemove(instance_id)) |entry| {
        var queue = entry.value;
        for (queue.items.items[queue.head..]) |item| if (item.trace) |trace| freeTrace(trace);
        queue.deinit();
    }
    if (queues.count() == 0) {
        queues.deinit();
        job_queues = null;
    }
}

fn enqueueJob(instance_id: i32, kind: []const u8) bool {
    const trace = capture(instance_id);
    mutex.lock();
    const queued = appendJob(instance_id, kind, trace);
    mutex.unlock();
    if (!queued) if (trace) |parent| freeTrace(parent);
    return queued;
}

fn appendJob(instance_id: i32, kind: []const u8, trace: ?Trace) bool {
    // A native QuickJS job has already been accepted when its phase-0 hook reaches us. Tests use this seam to exercise loss of only this Zig-side metadata entry without affecting the engine's own queue.
    if (@import("../tests/inspector_test_faults.zig").take(instance_id, .async_job_metadata_enqueue)) return false;
    const queues = jobQueues();
    if (queues.getPtr(instance_id) == null) {
        queues.put(instance_id, .{}) catch return false;
    }
    const q = queues.getPtr(instance_id) orelse return false;
    q.append(.{ .kind = kind, .trace = trace }) catch return false;
    return true;
}

/// Returns true only when phase 1 retained an active-job marker that phase 2 may consume. The native hook suppresses phase 2 when this returns false.
fn beforeJob(instance_id: i32) bool {
    mutex.lock();
    const item = popJob(instance_id);
    mutex.unlock();
    const did_enter = if (item.trace) |parent| enter(instance_id, item.kind, parent) else false;
    if (active_job_len == active_jobs.len) {
        if (did_enter) leave(instance_id);
        if (item.trace) |parent| freeTrace(parent);
        return false;
    }
    active_jobs[active_job_len] = .{
        .instance_id = instance_id,
        .trace = item.trace,
        .entered = did_enter,
    };
    active_job_len += 1;
    return true;
}

fn afterJob() void {
    if (active_job_len == 0) return;
    active_job_len -= 1;
    const item = active_jobs[active_job_len];
    if (item.entered) leave(item.instance_id);
    if (item.trace) |parent| freeTrace(parent);
}

fn popJob(instance_id: i32) Pending {
    const q = jobQueues().getPtr(instance_id) orelse return .{ .kind = "Promise", .trace = null };
    return q.pop() orelse .{ .kind = "Promise", .trace = null };
}

/// Drops all async-stack state retained for a runtime's engine instance. Called by the QuickJS runtime finalizer after queued jobs have been discarded, before an instance id can be reused.
pub fn deinitInstance(instance_id: i32) void {
    mutex.lock();
    defer mutex.unlock();
    if (job_queues) |*queues| {
        if (queues.fetchRemove(instance_id)) |entry| {
            var queue = entry.value;
            for (queue.items.items[queue.head..]) |item| if (item.trace) |trace| freeTrace(trace);
            queue.deinit();
        }
        if (queues.count() == 0) {
            queues.deinit();
            job_queues = null;
        }
    }
    if (slots) |*all_slots| {
        if (all_slots.fetchRemove(instance_id)) |entry| {
            if (entry.value.depth != 0) _ = enabled_instance_count.fetchSub(1, .release);
        }
        if (all_slots.count() == 0) {
            all_slots.deinit();
            slots = null;
        }
    }
}

const InspectorEnabledTests = if (@import("build_options").inspector) struct {
    test "async job queue preserves FIFO and keeps a consumed prefix cursor" {
        var queue = PendingQueue{};
        defer queue.deinit();

        try queue.append(.{ .kind = "first", .trace = null });
        try queue.append(.{ .kind = "second", .trace = null });
        try queue.append(.{ .kind = "third", .trace = null });

        const first = queue.pop() orelse return error.MissingPendingJob;
        try std.testing.expectEqualStrings("first", first.kind);
        try std.testing.expectEqual(@as(usize, 1), queue.head);

        try queue.append(.{ .kind = "fourth", .trace = null });
        const second = queue.pop() orelse return error.MissingPendingJob;
        const third = queue.pop() orelse return error.MissingPendingJob;
        const fourth = queue.pop() orelse return error.MissingPendingJob;
        try std.testing.expectEqualStrings("second", second.kind);
        try std.testing.expectEqualStrings("third", third.kind);
        try std.testing.expectEqualStrings("fourth", fourth.kind);
        try std.testing.expect(queue.pop() == null);
        try std.testing.expectEqual(@as(usize, 0), queue.head);
    }

    test "async depth zero job remains a FIFO null trace placeholder" {
        const instance_id = 0x7a51;
        deinitInstance(instance_id);
        defer deinitInstance(instance_id);

        try std.testing.expect(appendJob(instance_id, "depth-zero", null));
        try std.testing.expect(appendJob(instance_id, "captured", .{
            .frames = &.{},
            .parents = &.{},
        }));

        const first = popJob(instance_id);
        try std.testing.expectEqualStrings("depth-zero", first.kind);
        try std.testing.expect(first.trace == null);
        const second = popJob(instance_id);
        try std.testing.expectEqualStrings("captured", second.kind);
        try std.testing.expect(second.trace != null);
        if (second.trace) |trace| freeTrace(trace);
    }
};

comptime {
    _ = InspectorEnabledTests;
}

test "async stack depth contract preserves disabled and nesting behavior" {
    if (comptime !@import("build_options").inspector) {
        const instance_id = 0x7a52;
        deinitInstance(instance_id);
        defer deinitInstance(instance_id);
        setDepth(instance_id, max_links);
        try std.testing.expectEqual(@as(u32, 0), depth(instance_id));
        try std.testing.expect(!hasSlotForTesting(instance_id));
        try std.testing.expect(!hasJobQueueForTesting(instance_id));
        try std.testing.expect(!onJob(instance_id, 1, "disabled"));
        return;
    }
    const instance_id = 0x7a52;
    deinitInstance(instance_id);
    defer {
        // A failure at the admission assertion must not leak this thread's active-job markers into a later async-stack test.
        while (active_job_len != 0) afterJob();
        deinitInstance(instance_id);
    }
    setDepth(instance_id, max_links);

    const kinds = [_][]const u8{
        "job-1",  "job-2",  "job-3",  "job-4",  "job-5",  "job-6",  "job-7",  "job-8",
        "job-9",  "job-10", "job-11", "job-12", "job-13", "job-14", "job-15", "job-16",
        "job-17", "job-18", "job-19", "job-20", "job-21", "job-22", "job-23", "job-24",
        "job-25", "job-26", "job-27", "job-28", "job-29", "job-30", "job-31", "job-32",
        "job-33",
    };
    for (kinds[0..32]) |kind| {
        try std.testing.expect(appendJob(instance_id, kind, .{ .frames = &.{}, .parents = &.{} }));
        try std.testing.expect(onJob(instance_id, 1, kind));
    }
    try std.testing.expect(appendJob(instance_id, kinds[32], .{ .frames = &.{}, .parents = &.{} }));

    // A native phase 2 is only valid when phase 1 admitted an active-job record. Otherwise the next phase 2 would pop job-32 and shift every outer parent one level early.
    try std.testing.expect(!onJob(instance_id, 1, kinds[32]));

    // Jobs 32 through 9 do not own a retained Link at depth eight. Their completions must leave job-8 as the parent of the still-running job-9.
    for (0..24) |_| try std.testing.expect(onJob(instance_id, 2, ""));
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeParents(instance_id, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"description\":\"job-8\"") != null);
}

const InspectorEnabledTests2 = if (@import("build_options").inspector) struct {
    test "async frame cloning shares string storage" {
        const raw = [_]debugger_mod.DebugFrame{
            .{ .name = @constCast("first"), .url = @constCast("one.js"), .line = 3, .column = 4 },
            .{ .name = @constCast("second"), .url = @constCast("two.js"), .line = 5, .column = 6 },
        };
        const frames = cloneFrames(&raw) orelse return error.OutOfMemory;
        defer freeFrames(frames);

        try std.testing.expect(frames[0].storage.len != 0);
        try std.testing.expectEqual(@as(usize, 0), frames[1].storage.len);
        try std.testing.expectEqualStrings("first", frames[0].name);
        try std.testing.expectEqualStrings("two.js", frames[1].url);
    }
};

comptime {
    _ = InspectorEnabledTests2;
}
