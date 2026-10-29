pub fn Module(comptime Host: type) type {
    // CDP `Performance` domain backed only by measurements this runtime can make.
    //
    // `Timestamp` is a process-monotonic timeTicks value in seconds. QuickJS exposes heap accounting through `JS_ComputeMemoryUsage`; JSC's public C API does not, so a JSC response deliberately contains only Timestamp. We do not report duration metrics because there is no low-cost, cross-backend execution accounting source for them.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const io = Host.io;
        const runtime_control = Host.runtime_control;
        const transport_mod = @import("transport.zig");
        const json_writer = @import("json_writer.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);

        const InspectorState = state_mod.InspectorState;
        const TimeDomain = state_mod.PerformanceTimeDomain;

        const Job = struct {
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,

            fn run(ctx: ?*anyopaque) void {
                const job: *Job = @ptrCast(@alignCast(ctx.?));
                defer job.state.allocator.destroy(job);
                const session = state_mod.sessionPerformance(job.state, job.session_id) orelse {
                    json_writer.sendError(job.state, job.session_id, job.request_id, -32000, "Inspector session is no longer active");
                    return;
                };
                if (!session.enabled) {
                    sendMetrics(job, null);
                    return;
                }
                // Reject unsupported threadTicks in restored session state. Normal command handling rejects threadTicks before it is committed to a session.
                if (session.time_domain == .thread_ticks) {
                    json_writer.sendError(job.state, job.session_id, job.request_id, -32000, "Performance threadTicks is unsupported by this runtime");
                    return;
                }
                const usage = if (comptime backend.isQuickJsApiBackend(backend.active_backend)) runtime_control.getMemoryUsage(job.state.instance_id) else null;
                sendMetrics(job, usage);
            }

            fn cancel(ctx: ?*anyopaque) void {
                const job: *Job = @ptrCast(@alignCast(ctx.?));
                job.state.allocator.destroy(job);
            }
        };

        pub fn handle(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            method: []const u8,
            root: std.json.Value,
        ) void {
            if (std.mem.eql(u8, method, "Performance.enable")) {
                const time_domain = parseOptionalTimeDomain(root);
                if (hasTimeDomain(root) and time_domain == null) {
                    json_writer.sendInvalidParams(state, session_id, request_id, "timeDomain must be timeTicks or threadTicks");
                    return;
                }
                if (time_domain) |domain| {
                    if (domain == .thread_ticks) {
                        json_writer.sendError(state, session_id, request_id, -32000, "Performance threadTicks is unsupported by this runtime");
                        return;
                    }
                }
                switch (state_mod.configureSessionPerformance(state, session_id, true, time_domain)) {
                    .ok => json_writer.sendEmptyResult(state, session_id, request_id),
                    .active_time_domain_conflict => json_writer.sendError(state, session_id, request_id, -32000, "Cannot change time domain while Performance is enabled"),
                    .unknown_session => json_writer.sendError(state, session_id, request_id, -32000, "Inspector session is no longer active"),
                }
                return;
            }
            if (std.mem.eql(u8, method, "Performance.disable")) {
                switch (state_mod.configureSessionPerformance(state, session_id, false, null)) {
                    .ok => json_writer.sendEmptyResult(state, session_id, request_id),
                    .active_time_domain_conflict => unreachable,
                    .unknown_session => json_writer.sendError(state, session_id, request_id, -32000, "Inspector session is no longer active"),
                }
                return;
            }
            if (std.mem.eql(u8, method, "Performance.setTimeDomain")) {
                const time_domain = parseRequiredTimeDomain(root) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "timeDomain must be timeTicks or threadTicks");
                    return;
                };
                if (time_domain == .thread_ticks) {
                    json_writer.sendError(state, session_id, request_id, -32000, "Performance threadTicks is unsupported by this runtime");
                    return;
                }
                switch (state_mod.setSessionPerformanceTimeDomain(state, session_id, time_domain)) {
                    .ok => json_writer.sendEmptyResult(state, session_id, request_id),
                    .enabled => json_writer.sendError(state, session_id, request_id, -32000, "Cannot change time domain while Performance is enabled"),
                    .unknown_session => json_writer.sendError(state, session_id, request_id, -32000, "Inspector session is no longer active"),
                }
                return;
            }
            if (std.mem.eql(u8, method, "Performance.getMetrics")) {
                scheduleMetrics(state, session_id, request_id);
                return;
            }
            json_writer.sendMethodNotFound(state, session_id, request_id, method);
        }

        fn scheduleMetrics(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64) void {
            const job = state.allocator.create(Job) catch {
                json_writer.sendError(state, session_id, request_id, -32000, "Unable to schedule Performance metrics");
                return;
            };
            job.* = .{ .state = state, .session_id = session_id, .request_id = request_id };
            if (!state_mod.postInspectorTask(state, .{ .ctx = job, .run = Job.run, .cancel = Job.cancel })) {
                state.allocator.destroy(job);
                json_writer.sendError(state, session_id, request_id, -32000, "Unable to schedule Performance metrics");
            }
        }

        fn sendMetrics(job: *Job, usage: ?runtime_control.MemoryUsage) void {
            var aw: std.Io.Writer.Allocating = .init(job.state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"metrics\":[", .{job.request_id}) catch return;
            const now = monotonicMilliseconds();
            if (usage) |memory| {
                const used = if (memory.memory_used_size != 0) memory.memory_used_size else memory.malloc_size;
                const total = @max(memory.malloc_size, used);
                w.print("{{\"name\":\"Timestamp\",\"value\":{d}.{d:0>3}}},{{\"name\":\"JSHeapUsedSize\",\"value\":{d}}},{{\"name\":\"JSHeapTotalSize\",\"value\":{d}}}", .{ now / 1000, now % 1000, used, total }) catch return;
            } else if (state_mod.sessionPerformance(job.state, job.session_id)) |session| {
                if (session.enabled) w.print("{{\"name\":\"Timestamp\",\"value\":{d}.{d:0>3}}}", .{ now / 1000, now % 1000 }) catch return;
            }
            w.writeAll("]}}") catch return;
            json_writer.sendJson(job.state, job.session_id, aw.written());
        }

        fn monotonicMilliseconds() u64 {
            const ms = io.monotonicMilliseconds();
            return if (ms > 0) @intCast(ms) else 0;
        }

        fn params(root: std.json.Value) ?std.json.ObjectMap {
            if (root != .object) return null;
            const value = root.object.get("params") orelse return null;
            if (value != .object) return null;
            return value.object;
        }

        fn hasTimeDomain(root: std.json.Value) bool {
            return if (params(root)) |object| object.contains("timeDomain") else false;
        }

        fn parseOptionalTimeDomain(root: std.json.Value) ?TimeDomain {
            const object = params(root) orelse return null;
            const value = object.get("timeDomain") orelse return null;
            if (value != .string) return null;
            if (std.mem.eql(u8, value.string, "timeTicks")) return .time_ticks;
            if (std.mem.eql(u8, value.string, "threadTicks")) return .thread_ticks;
            return null;
        }

        fn parseRequiredTimeDomain(root: std.json.Value) ?TimeDomain {
            return parseOptionalTimeDomain(root);
        }
    };
}
