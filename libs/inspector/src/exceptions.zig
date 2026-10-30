pub fn Module(comptime Host: type) type {
    // Uncaught execution failures and independently observed Promise rejections. All value retention and release happens on the owning engine thread.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const dispatch = Host.dispatch;
        const engine = Host.engine;
        const io = Host.io;
        const state_mod = @import("state.zig").Module(Host);
        const json_writer = @import("json_writer.zig").Module(Host);
        const transport = @import("transport.zig");

        const ActiveEngine = backend.ActiveEngine;
        const InspectorState = state_mod.InspectorState;
        const rejection_limit = 64;

        pub fn isEnabled(instance_id: i32) bool {
            if (comptime !Host.build_options.inspector) return false;
            const state = state_mod.acquireStateLeaseByInstance(instance_id) orelse return false;
            defer state_mod.releaseStateLease(state);
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |session| if (session.runtime_enabled) return true;
            return false;
        }

        fn nextId(state: *InspectorState) u32 {
            const id = state.next_exception_id;
            state.next_exception_id +%= 1;
            if (state.next_exception_id == 0) state.next_exception_id = 1;
            return id;
        }

        pub fn reportUncaught(instance_id: i32, text: []const u8, url: []const u8) void {
            if (comptime !Host.build_options.inspector) return;
            const state = state_mod.acquireStateLeaseByInstance(instance_id) orelse return;
            defer state_mod.releaseStateLease(state);
            var owner_frame: dispatch.TaskOwnerFrame = undefined;
            dispatch.enterTaskOwnerFrame(&owner_frame, instance_id, state);
            defer dispatch.leaveTaskOwnerFrame(&owner_frame);
            sendThrown(state, nextId(state), text, url, null);
        }

        // Report the typed public execution path without coercing an arbitrary thrown object. In particular, user toString/getters must not change API semantics.
        pub fn reportValue(instance_id: i32, ctx: ActiveEngine.Context, value: ActiveEngine.Value, url: []const u8) void {
            if (comptime !Host.build_options.inspector) return;
            const state = state_mod.acquireStateLeaseByInstance(instance_id) orelse return;
            defer state_mod.releaseStateLease(state);
            var owner_frame: dispatch.TaskOwnerFrame = undefined;
            dispatch.enterTaskOwnerFrame(&owner_frame, instance_id, state);
            defer dispatch.leaveTaskOwnerFrame(&owner_frame);
            const message = nativeErrorMessage(ctx, value);
            defer if (message) |owned| std.heap.c_allocator.free(owned);
            sendThrown(state, nextId(state), message orelse "Uncaught exception", url, value);
        }

        fn nativeErrorMessage(ctx: ActiveEngine.Context, value: ActiveEngine.Value) ?[]const u8 {
            if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return null;
            const qjs = backend.ActiveEngineModule.c_api.qjs;
            const is_error = if (comptime backend.active_backend == .quickjs_ng) qjs.JS_IsError(value) else qjs.JS_IsError(ctx, value) != 0;
            if (!is_error) return null;
            const atom = qjs.JS_NewAtom(ctx, "message");
            if (atom == 0) return null;
            defer qjs.JS_FreeAtom(ctx, atom);
            var descriptor: qjs.JSPropertyDescriptor = undefined;
            if (qjs.JS_GetOwnProperty(ctx, &descriptor, value, atom) <= 0) return null;
            defer {
                ActiveEngine.freeValue(ctx, descriptor.value);
                ActiveEngine.freeValue(ctx, descriptor.getter);
                ActiveEngine.freeValue(ctx, descriptor.setter);
            }
            if (descriptor.flags & qjs.JS_PROP_GETSET != 0 or !ActiveEngine.isString(ctx, descriptor.value)) return null;
            return ActiveEngine.valueToString(ctx, descriptor.value);
        }

        fn writeExceptionValue(state: *InspectorState, writer: anytype, value: ActiveEngine.Value) !void {
            const ctx = engine.getContext(state.instance_id) orelse return error.InstanceUnavailable;
            const is_object = if (comptime backend.isQuickJsApiBackend(backend.active_backend))
                backend.ActiveEngineModule.c_api.jsbay_qjs_JS_IsObject(value) != 0
            else if (comptime backend.isJscApiBackend(backend.active_backend))
                backend.ActiveEngineModule.jsc.JSValueIsObject(@ptrCast(ctx), value)
            else
                ActiveEngine.isObjectVal(ctx, value);
            if (is_object) {
                const object_pending = state.exception_object_ids.items.len - state.exception_object_ids_head;
                if (object_pending == rejection_limit) {
                    const old = state.exception_object_ids.items[state.exception_object_ids_head];
                    state.exception_object_ids_head += 1;
                    if (state.exception_object_ids_head == state.exception_object_ids.items.len) {
                        state.exception_object_ids.clearRetainingCapacity();
                        state.exception_object_ids_head = 0;
                    }
                    _ = state.object_table.release(ctx, old);
                }
                const object_id = state.object_table.retain(ctx, value, null) orelse return error.OutOfMemory;
                state.exception_object_ids.append(state.allocator, object_id) catch {
                    _ = state.object_table.release(ctx, object_id);
                    return error.OutOfMemory;
                };
                if (state.exception_object_ids_head >= 32) {
                    const pend = state.exception_object_ids.items[state.exception_object_ids_head..];
                    var write: usize = 0;
                    while (write < pend.len) : (write += 1) {
                        state.exception_object_ids.items[write] = pend[write];
                    }
                    state.exception_object_ids.shrinkRetainingCapacity(pend.len);
                    state.exception_object_ids_head = 0;
                }
                // Do not enumerate or classify arbitrary objects: Proxy traps, getters and custom coercion are user code. The explicit objectId permits the frontend to inspect the original value on a subsequent user request.
                try writer.print("{{\"type\":\"{s}\",\"description\":\"Uncaught exception\",\"objectId\":\"{d}\"}}", .{ if (ActiveEngine.isFunction(ctx, value)) @as([]const u8, "function") else "object", object_id });
            } else {
                try @import("remote_object.zig").Module(Host).writeRemoteObject(state, ctx, writer, value, null);
            }
        }

        fn sendThrown(state: *InspectorState, id: u32, text: []const u8, url: []const u8, raw: ?ActiveEngine.Value) void {
            var sessions: std.ArrayList(transport.SessionId) = .empty;
            defer sessions.deinit(state.allocator);
            state_mod.snapshotEnabledSessions(state, &sessions);
            if (sessions.items.len == 0) return;
            var out: std.Io.Writer.Allocating = .init(state.allocator);
            defer out.deinit();
            const w = &out.writer;
            w.print("{{\"method\":\"Runtime.exceptionThrown\",\"params\":{{\"timestamp\":{d},\"exceptionDetails\":{{\"exceptionId\":{d},\"text\":", .{ io.milliTimestamp(), id }) catch return;
            json_writer.writeJsonString(w, text) catch return;
            // The host boundary preserves formatted exception text but does not expose a precise throw location. CDP's required location defaults to zero.
            w.writeAll(",\"lineNumber\":0,\"columnNumber\":0,\"executionContextId\":1") catch return;
            if (url.len != 0) {
                w.writeAll(",\"url\":") catch return;
                json_writer.writeJsonString(w, url) catch return;
            }
            if (raw) |value| {
                w.writeAll(",\"exception\":") catch return;
                writeExceptionValue(state, w, value) catch return;
            }
            w.writeAll("}}}") catch return;
            for (sessions.items) |session_id| json_writer.sendJson(state, session_id, out.written());
        }

        pub fn reportRejection(instance_id: i32, promise: ActiveEngine.Value, handled: bool, reason: ActiveEngine.Value) void {
            if (comptime !Host.build_options.inspector) return;
            if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
            const state = state_mod.acquireStateLeaseByInstance(instance_id) orelse return;
            defer state_mod.releaseStateLease(state);
            var owner_frame: dispatch.TaskOwnerFrame = undefined;
            dispatch.enterTaskOwnerFrame(&owner_frame, instance_id, state);
            defer dispatch.leaveTaskOwnerFrame(&owner_frame);
            const ctx = engine.getContext(instance_id) orelse return;
            const identity = @intFromPtr(promise.u.ptr);
            // Compact consumed prefix so identity scan/removal runs over the live set only.
            if (state.reported_rejections_head != 0) {
                const pend = state.reported_rejections.items[state.reported_rejections_head..];
                var write: usize = 0;
                while (write < pend.len) : (write += 1) {
                    state.reported_rejections.items[write] = pend[write];
                }
                state.reported_rejections.shrinkRetainingCapacity(pend.len);
                state.reported_rejections_head = 0;
            }
            for (state.reported_rejections.items, 0..) |entry, index| {
                if (entry.identity != identity) continue;
                if (!handled) return;
                // Stable compress (not swapRemove): keep oldest-first eviction order for the rest.
                const removed = entry;
                var write: usize = 0;
                for (state.reported_rejections.items, 0..) |keep, i| {
                    if (i == index) continue;
                    state.reported_rejections.items[write] = keep;
                    write += 1;
                }
                state.reported_rejections.shrinkRetainingCapacity(write);
                defer ActiveEngine.freeValue(ctx, removed.promise);
                var sessions: std.ArrayList(transport.SessionId) = .empty;
                defer sessions.deinit(state.allocator);
                state_mod.snapshotEnabledSessions(state, &sessions);
                var buf: [192]u8 = undefined;
                const event = std.fmt.bufPrint(&buf, "{{\"method\":\"Runtime.exceptionRevoked\",\"params\":{{\"reason\":\"Handler added to rejected promise\",\"exceptionId\":{d}}}}}", .{removed.exception_id}) catch return;
                for (sessions.items) |session_id| json_writer.sendJson(state, session_id, event);
                return;
            }
            if (handled or !isEnabled(instance_id)) return;
            // Keep the Promise itself alive until revocation/eviction; a recycled object address must never revoke an unrelated exception.
            const rejection_pending = state.reported_rejections.items.len - state.reported_rejections_head;
            if (rejection_pending == rejection_limit) {
                const removed = state.reported_rejections.items[state.reported_rejections_head];
                state.reported_rejections_head += 1;
                if (state.reported_rejections_head == state.reported_rejections.items.len) {
                    state.reported_rejections.clearRetainingCapacity();
                    state.reported_rejections_head = 0;
                }
                ActiveEngine.freeValue(ctx, removed.promise);
            }
            const retained = ActiveEngine.dupValue(ctx, promise);
            const id = nextId(state);
            state.reported_rejections.append(state.allocator, .{
                .identity = identity,
                .promise = retained,
                .exception_id = id,
            }) catch {
                ActiveEngine.freeValue(ctx, retained);
                return;
            };
            if (state.reported_rejections_head >= 32) {
                const pend = state.reported_rejections.items[state.reported_rejections_head..];
                var write: usize = 0;
                while (write < pend.len) : (write += 1) {
                    state.reported_rejections.items[write] = pend[write];
                }
                state.reported_rejections.shrinkRetainingCapacity(pend.len);
                state.reported_rejections_head = 0;
            }
            const message = nativeErrorMessage(ctx, reason);
            defer if (message) |owned| std.heap.c_allocator.free(owned);
            sendThrown(state, id, message orelse "Unhandled Promise rejection", "", reason);
        }

        pub fn deinit(state: *InspectorState, ctx: ActiveEngine.Context) void {
            for (state.reported_rejections.items[state.reported_rejections_head..]) |entry| ActiveEngine.freeValue(ctx, entry.promise);
            state.reported_rejections.deinit(state.allocator);
            state.reported_rejections = .empty;
            state.reported_rejections_head = 0;
            state.exception_object_ids.deinit(state.allocator);
            state.exception_object_ids = .empty;
            state.exception_object_ids_head = 0;
        }
    };
}
