pub fn Module(comptime Host: type) type {
    // CDP message parse + dispatch.
    //
    // Speaks JSON-RPC: parses `{"id":N,"method":"...","params":{...}}` from DevTools and routes each `method` to the appropriate domain handler. Cheap string compares are sufficient — the surface is small.
    //
    // Methods we implement live in `runtime.zig`. Methods that DevTools sends during its bring-up handshake but don't need behaviour (e.g. `Profiler.enable`) are answered with an empty `{}` so DevTools proceeds happily. `Debugger.*` breakpoints and stepping are handled in `debugger_cdp.zig` on the reader thread.
    //
    // Also exposes `transportEventHandler`, the callback handed to `transport.start`, which routes session lifecycle events to `state.addSession` / `state.removeSession` and message events here.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const build_options = Host.build_options;
        const dispatch = Host.dispatch;
        const transport_mod = @import("transport.zig");
        const json_writer = @import("json_writer.zig").Module(Host);
        const runtime_eval = @import("runtime_eval.zig").Module(Host);
        const runtime_objects = @import("runtime_objects.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);
        const console_cdp = @import("console.zig").Module(Host);
        const debugger_cdp = @import("debugger_cdp.zig").Module(Host);
        const await_promise = @import("await_promise.zig").Module(Host);

        const InspectorState = state_mod.InspectorState;

        // ---------------------------------------------------------------------------
        // Transport event handler
        // ---------------------------------------------------------------------------

        pub fn transportEventHandler(ctx: ?*anyopaque, event: transport_mod.Event) void {
            const state: *InspectorState = @ptrCast(@alignCast(ctx.?));
            // A host may synchronously call inspector.stop from sendText while handling this event. Hold a state lease and mark the callback as owner work so teardown waits for every use below to return.
            if (!state_mod.tryAcquireStateLease(state)) return;
            var owner_frame: dispatch.TaskOwnerFrame = undefined;
            dispatch.enterTaskOwnerFrame(&owner_frame, state.instance_id, state);
            defer {
                dispatch.leaveTaskOwnerFrame(&owner_frame);
                state_mod.releaseStateLease(state);
            }
            switch (event.kind) {
                .session_opened => if (!state_mod.addSession(state, event.session_id)) state.transport.closeSession(event.session_id),
                .session_closed => {
                    // The debugger owns session removal because it must turn the vanished session's async-depth request into an owner task. Await cleanup may still inspect its pending records afterwards.
                    debugger_cdp.sessionClosed(state, event.session_id);
                    await_promise.closeSession(state, event.session_id);
                },
                .message => if (!state_mod.isClosing(state)) handleMessage(state, event.session_id, event.payload),
            }
        }

        // ---------------------------------------------------------------------------
        // CDP message parse + dispatch
        // ---------------------------------------------------------------------------

        // Read request id + method + params string out of the raw JSON text.
        const ParsedRequest = struct {
            /// CDP request ids are signed integers. Messages without one are JSON-RPC notifications; this server has no notification-only CDP methods, so malformed ids and notifications are dropped before dispatch rather than manufacturing an id-zero reply.
            id: i64,
            method: []const u8, // borrowed slice into Parsed tree
            // Keep Parsed alive so method/params slices stay valid.
            parsed: std.json.Parsed(std.json.Value),

            fn deinit(self: *ParsedRequest) void {
                self.parsed.deinit();
            }
        };

        fn parseRequest(alloc: std.mem.Allocator, text: []const u8) ?ParsedRequest {
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return null;
            if (parsed.value != .object) {
                parsed.deinit();
                return null;
            }
            const obj = parsed.value.object;
            const method_val = obj.get("method") orelse {
                parsed.deinit();
                return null;
            };
            if (method_val != .string) {
                parsed.deinit();
                return null;
            }
            const id_val = obj.get("id") orelse {
                parsed.deinit();
                return null;
            };
            const id: i64 = switch (id_val) {
                .integer => |i| i,
                // Do not convert JSON floats here: a large finite exponent can trap during float-to-int conversion, and CDP declares this field as an integer rather than a generic JSON number.
                else => {
                    parsed.deinit();
                    return null;
                },
            };
            return .{
                .id = id,
                .method = method_val.string,
                .parsed = parsed,
            };
        }

        fn handleMessage(state: *InspectorState, session_id: transport_mod.SessionId, text: []const u8) void {
            const alloc = state.allocator;

            var req = parseRequest(alloc, text) orelse {
                // Unparseable — silently drop.
                return;
            };
            defer req.deinit();

            const id = req.id;
            const method = req.method;

            // Dispatch table — we do cheap string compares here; the surface is small.
            if (std.mem.eql(u8, method, "Schema.getDomains")) {
                sendSchemaDomains(state, session_id, id);
                return;
            }
            if (std.mem.eql(u8, method, "Runtime.enable")) {
                // Context first, then buffered console events. Enabling the session is paired with the replay inside enableRuntimeAndReplayConsole so a concurrent console call is delivered once.
                json_writer.sendEmptyResult(state, session_id, id);
                json_writer.sendExecutionContextCreated(state, session_id);
                console_cdp.enableRuntimeAndReplayConsole(state, session_id);
                return;
            }
            if (std.mem.eql(u8, method, "Runtime.discardConsoleEntries")) {
                console_cdp.handleDiscardConsoleEntries(state, session_id, id);
                return;
            }
            if (std.mem.eql(u8, method, "Runtime.disable")) {
                state_mod.setSessionRuntimeEnabled(state, session_id, false);
                json_writer.sendEmptyResult(state, session_id, id);
                return;
            }
            if (std.mem.eql(u8, method, "Runtime.evaluate")) {
                runtime_eval.handleEvaluate(state, session_id, id, req.parsed.value);
                return;
            }
            if (std.mem.eql(u8, method, "Runtime.getProperties")) {
                runtime_objects.handleGetProperties(state, session_id, id, req.parsed.value);
                return;
            }
            if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) {
                runtime_eval.handleCallFunctionOn(state, session_id, id, req.parsed.value);
                return;
            }
            if (std.mem.eql(u8, method, "Runtime.releaseObject")) {
                runtime_objects.handleReleaseObject(state, session_id, id, req.parsed.value);
                return;
            }
            if (std.mem.eql(u8, method, "Runtime.releaseObjectGroup")) {
                runtime_objects.handleReleaseObjectGroup(state, session_id, id, req.parsed.value);
                return;
            }
            if (std.mem.eql(u8, method, "Runtime.getIsolateId")) {
                json_writer.sendIsolateId(state, session_id, id);
                return;
            }
            if (std.mem.eql(u8, method, "Runtime.getHeapUsage")) {
                const heap = @import("heap.zig").Module(Host);
                heap.scheduleUsage(state, session_id, id);
                return;
            }
            if (std.mem.eql(u8, method, "Runtime.awaitPromise")) {
                await_promise.handle(state, session_id, id, req.parsed.value);
                return;
            }
            if (std.mem.eql(u8, method, "HeapProfiler.takeHeapSnapshot")) {
                const heap = @import("heap.zig").Module(Host);
                heap.scheduleSnapshot(state, session_id, id);
                return;
            }
            if (std.mem.startsWith(u8, method, "Performance.")) {
                const performance = @import("performance.zig").Module(Host);
                performance.handle(state, session_id, id, method, req.parsed.value);
                return;
            }
            if (std.mem.startsWith(u8, method, "Profiler.")) {
                const profiler = @import("profiler.zig").Module(Host);
                profiler.handle(state, session_id, id, method, req.parsed.value);
                return;
            }
            if (debugger_cdp.handle(state, session_id, id, method, req.parsed.value)) return;

            // No-op stubs — respond with `{}` so DevTools proceeds.
            if (isNoOpMethod(method)) {
                json_writer.sendEmptyResult(state, session_id, id);
                return;
            }

            // Unknown method — respond with JSON-RPC method-not-found error.
            json_writer.sendMethodNotFound(state, session_id, id, method);
        }

        fn sendSchemaDomains(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64) void {
            const domains = switch (backend.active_backend) {
                .quickjs_ng => if (build_options.heap_snapshot)
                    \\[{"name":"Runtime","version":"1.3"},{"name":"Debugger","version":"1.3"},{"name":"Profiler","version":"1.3"},{"name":"HeapProfiler","version":"1.3"},{"name":"Performance","version":"1.3"},{"name":"Schema","version":"1.3"}]
                else
                    \\[{"name":"Runtime","version":"1.3"},{"name":"Debugger","version":"1.3"},{"name":"Profiler","version":"1.3"},{"name":"Performance","version":"1.3"},{"name":"Schema","version":"1.3"}]
                ,
                .quickjs => if (build_options.heap_snapshot)
                    \\[{"name":"Runtime","version":"1.3"},{"name":"Profiler","version":"1.3"},{"name":"HeapProfiler","version":"1.3"},{"name":"Performance","version":"1.3"},{"name":"Schema","version":"1.3"}]
                else
                    \\[{"name":"Runtime","version":"1.3"},{"name":"Profiler","version":"1.3"},{"name":"Performance","version":"1.3"},{"name":"Schema","version":"1.3"}]
                ,
                .jsc =>
                \\[{"name":"Runtime","version":"1.3"},{"name":"Performance","version":"1.3"},{"name":"Schema","version":"1.3"}]
                ,
            };
            var buffer: [512]u8 = undefined;
            const response = std.fmt.bufPrint(&buffer, "{{\"id\":{d},\"result\":{{\"domains\":{s}}}}}", .{ request_id, domains }) catch return;
            json_writer.sendJson(state, session_id, response);
        }

        fn isNoOpMethod(method: []const u8) bool {
            const stubs = [_][]const u8{
                "Runtime.runIfWaitingForDebugger",
                "Debugger.setBlackboxPatterns",
                "Log.enable",
                "Log.disable",
                "Log.clear",
                "Log.startViolationsReport",
                "Page.enable",
                "DOM.enable",
                "CSS.enable",
                "Target.setDiscoverTargets",
                "Target.setAutoAttach",
                "Inspector.enable",
                "Inspector.disable",
                "HeapProfiler.enable",
                "HeapProfiler.disable",
            };
            for (stubs) |s| {
                if (std.mem.eql(u8, method, s)) return true;
            }
            return false;
        }
    };
}
