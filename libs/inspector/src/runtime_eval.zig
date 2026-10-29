pub fn Module(comptime Host: type) type {
    // Eval-driven Runtime methods: `Runtime.evaluate` and `Runtime.callFunctionOn`.
    //
    // Both methods compile their string payload by writing it into a sentinel property on `globalThis`, then read the resulting JS Value back out so we can serialize it as a `RemoteObject` (with optional retain into the ObjectTable). `callFunctionOn` additionally builds an argument array out of the CDP `arguments` descriptors before invoking.
    //
    // Marshal pattern (shared with `runtime_objects.zig`):
    // - The `handle*` entry parses params on the reader thread and posts a `RequestBox` to the JS thread via `request_box.postJsRequest`.
    // - The `run*` continuation runs on the JS thread once the engine context is available and emits the CDP reply.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const debugger_mod = Host.debugger;
        const engine = Host.engine;
        const transport_mod = @import("transport.zig");
        const json_writer = @import("json_writer.zig").Module(Host);
        const remote_object = @import("remote_object.zig").Module(Host);
        const request_box = @import("request_box.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);

        const ActiveEngine = backend.ActiveEngine;
        const InspectorState = state_mod.InspectorState;
        const RequestBox = request_box.RequestBox;
        const CallArg = request_box.CallArg;
        const writeJsonString = json_writer.writeJsonString;
        const sendJson = json_writer.sendJson;
        const sendInvalidParams = json_writer.sendInvalidParams;
        const sendError = json_writer.sendError;
        const sendObjectNotFound = json_writer.sendObjectNotFound;
        const sendEvalException = remote_object.sendEvalException;
        const sendSimpleRemoteObject = remote_object.sendSimpleRemoteObject;
        const writeRemoteObject = remote_object.writeRemoteObject;
        const writeRemoteObjectByValue = remote_object.writeRemoteObjectByValue;
        const parseObjectId = remote_object.parseObjectId;
        const buildEvalScript = remote_object.buildEvalScript;

        // --- Runtime.evaluate -------------------------------------------------------

        pub fn handleEvaluate(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            root: std.json.Value,
        ) void {
            const alloc = state.allocator;
            if (root != .object) return;

            const params_val = root.object.get("params") orelse {
                sendSimpleRemoteObject(state, session_id, request_id, .undefined_);
                return;
            };
            if (params_val != .object) {
                sendSimpleRemoteObject(state, session_id, request_id, .undefined_);
                return;
            }
            const expr_val = params_val.object.get("expression") orelse {
                sendSimpleRemoteObject(state, session_id, request_id, .undefined_);
                return;
            };
            if (expr_val != .string) {
                sendSimpleRemoteObject(state, session_id, request_id, .undefined_);
                return;
            }

            const expr_copy = alloc.dupe(u8, expr_val.string) catch return;
            var return_by_value = false;
            if (params_val.object.get("returnByValue")) |flag| {
                if (flag != .bool) {
                    alloc.free(expr_copy);
                    sendInvalidParams(state, session_id, request_id, "returnByValue must be boolean");
                    return;
                }
                return_by_value = flag.bool;
            }
            var await_promise = false;
            if (params_val.object.get("awaitPromise")) |flag| {
                if (flag != .bool) {
                    alloc.free(expr_copy);
                    sendInvalidParams(state, session_id, request_id, "awaitPromise must be boolean");
                    return;
                }
                await_promise = flag.bool;
            }
            var group_copy: []u8 = &.{};
            if (params_val.object.get("objectGroup")) |g| {
                if (g == .string and g.string.len != 0) {
                    group_copy = alloc.dupe(u8, g.string) catch {
                        alloc.free(expr_copy);
                        return;
                    };
                }
            }

            const box = alloc.create(RequestBox) catch {
                alloc.free(expr_copy);
                if (group_copy.len != 0) alloc.free(group_copy);
                return;
            };
            box.* = .{
                .state = state,
                .session_id = session_id,
                .request_id = request_id,
                .run_fn = runEvaluate,
                .expression = expr_copy,
                .object_group = group_copy,
                .return_by_value = return_by_value,
                .await_promise = await_promise,
            };

            if (!request_box.postJsRequest(state, box)) {
                request_box.freeRequestBox(alloc, box);
                sendEvalException(state, session_id, request_id, "Inspector could not dispatch to JS thread");
            }
        }

        fn runEvaluate(box: *RequestBox, ctx: ActiveEngine.Context) void {
            const state = box.state;

            // We need the raw result Value so we can retain objects / classify types. `engine.evalScript` stringifies, so instead we wrap the expression in `globalThis.<sentinel> = (0, eval)(<escaped>)` and then fetch the sentinel via getPropertyVal. Wrapping inside `eval` preserves the original top-level completion semantics so users can still paste `throw new Error('boom')` or other statements and have them surface through the exception path. `(0, eval)` is an indirect eval, executing in global scope like a REPL.
            const sentinel = "__jsbay_qjs_inspector_eval_result__";
            const wrapped = buildEvalScript(state.allocator, sentinel, box.expression) catch {
                sendEvalException(state, box.session_id, box.request_id, "Out of memory building evaluate wrapper");
                return;
            };
            defer state.allocator.free(wrapped);

            // Indirect eval compiles the user text as "<input>". Register that script first so Debugger.paused can point Sources at a real scriptId.
            debugger_mod.noteScript(state.instance_id, "<input>", box.expression);
            const res = engine.evalScript(state.instance_id, wrapped, "<inspector>");
            defer {
                if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
                if (res.err_is_heap) {
                    if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
                }
            }

            if (res.err) |emsg| {
                sendEvalException(state, box.session_id, box.request_id, emsg);
                return;
            }

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const value_opt = ActiveEngine.getPropertyVal(ctx, global, sentinel);

            if (box.await_promise) {
                if (value_opt) |value| {
                    defer ActiveEngine.freeValue(ctx, value);
                    _ = @import("await_promise.zig").Module(Host).attach(state, box.session_id, box.request_id, ctx, value, box.return_by_value, if (box.object_group.len == 0) null else box.object_group);
                } else {
                    sendInvalidParams(state, box.session_id, box.request_id, "awaitPromise requires a Promise result");
                }
                return;
            }

            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"result\":", .{box.request_id}) catch return;

            if (value_opt) |v| {
                defer ActiveEngine.freeValue(ctx, v);
                const group_opt: ?[]const u8 = if (box.object_group.len == 0) null else box.object_group;
                if (box.return_by_value) {
                    writeRemoteObjectByValue(state, ctx, w, v) catch |err| {
                        sendByValueError(state, box.session_id, box.request_id, err);
                        return;
                    };
                } else {
                    writeRemoteObject(state, ctx, w, v, group_opt) catch return;
                }
            } else {
                w.writeAll("{\"type\":\"undefined\"}") catch return;
            }

            w.writeAll("}}") catch return;
            sendJson(state, box.session_id, aw.written());
        }

        // --- Runtime.callFunctionOn -------------------------------------------------

        pub fn handleCallFunctionOn(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            root: std.json.Value,
        ) void {
            const alloc = state.allocator;
            if (root != .object) return;
            const params_val = root.object.get("params") orelse {
                sendInvalidParams(state, session_id, request_id, "missing params");
                return;
            };
            if (params_val != .object) {
                sendInvalidParams(state, session_id, request_id, "params must be object");
                return;
            }

            const decl_val = params_val.object.get("functionDeclaration") orelse {
                sendInvalidParams(state, session_id, request_id, "missing functionDeclaration");
                return;
            };
            if (decl_val != .string) {
                sendInvalidParams(state, session_id, request_id, "functionDeclaration must be string");
                return;
            }

            const expr_copy = alloc.dupe(u8, decl_val.string) catch return;
            var return_by_value = false;
            if (params_val.object.get("returnByValue")) |flag| {
                if (flag != .bool) {
                    alloc.free(expr_copy);
                    sendInvalidParams(state, session_id, request_id, "returnByValue must be boolean");
                    return;
                }
                return_by_value = flag.bool;
            }
            var await_promise = false;
            if (params_val.object.get("awaitPromise")) |flag| {
                if (flag != .bool) {
                    alloc.free(expr_copy);
                    sendInvalidParams(state, session_id, request_id, "awaitPromise must be boolean");
                    return;
                }
                await_promise = flag.bool;
            }

            var group_copy: []u8 = &.{};
            if (params_val.object.get("objectGroup")) |g| {
                if (g == .string and g.string.len != 0) {
                    group_copy = alloc.dupe(u8, g.string) catch {
                        alloc.free(expr_copy);
                        return;
                    };
                }
            }

            var has_this = false;
            var this_id: u64 = 0;
            if (params_val.object.get("objectId")) |oid| {
                if (oid == .string) {
                    if (parseObjectId(oid.string)) |n| {
                        has_this = true;
                        this_id = n;
                    } else {
                        alloc.free(expr_copy);
                        if (group_copy.len != 0) alloc.free(group_copy);
                        sendObjectNotFound(state, session_id, request_id);
                        return;
                    }
                }
            }

            // Parse arguments array.
            var args_list: std.ArrayList(CallArg) = .empty;
            defer args_list.deinit(alloc);
            if (params_val.object.get("arguments")) |av| {
                if (av == .array) {
                    for (av.array.items) |arg_val| {
                        if (arg_val != .object) {
                            args_list.append(alloc, .value_undefined) catch break;
                            continue;
                        }
                        const obj = arg_val.object;
                        if (obj.get("objectId")) |oid| {
                            if (oid == .string) {
                                if (parseObjectId(oid.string)) |n| {
                                    args_list.append(alloc, .{ .object_id = n }) catch break;
                                    continue;
                                }
                            }
                            args_list.append(alloc, .value_undefined) catch break;
                            continue;
                        }
                        if (obj.get("value")) |vv| {
                            switch (vv) {
                                .null => args_list.append(alloc, .value_null) catch break,
                                .bool => |b| args_list.append(alloc, .{ .value_bool = b }) catch break,
                                .integer => |i| args_list.append(alloc, .{ .value_number = @floatFromInt(i) }) catch break,
                                .float => |f| args_list.append(alloc, .{ .value_number = f }) catch break,
                                .string => |s| {
                                    const dup = alloc.dupe(u8, s) catch break;
                                    args_list.append(alloc, .{ .value_string = dup }) catch {
                                        alloc.free(dup);
                                        break;
                                    };
                                },
                                else => args_list.append(alloc, .value_undefined) catch break,
                            }
                        } else {
                            args_list.append(alloc, .value_undefined) catch break;
                        }
                    }
                }
            }
            const args_owned: []CallArg = args_list.toOwnedSlice(alloc) catch blk: {
                const empty: []CallArg = &.{};
                break :blk empty;
            };

            const box = alloc.create(RequestBox) catch {
                alloc.free(expr_copy);
                if (group_copy.len != 0) alloc.free(group_copy);
                for (args_owned) |a| {
                    if (a == .value_string) alloc.free(a.value_string);
                }
                if (args_owned.len != 0) alloc.free(args_owned);
                return;
            };
            box.* = .{
                .state = state,
                .session_id = session_id,
                .request_id = request_id,
                .run_fn = runCallFunctionOn,
                .expression = expr_copy,
                .object_group = group_copy,
                .call_this_id = this_id,
                .call_has_this = has_this,
                .call_args = args_owned,
                .return_by_value = return_by_value,
                .await_promise = await_promise,
            };

            if (!request_box.postJsRequest(state, box)) {
                request_box.freeRequestBox(alloc, box);
                sendEvalException(state, session_id, request_id, "Inspector could not dispatch to JS thread");
            }
        }

        fn runCallFunctionOn(box: *RequestBox, ctx: ActiveEngine.Context) void {
            const state = box.state;

            // Materialise the function via eval into globalThis.<sentinel>.
            const sentinel = "__jsbay_qjs_inspector_call_fn__";
            const wrapped = std.fmt.allocPrint(
                state.allocator,
                "globalThis.{s} = ({s});",
                .{ sentinel, box.expression },
            ) catch {
                sendEvalException(state, box.session_id, box.request_id, "Out of memory building call wrapper");
                return;
            };
            defer state.allocator.free(wrapped);

            const compile_res = engine.evalScript(state.instance_id, wrapped, "<inspector-call>");
            defer {
                if (compile_res.result) |s| std.heap.c_allocator.free(@constCast(s));
                if (compile_res.err_is_heap) {
                    if (compile_res.err) |e| std.heap.c_allocator.free(@constCast(e));
                }
            }
            if (compile_res.err) |emsg| {
                sendEvalException(state, box.session_id, box.request_id, emsg);
                return;
            }

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const fn_val = ActiveEngine.getPropertyVal(ctx, global, sentinel) orelse {
                sendEvalException(state, box.session_id, box.request_id, "functionDeclaration did not evaluate to a function");
                return;
            };
            defer ActiveEngine.freeValue(ctx, fn_val);

            if (!ActiveEngine.isFunction(ctx, fn_val)) {
                sendEvalException(state, box.session_id, box.request_id, "functionDeclaration did not evaluate to a function");
                return;
            }

            // Resolve `this` binding — either the retained target, or globalThis.
            var this_val: ActiveEngine.Value = undefined;
            if (box.call_has_this) {
                this_val = state.object_table.get(box.call_this_id) orelse {
                    sendObjectNotFound(state, box.session_id, box.request_id);
                    return;
                };
            } else {
                this_val = global;
            }

            // Build JS argument array. Each entry owns its ref — freed on scope exit via the deinit loop below.
            var args: std.ArrayList(ActiveEngine.Value) = .empty;
            defer {
                for (args.items) |a| ActiveEngine.freeValue(ctx, a);
                args.deinit(state.allocator);
            }
            var arg_build_failed = false;
            for (box.call_args) |arg| {
                const v: ActiveEngine.Value = switch (arg) {
                    .value_null => ActiveEngine.newNullVal(ctx),
                    .value_undefined => ActiveEngine.newUndefinedVal(ctx),
                    .value_bool => |b| ActiveEngine.newBoolVal(ctx, b),
                    .value_number => |n| ActiveEngine.newFloat64Val(ctx, n),
                    .value_string => |s| ActiveEngine.newStringVal(ctx, s),
                    .object_id => |oid| blk: {
                        const stored = state.object_table.get(oid) orelse {
                            arg_build_failed = true;
                            break :blk ActiveEngine.newUndefinedVal(ctx);
                        };
                        break :blk ActiveEngine.dupValue(ctx, stored);
                    },
                };
                args.append(state.allocator, v) catch {
                    ActiveEngine.freeValue(ctx, v);
                    arg_build_failed = true;
                    break;
                };
            }
            if (arg_build_failed) {
                sendObjectNotFound(state, box.session_id, box.request_id);
                return;
            }

            const result = ActiveEngine.callFunction(ctx, fn_val, this_val, args.items) orelse {
                sendEvalException(state, box.session_id, box.request_id, "Call threw an exception");
                return;
            };
            defer ActiveEngine.freeValue(ctx, result);

            if (box.await_promise) {
                _ = @import("await_promise.zig").Module(Host).attach(state, box.session_id, box.request_id, ctx, result, box.return_by_value, if (box.object_group.len == 0) null else box.object_group);
                return;
            }

            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"result\":", .{box.request_id}) catch return;
            const group_opt: ?[]const u8 = if (box.object_group.len == 0) null else box.object_group;
            if (box.return_by_value) {
                writeRemoteObjectByValue(state, ctx, w, result) catch |err| {
                    sendByValueError(state, box.session_id, box.request_id, err);
                    return;
                };
            } else {
                writeRemoteObject(state, ctx, w, result, group_opt) catch return;
            }
            w.writeAll("}}") catch return;
            sendJson(state, box.session_id, aw.written());
        }

        fn sendByValueError(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64, err: anyerror) void {
            switch (err) {
                error.ByValueCycle, error.ByValueDepth => sendError(state, session_id, request_id, -32000, "Object reference chain is too long"),
                error.UnsupportedByValue => sendError(state, session_id, request_id, -32000, "Object couldn't be returned by value"),
                else => sendError(state, session_id, request_id, -32603, "Internal error"),
            }
        }
    };
}
