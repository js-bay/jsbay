pub fn Module(comptime Host: type) type {
    // Runtime Promise awaiting. QuickJS uses native Promise reactions; JSC's public API cannot observe arbitrary Promise settlement reliably.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const json_writer = @import("json_writer.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);
        const transport_mod = @import("transport.zig");

        const InspectorState = state_mod.InspectorState;

        pub fn handle(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64, root: std.json.Value) void {
            if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                return @import("await_promise_qjs.zig").Module(Host).handle(state, session_id, request_id, root);
            }
            json_writer.sendError(state, session_id, request_id, -32601, "Runtime.awaitPromise is unsupported by this backend");
        }

        // Attach to `value` only when it is a genuine QuickJS Promise. The caller retains ownership of value and must still free it after this returns.
        pub fn attach(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            ctx: backend.ActiveEngine.Context,
            value: backend.ActiveEngine.Value,
            return_by_value: bool,
            object_group: ?[]const u8,
        ) bool {
            if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                return @import("await_promise_qjs.zig").Module(Host).attach(state, session_id, request_id, ctx, value, return_by_value, object_group);
            }
            json_writer.sendError(state, session_id, request_id, -32601, "Runtime.awaitPromise is unsupported by this backend");
            return false;
        }

        pub fn cancelSession(state: *InspectorState, session_id: transport_mod.SessionId) void {
            if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                @import("await_promise_qjs.zig").Module(Host).cancelSession(state, session_id);
            }
        }

        pub fn closeSession(state: *InspectorState, session_id: transport_mod.SessionId) void {
            if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                @import("await_promise_qjs.zig").Module(Host).closeSession(state, session_id);
                return;
            }
            _ = state_mod.removeSession(state, session_id);
        }

        pub fn cancelState(state: *InspectorState) void {
            if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                @import("await_promise_qjs.zig").Module(Host).cancelState(state);
            }
        }
    };
}
