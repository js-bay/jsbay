pub fn Module(comptime Host: type) type {
    // `Runtime.getHeapUsage` and `HeapProfiler.takeHeapSnapshot`.
    //
    // Both sample on the JS thread. The snapshot walks live QuickJS objects and emits one DevTools node per object. ArrayBuffer nodes use the buffer's byte length as `self_size`.

    return struct {
        const std = @import("std");
        const build_options = Host.build_options;
        const backend = Host.backend;
        const engine = Host.engine;
        const runtime_control = Host.runtime_control;
        const transport_mod = @import("transport.zig");
        const json_writer = @import("json_writer.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);

        const InspectorState = state_mod.InspectorState;
        const max_nodes = 2048;
        const max_edges = max_nodes * 8;
        const max_edge_label_bytes = 16 * 1024;
        const max_total_edge_label_bytes = 1024 * 1024;

        const Job = struct {
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            snapshot: bool,

            fn run(ctx: ?*anyopaque) void {
                const job: *Job = @ptrCast(@alignCast(ctx.?));
                defer job.state.allocator.destroy(job);
                const usage = runtime_control.getMemoryUsage(job.state.instance_id) orelse runtime_control.MemoryUsage{};
                if (job.snapshot) {
                    sendSnapshot(job, usage);
                } else {
                    if (comptime backend.active_backend == .jsc) {
                        json_writer.sendError(job.state, job.session_id, job.request_id, -32601, "Heap usage statistics are unsupported by this backend");
                        return;
                    }
                    const used = if (usage.memory_used_size != 0) usage.memory_used_size else usage.malloc_size;
                    const total = @max(usage.malloc_size, used);
                    json_writer.sendHeapUsage(job.state, job.session_id, job.request_id, used, total);
                }
            }

            fn cancel(ctx: ?*anyopaque) void {
                const job: *Job = @ptrCast(@alignCast(ctx.?));
                job.state.allocator.destroy(job);
            }
        };

        pub fn scheduleUsage(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64) void {
            schedule(state, session_id, request_id, false);
        }

        pub fn scheduleSnapshot(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64) void {
            schedule(state, session_id, request_id, true);
        }

        fn schedule(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64, snapshot: bool) void {
            const job = state.allocator.create(Job) catch {
                json_writer.sendEmptyResult(state, session_id, request_id);
                return;
            };
            job.* = .{
                .state = state,
                .session_id = session_id,
                .request_id = request_id,
                .snapshot = snapshot,
            };
            if (!state_mod.postInspectorTask(state, .{ .ctx = job, .run = Job.run, .cancel = Job.cancel })) {
                state.allocator.destroy(job);
                json_writer.sendEmptyResult(state, session_id, request_id);
            }
        }

        const Obj = struct {
            ptr: ?*const anyopaque,
            name: []u8,
            size: u64,
        };

        const EdgeKind = enum { property, element, prototype, internal };

        const Edge = struct {
            from: usize,
            to: usize,
            kind: EdgeKind,
            name: ?[]u8,
            index: u32,
        };

        const Graph = struct {
            objects: std.ArrayList(Obj) = .empty,
            edges: std.ArrayList(Edge) = .empty,
            indices: std.AutoHashMapUnmanaged(usize, usize) = .empty,
            total_nodes: u64 = 0,
            omitted_nodes: u64 = 0,
            omitted_edges: u64 = 0,
            omitted_edge_labels: u64 = 0,
            edge_label_bytes: usize = 0,

            fn deinit(self: *Graph) void {
                for (self.objects.items) |obj| std.heap.c_allocator.free(obj.name);
                self.objects.deinit(std.heap.c_allocator);
                for (self.edges.items) |edge| {
                    if (edge.name) |name| std.heap.c_allocator.free(name);
                }
                self.edges.deinit(std.heap.c_allocator);
                self.indices.deinit(std.heap.c_allocator);
            }

            fn indexOf(self: *const Graph, ptr: ?*const anyopaque) ?usize {
                const raw = ptr orelse return null;
                return self.indices.get(@intFromPtr(raw));
            }

            fn truncated(self: *const Graph) bool {
                return self.omitted_nodes != 0 or self.omitted_edges != 0;
            }
        };

        fn sendSnapshot(job: *Job, usage: runtime_control.MemoryUsage) void {
            if (comptime !build_options.heap_snapshot) {
                _ = usage;
                json_writer.sendError(job.state, job.session_id, job.request_id, -32601, "Heap snapshots are unsupported because this build disables them");
            } else if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                sendObjectSnapshot(job);
            } else {
                _ = usage;
                json_writer.sendError(job.state, job.session_id, job.request_id, -32601, "Heap snapshots are unsupported by this backend");
            }
        }

        fn sendObjectSnapshot(job: *Job) void {
            sendObjectSnapshotChecked(job) catch {
                json_writer.sendError(job.state, job.session_id, job.request_id, -32000, "Unable to encode heap snapshot");
            };
        }

        fn sendObjectSnapshotChecked(job: *Job) !void {
            var graph: Graph = .{};
            defer graph.deinit();
            const ctx = engine.getContext(job.state.instance_id) orelse return error.InstanceUnavailable;
            const qjs = Host.backend.ActiveEngineModule.c_api.qjs;
            qjs.JS_WalkHeapGraph(qjs.JS_GetRuntime(ctx), visitGraphNode, visitGraphEdge, @ptrCast(&graph));

            var aw: std.Io.Writer.Allocating = .init(job.state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            const count = graph.objects.items.len + 1;
            const total_edges = graph.objects.items.len + graph.edges.items.len;
            try w.writeAll("{\"snapshot\":{\"meta\":{\"node_fields\":[\"type\",\"name\",\"id\",\"self_size\",\"edge_count\",\"trace_node_id\",\"detachedness\"],\"node_types\":[[\"hidden\",\"array\",\"string\",\"object\",\"code\",\"closure\",\"regexp\",\"number\",\"native\",\"synthetic\",\"concatenated string\",\"sliced string\",\"symbol\",\"bigint\"],\"string\",\"number\",\"number\",\"number\",\"number\",\"number\"],\"edge_fields\":[\"type\",\"name_or_index\",\"to_node\"],\"edge_types\":[[\"context\",\"element\",\"property\",\"internal\",\"hidden\",\"shortcut\",\"weak\"],\"string_or_number\",\"node\"]},");
            try w.print("\"node_count\":{d},\"edge_count\":{d},\"trace_function_count\":0}},\"nodes\":[9,1,1,0,{d},0,0", .{ count, total_edges, graph.objects.items.len });
            var strings: std.ArrayList([]const u8) = .empty;
            defer {
                if (strings.items.len > 2) for (strings.items[2..]) |s| std.heap.c_allocator.free(s);
                strings.deinit(std.heap.c_allocator);
            }
            try strings.append(std.heap.c_allocator, "");
            try strings.append(std.heap.c_allocator, "root");
            for (graph.objects.items, 0..) |obj, i| {
                const name_index = stringIndex(&strings, obj.name) orelse return error.OutOfMemory;
                var outgoing: usize = 0;
                for (graph.edges.items) |edge| {
                    if (edge.from == i) outgoing += 1;
                }
                try w.print(",3,{d},{d},{d},{d},0,0", .{ name_index, i + 2, obj.size, outgoing });
            }
            try w.writeAll("],\"edges\":[");
            var emitted: usize = 0;
            for (graph.objects.items, 0..) |_, i| {
                if (emitted != 0) try w.writeByte(',');
                try w.print("3,0,{d}", .{(i + 1) * 7});
                emitted += 1;
            }
            for (graph.edges.items) |edge| {
                if (emitted != 0) try w.writeByte(',');
                const label = if (edge.kind == .element) @as(usize, edge.index) else stringIndex(&strings, edge.name orelse "") orelse return error.OutOfMemory;
                try w.print("{d},{d},{d}", .{ edgeType(edge.kind), label, (edge.to + 1) * 7 });
                emitted += 1;
            }
            try w.writeAll("],\"strings\":[");
            for (strings.items, 0..) |s, i| {
                if (i != 0) try w.writeByte(',');
                try json_writer.writeJsonString(w, s);
            }
            try w.writeAll("],\"trace_function_infos\":[],\"trace_tree\":[],\"samples\":[],\"locations\":[]}");
            if (!sendChunk(job, aw.written())) return error.OutOfMemory;
            try sendSnapshotResult(job, &graph);
        }

        fn stringIndex(strings: *std.ArrayList([]const u8), name: []const u8) ?usize {
            for (strings.items, 0..) |s, i| {
                if (std.mem.eql(u8, s, name)) return i;
            }
            const copy = std.heap.c_allocator.dupe(u8, name) catch return null;
            strings.append(std.heap.c_allocator, copy) catch {
                std.heap.c_allocator.free(copy);
                return null;
            };
            return strings.items.len - 1;
        }

        fn visitGraphNode(opaque_ptr: ?*anyopaque, ptr: ?*const anyopaque, name: [*c]const u8, name_len: usize, class_id: c_int, size: u64) callconv(.c) void {
            _ = class_id;
            const graph: *Graph = @ptrCast(@alignCast(opaque_ptr orelse return));
            graph.total_nodes += 1;
            if (graph.objects.items.len >= max_nodes) {
                graph.omitted_nodes += 1;
                return;
            }
            const raw = name orelse {
                graph.omitted_nodes += 1;
                return;
            };
            const copy = std.heap.c_allocator.dupe(u8, raw[0..name_len]) catch {
                graph.omitted_nodes += 1;
                return;
            };
            const object_ptr = ptr orelse {
                std.heap.c_allocator.free(copy);
                graph.omitted_nodes += 1;
                return;
            };
            graph.objects.append(std.heap.c_allocator, .{ .ptr = ptr, .name = copy, .size = size }) catch {
                std.heap.c_allocator.free(copy);
                graph.omitted_nodes += 1;
                return;
            };
            graph.indices.put(std.heap.c_allocator, @intFromPtr(object_ptr), graph.objects.items.len - 1) catch {
                const obj = graph.objects.pop().?;
                std.heap.c_allocator.free(obj.name);
                graph.omitted_nodes += 1;
            };
        }

        fn visitGraphEdge(opaque_ptr: ?*anyopaque, from: ?*const anyopaque, to: ?*const anyopaque, kind: c_int, name: [*c]const u8, name_len: usize, index: u32) callconv(.c) void {
            const graph: *Graph = @ptrCast(@alignCast(opaque_ptr orelse return));
            const from_index = graph.indexOf(from) orelse return;
            const to_index = graph.indexOf(to) orelse return;
            if (graph.edges.items.len >= max_edges) {
                graph.omitted_edges += 1;
                return;
            }
            const edge_kind: EdgeKind = switch (kind) {
                1 => .property,
                2 => .element,
                3 => .prototype,
                else => .internal,
            };
            var copy: ?[]u8 = null;
            if (edge_kind != .element) {
                if (name) |raw| {
                    if (name_len <= max_edge_label_bytes and
                        name_len <= max_total_edge_label_bytes -| graph.edge_label_bytes)
                    {
                        copy = std.heap.c_allocator.dupe(u8, raw[0..name_len]) catch {
                            graph.omitted_edges += 1;
                            return;
                        };
                        graph.edge_label_bytes += name_len;
                    } else {
                        graph.omitted_edge_labels += 1;
                    }
                } else {
                    // Symbol keys lack a lossless CDP spelling in the native walker.
                    graph.omitted_edge_labels += 1;
                }
            }
            graph.edges.append(std.heap.c_allocator, .{ .from = from_index, .to = to_index, .kind = edge_kind, .name = copy, .index = index }) catch {
                if (copy) |label| std.heap.c_allocator.free(label);
                graph.omitted_edges += 1;
            };
        }

        fn edgeType(kind: EdgeKind) u8 {
            return switch (kind) {
                .element => 1,
                .property => 2,
                .internal, .prototype => 3,
            };
        }

        fn sendSnapshotResult(job: *Job, graph: *const Graph) !void {
            var aw: std.Io.Writer.Allocating = .init(job.state.allocator);
            defer aw.deinit();
            const omitted_nodes = graph.omitted_nodes;
            try aw.writer.print("{{\"id\":{d},\"result\":{{\"jsbaySnapshot\":{{\"complete\":false,\"truncated\":{},\"unsupported\":false,\"omittedNodes\":{d},\"omittedEdgeLabels\":{d},\"edgeCoverage\":[\"properties\",\"elements\",\"prototype\",\"cycles\"],\"propertyNamePrecision\":\"{s}\",\"rootCoverage\":\"synthetic-root-all-nodes\",\"retainedSizeSupported\":false}}}}}}", .{ job.request_id, graph.truncated(), omitted_nodes, graph.omitted_edge_labels, if (graph.omitted_edge_labels == 0) "complete" else "partial" });
            json_writer.sendJson(job.state, job.session_id, aw.written());
        }

        fn sendChunk(job: *Job, payload: []const u8) bool {
            if (Host.test_faults.take(job.state.instance_id, .heap_snapshot_chunk)) return false;
            var chunk: std.Io.Writer.Allocating = .init(job.state.allocator);
            defer chunk.deinit();
            const cw = &chunk.writer;
            cw.writeAll("{\"method\":\"HeapProfiler.addHeapSnapshotChunk\",\"params\":{\"chunk\":") catch return false;
            json_writer.writeJsonString(cw, payload) catch return false;
            cw.writeAll("}}") catch return false;
            json_writer.sendJson(job.state, job.session_id, chunk.written());
            return true;
        }
    };
}
