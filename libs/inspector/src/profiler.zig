pub fn Module(comptime Host: type) type {
    // CPU profiles sampled from the backend interrupt.
    //
    // QuickJS checks the interrupt every few thousand bytecodes, so a busy function shows up in `Profiler.stop`. `Profiler.setSamplingInterval` stores a positive microsecond interval for the next profile.
    //
    // `begin` reserves a fixed sample ring and one string buffer. `onSample` only writes that memory. A full ring overwrites the oldest sample. A sample that does not fit in its byte slice is dropped. The callback does not call the allocator and does not enter JS while the profiler mutex is held.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const debugger_mod = Host.debugger;
        const runtime_control = Host.runtime_control;
        const sample_hook = Host.sample_hook;
        const sync = Host.sync;
        const transport_mod = @import("transport.zig");
        const json_writer = @import("json_writer.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);

        const InspectorState = state_mod.InspectorState;

        // Default samples kept per instance. Older samples are overwritten after this.
        pub const sample_capacity: usize = 1024;
        pub const min_sample_capacity: usize = 16;
        pub const max_sample_capacity: usize = 4096;
        // Frames stored for one sample, innermost first.
        pub const frame_capacity: usize = 8;
        const name_capacity: usize = 64;
        const url_capacity: usize = 128;
        const bytes_per_frame: usize = name_capacity + url_capacity;
        const bytes_per_sample: usize = frame_capacity * bytes_per_frame;
        // One byte buffer for every reserved frame's name and url.
        pub const string_buffer_len: usize = sample_capacity * bytes_per_sample;

        const Frame = struct {
            name: []const u8,
            url: []const u8,
            line: i32,
            column: i32,
        };

        const StoredFrame = struct {
            name_off: u32,
            name_len: u16,
            url_off: u32,
            url_len: u16,
            line: i32,
            column: i32,
        };

        const StoredSample = struct {
            at_us: u64,
            frame_count: u16,
            frames: [frame_capacity]StoredFrame,
        };

        const Slot = struct {
            active: bool = false,
            /// CDP's configured interval for the next `Profiler.start`.
            configured_interval_us: u64 = 1000,
            interval_us: u64 = 1000,
            last_us: u64 = 0,
            start_us: u64 = 0,
            samples: []StoredSample = &.{},
            strings: []u8 = &.{},
            capacity: usize = 0,
            /// Next ring index to write. When the ring is full this is the oldest.
            next: usize = 0,
            filled: usize = 0,
            total_samples: u64 = 0,
            dropped_samples: u64 = 0,
            truncated_stacks: u64 = 0,
            overwritten_samples: u64 = 0,
            session_start_us: u64 = 0,
        };

        const Stolen = struct {
            samples: []StoredSample = &.{},
            strings: []u8 = &.{},
            next: usize = 0,
            filled: usize = 0,
            start_us: u64 = 0,
            capacity: usize = 0,
            total_samples: u64 = 0,
            dropped_samples: u64 = 0,
            truncated_stacks: u64 = 0,
            overwritten_samples: u64 = 0,
        };

        var mutex: sync.Mutex = .{};
        var slots: ?std.AutoHashMap(i32, *Slot) = null;
        threadlocal var in_sample: bool = false;

        const Task = struct {
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            start: bool,
            max_samples: usize,

            fn run(ctx: ?*anyopaque) void {
                const task: *Task = @ptrCast(@alignCast(ctx.?));
                defer task.state.allocator.destroy(task);
                if (task.start) {
                    if (!runtime_control.init(task.state.instance_id) or !begin(task.state.instance_id, task.max_samples)) {
                        json_writer.sendError(task.state, task.session_id, task.request_id, -32000, "Unable to allocate profiler buffers");
                    } else {
                        json_writer.sendEmptyResult(task.state, task.session_id, task.request_id);
                    }
                } else {
                    sendProfile(task);
                }
            }

            fn cancel(ctx: ?*anyopaque) void {
                const task: *Task = @ptrCast(@alignCast(ctx.?));
                task.state.allocator.destroy(task);
            }
        };

        pub fn handle(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            method: []const u8,
            root: std.json.Value,
        ) void {
            if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) {
                json_writer.sendError(state, session_id, request_id, -32601, "CPU profiling is unsupported by this backend");
                return;
            }
            if (std.mem.eql(u8, method, "Profiler.enable")) {
                json_writer.sendEmptyResult(state, session_id, request_id);
                return;
            }
            if (std.mem.eql(u8, method, "Profiler.disable")) {
                end(state.instance_id);
                json_writer.sendEmptyResult(state, session_id, request_id);
                return;
            }
            if (std.mem.eql(u8, method, "Profiler.start")) {
                const params = objectParams(root);
                const max_samples = maxSamples(params) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "maxSamples must be an integer from 16 to 4096");
                    return;
                };
                schedule(state, session_id, request_id, true, max_samples);
                return;
            }
            if (std.mem.eql(u8, method, "Profiler.setSamplingInterval")) {
                // Match V8's state error precedence: an active profile rejects this command even when the requested value is otherwise malformed.
                if (isActive(state.instance_id)) {
                    json_writer.sendError(state, session_id, request_id, -32000, "Cannot change sampling interval when profiling.");
                    return;
                }
                const interval = standardSamplingInterval(objectParams(root)) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "interval must be a positive integer number of microseconds");
                    return;
                };
                switch (configureInterval(state.instance_id, interval)) {
                    .ok => json_writer.sendEmptyResult(state, session_id, request_id),
                    .active => json_writer.sendError(state, session_id, request_id, -32000, "Cannot change sampling interval when profiling."),
                    .allocation_failed => json_writer.sendError(state, session_id, request_id, -32000, "Unable to configure profiler sampling interval"),
                }
                return;
            }
            if (std.mem.eql(u8, method, "Profiler.stop")) {
                schedule(state, session_id, request_id, false, sample_capacity);
                return;
            }
            json_writer.sendMethodNotFound(state, session_id, request_id, method);
        }

        fn schedule(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            start: bool,
            max_samples: usize,
        ) void {
            const task = state.allocator.create(Task) catch {
                json_writer.sendEmptyResult(state, session_id, request_id);
                return;
            };
            task.* = .{
                .state = state,
                .session_id = session_id,
                .request_id = request_id,
                .start = start,
                .max_samples = max_samples,
            };
            if (!state_mod.postInspectorTask(state, .{ .ctx = task, .run = Task.run, .cancel = Task.cancel })) {
                state.allocator.destroy(task);
                json_writer.sendEmptyResult(state, session_id, request_id);
            }
        }

        fn begin(instance_id: i32, max_samples: usize) bool {
            mutex.lock();
            defer mutex.unlock();
            const slot = slotPtr(instance_id) orelse return false;
            if (!ensureBuffers(slot, max_samples, instance_id)) return false;
            slot.active = true;
            slot.interval_us = slot.configured_interval_us;
            slot.last_us = 0;
            slot.start_us = nowUs();
            slot.session_start_us = slot.start_us;
            slot.next = 0;
            slot.filled = 0;
            slot.total_samples = 0;
            slot.dropped_samples = 0;
            slot.truncated_stacks = 0;
            slot.overwritten_samples = 0;
            sample_hook.store(onSample);
            return true;
        }

        fn isActive(instance_id: i32) bool {
            mutex.lock();
            defer mutex.unlock();
            return if (existingSlot(instance_id)) |slot| slot.active else false;
        }

        const ConfigureIntervalResult = enum { ok, active, allocation_failed };

        fn configureInterval(instance_id: i32, interval_us: u64) ConfigureIntervalResult {
            mutex.lock();
            defer mutex.unlock();
            const slot = slotPtr(instance_id) orelse return .allocation_failed;
            if (slot.active) return .active;
            slot.configured_interval_us = interval_us;
            return .ok;
        }

        fn end(instance_id: i32) void {
            mutex.lock();
            defer mutex.unlock();
            const slot = existingSlot(instance_id) orelse return;
            slot.active = false;
            slot.next = 0;
            slot.filled = 0;
            clearHookIfIdle();
        }

        // Stop sampling for an inspector that is being torn down.
        pub fn stopInstance(instance_id: i32) void {
            mutex.lock();
            defer mutex.unlock();
            if (slots) |*map| {
                if (map.fetchRemove(instance_id)) |entry| {
                    const slot = entry.value;
                    slot.active = false;
                    if (slot.samples.len != 0) std.heap.c_allocator.free(slot.samples);
                    if (slot.strings.len != 0) std.heap.c_allocator.free(slot.strings);
                    std.heap.c_allocator.destroy(slot);
                }
            }
            clearHookIfIdle();
        }

        fn clearHookIfIdle() void {
            if (slots) |map| {
                var it = map.valueIterator();
                while (it.next()) |slot| {
                    if (slot.*.active) return;
                }
            }
            sample_hook.store(null);
        }

        fn onSample(instance_id: i32) void {
            if (in_sample) return;
            in_sample = true;
            defer in_sample = false;

            mutex.lock();
            const slot = existingSlot(instance_id) orelse {
                mutex.unlock();
                return;
            };
            if (!slot.active or !buffersReady(slot)) {
                mutex.unlock();
                return;
            }
            const interval = slot.interval_us;
            const previous = slot.last_us;
            mutex.unlock();

            const now = nowUs();
            if (interval != 0 and previous != 0 and now - previous < interval) return;

            // Stack capture enters the engine. Do it without the profiler mutex.
            var names: [frame_capacity][name_capacity]u8 = undefined;
            var urls: [frame_capacity][url_capacity]u8 = undefined;
            var bufs: [frame_capacity]debugger_mod.StackFrameBuf = undefined;
            for (&bufs, 0..) |*buf, i| {
                buf.* = .{ .name = &names[i], .url = &urls[i] };
            }
            const n = debugger_mod.writeDebugStack(instance_id, &bufs);

            mutex.lock();
            defer mutex.unlock();
            const live = existingSlot(instance_id) orelse return;
            if (!live.active or !buffersReady(live)) return;
            if (n == frame_capacity) live.truncated_stacks += 1;
            if (!storeSample(live, now, bufs[0..n])) {
                live.dropped_samples += 1;
                return;
            }
            live.last_us = now;
        }

        fn sendProfile(task: *Task) void {
            mutex.lock();
            var stolen: Stolen = .{};
            if (existingSlot(task.state.instance_id)) |live| {
                live.active = false;
                stolen = .{
                    .samples = live.samples,
                    .strings = live.strings,
                    .next = live.next,
                    .filled = live.filled,
                    .start_us = live.start_us,
                    .capacity = live.capacity,
                    .total_samples = live.total_samples,
                    .dropped_samples = live.dropped_samples,
                    .truncated_stacks = live.truncated_stacks,
                    .overwritten_samples = live.overwritten_samples,
                };
                live.samples = &.{};
                live.strings = &.{};
                live.next = 0;
                live.filled = 0;
                live.capacity = 0;
            }
            clearHookIfIdle();
            mutex.unlock();
            defer if (stolen.samples.len != 0) std.heap.c_allocator.free(stolen.samples);
            defer if (stolen.strings.len != 0) std.heap.c_allocator.free(stolen.strings);

            var nodes: std.ArrayList(Node) = .empty;
            defer {
                for (nodes.items) |node| {
                    if (node.name.len != 0) std.heap.c_allocator.free(node.name);
                    if (node.url.len != 0) std.heap.c_allocator.free(node.url);
                    var children = node.children;
                    children.deinit(std.heap.c_allocator);
                }
                nodes.deinit(std.heap.c_allocator);
            }
            nodes.append(std.heap.c_allocator, .{
                .id = 1,
                .name = std.heap.c_allocator.dupe(u8, "(root)") catch &.{},
                .url = &.{},
                .line = 0,
                .column = 0,
            }) catch return;

            var sample_ids: std.ArrayList(i32) = .empty;
            defer sample_ids.deinit(std.heap.c_allocator);
            var deltas: std.ArrayList(u64) = .empty;
            defer deltas.deinit(std.heap.c_allocator);
            const session_end_us = nowUs();
            const retained_start_us = if (stolen.filled == 0) stolen.start_us else stolen.samples[ringIndex(stolen.filled, stolen.next, stolen.capacity, 0)].at_us;
            const retained_end_us = if (stolen.filled == 0) retained_start_us else stolen.samples[ringIndex(stolen.filled, stolen.next, stolen.capacity, stolen.filled - 1)].at_us;
            var previous = retained_start_us;
            var ordinal: usize = 0;
            while (ordinal < stolen.filled) : (ordinal += 1) {
                const index = ringIndex(stolen.filled, stolen.next, stolen.capacity, ordinal);
                if (index >= stolen.samples.len) continue;
                const sample = stolen.samples[index];
                var parent: usize = 0;
                var i: usize = sample.frame_count;
                while (i > 0) {
                    i -= 1;
                    const raw = sample.frames[i];
                    if (raw.name_off + raw.name_len > stolen.strings.len or raw.url_off + raw.url_len > stolen.strings.len) continue;
                    parent = ensureChild(&nodes, parent, .{
                        .name = stolen.strings[raw.name_off..][0..raw.name_len],
                        .url = stolen.strings[raw.url_off..][0..raw.url_len],
                        .line = raw.line,
                        .column = raw.column,
                    }) orelse parent;
                }
                if (parent < nodes.items.len) nodes.items[parent].hit += 1;
                const id = if (parent < nodes.items.len) nodes.items[parent].id else 1;
                sample_ids.append(std.heap.c_allocator, id) catch {};
                const at = sample.at_us;
                const dt = if (at > previous) at - previous else 0;
                deltas.append(std.heap.c_allocator, dt) catch {};
                previous = at;
            }

            var aw: std.Io.Writer.Allocating = .init(task.state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"profile\":{{\"nodes\":[", .{task.request_id}) catch return;
            for (nodes.items, 0..) |node, index| {
                if (index != 0) w.writeByte(',') catch return;
                w.writeAll("{\"id\":") catch return;
                w.print("{d}", .{node.id}) catch return;
                w.writeAll(",\"callFrame\":{\"functionName\":") catch return;
                json_writer.writeJsonString(w, node.name) catch return;
                w.writeAll(",\"scriptId\":\"0\",\"url\":") catch return;
                json_writer.writeJsonString(w, node.url) catch return;
                w.print(",\"lineNumber\":{d},\"columnNumber\":{d}", .{ node.line, node.column }) catch return;
                w.print("}},\"hitCount\":{d},\"children\":[", .{node.hit}) catch return;
                for (node.children.items, 0..) |child, child_index| {
                    if (child_index != 0) w.writeByte(',') catch return;
                    if (child >= nodes.items.len) continue;
                    w.print("{d}", .{nodes.items[child].id}) catch return;
                }
                w.writeAll("]}") catch return;
            }
            w.print("],\"startTime\":{d},\"endTime\":{d},\"samples\":[", .{ retained_start_us, retained_end_us }) catch return;
            for (sample_ids.items, 0..) |id, index| {
                if (index != 0) w.writeByte(',') catch return;
                w.print("{d}", .{id}) catch return;
            }
            w.writeAll("],\"timeDeltas\":[") catch return;
            for (deltas.items, 0..) |dt, index| {
                if (index != 0) w.writeByte(',') catch return;
                w.print("{d}", .{dt}) catch return;
            }
            w.print("],\"jsbaySampling\":{{\"clockResolutionUs\":1000,\"retainedSamples\":{d},\"droppedSamples\":{d},\"truncatedStacks\":{d},\"sessionStartTimeUs\":{d},\"sessionEndTimeUs\":{d},\"retainedStartTimeUs\":{d},\"retainedEndTimeUs\":{d},\"startTimeUs\":{d},\"endTimeUs\":{d},\"totalSamples\":{d},\"overwrittenSamples\":{d}", .{ stolen.filled, stolen.dropped_samples, stolen.truncated_stacks, stolen.start_us, session_end_us, retained_start_us, retained_end_us, stolen.start_us, session_end_us, stolen.total_samples, stolen.overwritten_samples }) catch return;
            w.writeAll("}}}}") catch return;
            json_writer.sendJson(task.state, task.session_id, aw.written());
        }

        fn ensureChild(nodes: *std.ArrayList(Node), parent: usize, frame: Frame) ?usize {
            if (parent >= nodes.items.len) return null;
            for (nodes.items[parent].children.items) |child| {
                if (child >= nodes.items.len) continue;
                const node = nodes.items[child];
                if (node.line == frame.line and std.mem.eql(u8, node.name, frame.name)) return child;
            }
            const id: i32 = @intCast(nodes.items.len + 1);
            const index = nodes.items.len;
            nodes.append(std.heap.c_allocator, .{
                .id = id,
                .name = std.heap.c_allocator.dupe(u8, frame.name) catch &.{},
                .url = std.heap.c_allocator.dupe(u8, frame.url) catch &.{},
                .line = frame.line,
                .column = frame.column,
            }) catch return null;
            nodes.items[parent].children.append(std.heap.c_allocator, index) catch return null;
            return index;
        }

        const Node = struct {
            id: i32,
            name: []u8,
            url: []u8,
            line: i32,
            column: i32,
            hit: u32 = 0,
            children: std.ArrayList(usize) = .empty,
        };

        fn ensureBuffers(slot: *Slot, capacity: usize, instance_id: i32) bool {
            if (buffersReady(slot) and slot.capacity == capacity) return true;
            if (Host.test_faults.take(instance_id, .profiler_samples)) return false;
            const samples = std.heap.c_allocator.alloc(StoredSample, capacity) catch return false;
            if (Host.test_faults.take(instance_id, .profiler_strings)) {
                std.heap.c_allocator.free(samples);
                return false;
            }
            const strings = std.heap.c_allocator.alloc(u8, capacity * bytes_per_sample) catch {
                std.heap.c_allocator.free(samples);
                return false;
            };
            if (slot.samples.len != 0) std.heap.c_allocator.free(slot.samples);
            if (slot.strings.len != 0) std.heap.c_allocator.free(slot.strings);
            slot.samples = samples;
            slot.strings = strings;
            slot.capacity = capacity;
            slot.next = 0;
            slot.filled = 0;
            return true;
        }

        fn buffersReady(slot: *const Slot) bool {
            return slot.capacity >= min_sample_capacity and slot.samples.len == slot.capacity and slot.strings.len == slot.capacity * bytes_per_sample;
        }

        // Writes one sample into the preallocated ring. Returns false when this sample's strings do not fit, leaving the ring unchanged.
        fn storeSample(slot: *Slot, at: u64, frames: []const debugger_mod.StackFrameBuf) bool {
            const index = slot.next;
            const base = index * bytes_per_sample;
            var bump: usize = 0;
            var stored = StoredSample{
                .at_us = at,
                .frame_count = 0,
                .frames = undefined,
            };
            for (frames) |frame| {
                if (stored.frame_count >= frame_capacity) break;
                const name_len = @min(frame.name_len, @min(frame.name.len, name_capacity));
                const url_len = @min(frame.url_len, @min(frame.url.len, url_capacity));
                if (bump + name_len + url_len > bytes_per_sample) break;
                const name_off: u32 = @intCast(base + bump);
                if (name_len != 0) @memcpy(slot.strings[name_off..][0..name_len], frame.name[0..name_len]);
                bump += name_len;
                const url_off: u32 = @intCast(base + bump);
                if (url_len != 0) @memcpy(slot.strings[url_off..][0..url_len], frame.url[0..url_len]);
                bump += url_len;
                stored.frames[stored.frame_count] = .{
                    .name_off = name_off,
                    .name_len = @intCast(name_len),
                    .url_off = url_off,
                    .url_len = @intCast(url_len),
                    .line = if (frame.line > 0) frame.line - 1 else 0,
                    .column = frame.column,
                };
                stored.frame_count += 1;
            }
            if (frames.len != 0 and stored.frame_count == 0) return false;
            slot.samples[index] = stored;
            slot.next = (slot.next + 1) % slot.capacity;
            if (slot.filled < slot.capacity) {
                slot.filled += 1;
            } else {
                slot.overwritten_samples += 1;
            }
            slot.total_samples += 1;
            return true;
        }

        fn ringIndex(filled: usize, next: usize, capacity: usize, ordinal: usize) usize {
            if (filled < capacity) return ordinal;
            return (next + ordinal) % capacity;
        }

        fn existingSlot(instance_id: i32) ?*Slot {
            const map = &(slots orelse return null);
            return map.get(instance_id);
        }

        fn slotPtr(instance_id: i32) ?*Slot {
            if (slots == null) slots = std.AutoHashMap(i32, *Slot).init(std.heap.c_allocator);
            const map = &slots.?;
            if (map.get(instance_id)) |slot| return slot;
            const slot = std.heap.c_allocator.create(Slot) catch return null;
            slot.* = .{};
            map.put(instance_id, slot) catch {
                std.heap.c_allocator.destroy(slot);
                return null;
            };
            return slot;
        }

        fn nowUs() u64 {
            const ms = Host.io.monotonicMilliseconds();
            if (ms <= 0) return 0;
            return @as(u64, @intCast(ms)) * 1000;
        }

        fn objectParams(root: std.json.Value) ?std.json.ObjectMap {
            if (root != .object) return null;
            const params = root.object.get("params") orelse return null;
            if (params != .object) return null;
            return params.object;
        }

        // CDP's `Profiler.setSamplingInterval` requires a positive integer measured in microseconds.
        fn standardSamplingInterval(params: ?std.json.ObjectMap) ?u64 {
            const object = params orelse return null;
            const value = object.get("interval") orelse return null;
            if (value != .integer or value.integer <= 0) return null;
            return @intCast(value.integer);
        }

        fn maxSamples(params: ?std.json.ObjectMap) ?usize {
            const object = params orelse return sample_capacity;
            const value = object.get("maxSamples") orelse return sample_capacity;
            if (value != .integer or value.integer < min_sample_capacity or value.integer > max_sample_capacity) return null;
            return @intCast(value.integer);
        }

        pub const TestCases = if (@import("builtin").is_test) struct {
            pub fn recordedSampleCount(instance_id: i32) u64 {
                mutex.lock();
                defer mutex.unlock();
                return if (existingSlot(instance_id)) |slot| slot.total_samples else 0;
            }

            pub fn profilerStopInstanceReleasesSlotAndBuffers() !void {
                const instance_id: i32 = 94_519;
                try std.testing.expect(begin(instance_id, sample_capacity));
                try std.testing.expect(existingSlot(instance_id) != null);
                stopInstance(instance_id);
                try std.testing.expect(existingSlot(instance_id) == null);
                try std.testing.expect(sample_hook.load() == null);
            }

            pub fn profilerClearsSampleHookAfterLastActiveInstanceStops() !void {
                const first_id: i32 = 94_517;
                const second_id: i32 = 94_518;
                try std.testing.expect(begin(first_id, sample_capacity));
                try std.testing.expect(begin(second_id, sample_capacity));
                defer {
                    end(first_id);
                    end(second_id);
                    sample_hook.store(null);
                }
                try std.testing.expect(sample_hook.load() != null);
                end(first_id);
                try std.testing.expect(sample_hook.load() != null);
                end(second_id);
                try std.testing.expect(sample_hook.load() == null);
            }

            pub fn profilerStartUsesConfiguredInterval() !void {
                const instance_id: i32 = 94_520;
                defer stopInstance(instance_id);
                try std.testing.expectEqual(ConfigureIntervalResult.ok, configureInterval(instance_id, 4321));
                try std.testing.expect(begin(instance_id, sample_capacity));
                const slot = existingSlot(instance_id) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(u64, 4321), slot.interval_us);
            }
        } else struct {};
    };
}
