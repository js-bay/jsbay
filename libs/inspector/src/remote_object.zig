pub fn Module(comptime Host: type) type {
    // CDP `RemoteObject` serializer + helpers shared across Runtime handlers.
    //
    // `writeRemoteObject` is the canonical serializer for any JS Value crossing the CDP boundary. Primitives (undefined / null / bool / number / string) are inlined; non-primitives are retained in the `ObjectTable` and tagged with an objectId DevTools can later pass to `Runtime.getProperties` / `Runtime.callFunctionOn` / `Runtime.releaseObject`.
    //
    // Also exposes a couple of small helpers that don't fit elsewhere:
    // - `sendEvalException` / `sendSimpleRemoteObject` for fixed-shape replies built around a RemoteObject.
    // - `parseObjectId` to turn the string objectIds DevTools sends back into our internal u64.
    // - `buildEvalScript` to wrap a user expression in a sentinel-assignment so we can recover the raw Value after `engine.evalScript` runs.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const transport_mod = @import("transport.zig");
        const json_writer = @import("json_writer.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);

        const ActiveEngine = backend.ActiveEngine;
        const InspectorState = state_mod.InspectorState;
        const writeJsonString = json_writer.writeJsonString;
        const sendJson = json_writer.sendJson;

        pub fn parseObjectId(s: []const u8) ?u64 {
            return std.fmt.parseInt(u64, s, 10) catch null;
        }

        // Produce `globalThis.<sentinel> = (0, eval)("<json-escaped expr>"); void 0;`. Indirect eval runs the source in the global (top-level) scope, so statements and expressions behave the same as if typed at the REPL. The final `void 0` prevents the engine.evalScript reporting path from JSON-stringifying the assigned object (which would call user `toJSON`) before the raw sentinel is serialized for CDP.
        pub fn buildEvalScript(alloc: std.mem.Allocator, sentinel: []const u8, expr: []const u8) ![]u8 {
            var aw: std.Io.Writer.Allocating = .init(alloc);
            errdefer aw.deinit();
            const w = &aw.writer;
            try w.writeAll("globalThis.");
            try w.writeAll(sentinel);
            try w.writeAll(" = (0, eval)(");
            try writeJsonString(w, expr);
            try w.writeAll("); void 0;");
            var list = aw.toArrayList();
            return list.toOwnedSlice(alloc);
        }

        pub const SimpleRemote = enum { undefined_ };

        pub fn sendSimpleRemoteObject(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            kind: SimpleRemote,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"result\":", .{request_id}) catch return;
            switch (kind) {
                .undefined_ => w.writeAll("{\"type\":\"undefined\"}") catch return,
            }
            w.writeAll("}}") catch return;
            sendJson(state, session_id, aw.written());
        }

        // Emit a CDP `RemoteObject` JSON fragment for `value` at the writer's current position. Primitives are inlined; non-primitives are retained in the ObjectTable and tagged with an objectId the client can later pass to getProperties/callFunctionOn/releaseObject.
        pub fn writeRemoteObject(
            state: *InspectorState,
            ctx: ActiveEngine.Context,
            writer: anytype,
            value: ActiveEngine.Value,
            object_group: ?[]const u8,
        ) !void {
            try writeRemoteObjectEx(state, ctx, writer, value, object_group, false);
        }

        // Serialize a Runtime evaluation result without retaining a remote object. The recursive payload deliberately uses the creation-time Object.keys intrinsic stored on InspectorState: user code can replace global helpers, and JSON.stringify would incorrectly call toJSON.
        pub fn writeRemoteObjectByValue(
            state: *InspectorState,
            ctx: ActiveEngine.Context,
            writer: anytype,
            value: ActiveEngine.Value,
        ) !void {
            if (isSymbolByValue(ctx, value)) return error.UnsupportedByValue;
            if (ActiveEngine.isBigInt(ctx, value)) {
                const digits = ActiveEngine.valueToStringVal(ctx, value) orelse return error.InternalByValue;
                defer std.heap.c_allocator.free(@constCast(digits));
                try writer.writeAll("{\"type\":\"bigint\",\"unserializableValue\":");
                try writeBigIntText(writer, digits);
                try writer.writeAll(",\"description\":");
                try writeBigIntText(writer, digits);
                try writer.writeByte('}');
                return;
            }
            if (ActiveEngine.isNumber(ctx, value)) {
                const n = ActiveEngine.toFloat64(ctx, value) orelse return error.UnsupportedByValue;
                if (n == 0 and std.math.signbit(n)) {
                    try writer.writeAll("{\"type\":\"number\",\"unserializableValue\":\"-0\",\"description\":\"-0\"}");
                    return;
                }
            }
            if (!ActiveEngine.isObjectVal(ctx, value) and !ActiveEngine.isFunction(ctx, value)) {
                try writeRemoteObject(state, ctx, writer, value, null);
                return;
            }

            try writer.writeAll(if (ActiveEngine.isFunction(ctx, value)) "{\"type\":\"function\",\"value\":" else "{\"type\":\"object\",\"value\":");
            try writeByValueJson(state, ctx, writer, value);
            try writer.writeByte('}');
        }

        const by_value_depth_limit = 1000;

        const ByValueFrame = struct {
            value: ActiveEngine.Value,
            depth: usize,
            node: union(enum) {
                enter,
                array: struct {
                    next: u32,
                    len: u32,
                },
                object: struct {
                    keys: ActiveEngine.Value,
                    next: u32,
                    len: u32,
                    wrote_one: bool,
                },
            } = .enter,
        };

        fn writeByValueJson(
            state: *InspectorState,
            ctx: ActiveEngine.Context,
            writer: anytype,
            value: ActiveEngine.Value,
        ) !void {
            var frames: std.ArrayList(ByValueFrame) = .empty;
            defer {
                while (frames.items.len != 0) freeByValueFrame(ctx, frames.pop().?);
                frames.deinit(state.allocator);
            }
            const root = ActiveEngine.dupValue(ctx, value);
            frames.append(state.allocator, .{ .value = root, .depth = 0 }) catch |err| {
                ActiveEngine.freeValue(ctx, root);
                return err;
            };

            while (frames.items.len != 0) {
                const top = frames.items.len - 1;
                switch (frames.items[top].node) {
                    .enter => {
                        const frame_value = frames.items[top].value;
                        const depth = frames.items[top].depth;
                        // V8 counts every protocol value in the chain, including primitive leaves.
                        if (depth >= by_value_depth_limit) return error.ByValueDepth;
                        if (ActiveEngine.isUndefined(ctx, frame_value) or ActiveEngine.isNull(ctx, frame_value)) {
                            try writer.writeAll("null");
                            freeByValueFrame(ctx, frames.pop().?);
                            continue;
                        }
                        if (ActiveEngine.isBool(ctx, frame_value)) {
                            try writer.writeAll(if (ActiveEngine.toBool(ctx, frame_value) orelse false) "true" else "false");
                            freeByValueFrame(ctx, frames.pop().?);
                            continue;
                        }
                        if (ActiveEngine.isNumber(ctx, frame_value)) {
                            const n = ActiveEngine.toFloat64(ctx, frame_value) orelse return error.UnsupportedByValue;
                            if (!std.math.isFinite(n)) {
                                try writer.writeAll("null");
                            } else if (n == 0) {
                                try writer.writeByte('0');
                            } else {
                                try writer.print("{d}", .{n});
                            }
                            freeByValueFrame(ctx, frames.pop().?);
                            continue;
                        }
                        if (ActiveEngine.isString(ctx, frame_value)) {
                            const text = ActiveEngine.valueToStringVal(ctx, frame_value) orelse return error.InternalByValue;
                            defer std.heap.c_allocator.free(@constCast(text));
                            try writeJsonString(writer, text);
                            freeByValueFrame(ctx, frames.pop().?);
                            continue;
                        }
                        if (!ActiveEngine.isObjectVal(ctx, frame_value) and !ActiveEngine.isFunction(ctx, frame_value)) return error.UnsupportedByValue;
                        for (frames.items[0..top]) |ancestor| {
                            switch (ancestor.node) {
                                .array, .object => if (ActiveEngine.sameValue(ctx, ancestor.value, frame_value)) return error.ByValueCycle,
                                .enter => {},
                            }
                        }

                        if (ActiveEngine.isArray(ctx, frame_value)) {
                            const len = ActiveEngine.getLength(ctx, frame_value) orelse return error.InternalByValue;
                            try writer.writeByte('[');
                            frames.items[top].node = .{ .array = .{ .next = 0, .len = len } };
                            continue;
                        }

                        const object_ctor = state.runtime_object_ctor orelse return error.InternalByValue;
                        const keys_fn = state.runtime_object_keys orelse return error.InternalByValue;
                        const args = [_]ActiveEngine.Value{frame_value};
                        const keys_and_len = blk: {
                            const keys = ActiveEngine.callFunction(ctx, keys_fn, object_ctor, &args) orelse {
                                clearByValueException(ctx);
                                return error.InternalByValue;
                            };
                            errdefer ActiveEngine.freeValue(ctx, keys);
                            const len = ActiveEngine.getLength(ctx, keys) orelse return error.InternalByValue;
                            try writer.writeByte('{');
                            break :blk .{ .keys = keys, .len = len };
                        };
                        frames.items[top].node = .{ .object = .{ .keys = keys_and_len.keys, .next = 0, .len = keys_and_len.len, .wrote_one = false } };
                    },
                    .array => |array| {
                        if (array.next == array.len) {
                            try writer.writeByte(']');
                            freeByValueFrame(ctx, frames.pop().?);
                            continue;
                        }
                        if (array.next != 0) try writer.writeByte(',');
                        const parent_value = frames.items[top].value;
                        const child_depth = frames.items[top].depth + 1;
                        const index = ActiveEngine.newFloat64Val(ctx, @floatFromInt(array.next));
                        defer ActiveEngine.freeValue(ctx, index);
                        const reflect = state.runtime_reflect orelse return error.InternalByValue;
                        const reflect_get = state.runtime_reflect_get orelse return error.InternalByValue;
                        const get_args = [_]ActiveEngine.Value{ parent_value, index };
                        const child = ActiveEngine.callFunction(ctx, reflect_get, reflect, &get_args) orelse {
                            clearByValueException(ctx);
                            return error.InternalByValue;
                        };
                        frames.items[top].node.array.next += 1;
                        frames.append(state.allocator, .{ .value = child, .depth = child_depth }) catch |err| {
                            ActiveEngine.freeValue(ctx, child);
                            return err;
                        };
                    },
                    .object => |object| {
                        if (object.next == object.len) {
                            try writer.writeByte('}');
                            freeByValueFrame(ctx, frames.pop().?);
                            continue;
                        }
                        const parent_value = frames.items[top].value;
                        const child_depth = frames.items[top].depth + 1;
                        const key_value = ActiveEngine.getIndex(ctx, object.keys, object.next) orelse return error.InternalByValue;
                        defer ActiveEngine.freeValue(ctx, key_value);
                        const key = ActiveEngine.valueToStringVal(ctx, key_value) orelse return error.InternalByValue;
                        defer std.heap.c_allocator.free(@constCast(key));
                        const reflect = state.runtime_reflect orelse return error.InternalByValue;
                        const reflect_get = state.runtime_reflect_get orelse return error.InternalByValue;
                        const get_args = [_]ActiveEngine.Value{ parent_value, key_value };
                        const child = ActiveEngine.callFunction(ctx, reflect_get, reflect, &get_args) orelse {
                            clearByValueException(ctx);
                            return error.InternalByValue;
                        };
                        frames.items[top].node.object.next += 1;
                        // Object properties whose value is undefined are omitted by CDP's value serializer. Array slots take the separate null path above.
                        if (ActiveEngine.isUndefined(ctx, child)) {
                            ActiveEngine.freeValue(ctx, child);
                            continue;
                        }
                        {
                            errdefer ActiveEngine.freeValue(ctx, child);
                            if (frames.items[top].node.object.wrote_one) try writer.writeByte(',');
                            frames.items[top].node.object.wrote_one = true;
                            try writeJsonString(writer, key);
                            try writer.writeByte(':');
                            try frames.append(state.allocator, .{ .value = child, .depth = child_depth });
                        }
                    },
                }
            }
        }

        fn freeByValueFrame(ctx: ActiveEngine.Context, frame: ByValueFrame) void {
            switch (frame.node) {
                .object => |object| ActiveEngine.freeValue(ctx, object.keys),
                else => {},
            }
            ActiveEngine.freeValue(ctx, frame.value);
        }

        fn isSymbolByValue(ctx: ActiveEngine.Context, value: ActiveEngine.Value) bool {
            if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                const qjs = backend.ActiveEngineModule.c_api.qjs;
                return value.tag == qjs.JS_TAG_SYMBOL;
            }
            return backend.ActiveEngineModule.jsc.JSValueIsSymbol(@ptrCast(ctx), value);
        }

        fn writeBigIntText(writer: anytype, digits: []const u8) !void {
            try writer.writeByte('"');
            try writer.writeAll(digits);
            try writer.writeAll("n\"");
        }

        fn clearByValueException(ctx: ActiveEngine.Context) void {
            if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                if (ActiveEngine.getAndFormatException(ctx)) |message| std.heap.c_allocator.free(@constCast(message));
            }
        }

        // `preview` adds a shallow CDP `preview` for objects and arrays. Accessors are not invoked. Nested objects are described by type only.
        pub fn writeRemoteObjectEx(
            state: *InspectorState,
            ctx: ActiveEngine.Context,
            writer: anytype,
            value: ActiveEngine.Value,
            object_group: ?[]const u8,
            preview: bool,
        ) !void {
            try writeRemoteObjectOwned(state, ctx, writer, value, object_group, preview, false);
        }

        // Console-only serializer. Its object group is private to console history.
        pub fn writeConsoleRemoteObjectEx(
            state: *InspectorState,
            ctx: ActiveEngine.Context,
            writer: anytype,
            value: ActiveEngine.Value,
            object_group: ?[]const u8,
            preview: bool,
        ) !void {
            try writeRemoteObjectOwned(state, ctx, writer, value, object_group, preview, true);
        }

        fn writeRemoteObjectOwned(
            state: *InspectorState,
            ctx: ActiveEngine.Context,
            writer: anytype,
            value: ActiveEngine.Value,
            object_group: ?[]const u8,
            preview: bool,
            console_owner: bool,
        ) !void {
            if (ActiveEngine.isUndefined(ctx, value)) {
                try writer.writeAll("{\"type\":\"undefined\"}");
                return;
            }
            if (ActiveEngine.isNull(ctx, value)) {
                try writer.writeAll("{\"type\":\"object\",\"subtype\":\"null\",\"value\":null}");
                return;
            }
            if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                const qjs = Host.backend.ActiveEngineModule.c_api.qjs;
                if (value.tag == qjs.JS_TAG_SYMBOL) {
                    try writer.writeAll("{\"type\":\"symbol\",\"description\":");
                    if (ActiveEngine.valueToStringVal(ctx, value)) |s| {
                        defer std.heap.c_allocator.free(@constCast(s));
                        try writeJsonString(writer, s);
                    } else {
                        try writer.writeAll("\"Symbol()\"");
                    }
                    try writer.writeAll("}");
                    return;
                }
            }
            if (ActiveEngine.isBool(ctx, value)) {
                const b = ActiveEngine.toBool(ctx, value) orelse false;
                try writer.writeAll("{\"type\":\"boolean\",\"value\":");
                try writer.writeAll(if (b) "true" else "false");
                try writer.writeAll("}");
                return;
            }
            if (ActiveEngine.isNumber(ctx, value)) {
                const n = ActiveEngine.toFloat64(ctx, value) orelse 0.0;
                if (!std.math.isFinite(n)) {
                    try writer.writeAll("{\"type\":\"number\",\"unserializableValue\":");
                    if (std.math.isNan(n)) {
                        try writer.writeAll("\"NaN\"");
                    } else if (n > 0) {
                        try writer.writeAll("\"Infinity\"");
                    } else {
                        try writer.writeAll("\"-Infinity\"");
                    }
                    try writer.writeAll("}");
                    return;
                }
                if (@floor(n) == n and n >= -1e15 and n <= 1e15) {
                    const as_i: i64 = @intFromFloat(n);
                    try writer.print("{{\"type\":\"number\",\"value\":{d},\"description\":\"{d}\"}}", .{ as_i, as_i });
                } else {
                    try writer.print("{{\"type\":\"number\",\"value\":{d},\"description\":\"{d}\"}}", .{ n, n });
                }
                return;
            }
            if (ActiveEngine.isString(ctx, value)) {
                const s_opt = ActiveEngine.valueToStringVal(ctx, value);
                if (s_opt) |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    try writer.writeAll("{\"type\":\"string\",\"value\":");
                    try writeJsonString(writer, s);
                    try writer.writeAll("}");
                } else {
                    try writer.writeAll("{\"type\":\"string\",\"value\":\"\"}");
                }
                return;
            }

            // Object / function / array — retain and emit with objectId.
            const is_fn = ActiveEngine.isFunction(ctx, value);
            const is_arr = ActiveEngine.isArray(ctx, value);

            const class_name: []const u8 = if (is_fn) "Function" else if (is_arr) "Array" else "Object";
            const subtype: ?[]const u8 = if (is_arr) "array" else null;

            // Description: for arrays `Array(len)`, for functions just "function", for plain objects reuse className. DevTools uses this only as a console-tree label.
            var desc_owned: ?[]u8 = null;
            defer if (desc_owned) |d| state.allocator.free(d);
            const description: []const u8 = blk: {
                if (is_arr) {
                    const len = ActiveEngine.getLength(ctx, value) orelse 0;
                    const s = std.fmt.allocPrint(state.allocator, "Array({d})", .{len}) catch break :blk "Array";
                    desc_owned = s;
                    break :blk s;
                }
                if (is_fn) break :blk "function";
                break :blk "Object";
            };

            const oid = (if (console_owner) state.object_table.retainConsole(ctx, value, object_group) else state.object_table.retain(ctx, value, object_group)) orelse {
                try writer.writeAll("{\"type\":\"object\",\"className\":");
                try writeJsonString(writer, class_name);
                try writer.writeAll(",\"description\":");
                try writeJsonString(writer, description);
                if (preview) try writeObjectPreview(state, ctx, writer, value, class_name, subtype);
                try writer.writeAll("}");
                return;
            };

            try writer.writeAll("{\"type\":");
            if (is_fn) {
                try writer.writeAll("\"function\"");
            } else {
                try writer.writeAll("\"object\"");
            }
            if (subtype) |st| {
                try writer.writeAll(",\"subtype\":");
                try writeJsonString(writer, st);
            }
            try writer.writeAll(",\"className\":");
            try writeJsonString(writer, class_name);
            try writer.writeAll(",\"description\":");
            try writeJsonString(writer, description);
            try writer.writeAll(",\"objectId\":");
            try writer.print("\"{d}\"", .{oid});
            if (preview) try writeObjectPreview(state, ctx, writer, value, class_name, subtype);
            try writer.writeAll("}");
        }

        fn descriptorHasSlot(
            ctx: ActiveEngine.Context,
            object_ctor: ActiveEngine.Value,
            desc: ActiveEngine.Value,
            name: [:0]const u8,
        ) bool {
            const proto = ActiveEngine.getPropertyVal(ctx, object_ctor, "prototype") orelse return false;
            defer ActiveEngine.freeValue(ctx, proto);
            const hop = ActiveEngine.getPropertyVal(ctx, proto, "hasOwnProperty") orelse return false;
            defer ActiveEngine.freeValue(ctx, hop);
            const key = ActiveEngine.newStringVal(ctx, name);
            defer ActiveEngine.freeValue(ctx, key);
            const result = callMethod(ctx, hop, desc, &.{key}) orelse return false;
            defer ActiveEngine.freeValue(ctx, result);
            return ActiveEngine.toBool(ctx, result) orelse false;
        }

        fn callMethod(
            ctx: ActiveEngine.Context,
            func: ActiveEngine.Value,
            this_obj: ActiveEngine.Value,
            args: []const ActiveEngine.Value,
        ) ?ActiveEngine.Value {
            return ActiveEngine.callFunction(ctx, func, this_obj, args) orelse {
                // QuickJS leaves the exception pending. JSC already captured it.
                if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                    if (ActiveEngine.getAndFormatException(ctx)) |msg| std.heap.c_allocator.free(@constCast(msg));
                }
                return null;
            };
        }

        // Shallow preview of own enumerable names. A failing lookup omits the preview rather than failing the RemoteObject.
        fn writeObjectPreview(
            _: *InspectorState,
            ctx: ActiveEngine.Context,
            writer: anytype,
            value: ActiveEngine.Value,
            class_name: []const u8,
            subtype: ?[]const u8,
        ) !void {
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const object_ctor = ActiveEngine.getPropertyVal(ctx, global, "Object") orelse return;
            defer ActiveEngine.freeValue(ctx, object_ctor);
            const keys_fn = ActiveEngine.getPropertyVal(ctx, object_ctor, "keys") orelse return;
            defer ActiveEngine.freeValue(ctx, keys_fn);
            const desc_fn = ActiveEngine.getPropertyVal(ctx, object_ctor, "getOwnPropertyDescriptor") orelse return;
            defer ActiveEngine.freeValue(ctx, desc_fn);
            const keys = callMethod(ctx, keys_fn, object_ctor, &.{value}) orelse return;
            defer ActiveEngine.freeValue(ctx, keys);
            const len = ActiveEngine.getLength(ctx, keys) orelse 0;

            try writer.writeAll(",\"preview\":{\"type\":\"object\"");
            if (subtype) |st| {
                try writer.writeAll(",\"subtype\":");
                try writeJsonString(writer, st);
            }
            try writer.writeAll(",\"description\":");
            try writeJsonString(writer, class_name);
            const preview_property_cap = 5;
            try writer.writeAll(",\"overflow\":");
            try writer.writeAll(if (len > preview_property_cap) "true" else "false");
            try writer.writeAll(",\"properties\":[");

            var written: u32 = 0;
            var i: u32 = 0;
            while (i < len and written < preview_property_cap) : (i += 1) {
                const key_val = ActiveEngine.getIndex(ctx, keys, i) orelse continue;
                defer ActiveEngine.freeValue(ctx, key_val);
                const key_str = ActiveEngine.valueToStringVal(ctx, key_val) orelse continue;
                defer std.heap.c_allocator.free(@constCast(key_str));
                const key_js = ActiveEngine.newStringVal(ctx, key_str);
                defer ActiveEngine.freeValue(ctx, key_js);
                const desc = callMethod(ctx, desc_fn, object_ctor, &.{ value, key_js }) orelse continue;
                defer ActiveEngine.freeValue(ctx, desc);
                if (written != 0) try writer.writeByte(',');
                written += 1;
                try writer.writeAll("{\"name\":");
                try writeJsonString(writer, key_str);
                // `getPropertyVal` treats undefined as missing. An accessor whose get and set are both undefined still owns those slots.
                if (descriptorHasSlot(ctx, object_ctor, desc, "get") or descriptorHasSlot(ctx, object_ctor, desc, "set")) {
                    try writer.writeAll(",\"type\":\"accessor\"}");
                    continue;
                }
                const prop = ActiveEngine.getPropertyVal(ctx, desc, "value");
                defer if (prop) |pv| ActiveEngine.freeValue(ctx, pv);
                try writePreviewTypeAndValue(writer, ctx, prop);
                try writer.writeByte('}');
            }
            try writer.writeAll("]}");
        }

        fn writePreviewTypeAndValue(writer: anytype, ctx: ActiveEngine.Context, prop: ?ActiveEngine.Value) !void {
            const value = prop orelse {
                try writer.writeAll(",\"type\":\"undefined\"");
                return;
            };
            if (ActiveEngine.isUndefined(ctx, value)) {
                try writer.writeAll(",\"type\":\"undefined\"");
                return;
            }
            if (ActiveEngine.isNull(ctx, value)) {
                try writer.writeAll(",\"type\":\"object\",\"subtype\":\"null\",\"value\":\"null\"");
                return;
            }
            if (ActiveEngine.isBool(ctx, value)) {
                const b = ActiveEngine.toBool(ctx, value) orelse false;
                try writer.writeAll(",\"type\":\"boolean\",\"value\":");
                try writer.writeAll(if (b) "\"true\"" else "\"false\"");
                return;
            }
            if (ActiveEngine.isNumber(ctx, value)) {
                const n = ActiveEngine.toFloat64(ctx, value) orelse 0;
                try writer.writeAll(",\"type\":\"number\",\"value\":");
                try writer.print("\"{d}\"", .{n});
                return;
            }
            if (ActiveEngine.isString(ctx, value)) {
                try writer.writeAll(",\"type\":\"string\",\"value\":");
                if (ActiveEngine.valueToStringVal(ctx, value)) |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    try writeJsonString(writer, s);
                } else try writer.writeAll("\"\"");
                return;
            }
            if (ActiveEngine.isArray(ctx, value)) {
                try writer.writeAll(",\"type\":\"object\",\"subtype\":\"array\",\"value\":\"Array\"");
                return;
            }
            if (ActiveEngine.isFunction(ctx, value)) {
                try writer.writeAll(",\"type\":\"function\",\"value\":\"function\"");
                return;
            }
            try writer.writeAll(",\"type\":\"object\",\"value\":\"Object\"");
        }

        pub fn sendEvalException(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            message: []const u8,
        ) void {
            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            const w = &aw.writer;

            w.print("{{\"id\":{d},\"result\":{{", .{request_id}) catch return;
            w.writeAll("\"result\":{\"type\":\"object\",\"subtype\":\"error\",\"description\":") catch return;
            writeJsonString(w, message) catch return;
            w.writeAll("},\"exceptionDetails\":{\"exceptionId\":1,\"text\":\"Uncaught\",\"lineNumber\":0,\"columnNumber\":0,\"exception\":{\"type\":\"object\",\"subtype\":\"error\",\"description\":") catch return;
            writeJsonString(w, message) catch return;
            w.writeAll("}}}}") catch return;
            sendJson(state, session_id, aw.written());
        }
    };
}
