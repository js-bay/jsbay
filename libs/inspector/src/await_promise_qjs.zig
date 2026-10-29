pub fn Module(comptime Host: type) type {
    // QuickJS implementation behind Runtime.awaitPromise.
    //
    // A native success/failure pair is attached through the engine's intrinsic reaction API, without looking up constructor/species. Promise reactions run on the engine's normal job queue, so no reader-thread wait, JS-thread loop, or self-posted polling task is needed. Native callbacks carry only a monotonic exact-int token; removing that token on close makes late jobs harmless without retaining a stale InspectorState pointer in JavaScript.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const dispatch = Host.dispatch;
        const sync = Host.sync;
        const json_writer = @import("json_writer.zig").Module(Host);
        const remote_object = @import("remote_object.zig").Module(Host);
        const request_box = @import("request_box.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);
        const transport_mod = @import("transport.zig");
        const c = if (backend.active_backend == .quickjs)
            Host.quickjs_c_api
        else
            Host.quickjs_ng_c_api;
        const qjs = c.qjs;

        const ActiveEngine = backend.ActiveEngine;
        const InspectorState = state_mod.InspectorState;

        const Pending = struct {
            token: u32,
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            return_by_value: bool,
            object_group: []u8 = &.{},
        };

        var pending_mutex: sync.Mutex = .{};
        var pending: ?std.AutoHashMap(u32, *Pending) = null;
        var next_token: u32 = 1;
        // Bound retained CDP requests even when a client deliberately awaits Promises that never settle. These are internal inspector limits, not SDK options.
        const max_pending_per_session: usize = 64;
        const max_pending_per_state: usize = 256;

        const Admit = enum { ok, session_full, state_full, token_exhausted, out_of_memory };
        const Admission = struct { kind: Admit, token: u32 = 0 };

        fn pendingMap() *std.AutoHashMap(u32, *Pending) {
            if (pending == null) pending = std.AutoHashMap(u32, *Pending).init(std.heap.c_allocator);
            return &pending.?;
        }

        fn freePending(item: *Pending) void {
            if (item.object_group.len != 0) std.heap.c_allocator.free(item.object_group);
            std.heap.c_allocator.destroy(item);
        }

        fn insertPending(item: *Pending) Admission {
            pending_mutex.lock();
            defer pending_mutex.unlock();
            var session_count: usize = 0;
            var state_count: usize = 0;
            if (pending) |*map| {
                var it = map.valueIterator();
                while (it.next()) |entry| {
                    if (entry.*.state != item.state) continue;
                    state_count += 1;
                    if (entry.*.session_id == item.session_id) session_count += 1;
                }
            }
            if (session_count >= max_pending_per_session) return .{ .kind = .session_full };
            if (state_count >= max_pending_per_state) return .{ .kind = .state_full };
            if (next_token > std.math.maxInt(i32)) return .{ .kind = .token_exhausted };
            item.token = next_token;
            next_token += 1;
            pendingMap().put(item.token, item) catch return .{ .kind = .out_of_memory };
            return .{ .kind = .ok, .token = item.token };
        }

        fn takePending(token: u32) ?*Pending {
            pending_mutex.lock();
            defer pending_mutex.unlock();
            return if (pending) |*map| if (map.fetchRemove(token)) |entry| entry.value else null else null;
        }

        pub fn cancelSession(state: *InspectorState, session_id: transport_mod.SessionId) void {
            cancelWhere(state, session_id, false);
        }

        // Make session removal and await admission mutually exclusive. A request that was parsed before disconnect cannot insert a pending token after this returns, and every token already admitted for the session is removed.
        pub fn closeSession(state: *InspectorState, session_id: transport_mod.SessionId) void {
            state.task_mutex.lock();
            defer state.task_mutex.unlock();
            _ = state_mod.removeSession(state, session_id);
            cancelWhere(state, session_id, false);
        }

        pub fn cancelState(state: *InspectorState) void {
            cancelWhere(state, 0, true);
        }

        fn cancelWhere(state: *InspectorState, session_id: transport_mod.SessionId, every_session: bool) void {
            var removed: std.ArrayList(*Pending) = .empty;
            defer removed.deinit(std.heap.c_allocator);
            pending_mutex.lock();
            if (pending) |*map| {
                while (true) {
                    var found: ?u32 = null;
                    var it = map.iterator();
                    while (it.next()) |entry| {
                        const item = entry.value_ptr.*;
                        if (item.state == state and (every_session or item.session_id == session_id)) {
                            found = entry.key_ptr.*;
                            break;
                        }
                    }
                    const token = found orelse break;
                    if (map.fetchRemove(token)) |taken| removed.append(std.heap.c_allocator, taken.value) catch freePending(taken.value);
                }
            }
            pending_mutex.unlock();
            for (removed.items) |item| freePending(item);
        }

        pub fn handle(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64, root: std.json.Value) void {
            const params = objectParams(root) orelse {
                json_writer.sendInvalidParams(state, session_id, request_id, "params");
                return;
            };
            const raw_id = stringField(params, "promiseObjectId") orelse {
                json_writer.sendInvalidParams(state, session_id, request_id, "promiseObjectId");
                return;
            };
            const object_id = remote_object.parseObjectId(raw_id) orelse {
                json_writer.sendInvalidParams(state, session_id, request_id, "promiseObjectId");
                return;
            };
            const return_by_value = boolField(params, "returnByValue") orelse false;
            if (params.get("returnByValue")) |field| if (field != .bool) {
                json_writer.sendInvalidParams(state, session_id, request_id, "returnByValue must be boolean");
                return;
            };
            const group = stringField(params, "objectGroup") orelse "";
            if (params.get("objectGroup")) |field| if (field != .string) {
                json_writer.sendInvalidParams(state, session_id, request_id, "objectGroup must be string");
                return;
            };
            const box = state.allocator.create(request_box.RequestBox) catch {
                json_writer.sendError(state, session_id, request_id, -32000, "Unable to allocate Runtime.awaitPromise request");
                return;
            };
            box.* = .{
                .state = state,
                .session_id = session_id,
                .request_id = request_id,
                .run_fn = runRequest,
                .object_id = object_id,
                .return_by_value = return_by_value,
                .object_group = state.allocator.dupe(u8, group) catch &.{},
                .await_promise = true,
            };
            if (!request_box.postJsRequest(state, box)) {
                request_box.freeRequestBox(state.allocator, box);
                remote_object.sendEvalException(state, session_id, request_id, "Inspector could not dispatch to JS thread");
            }
        }

        fn runRequest(box: *request_box.RequestBox, ctx: ActiveEngine.Context) void {
            if (!state_mod.hasSession(box.state, box.session_id)) return;
            const promise = box.state.object_table.get(box.object_id) orelse {
                json_writer.sendObjectNotFound(box.state, box.session_id, box.request_id);
                return;
            };
            _ = attach(box.state, box.session_id, box.request_id, ctx, promise, box.return_by_value, if (box.object_group.len == 0) null else box.object_group);
        }

        pub fn attach(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            ctx: ActiveEngine.Context,
            promise: ActiveEngine.Value,
            return_by_value: bool,
            object_group: ?[]const u8,
        ) bool {
            if (c.jsbay_qjs_JS_IsPromise(ctx, promise) == 0) {
                json_writer.sendInvalidParams(state, session_id, request_id, "promiseObjectId must identify a Promise");
                return false;
            }
            const item = std.heap.c_allocator.create(Pending) catch {
                json_writer.sendError(state, session_id, request_id, -32000, "Unable to allocate Runtime.awaitPromise state");
                return false;
            };
            item.* = .{
                .token = 0,
                .state = state,
                .session_id = session_id,
                .request_id = request_id,
                .return_by_value = return_by_value,
                .object_group = if (object_group) |group| std.heap.c_allocator.dupe(u8, group) catch {
                    std.heap.c_allocator.destroy(item);
                    json_writer.sendError(state, session_id, request_id, -32000, "Unable to allocate Runtime.awaitPromise group");
                    return false;
                } else &.{},
            };
            // beginClosing takes task_mutex before cancelling pending tokens. Holding it across admission prevents teardown from removing/freeing this entry in the small interval before attach has finished creating its callbacks.
            state.task_mutex.lock();
            if (state.closing) {
                state.task_mutex.unlock();
                freePending(item);
                json_writer.sendError(state, session_id, request_id, -32000, "Inspector is closing");
                return false;
            }
            if (!state_mod.hasSession(state, session_id)) {
                state.task_mutex.unlock();
                freePending(item);
                return false;
            }
            const admission = insertPending(item);
            state.task_mutex.unlock();
            if (admission.kind != .ok) {
                freePending(item);
                const message = switch (admission.kind) {
                    .session_full => "Runtime.awaitPromise has too many pending requests for this session",
                    .state_full => "Runtime.awaitPromise has too many pending requests for this instance",
                    .token_exhausted => "Runtime.awaitPromise token capacity exhausted",
                    .out_of_memory => "Unable to retain Runtime.awaitPromise state",
                    .ok => unreachable,
                };
                json_writer.sendError(state, session_id, request_id, -32000, message);
                return false;
            }
            const token = admission.token;
            const token_value = c.jsbay_qjs_JS_NewInt32(ctx, @intCast(token));
            if (c.jsIsException(token_value)) {
                if (takePending(token)) |owned| freePending(owned);
                json_writer.sendError(state, session_id, request_id, -32000, "Unable to create Runtime.awaitPromise callbacks");
                return false;
            }
            defer c.jsbay_qjs_JS_FreeValue(ctx, token_value);
            const fulfilled = c.jsbay_qjs_JS_NewCFunctionData(ctx, &onFulfilled, "jsbay_await_fulfilled", 1, token_value);
            if (c.jsIsException(fulfilled)) {
                if (takePending(token)) |owned| freePending(owned);
                json_writer.sendError(state, session_id, request_id, -32000, "Unable to create Runtime.awaitPromise callbacks");
                return false;
            }
            defer c.jsbay_qjs_JS_FreeValue(ctx, fulfilled);
            const rejected = c.jsbay_qjs_JS_NewCFunctionData(ctx, &onRejected, "jsbay_await_rejected", 1, token_value);
            if (c.jsIsException(rejected)) {
                if (takePending(token)) |owned| freePending(owned);
                json_writer.sendError(state, session_id, request_id, -32000, "Unable to create Runtime.awaitPromise callbacks");
                return false;
            }
            defer c.jsbay_qjs_JS_FreeValue(ctx, rejected);
            const reaction = if (comptime backend.active_backend == .quickjs_ng)
                qjs.JS_PromiseThen(ctx, promise, fulfilled, rejected)
            else
                qjs.JS_BayPromiseThen(ctx, promise, fulfilled, rejected);
            if (!c.jsIsException(reaction)) {
                c.jsbay_qjs_JS_FreeValue(ctx, reaction);
                return true;
            }
            if (takePending(token)) |owned| freePending(owned);
            remote_object.sendEvalException(state, session_id, request_id, "Unable to attach native Promise reaction");
            return false;
        }

        fn onFulfilled(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue, _: c_int, func_data: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
            settle(ctx, argc, argv, func_data, true);
            return c.JS_UNDEFINED;
        }

        fn onRejected(ctx: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue, _: c_int, func_data: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
            settle(ctx, argc, argv, func_data, false);
            return c.JS_UNDEFINED;
        }

        fn settle(ctx: ?*qjs.JSContext, argc: c_int, argv: [*c]qjs.JSValue, func_data: [*c]qjs.JSValue, fulfilled: bool) void {
            var raw_token: i64 = 0;
            if (qjs.JS_ToInt64(ctx, &raw_token, func_data[0]) < 0 or raw_token <= 0 or raw_token > std.math.maxInt(u32)) return;
            const item = takePending(@intCast(raw_token)) orelse return;
            defer freePending(item);
            if (!state_mod.tryAcquireStateLease(item.state)) return;
            defer state_mod.releaseStateLease(item.state);
            // Promise jobs may run from a normal engine eval/tick rather than a RequestBox. Make this lease visible to inspector.stop so a native callback invoked while serializing can defer finalization instead of waiting on this same callback.
            var owner_frame: dispatch.TaskOwnerFrame = undefined;
            dispatch.enterTaskOwnerFrame(&owner_frame, item.state.instance_id, item.state);
            defer dispatch.leaveTaskOwnerFrame(&owner_frame);
            const value = if (argc > 0) argv[0] else c.JS_UNDEFINED;
            if (fulfilled) {
                sendFulfilled(item, ctx, value);
            } else {
                const converted = ActiveEngine.valueToStringVal(ctx, value);
                const message = converted orelse "Promise rejected";
                defer if (converted) |owned| std.heap.c_allocator.free(@constCast(owned));
                remote_object.sendEvalException(item.state, item.session_id, item.request_id, message);
            }
        }

        fn sendFulfilled(item: *Pending, ctx: ActiveEngine.Context, value: ActiveEngine.Value) void {
            var aw: std.Io.Writer.Allocating = .init(item.state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"result\":", .{item.request_id}) catch return;
            const group: ?[]const u8 = if (item.object_group.len == 0) null else item.object_group;
            if (item.return_by_value) {
                remote_object.writeRemoteObjectByValue(item.state, ctx, w, value) catch |err| {
                    sendByValueError(item.state, item.session_id, item.request_id, err);
                    return;
                };
            } else {
                remote_object.writeRemoteObject(item.state, ctx, w, value, group) catch return;
            }
            w.writeAll("}}") catch return;
            json_writer.sendJson(item.state, item.session_id, aw.written());
        }

        fn sendByValueError(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64, err: anyerror) void {
            switch (err) {
                error.ByValueCycle, error.ByValueDepth => json_writer.sendError(state, session_id, request_id, -32000, "Object reference chain is too long"),
                error.UnsupportedByValue => json_writer.sendError(state, session_id, request_id, -32000, "Object couldn't be returned by value"),
                else => json_writer.sendError(state, session_id, request_id, -32603, "Internal error"),
            }
        }

        fn objectParams(root: std.json.Value) ?std.json.ObjectMap {
            if (root != .object) return null;
            const params = root.object.get("params") orelse return null;
            if (params != .object) return null;
            return params.object;
        }

        fn stringField(params: std.json.ObjectMap, name: []const u8) ?[]const u8 {
            const value = params.get(name) orelse return null;
            return if (value == .string) value.string else null;
        }

        fn boolField(params: std.json.ObjectMap, name: []const u8) ?bool {
            const value = params.get(name) orelse return null;
            return if (value == .bool) value.bool else null;
        }
    };
}
