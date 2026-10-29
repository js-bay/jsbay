pub fn Module(comptime Host: type) type {
    // Object-table-driven Runtime methods: `Runtime.getProperties`, `Runtime.releaseObject`, `Runtime.releaseObjectGroup`.
    //
    // On QuickJS, `getProperties` follows Chrome: own keys from `Reflect.ownKeys` (non-enumerable names, symbols, and accessors), enumerable names inherited from the prototype chain when `ownProperties` is false, and a synthetic `__proto__` descriptor. Accessors are reported via `get`/`set` and are not invoked. JSC keeps the older `Object.keys` listing so its build stays unchanged. `releaseObject` and `releaseObjectGroup` drop the corresponding entries from the inspector's `ObjectTable`, releasing their JS references.
    //
    // All three marshal to the JS thread via `request_box.postJsRequest` so they can call into the engine context without blocking the reader thread.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const transport_mod = @import("transport.zig");
        const json_writer = @import("json_writer.zig").Module(Host);
        const remote_object = @import("remote_object.zig").Module(Host);
        const request_box = @import("request_box.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);

        const ActiveEngine = backend.ActiveEngine;
        const InspectorState = state_mod.InspectorState;
        const RequestBox = request_box.RequestBox;
        const writeJsonString = json_writer.writeJsonString;
        const sendJson = json_writer.sendJson;
        const sendEmptyResult = json_writer.sendEmptyResult;
        const sendInvalidParams = json_writer.sendInvalidParams;
        const sendObjectNotFound = json_writer.sendObjectNotFound;
        const writeRemoteObject = remote_object.writeRemoteObject;
        const writeRemoteObjectEx = remote_object.writeRemoteObjectEx;
        const parseObjectId = remote_object.parseObjectId;

        // Create a clean realm in the same runtime and retain its reflection methods. Values from a realm in the same QuickJS runtime / JSC context group can be called against the inspected context, while staying outside page control.
        pub fn captureRuntimeIntrinsicsFromFreshRealm(runtime: ActiveEngine.Runtime, state: *InspectorState) bool {
            const ctx = ActiveEngine.newContext(runtime) orelse return false;
            errdefer ActiveEngine.freeContext(ctx);
            captureRuntimeIntrinsics(ctx, state);
            state.runtime_intrinsics_ctx = ctx;
            return true;
        }

        fn captureRuntimeIntrinsics(ctx: ActiveEngine.Context, state: *InspectorState) void {
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);

            if (ActiveEngine.getPropertyVal(ctx, global, "Object")) |object_ctor| {
                state.runtime_object_ctor = object_ctor;
                if (ActiveEngine.getPropertyVal(ctx, object_ctor, "keys")) |keys| state.runtime_object_keys = keys;
                if (ActiveEngine.getPropertyVal(ctx, object_ctor, "getOwnPropertyDescriptor")) |descriptor| {
                    state.runtime_get_own_descriptor = descriptor;
                }
                if (ActiveEngine.getPropertyVal(ctx, object_ctor, "getPrototypeOf")) |prototype| {
                    state.runtime_get_prototype_of = prototype;
                }
                if (ActiveEngine.getPropertyVal(ctx, object_ctor, "prototype")) |prototype| {
                    defer ActiveEngine.freeValue(ctx, prototype);
                    if (ActiveEngine.getPropertyVal(ctx, prototype, "hasOwnProperty")) |has_own| {
                        state.runtime_has_own = has_own;
                    }
                }
            }
            if (ActiveEngine.getPropertyVal(ctx, global, "Reflect")) |reflect| {
                state.runtime_reflect = reflect;
                if (ActiveEngine.getPropertyVal(ctx, reflect, "ownKeys")) |own_keys| {
                    state.runtime_own_keys = own_keys;
                }
                if (ActiveEngine.getPropertyVal(ctx, reflect, "get")) |reflect_get| {
                    state.runtime_reflect_get = reflect_get;
                }
            }
        }

        pub fn releaseRuntimeIntrinsics(ctx: ActiveEngine.Context, state: *InspectorState) void {
            const owner_ctx = state.runtime_intrinsics_ctx orelse ctx;
            inline for (.{
                &state.runtime_object_ctor,
                &state.runtime_reflect,
                &state.runtime_object_keys,
                &state.runtime_own_keys,
                &state.runtime_reflect_get,
                &state.runtime_has_own,
                &state.runtime_get_own_descriptor,
                &state.runtime_get_prototype_of,
            }) |slot| {
                if (slot.*) |value| ActiveEngine.freeValue(owner_ctx, value);
                slot.* = null;
            }
            if (state.runtime_intrinsics_ctx) |capture_ctx| {
                state.runtime_intrinsics_ctx = null;
                ActiveEngine.freeContext(capture_ctx);
            }
        }

        // --- Runtime.getProperties --------------------------------------------------

        pub fn handleGetProperties(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            root: std.json.Value,
        ) void {
            if (root != .object) return;
            const params_val = root.object.get("params") orelse {
                sendInvalidParams(state, session_id, request_id, "missing params");
                return;
            };
            if (params_val != .object) {
                sendInvalidParams(state, session_id, request_id, "params must be object");
                return;
            }

            const obj_id_val = params_val.object.get("objectId") orelse {
                sendInvalidParams(state, session_id, request_id, "missing objectId");
                return;
            };
            if (obj_id_val != .string) {
                sendInvalidParams(state, session_id, request_id, "objectId must be string");
                return;
            }
            const obj_id = parseObjectId(obj_id_val.string) orelse {
                sendObjectNotFound(state, session_id, request_id);
                return;
            };

            var own_properties = true;
            if (params_val.object.get("ownProperties")) |o| {
                if (o == .bool) own_properties = o.bool;
            }
            var accessor_properties_only = false;
            if (params_val.object.get("accessorPropertiesOnly")) |o| {
                if (o == .bool) accessor_properties_only = o.bool;
            }
            var generate_preview = false;
            if (params_val.object.get("generatePreview")) |o| {
                if (o == .bool) generate_preview = o.bool;
            }
            var non_indexed_properties_only = false;
            if (params_val.object.get("nonIndexedPropertiesOnly")) |o| {
                if (o == .bool) non_indexed_properties_only = o.bool;
            }

            const alloc = state.allocator;
            const box = alloc.create(RequestBox) catch return;
            box.* = .{
                .state = state,
                .session_id = session_id,
                .request_id = request_id,
                .run_fn = if (comptime backend.isQuickJsApiBackend(backend.active_backend))
                    runGetPropertiesWithDescriptors
                else
                    runGetPropertiesOwnEnumerable,
                .object_id = obj_id,
                .own_properties = own_properties,
                .accessor_properties_only = accessor_properties_only,
                .generate_preview = generate_preview,
                .non_indexed_properties_only = non_indexed_properties_only,
            };

            if (!request_box.postJsRequest(state, box)) {
                request_box.freeRequestBox(alloc, box);
                sendInvalidParams(state, session_id, request_id, "could not dispatch to JS thread");
            }
        }

        fn runGetPropertiesOwnEnumerable(box: *RequestBox, ctx: ActiveEngine.Context) void {
            const state = box.state;
            const target = state.object_table.get(box.object_id) orelse {
                sendObjectNotFound(state, box.session_id, box.request_id);
                return;
            };

            // Fetch Object.keys(target) via callFunction so both backends share OwnEnumerableStringProperties semantics.
            const object_ctor = state.runtime_object_ctor orelse {
                sendInvalidParams(state, box.session_id, box.request_id, "no Object constructor");
                return;
            };
            const keys_fn = state.runtime_object_keys orelse {
                sendInvalidParams(state, box.session_id, box.request_id, "no Object.keys");
                return;
            };

            const keys_args = [_]ActiveEngine.Value{target};
            const keys_arr = ActiveEngine.callFunction(ctx, keys_fn, object_ctor, &keys_args) orelse {
                sendInvalidParams(state, box.session_id, box.request_id, "Object.keys threw");
                return;
            };
            defer ActiveEngine.freeValue(ctx, keys_arr);

            const len = ActiveEngine.getLength(ctx, keys_arr) orelse 0;

            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"result\":[", .{box.request_id}) catch return;

            var i: u32 = 0;
            var wrote_one = false;
            while (i < len) : (i += 1) {
                const key_val = ActiveEngine.getIndex(ctx, keys_arr, i) orelse continue;
                defer ActiveEngine.freeValue(ctx, key_val);
                const key_str = ActiveEngine.valueToStringVal(ctx, key_val) orelse continue;
                defer std.heap.c_allocator.free(@constCast(key_str));

                // Fetch value. Key isn't necessarily NUL-terminated, so copy.
                const kz = std.heap.c_allocator.dupeSentinel(u8, key_str, 0) catch continue;
                defer std.heap.c_allocator.free(kz);
                const prop_val_opt = ActiveEngine.getPropertyVal(ctx, target, kz.ptr);

                if (wrote_one) w.writeAll(",") catch return;
                wrote_one = true;

                w.writeAll("{\"name\":") catch return;
                writeJsonString(w, key_str) catch return;
                w.writeAll(",\"value\":") catch return;
                if (prop_val_opt) |pv| {
                    defer ActiveEngine.freeValue(ctx, pv);
                    writeRemoteObject(state, ctx, w, pv, null) catch return;
                } else {
                    w.writeAll("{\"type\":\"undefined\"}") catch return;
                }
                w.writeAll(",\"writable\":true,\"enumerable\":true,\"configurable\":true,\"isOwn\":true}") catch return;
            }

            _ = box.own_properties; // prototype-chain walk intentionally skipped for JSC.

            w.writeAll("],\"internalProperties\":[]}}") catch return;
            sendJson(state, box.session_id, aw.written());
        }

        fn callObject(
            ctx: ActiveEngine.Context,
            func: ActiveEngine.Value,
            this_obj: ActiveEngine.Value,
            args: []const ActiveEngine.Value,
        ) ?ActiveEngine.Value {
            return ActiveEngine.callFunction(ctx, func, this_obj, args) orelse {
                if (ActiveEngine.getAndFormatException(ctx)) |msg| {
                    std.heap.c_allocator.free(@constCast(msg));
                }
                return null;
            };
        }

        fn descriptorBool(ctx: ActiveEngine.Context, obj: ActiveEngine.Value, name: [*:0]const u8, default: bool) bool {
            const v = ActiveEngine.getPropertyVal(ctx, obj, name) orelse return default;
            defer ActiveEngine.freeValue(ctx, v);
            return ActiveEngine.toBool(ctx, v) orelse default;
        }

        fn rememberPropertyName(alloc: std.mem.Allocator, seen: *std.StringHashMap(void), name: []const u8) void {
            if (seen.contains(name)) return;
            const copy = alloc.dupe(u8, name) catch return;
            seen.put(copy, {}) catch alloc.free(copy);
        }

        const PropertyQuery = struct {
            accessor_only: bool,
            preview: bool,
            non_indexed: bool,
        };

        // ECMAScript canonical numeric index is [0, 2^32 - 2].
        const max_array_index: u32 = std.math.maxInt(u32) - 1;
        const max_array_index_digits: usize = blk: {
            var n: u32 = max_array_index;
            var digits: usize = 1;
            while (n >= 10) {
                n /= 10;
                digits += 1;
            }
            break :blk digits;
        };

        fn isCanonicalIndex(name: []const u8) bool {
            if (name.len == 0 or name.len > max_array_index_digits) return false;
            if (name[0] == '0') return name.len == 1;
            for (name) |ch| {
                if (ch < '0' or ch > '9') return false;
            }
            const n = std.fmt.parseInt(u32, name, 10) catch return false;
            return n <= max_array_index;
        }

        // `ToString` throws on a symbol. Use the `description` slot instead.
        fn symbolName(ctx: ActiveEngine.Context, key: ActiveEngine.Value, symbol: bool) ?[]u8 {
            if (!symbol) {
                const s = ActiveEngine.valueToStringVal(ctx, key) orelse return null;
                defer std.heap.c_allocator.free(@constCast(s));
                return std.heap.c_allocator.dupe(u8, s) catch null;
            }
            const desc = ActiveEngine.getPropertyVal(ctx, key, "description");
            defer if (desc) |d| ActiveEngine.freeValue(ctx, d);
            if (desc) |d| {
                if (ActiveEngine.valueToStringVal(ctx, d)) |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    return std.fmt.allocPrint(std.heap.c_allocator, "Symbol({s})", .{s}) catch null;
                }
            }
            return std.heap.c_allocator.dupe(u8, "Symbol()") catch null;
        }

        fn isSymbolValue(value: ActiveEngine.Value) bool {
            if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return false;
            const qjs = Host.backend.ActiveEngineModule.c_api.qjs;
            return value.tag == qjs.JS_TAG_SYMBOL;
        }

        fn descriptorOwns(
            ctx: ActiveEngine.Context,
            hop: ActiveEngine.Value,
            desc: ActiveEngine.Value,
            name: [:0]const u8,
        ) bool {
            const key = ActiveEngine.newStringVal(ctx, name);
            defer ActiveEngine.freeValue(ctx, key);
            const args = [_]ActiveEngine.Value{key};
            const result = callObject(ctx, hop, desc, &args) orelse return false;
            defer ActiveEngine.freeValue(ctx, result);
            return ActiveEngine.toBool(ctx, result) orelse false;
        }

        // Emit own or inherited properties for one object on the chain. Accessors contribute `get`/`set` and are not called. A descriptor whose getter and setter are both `undefined` stays an accessor.
        fn appendDescriptorProperties(
            state: *InspectorState,
            ctx: ActiveEngine.Context,
            w: anytype,
            wrote: *bool,
            seen: *std.StringHashMap(void),
            object_ctor: ActiveEngine.Value,
            desc_fn: ActiveEngine.Value,
            hop: ActiveEngine.Value,
            obj: ActiveEngine.Value,
            names: ActiveEngine.Value,
            is_own: bool,
            query: PropertyQuery,
        ) !void {
            const len = ActiveEngine.getLength(ctx, names) orelse 0;
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const key_val = ActiveEngine.getIndex(ctx, names, i) orelse continue;
                defer ActiveEngine.freeValue(ctx, key_val);
                const symbol = isSymbolValue(key_val);
                const key_owned = symbolName(ctx, key_val, symbol) orelse continue;
                defer std.heap.c_allocator.free(key_owned);
                const key_str = key_owned;
                if (seen.contains(key_str)) continue;
                if (!symbol and query.non_indexed and isCanonicalIndex(key_str)) {
                    rememberPropertyName(state.allocator, seen, key_str);
                    continue;
                }

                const desc_args = [_]ActiveEngine.Value{ obj, key_val };
                const desc = callObject(ctx, desc_fn, object_ctor, &desc_args) orelse {
                    rememberPropertyName(state.allocator, seen, key_str);
                    if (wrote.*) try w.writeAll(",");
                    wrote.* = true;
                    try w.writeAll("{\"name\":");
                    try writeJsonString(w, key_str);
                    if (symbol) {
                        try w.writeAll(",\"symbol\":{\"type\":\"symbol\",\"description\":");
                        try writeJsonString(w, key_str);
                        try w.writeByte('}');
                    }
                    try w.writeAll(",\"wasThrown\":true,\"enumerable\":false,\"configurable\":false,\"isOwn\":");
                    try w.writeAll(if (is_own) "true}" else "false}");
                    continue;
                };
                defer ActiveEngine.freeValue(ctx, desc);
                if (!ActiveEngine.isObjectVal(ctx, desc)) continue;

                const enumerable = descriptorBool(ctx, desc, "enumerable", false);
                const configurable = descriptorBool(ctx, desc, "configurable", false);
                const owns_get = descriptorOwns(ctx, hop, desc, "get");
                const owns_set = descriptorOwns(ctx, hop, desc, "set");
                const is_accessor = owns_get or owns_set;
                const get_v = if (owns_get) ActiveEngine.getPropertyVal(ctx, desc, "get") else null;
                defer if (get_v) |v| ActiveEngine.freeValue(ctx, v);
                const set_v = if (owns_set) ActiveEngine.getPropertyVal(ctx, desc, "set") else null;
                defer if (set_v) |v| ActiveEngine.freeValue(ctx, v);

                // A non-enumerable name on a prototype still hides the same name further up the chain, matching for-in.
                if (!is_own and !enumerable) {
                    rememberPropertyName(state.allocator, seen, key_str);
                    continue;
                }
                if (query.accessor_only and !is_accessor) {
                    rememberPropertyName(state.allocator, seen, key_str);
                    continue;
                }
                rememberPropertyName(state.allocator, seen, key_str);

                if (wrote.*) try w.writeAll(",");
                wrote.* = true;
                try w.writeAll("{\"name\":");
                try writeJsonString(w, key_str);
                if (symbol) {
                    try w.writeAll(",\"symbol\":{\"type\":\"symbol\",\"description\":");
                    try writeJsonString(w, key_str);
                    try w.writeByte('}');
                }

                if (is_accessor) {
                    if (owns_get) {
                        try w.writeAll(",\"get\":");
                        if (get_v) |g| {
                            try writeRemoteObjectEx(state, ctx, w, g, null, query.preview);
                        } else {
                            try w.writeAll("{\"type\":\"undefined\"}");
                        }
                    }
                    if (owns_set) {
                        try w.writeAll(",\"set\":");
                        if (set_v) |s| {
                            try writeRemoteObjectEx(state, ctx, w, s, null, query.preview);
                        } else {
                            try w.writeAll("{\"type\":\"undefined\"}");
                        }
                    }
                } else {
                    const value_v = ActiveEngine.getPropertyVal(ctx, desc, "value");
                    defer if (value_v) |v| ActiveEngine.freeValue(ctx, v);
                    const writable = descriptorBool(ctx, desc, "writable", false);
                    try w.writeAll(",\"value\":");
                    if (value_v) |pv| {
                        try writeRemoteObjectEx(state, ctx, w, pv, null, query.preview);
                    } else {
                        try w.writeAll("{\"type\":\"undefined\"}");
                    }
                    try w.writeAll(",\"writable\":");
                    try w.writeAll(if (writable) "true" else "false");
                }

                try w.writeAll(",\"enumerable\":");
                try w.writeAll(if (enumerable) "true" else "false");
                try w.writeAll(",\"configurable\":");
                try w.writeAll(if (configurable) "true" else "false");
                try w.writeAll(",\"isOwn\":");
                try w.writeAll(if (is_own) "true" else "false");
                try w.writeAll("}");
            }
        }

        fn writeProtoDescriptor(
            state: *InspectorState,
            ctx: ActiveEngine.Context,
            w: anytype,
            wrote: *bool,
            proto_fn: ActiveEngine.Value,
            object_ctor: ActiveEngine.Value,
            target: ActiveEngine.Value,
            preview: bool,
        ) !void {
            const args = [_]ActiveEngine.Value{target};
            const proto = callObject(ctx, proto_fn, object_ctor, &args) orelse return;
            defer ActiveEngine.freeValue(ctx, proto);
            var writable = true;
            if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                const qjs = backend.ActiveEngineModule.qjs;
                const object_proto = qjs.JS_GetPropertyStr(ctx, object_ctor, "prototype");
                defer qjs.JS_FreeValue(ctx, object_proto);
                const same = backend.ActiveEngine.sameValue(ctx, target, object_proto);
                const ext = qjs.JS_IsExtensible(ctx, target);
                writable = ext == 1 and !same;
            }
            if (wrote.*) try w.writeAll(",");
            wrote.* = true;
            // Chrome's default getProperties reply always includes this synthetic descriptor, including when ownProperties is true. It is not the Object.prototype.__proto__ accessor and it is not invoked.
            try w.writeAll("{\"name\":\"__proto__\",\"value\":");
            try writeRemoteObjectEx(state, ctx, w, proto, null, preview);
            try w.writeAll(",\"writable\":");
            try w.writeAll(if (writable) "true" else "false");
            try w.writeAll(",\"enumerable\":false,\"configurable\":true,\"isOwn\":true}");
        }

        // Writes the elements of `internalProperties` only. The caller owns the surrounding `],"internalProperties":[` ... `]}}` envelope.
        fn writeInternalProperties(
            state: *InspectorState,
            ctx: ActiveEngine.Context,
            w: anytype,
            target: ActiveEngine.Value,
            preview: bool,
        ) !void {
            if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
            const qjs = Host.backend.ActiveEngineModule.c_api.qjs;
            if (Host.backend.ActiveEngineModule.c_api.jsbay_qjs_JS_IsPromise(ctx, target) != 0) {
                const st = qjs.JS_PromiseState(ctx, target);
                const label: []const u8 = if (st == qjs.JS_PROMISE_FULFILLED)
                    "fulfilled"
                else if (st == qjs.JS_PROMISE_REJECTED)
                    "rejected"
                else
                    "pending";
                try w.writeAll("{\"name\":\"[[PromiseState]]\",\"value\":{\"type\":\"string\",\"value\":");
                try writeJsonString(w, label);
                try w.writeAll("}}");
                if (st == qjs.JS_PROMISE_FULFILLED or st == qjs.JS_PROMISE_REJECTED) {
                    const result = qjs.JS_PromiseResult(ctx, target);
                    defer qjs.JS_FreeValue(ctx, result);
                    try w.writeAll(",{\"name\":\"[[PromiseResult]]\",\"value\":");
                    try writeRemoteObjectEx(state, ctx, w, result, null, preview);
                    try w.writeAll("}");
                }
            }
        }

        fn runGetPropertiesWithDescriptors(box: *RequestBox, ctx: ActiveEngine.Context) void {
            const state = box.state;
            const target = state.object_table.get(box.object_id) orelse {
                sendObjectNotFound(state, box.session_id, box.request_id);
                return;
            };

            const object_ctor = state.runtime_object_ctor orelse {
                sendInvalidParams(state, box.session_id, box.request_id, "no Object constructor");
                return;
            };
            const reflect = state.runtime_reflect orelse {
                sendInvalidParams(state, box.session_id, box.request_id, "no Reflect");
                return;
            };
            const names_fn = state.runtime_own_keys orelse {
                sendInvalidParams(state, box.session_id, box.request_id, "no Reflect.ownKeys");
                return;
            };
            const hop = state.runtime_has_own orelse {
                sendInvalidParams(state, box.session_id, box.request_id, "no hasOwnProperty");
                return;
            };
            const desc_fn = state.runtime_get_own_descriptor orelse {
                sendInvalidParams(state, box.session_id, box.request_id, "no Object.getOwnPropertyDescriptor");
                return;
            };
            const proto_fn = state.runtime_get_prototype_of orelse {
                sendInvalidParams(state, box.session_id, box.request_id, "no Object.getPrototypeOf");
                return;
            };

            var current = ActiveEngine.dupValue(ctx, target);
            defer ActiveEngine.freeValue(ctx, current);

            var seen = std.StringHashMap(void).init(state.allocator);
            defer {
                var it = seen.iterator();
                while (it.next()) |kv| state.allocator.free(kv.key_ptr.*);
                seen.deinit();
            }

            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"result\":[", .{box.request_id}) catch return;
            var wrote_one = false;

            // ownProperties true: stop after the object itself. false: also walk enumerable prototype names. __proto__ is appended either way.
            var depth: u32 = 0;
            while (depth < 64) : (depth += 1) {
                if (ActiveEngine.isNull(ctx, current) or ActiveEngine.isUndefined(ctx, current)) break;
                if (!ActiveEngine.isObjectVal(ctx, current)) break;

                const name_args = [_]ActiveEngine.Value{current};
                const names = callObject(ctx, names_fn, reflect, &name_args) orelse {
                    if (depth == 0) {
                        sendInvalidParams(state, box.session_id, box.request_id, "Reflect.ownKeys threw");
                        return;
                    }
                    break;
                };
                defer ActiveEngine.freeValue(ctx, names);

                appendDescriptorProperties(
                    state,
                    ctx,
                    w,
                    &wrote_one,
                    &seen,
                    object_ctor,
                    desc_fn,
                    hop,
                    current,
                    names,
                    depth == 0,
                    .{
                        .accessor_only = box.accessor_properties_only,
                        .preview = box.generate_preview,
                        .non_indexed = box.non_indexed_properties_only,
                    },
                ) catch return;

                if (box.own_properties) break;

                const next_args = [_]ActiveEngine.Value{current};
                const next = callObject(ctx, proto_fn, object_ctor, &next_args) orelse break;
                if (ActiveEngine.isNull(ctx, next) or ActiveEngine.isUndefined(ctx, next) or !ActiveEngine.isObjectVal(ctx, next)) {
                    ActiveEngine.freeValue(ctx, next);
                    break;
                }
                ActiveEngine.freeValue(ctx, current);
                current = next;
            }

            writeProtoDescriptor(state, ctx, w, &wrote_one, proto_fn, object_ctor, target, box.generate_preview) catch return;

            w.writeAll("],\"internalProperties\":[") catch return;
            writeInternalProperties(state, ctx, w, target, box.generate_preview) catch return;
            w.writeAll("]}}") catch return;
            sendJson(state, box.session_id, aw.written());
        }

        // --- Runtime.releaseObject / releaseObjectGroup -----------------------------

        pub fn handleReleaseObject(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            root: std.json.Value,
        ) void {
            if (root != .object) return;
            const params_val = root.object.get("params") orelse {
                sendEmptyResult(state, session_id, request_id);
                return;
            };
            if (params_val != .object) {
                sendEmptyResult(state, session_id, request_id);
                return;
            }
            const obj_id_val = params_val.object.get("objectId") orelse {
                sendEmptyResult(state, session_id, request_id);
                return;
            };
            if (obj_id_val != .string) {
                sendEmptyResult(state, session_id, request_id);
                return;
            }
            const obj_id = parseObjectId(obj_id_val.string) orelse {
                // Unparseable id — release is idempotent, reply empty.
                sendEmptyResult(state, session_id, request_id);
                return;
            };

            const alloc = state.allocator;
            const box = alloc.create(RequestBox) catch {
                sendEmptyResult(state, session_id, request_id);
                return;
            };
            box.* = .{
                .state = state,
                .session_id = session_id,
                .request_id = request_id,
                .run_fn = runReleaseObject,
                .object_id = obj_id,
            };
            if (!request_box.postJsRequest(state, box)) {
                request_box.freeRequestBox(alloc, box);
                sendEmptyResult(state, session_id, request_id);
            }
        }

        fn runReleaseObject(box: *RequestBox, ctx: ActiveEngine.Context) void {
            _ = box.state.object_table.release(ctx, box.object_id);
            sendEmptyResult(box.state, box.session_id, box.request_id);
        }

        pub fn handleReleaseObjectGroup(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            root: std.json.Value,
        ) void {
            if (root != .object) return;
            const params_val = root.object.get("params") orelse {
                sendEmptyResult(state, session_id, request_id);
                return;
            };
            if (params_val != .object) {
                sendEmptyResult(state, session_id, request_id);
                return;
            }
            const name_val = params_val.object.get("objectGroup") orelse {
                sendEmptyResult(state, session_id, request_id);
                return;
            };
            if (name_val != .string or name_val.string.len == 0) {
                sendEmptyResult(state, session_id, request_id);
                return;
            }

            const alloc = state.allocator;
            const name_copy = alloc.dupe(u8, name_val.string) catch {
                sendEmptyResult(state, session_id, request_id);
                return;
            };
            const box = alloc.create(RequestBox) catch {
                alloc.free(name_copy);
                sendEmptyResult(state, session_id, request_id);
                return;
            };
            box.* = .{
                .state = state,
                .session_id = session_id,
                .request_id = request_id,
                .run_fn = runReleaseObjectGroup,
                .group_name = name_copy,
            };
            if (!request_box.postJsRequest(state, box)) {
                request_box.freeRequestBox(alloc, box);
                sendEmptyResult(state, session_id, request_id);
            }
        }

        fn runReleaseObjectGroup(box: *RequestBox, ctx: ActiveEngine.Context) void {
            _ = box.state.object_table.releaseGroup(ctx, box.group_name);
            sendEmptyResult(box.state, box.session_id, box.request_id);
        }
    };
}
