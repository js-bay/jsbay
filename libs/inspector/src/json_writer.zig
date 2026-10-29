pub fn Module(comptime Host: type) type {
    // JSON emission primitives shared across CDP message handlers.
    //
    // All inspector responses are hand-rolled JSON strings — using a Value tree just to stringify a fixed-shape object would be overkill. This module provides:
    //
    // - `writeJsonString`: append a JSON-escaped (double-quoted) string to a writer.
    // - `sendJson`: forward a pre-built payload to the transport for a single session. The inspector lock is never held across this call.
    // - `sendEmptyResult` / `sendIsolateId` / `sendHeapUsage` / `sendDebuggerEnabled` / `sendMethodNotFound` / `sendInvalidParams` / `sendObjectNotFound`: small fixed-shape replies that don't touch the JS runtime.
    //
    // Anything that needs to look up live `Value`s (Runtime.evaluate result, getProperties tree, …) lives in `runtime.zig` and uses these helpers.

    return struct {
        const std = @import("std");
        const transport_mod = @import("transport.zig");
        const state_mod = @import("state.zig").Module(Host);

        const InspectorState = state_mod.InspectorState;

        // Append a JSON-escaped string (double-quoted) to the writer.
        pub fn writeJsonString(writer: anytype, s: []const u8) !void {
            try writer.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    0...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                        var buf: [8]u8 = undefined;
                        const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                        try writer.writeAll(esc);
                    },
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeByte('"');
        }

        // Send a pre-built JSON payload to a single session. Transport takes care of framing. No inspector lock is held across this call.
        pub fn sendJson(state: *InspectorState, session_id: transport_mod.SessionId, payload: []const u8) void {
            _ = state.transport.sendText(session_id, payload);
        }

        pub fn sendEmptyResult(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{}}}}", .{request_id}) catch return;
            sendJson(state, session_id, aw.written());
        }

        pub fn sendIsolateId(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"id\":", .{request_id}) catch return;
            writeJsonString(w, state.target_id) catch return;
            w.writeAll("}}") catch return;
            sendJson(state, session_id, aw.written());
        }

        pub fn sendHeapUsage(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            used_size: u64,
            total_size: u64,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print(
                "{{\"id\":{d},\"result\":{{\"usedSize\":{d},\"totalSize\":{d}}}}}",
                .{ request_id, used_size, total_size },
            ) catch return;
            sendJson(state, session_id, aw.written());
        }

        pub fn sendDebuggerEnabled(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"debuggerId\":", .{request_id}) catch return;
            writeJsonString(w, state.target_id) catch return;
            w.writeAll("}}") catch return;
            sendJson(state, session_id, aw.written());
        }

        pub fn sendMethodNotFound(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            method: []const u8,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"error\":{{\"code\":-32601,\"message\":", .{request_id}) catch return;
            const composed = std.fmt.allocPrint(state.allocator, "Method not found: {s}", .{method}) catch return;
            defer state.allocator.free(composed);
            writeJsonString(w, composed) catch return;
            w.writeAll("}}") catch return;
            sendJson(state, session_id, aw.written());
        }

        pub fn sendError(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            code: i32,
            message: []const u8,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"error\":{{\"code\":{d},\"message\":", .{ request_id, code }) catch return;
            writeJsonString(w, message) catch return;
            w.writeAll("}}") catch return;
            sendJson(state, session_id, aw.written());
        }

        pub fn sendInvalidParams(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            message: []const u8,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"error\":{{\"code\":-32602,\"message\":", .{request_id}) catch return;
            writeJsonString(w, message) catch return;
            w.writeAll("}}") catch return;
            sendJson(state, session_id, aw.written());
        }

        pub fn sendObjectNotFound(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print(
                "{{\"id\":{d},\"error\":{{\"code\":-32000,\"message\":\"Could not find object with given id\"}}}}",
                .{request_id},
            ) catch return;
            sendJson(state, session_id, aw.written());
        }

        pub fn sendExecutionContextCreated(state: *InspectorState, session_id: transport_mod.SessionId) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"method\":\"Runtime.executionContextCreated\",\"params\":{{\"context\":{{\"id\":{d},\"origin\":\"\",\"name\":", .{state_mod.default_execution_context_id}) catch return;
            writeJsonString(w, state.title) catch return;
            w.writeAll(",\"uniqueId\":") catch return;
            writeJsonString(w, state.target_id) catch return;
            w.writeAll(",\"auxData\":{\"isDefault\":true}}}}") catch return;
            sendJson(state, session_id, aw.written());
        }

        // Announce context teardown while the transport is still available.
        pub fn sendExecutionContextDestroyed(state: *InspectorState) void {
            var sessions: std.ArrayList(transport_mod.SessionId) = .empty;
            defer sessions.deinit(state.allocator);
            state_mod.snapshotEnabledSessions(state, &sessions);
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"method\":\"Runtime.executionContextDestroyed\",\"params\":{{\"executionContextId\":{d},\"executionContextUniqueId\":", .{state_mod.default_execution_context_id}) catch return;
            writeJsonString(w, state.target_id) catch return;
            w.writeAll("}}") catch return;
            for (sessions.items) |session_id| {
                sendJson(state, session_id, aw.written());
                sendJson(state, session_id, "{\"method\":\"Runtime.executionContextsCleared\",\"params\":{}}");
            }
        }

        pub fn sendScriptParsed(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            script_id: u32,
            url: []const u8,
            end_line: i32,
            end_column: i32,
            hash: []const u8,
            source_map_url: []const u8,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"method\":\"Debugger.scriptParsed\",\"params\":{{\"scriptId\":\"{d}\",\"url\":", .{script_id}) catch return;
            writeJsonString(w, url) catch return;
            w.print(",\"startLine\":0,\"startColumn\":0,\"endLine\":{d},\"endColumn\":{d},\"executionContextId\":{d},\"hash\":", .{ end_line, end_column, state_mod.default_execution_context_id }) catch return;
            writeJsonString(w, hash) catch return;
            if (source_map_url.len != 0) {
                w.writeAll(",\"sourceMapURL\":") catch return;
                writeJsonString(w, source_map_url) catch return;
            }
            w.writeAll("}}") catch return;
            sendJson(state, session_id, aw.written());
        }

        pub fn sendScriptSource(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            source: []const u8,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"scriptSource\":", .{request_id}) catch return;
            writeJsonString(w, source) catch return;
            w.writeAll("}}") catch return;
            sendJson(state, session_id, aw.written());
        }

        pub const PausedFrame = struct {
            call_frame_id: u32,
            function_name: []const u8,
            script_id: u32,
            url: []const u8,
            line: i32,
            column: i32,
            local_id: u64,
            closure_id: u64,
            global_id: u64,
            this_id: u64,
        };

        pub fn sendDebuggerPaused(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            reason: []const u8,
            frames: []const PausedFrame,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.writeAll("{\"method\":\"Debugger.paused\",\"params\":{\"callFrames\":[") catch return;
            for (frames, 0..) |frame, i| {
                if (i != 0) w.writeAll(",") catch return;
                writePausedFrame(w, frame);
            }
            w.writeAll("]") catch return;
            const async_stack = Host.async_stack;
            async_stack.writeAsyncStackTrace(state.instance_id, w) catch return;
            w.writeAll(",\"reason\":") catch return;
            writeJsonString(w, reason) catch return;
            w.writeAll("}}") catch return;
            sendJson(state, session_id, aw.written());
        }

        fn writePausedFrame(w: anytype, frame: PausedFrame) void {
            const line0: i32 = if (frame.line > 0) frame.line - 1 else 0;
            w.print("{{\"callFrameId\":\"{d}\",\"functionName\":", .{frame.call_frame_id}) catch return;
            writeJsonString(w, frame.function_name) catch return;
            w.print(",\"location\":{{\"scriptId\":\"{d}\",\"lineNumber\":{d},\"columnNumber\":{d}}},\"url\":", .{
                frame.script_id, line0, frame.column,
            }) catch return;
            writeJsonString(w, frame.url) catch return;
            w.writeAll(",\"scopeChain\":[") catch return;
            writeScope(w, "local", frame.local_id);
            w.writeAll(",") catch return;
            writeScope(w, "closure", frame.closure_id);
            w.writeAll(",") catch return;
            writeScope(w, "global", frame.global_id);
            w.print("],\"this\":{{\"type\":\"object\",\"className\":\"Object\",\"description\":\"Object\",\"objectId\":\"{d}\"}}}}", .{frame.this_id}) catch return;
        }

        fn writeScope(w: anytype, kind: []const u8, object_id: u64) void {
            w.writeAll("{\"type\":") catch return;
            writeJsonString(w, kind) catch return;
            w.print(",\"object\":{{\"type\":\"object\",\"className\":\"Object\",\"description\":\"Object\",\"objectId\":\"{d}\"}},\"name\":", .{object_id}) catch return;
            const name = switch (kind[0]) {
                'l' => "Local",
                'c' => "Closure",
                else => "Global",
            };
            writeJsonString(w, name) catch return;
            w.writeAll("}") catch return;
        }

        pub fn sendDebuggerResumed(state: *InspectorState, session_id: transport_mod.SessionId) void {
            sendJson(state, session_id, "{\"method\":\"Debugger.resumed\",\"params\":{}}");
        }

        pub fn sendBreakpointResolved(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            breakpoint_id: u32,
            script_id: u32,
            line: i32,
            column: i32,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            const line0: i32 = if (line > 0) line - 1 else 0;
            w.print(
                "{{\"method\":\"Debugger.breakpointResolved\",\"params\":{{\"breakpointId\":\"{d}\",\"location\":{{\"scriptId\":\"{d}\",\"lineNumber\":{d},\"columnNumber\":{d}}}}}}}",
                .{ breakpoint_id, script_id, line0, column },
            ) catch return;
            sendJson(state, session_id, aw.written());
        }

        pub const BreakLocationJson = struct {
            script_id: u32,
            line: i32,
            column: i32,
        };

        pub fn sendBreakpointResult(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            breakpoint_id: u32,
            locations: []const BreakLocationJson,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"breakpointId\":\"{d}\",\"locations\":[", .{ request_id, breakpoint_id }) catch return;
            for (locations, 0..) |location, i| {
                if (i != 0) w.writeAll(",") catch return;
                const line0: i32 = if (location.line > 0) location.line - 1 else 0;
                w.print("{{\"scriptId\":\"{d}\",\"lineNumber\":{d},\"columnNumber\":{d}}}", .{
                    location.script_id, line0, location.column,
                }) catch return;
            }
            w.writeAll("]}}") catch return;
            sendJson(state, session_id, aw.written());
        }

        pub fn sendPossibleBreakpoints(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            locations: []const BreakLocationJson,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"locations\":[", .{request_id}) catch return;
            for (locations, 0..) |location, i| {
                if (i != 0) w.writeAll(",") catch return;
                const line0: i32 = if (location.line > 0) location.line - 1 else 0;
                w.print("{{\"scriptId\":\"{d}\",\"lineNumber\":{d},\"columnNumber\":{d}}}", .{
                    location.script_id, line0, location.column,
                }) catch return;
            }
            w.writeAll("]}}") catch return;
            sendJson(state, session_id, aw.written());
        }
    };
}
