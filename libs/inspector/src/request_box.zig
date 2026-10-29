pub fn Module(comptime Host: type) type {
    // Boxed request descriptor — used by every Runtime.* handler that needs to marshal work to the JS thread.
    //
    // A handler parses its CDP `params`, allocates a `RequestBox` on the inspector allocator with a per-method `run_fn`, and posts it via `dispatch.postTask`. The reader thread returns immediately. When the JS thread drains the task queue, `runRequestOnJsThread` invokes the stored `run_fn` and frees the box.
    //
    // Each handler owns its slice of the union-style payload fields (expression / object_id / call_args / …) — see the per-method runners in `runtime_eval.zig` and `runtime_objects.zig` for which fields apply.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const engine = Host.engine;
        const transport_mod = @import("transport.zig");
        const remote_object = @import("remote_object.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);

        const ActiveEngine = backend.ActiveEngine;
        const InspectorState = state_mod.InspectorState;

        // Per-argument descriptor for Runtime.callFunctionOn. Either a literal value (number/string/bool/null) or a reference to an existing objectId.
        pub const CallArg = union(enum) {
            value_null,
            value_undefined,
            value_bool: bool,
            value_number: f64,
            value_string: []u8, // allocator-owned
            object_id: u64,
        };

        // Function pointer invoked on the JS thread once `runRequestOnJsThread` has resolved the live `Context` for the box's instance.
        pub const RunFn = *const fn (*RequestBox, ActiveEngine.Context) void;

        // Generic boxed request — used by every JS-thread-marshalled handler. Payload fields are filled only when relevant to the op; `run_fn` is the handler-specific dispatch invoked from `runRequestOnJsThread`.
        pub const RequestBox = struct {
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            run_fn: RunFn,
            expression: []u8 = &.{},
            object_group: []u8 = &.{},
            return_by_value: bool = false,
            /// Runtime.evaluate/callFunctionOn may defer their response until a returned Promise settles. Runtime.awaitPromise sets this on its direct request.
            await_promise: bool = false,
            object_id: u64 = 0,
            own_properties: bool = true,
            accessor_properties_only: bool = false,
            generate_preview: bool = false,
            non_indexed_properties_only: bool = false,
            call_this_id: u64 = 0,
            call_has_this: bool = false,
            call_args: []CallArg = &.{},
            group_name: []u8 = &.{},
            frame_index: i32 = 0,
        };

        pub fn freeRequestBox(alloc: std.mem.Allocator, box: *RequestBox) void {
            if (box.expression.len != 0) alloc.free(box.expression);
            if (box.object_group.len != 0) alloc.free(box.object_group);
            if (box.group_name.len != 0) alloc.free(box.group_name);
            for (box.call_args) |arg| {
                switch (arg) {
                    .value_string => |s| alloc.free(s),
                    else => {},
                }
            }
            if (box.call_args.len != 0) alloc.free(box.call_args);
            alloc.destroy(box);
        }

        pub fn postJsRequest(state: *InspectorState, box: *RequestBox) bool {
            return state_mod.postInspectorTask(state, .{
                .ctx = box,
                .run = runRequestOnJsThread,
                .cancel = cancelRequestOnShutdown,
            });
        }

        fn cancelRequestOnShutdown(ctx: ?*anyopaque) void {
            const box: *RequestBox = @ptrCast(@alignCast(ctx.?));
            freeRequestBox(box.state.allocator, box);
        }

        fn runRequestOnJsThread(ctx: ?*anyopaque) void {
            const box: *RequestBox = @ptrCast(@alignCast(ctx.?));
            defer freeRequestBox(box.state.allocator, box);

            const js_ctx = engine.getContext(box.state.instance_id) orelse {
                remote_object.sendEvalException(box.state, box.session_id, box.request_id, "JS context is not available");
                return;
            };

            box.run_fn(box, js_ctx);
        }
    };
}
