//! C ABI operation ownership: admission, admitted re-read/pin, publication and release. Primary typed values and packed byte storage retain separate representations. No synchronous-binding policy or handle-table implementation lives here.
const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const api_value = @import("api_value.zig");
const packed_api_value = @import("packed_api_value.zig");
const api_backend = @import("api_backend.zig");
const typed_bytecode = @import("../script/typed_bytecode.zig");
const host_wake = @import("js_event_loop").host_wake;
const hyper_box = @import("hyper_box");
const HyperValue = hyper_box.Value;
const ActiveEngine = backend.ActiveEngine;

/// Boundary-owned status numbers and C byte layout are supplied once by c_api; this module never imports the export layer. This is not a backend or handle-store abstraction.
pub const StatusCodes = struct {
    API_OK: c_int,
    API_EXCEPTION: c_int,
    API_INVALID_ARGUMENT: c_int,
    API_WRONG_THREAD: c_int,
    API_INSTANCE_NOT_FOUND: c_int,
    API_STALE_VALUE: c_int,
    API_OUT_OF_MEMORY: c_int,
    API_UNSUPPORTED: c_int,
    API_LOOP_FAILED: c_int,
};

pub fn Operations(comptime Bytes: type, comptime codes: StatusCodes) type {
    return struct {
        const API_OK = codes.API_OK;
        const API_EXCEPTION = codes.API_EXCEPTION;
        const API_INVALID_ARGUMENT = codes.API_INVALID_ARGUMENT;
        const API_WRONG_THREAD = codes.API_WRONG_THREAD;
        const API_INSTANCE_NOT_FOUND = codes.API_INSTANCE_NOT_FOUND;
        const API_STALE_VALUE = codes.API_STALE_VALUE;
        const API_OUT_OF_MEMORY = codes.API_OUT_OF_MEMORY;
        const API_UNSUPPORTED = codes.API_UNSUPPORTED;
        const API_LOOP_FAILED = codes.API_LOOP_FAILED;

        pub const ApiOp = struct {
            id: i32,
            ctx: ActiveEngine.Context,
            lease: engine_thread.EvalLease,
            entered_js: bool,
            allocator: std.mem.Allocator,
            execution: ?@import("../runtime/js_scheduler.zig").Execution = null,

            pub fn deinit(self: *ApiOp) void {
                if (self.execution) |*execution| @import("../runtime/js_scheduler.zig").checkpointAfterExecution(execution, self.ctx);
                self.execution = null;
                // Raw typed operations below use backend C APIs directly.  Keep the QuickJS stack anchor around the entire admission lease, including re-entrant getter/toString/native-callback execution.
                if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                    if (self.entered_js) backend.ActiveEngineModule.lifecycle.leaveJs(self.ctx);
                }
                engine.finishEvalEntry(self.id, self.lease);
            }
        };

        pub const ApiOpResult = union(enum) { ok: ApiOp, status: c_int };

        pub fn beginApiOpMode(id: i32, require_execution: bool) ApiOpResult {
            if (host_wake.isNotifying()) return .{ .status = API_INVALID_ARGUMENT };
            if (@import("../runtime/instance_map.zig").isTeardownPending(id)) return .{ .status = API_INSTANCE_NOT_FOUND };
            if (!api_value.isOwner(id)) return .{ .status = if (@import("../runtime/instance_map.zig").getPtrs(id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
            const lease = engine_thread.beginEval(id);
            if (!lease.allowed) return .{ .status = if (@import("../runtime/instance_map.zig").getPtrs(id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
            const inst = @import("../runtime/instance_map.zig").getInstance(id) orelse {
                engine.finishEvalEntry(id, lease);
                return .{ .status = API_INSTANCE_NOT_FOUND };
            };
            if (inst.loop.lastError() != null) {
                engine.finishEvalEntry(id, lease);
                return .{ .status = API_LOOP_FAILED };
            }
            const ctx = inst.monoCtx() orelse {
                engine.finishEvalEntry(id, lease);
                return .{ .status = API_INSTANCE_NOT_FOUND };
            };
            const entered_js = if (comptime backend.isQuickJsApiBackend(backend.active_backend)) backend.ActiveEngineModule.lifecycle.enterJs(ctx) else true;
            if (!entered_js) {
                engine.finishEvalEntry(id, lease);
                return .{ .status = API_WRONG_THREAD };
            }
            if (!require_execution) return .{ .ok = .{ .id = id, .ctx = ctx, .lease = lease, .entered_js = entered_js, .allocator = inst.allocator } };
            const execution = @import("../runtime/js_scheduler.zig").beginExecution(id) orelse {
                if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                    if (entered_js) backend.ActiveEngineModule.lifecycle.leaveJs(ctx);
                }
                engine.finishEvalEntry(id, lease);
                return .{ .status = API_INSTANCE_NOT_FOUND };
            };
            return .{ .ok = .{ .id = id, .ctx = ctx, .lease = lease, .entered_js = entered_js, .allocator = inst.allocator, .execution = execution } };
        }

        pub fn beginApiOp(id: i32) ApiOpResult {
            return beginApiOpMode(id, true);
        }

        pub fn beginCleanupApiOp(id: i32) ApiOpResult {
            return beginApiOpMode(id, false);
        }

        pub fn apiContext(instance_id: i32) union(enum) { ok: ActiveEngine.Context, status: c_int } {
            const ptrs = @import("../runtime/instance_map.zig").getPtrs(instance_id) orelse return .{ .status = API_INSTANCE_NOT_FOUND };
            if (!api_value.isOwner(instance_id)) return .{ .status = API_WRONG_THREAD };
            return .{ .ok = ptrs.ctx };
        }

        pub const ValueOp = struct {
            op: ApiOp,
            value: ActiveEngine.Value,

            pub fn deinit(self: *ValueOp) void {
                ActiveEngine.freeValue(self.op.ctx, self.value);
                self.op.deinit();
            }
        };

        pub fn beginValueOp(handle: u64) union(enum) { ok: ValueOp, status: c_int } {
            const entry = api_value.get(handle) orelse return .{ .status = API_STALE_VALUE };
            var op = switch (beginApiOp(entry.instance_id)) {
                .status => |status| return .{ .status = status },
                .ok => |value| value,
            };
            // Re-read while admitted, then pin a backend reference. A getter/toString can re-enter the C ABI and release the public handle being operated on.
            const live = api_value.get(handle) orelse {
                op.deinit();
                return .{ .status = API_STALE_VALUE };
            };
            if (live.instance_id != op.id) {
                op.deinit();
                return .{ .status = API_STALE_VALUE };
            }
            return .{ .ok = .{ .op = op, .value = ActiveEngine.dupValue(op.ctx, live.value) } };
        }

        pub fn pinValue(op: ApiOp, handle: u64) union(enum) { ok: ActiveEngine.Value, status: c_int } {
            const val = HyperValue{ .raw = handle };
            if (val.isHandle()) {
                const entry = api_value.get(handle) orelse return .{ .status = API_STALE_VALUE };
                if (entry.instance_id != op.id) return .{ .status = API_STALE_VALUE };
                return .{ .ok = ActiveEngine.dupValue(op.ctx, entry.value) };
            }
            if (val.isUndefined()) return .{ .ok = ActiveEngine.undefinedValue() };
            if (val.isNull()) return .{ .ok = ActiveEngine.nullValue() };
            if (val.isBool()) return .{ .ok = ActiveEngine.newBoolVal(op.ctx, val.asBool()) };
            if (val.isInt32()) return .{ .ok = ActiveEngine.newInt32Val(op.ctx, val.asInt32()) };
            if (val.isSso()) {
                const sso_buf = val.asSsoBytes();
                return switch (api_backend.newString(op.ctx, sso_buf.slice())) {
                    .ok => |str_val| .{ .ok = str_val },
                    else => .{ .status = API_OUT_OF_MEMORY },
                };
            }
            return .{ .status = API_STALE_VALUE };
        }

        pub fn apiStore(instance_id: i32, value: ActiveEngine.Value, out: *u64) c_int {
            out.* = 0;
            // A getter/native callback may request destroy while raw backend work is re-entered. Never publish a value that is invalid as soon as this C call returns; retain the backend ownership only long enough to release it.
            if (@import("../runtime/instance_map.zig").isTeardownPending(instance_id)) {
                if (@import("../runtime/instance_map.zig").getPtrs(instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, value);
                return API_INSTANCE_NOT_FOUND;
            }
            out.* = api_value.putOwned(instance_id, value) orelse {
                if (@import("../runtime/instance_map.zig").getPtrs(instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, value);
                return API_OUT_OF_MEMORY;
            };
            return API_OK;
        }

        pub fn drainApiJobs(op: *ApiOp) bool {
            const map = @import("../runtime/instance_map.zig");
            if (op.execution) |*execution| {
                if (!map.isTeardownPending(op.id)) @import("../runtime/js_scheduler.zig").checkpointAfterExecution(execution, op.ctx) else execution.end();
                op.execution = null;
            }
            return !map.isTeardownPending(op.id);
        }

        pub fn discardBackendResult(ctx: ActiveEngine.Context, result: api_backend.Result) void {
            switch (result) {
                .ok => |value| ActiveEngine.freeValue(ctx, value),
                .exception => |exception| ActiveEngine.freeValue(ctx, exception),
                .out_of_memory => {},
            }
        }

        pub fn discardBytesResult(ctx: ActiveEngine.Context, result: api_backend.BytesResult) void {
            switch (result) {
                .ok => |bytes| std.heap.c_allocator.free(bytes),
                .exception => |exception| ActiveEngine.freeValue(ctx, exception),
                .out_of_memory, .invalid_argument => {},
            }
        }

        pub fn discardTypedBytecodeResult(ctx: ActiveEngine.Context, result: typed_bytecode.Result) void {
            if (result.bytes) |bytes| typed_bytecode.freeBytes(bytes);
            if (result.value) |value| ActiveEngine.freeValue(ctx, value);
            if (result.exception) |exception| ActiveEngine.freeValue(ctx, exception);
        }

        pub fn packedNewFromResult(instance_id: i32, result: @import("../backend_dispatch.zig").EvalValueResult, tag: backend.BackendType, ctx_addr: usize, out_value: *u64) c_int {
            return packedPublish(instance_id, tag, ctx_addr, result, out_value, null);
        }

        pub fn packedHandlesOf(instance_id: i32) ?@import("../backend_dispatch.zig").Handles {
            const inst = @import("../runtime/instance_map.zig").getInstance(instance_id) orelse return null;
            return switch (inst.engine_handles) {
                .packed_alt => |a| .{ .runtime_addr = a.runtime_addr, .ctx_addr = a.ctx_addr },
                .mono => null,
            };
        }

        pub const PackedJsOp = struct {
            id: i32,
            tag: backend.BackendType,
            ctx_addr: usize,
            lease: engine_thread.EvalLease,
            entered_js: bool,
            allocator: std.mem.Allocator,
            execution: ?@import("../runtime/js_scheduler.zig").Execution = null,

            pub fn deinit(self: *PackedJsOp) void {
                if (self.execution) |*execution| @import("../runtime/js_scheduler.zig").checkpointInstanceAfterExecution(execution);
                self.execution = null;
                if (self.entered_js) @import("../backend_dispatch.zig").leaveJsPacked(self.tag, self.ctx_addr);
                engine.finishEvalEntry(self.id, self.lease);
            }
        };

        pub const PackedJsOpResult = union(enum) { ok: PackedJsOp, status: c_int };

        pub fn beginPackedJsOpMode(instance_id: i32, tag: backend.BackendType, ctx_addr: usize, require_execution: bool) PackedJsOpResult {
            if (host_wake.isNotifying()) return .{ .status = API_INVALID_ARGUMENT };
            if (@import("../runtime/instance_map.zig").isTeardownPending(instance_id)) return .{ .status = API_INSTANCE_NOT_FOUND };
            if (!api_value.isOwner(instance_id)) return .{ .status = if (@import("../runtime/instance_map.zig").getPtrs(instance_id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
            const lease = engine_thread.beginEval(instance_id);
            if (!lease.allowed) return .{ .status = if (@import("../runtime/instance_map.zig").getPtrs(instance_id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
            const inst = @import("../runtime/instance_map.zig").getInstance(instance_id) orelse {
                engine.finishEvalEntry(instance_id, lease);
                return .{ .status = API_INSTANCE_NOT_FOUND };
            };
            if (inst.loop.lastError() != null) {
                engine.finishEvalEntry(instance_id, lease);
                return .{ .status = API_LOOP_FAILED };
            }
            if (!@import("../backend_dispatch.zig").enterJsPacked(tag, ctx_addr)) {
                engine.finishEvalEntry(instance_id, lease);
                return .{ .status = API_WRONG_THREAD };
            }
            if (!require_execution) return .{ .ok = .{ .id = instance_id, .tag = tag, .ctx_addr = ctx_addr, .lease = lease, .entered_js = true, .allocator = inst.allocator } };
            const execution = @import("../runtime/js_scheduler.zig").beginExecution(instance_id) orelse {
                @import("../backend_dispatch.zig").leaveJsPacked(tag, ctx_addr);
                engine.finishEvalEntry(instance_id, lease);
                return .{ .status = API_INSTANCE_NOT_FOUND };
            };
            return .{ .ok = .{
                .id = instance_id,
                .tag = tag,
                .ctx_addr = ctx_addr,
                .lease = lease,
                .entered_js = true,
                .allocator = inst.allocator,
                .execution = execution,
            } };
        }

        pub fn beginPackedJsOp(instance_id: i32, tag: backend.BackendType, ctx_addr: usize) PackedJsOpResult {
            return beginPackedJsOpMode(instance_id, tag, ctx_addr, true);
        }

        pub fn beginPackedCleanupOp(instance_id: i32, tag: backend.BackendType, ctx_addr: usize) PackedJsOpResult {
            return beginPackedJsOpMode(instance_id, tag, ctx_addr, false);
        }

        pub const PackedValueOp = struct {
            js: PackedJsOp,
            value_buf: [@import("../backend_dispatch.zig").value_storage_size]u8 = undefined,
            value_len: usize = 0,

            pub fn bytes(self: *const PackedValueOp) []const u8 {
                return self.value_buf[0..self.value_len];
            }

            pub fn deinit(self: *PackedValueOp) void {
                if (self.value_len != 0) {
                    @import("../backend_dispatch.zig").timerFreeValue(self.js.tag, self.js.ctx_addr, self.bytes());
                    self.value_len = 0;
                }
                self.js.deinit();
            }
        };

        pub fn beginPackedValueOp(handle: u64) union(enum) { ok: PackedValueOp, status: c_int } {
            const entry = packed_api_value.get(handle) orelse return .{ .status = API_STALE_VALUE };
            if (!api_value.isOwner(entry.instance_id)) {
                return .{ .status = if (@import("../runtime/instance_map.zig").getPtrs(entry.instance_id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
            }
            var js = switch (beginPackedJsOp(entry.instance_id, entry.tag, entry.ctx_addr)) {
                .status => |status| return .{ .status = status },
                .ok => |ok| ok,
            };
            // Re-read while admitted, then pin. A toPrimitive / getter can re-enter and release the public handle.
            const live = packed_api_value.get(handle) orelse {
                js.deinit();
                return .{ .status = API_STALE_VALUE };
            };
            if (live.instance_id != js.id or live.tag != js.tag) {
                js.deinit();
                return .{ .status = API_STALE_VALUE };
            }
            var op: PackedValueOp = .{ .js = js, .value_len = 0 };
            op.value_len = @import("../backend_dispatch.zig").timerDupValue(live.tag, live.ctx_addr, live.bytes(), op.value_buf[0..]) orelse {
                op.js.deinit();
                return .{ .status = API_STALE_VALUE };
            };
            return .{ .ok = op };
        }

        pub fn drainPackedJobs(js: *PackedJsOp) bool {
            const map = @import("../runtime/instance_map.zig");
            if (js.execution) |*execution| {
                if (!map.isTeardownPending(js.id)) @import("../runtime/js_scheduler.zig").checkpointInstanceAfterExecution(execution) else execution.end();
                js.execution = null;
            }
            return !map.isTeardownPending(js.id);
        }

        pub fn discardPackedEvalResult(tag: backend.BackendType, ctx_addr: usize, result: @import("../backend_dispatch.zig").EvalValueResult) void {
            if (result.value) |v| @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, v.slice());
            if (result.exception) |e| @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
        }

        pub fn discardPackedBytesResult(tag: backend.BackendType, ctx_addr: usize, result: @import("../backend_dispatch.zig").BytesValueResult) void {
            if (result.bytes) |b| std.heap.c_allocator.free(b);
            if (result.exception) |e| @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
        }

        pub fn discardPackedBoolResult(tag: backend.BackendType, ctx_addr: usize, result: @import("../backend_dispatch.zig").BoolValueResult) void {
            if (result.exception) |e| @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
        }

        pub fn packedTagOf(instance_id: i32) ?backend.BackendType {
            const inst = @import("../runtime/instance_map.zig").getInstance(instance_id) orelse return null;
            return switch (inst.engine_handles) {
                .packed_alt => |a| a.tag,
                .mono => null,
            };
        }

        pub fn packedStore(instance_id: i32, tag: backend.BackendType, ctx_addr: usize, erased: @import("../backend_dispatch.zig").ErasedValue, out: *u64) c_int {
            out.* = 0;
            if (@import("../runtime/instance_map.zig").isTeardownPending(instance_id)) {
                @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, erased.slice());
                return API_INSTANCE_NOT_FOUND;
            }
            out.* = packed_api_value.putOwned(instance_id, tag, ctx_addr, erased.slice()) orelse {
                @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, erased.slice());
                return API_OUT_OF_MEMORY;
            };
            return API_OK;
        }

        pub fn packedPublish(instance_id: i32, tag: backend.BackendType, ctx_addr: usize, result: @import("../backend_dispatch.zig").EvalValueResult, out_value: *u64, out_exception: ?*u64) c_int {
            if (out_exception) |exc| exc.* = 0;
            if (result.out_of_memory) {
                if (result.value) |v| @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, v.slice());
                if (result.exception) |e| @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
                return API_OUT_OF_MEMORY;
            }
            if (result.exception) |exc| {
                if (out_exception) |slot| {
                    const stored = packedStore(instance_id, tag, ctx_addr, exc, slot);
                    return if (stored == API_OK) 1 else stored;
                }
                @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, exc.slice());
                return API_OUT_OF_MEMORY;
            }
            if (result.value) |value| return packedStore(instance_id, tag, ctx_addr, value, out_value);
            // set-style ops succeed with empty result
            out_value.* = 0;
            return API_OK;
        }

        pub fn packedPublishBool(instance_id: i32, tag: backend.BackendType, ctx_addr: usize, result: @import("../backend_dispatch.zig").BoolValueResult, out_flag: *bool, out_exception: *u64) c_int {
            out_exception.* = 0;
            if (@import("../runtime/instance_map.zig").isTeardownPending(instance_id)) {
                if (result.exception) |e| @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
                return API_INSTANCE_NOT_FOUND;
            }
            if (result.out_of_memory) {
                if (result.exception) |e| @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
                return API_OUT_OF_MEMORY;
            }
            if (result.exception) |exc| {
                const stored = packedStore(instance_id, tag, ctx_addr, exc, out_exception);
                return if (stored == API_OK) 1 else stored;
            }
            out_flag.* = result.value;
            return API_OK;
        }

        pub fn packedPublishBytes(instance_id: i32, tag: backend.BackendType, ctx_addr: usize, result: @import("../backend_dispatch.zig").BytesValueResult, out_bytes: *Bytes, out_exception: *u64) c_int {
            out_exception.* = 0;
            if (@import("../runtime/instance_map.zig").isTeardownPending(instance_id)) {
                if (result.bytes) |b| std.heap.c_allocator.free(b);
                if (result.exception) |e| @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
                return API_INSTANCE_NOT_FOUND;
            }
            if (result.out_of_memory) {
                if (result.bytes) |b| std.heap.c_allocator.free(b);
                if (result.exception) |e| @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
                return API_OUT_OF_MEMORY;
            }
            if (result.invalid_argument) {
                if (result.bytes) |b| std.heap.c_allocator.free(b);
                if (result.exception) |e| @import("../backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
                return API_INVALID_ARGUMENT;
            }
            if (result.exception) |exc| {
                if (result.bytes) |b| std.heap.c_allocator.free(b);
                const stored = packedStore(instance_id, tag, ctx_addr, exc, out_exception);
                return if (stored == API_OK) 1 else stored;
            }
            const bytes = result.bytes orelse return API_OUT_OF_MEMORY;
            out_bytes.* = .{ .data = bytes.ptr, .len = bytes.len };
            return API_OK;
        }

        pub fn packedDupBytes(handle: u64, expect_instance: i32, expect_tag: backend.BackendType, out: []u8) ?usize {
            const val = HyperValue{ .raw = handle };
            if (val.isSso()) {
                const sso_buf = val.asSsoBytes();
                const handles = packedHandlesOf(expect_instance) orelse return null;
                const res = @import("../backend_dispatch.zig").valueNewString(expect_tag, handles.ctx_addr, sso_buf.slice());
                if (res.exception) |e| @import("../backend_dispatch.zig").timerFreeValue(expect_tag, handles.ctx_addr, e.slice());
                if (res.value) |v| {
                    if (out.len < v.len) {
                        @import("../backend_dispatch.zig").timerFreeValue(expect_tag, handles.ctx_addr, v.slice());
                        return null;
                    }
                    @memcpy(out[0..v.len], v.bytes[0..v.len]);
                    return v.len;
                }
                return null;
            }
            const entry = packed_api_value.get(handle) orelse return null;
            if (entry.instance_id != expect_instance or entry.tag != expect_tag) return null;
            return @import("../backend_dispatch.zig").timerDupValue(entry.tag, entry.ctx_addr, entry.bytes(), out);
        }

        pub fn packedInstanceReady(instance_id: i32) union(enum) {
            ok: struct { tag: backend.BackendType, ctx_addr: usize },
            status: c_int,
        } {
            if (host_wake.isNotifying()) return .{ .status = API_INVALID_ARGUMENT };
            if (@import("../runtime/instance_map.zig").isTeardownPending(instance_id)) return .{ .status = API_INSTANCE_NOT_FOUND };
            if (!api_value.isOwner(instance_id)) return .{ .status = if (@import("../runtime/instance_map.zig").getPtrs(instance_id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
            const tag = packedTagOf(instance_id) orelse return .{ .status = API_INSTANCE_NOT_FOUND };
            const handles = packedHandlesOf(instance_id) orelse return .{ .status = API_INSTANCE_NOT_FOUND };
            if (@import("../runtime/instance_map.zig").getInstance(instance_id)) |inst| {
                if (inst.loop.lastError() != null) return .{ .status = API_LOOP_FAILED };
            }
            return .{ .ok = .{ .tag = tag, .ctx_addr = handles.ctx_addr } };
        }

        pub fn finishBoolOp(op: *ApiOp, result: api_backend.BoolResult, out_flag: *bool, out_exception: *u64) c_int {
            if (!drainApiJobs(op)) {
                switch (result) {
                    .exception => |exception| ActiveEngine.freeValue(op.ctx, exception),
                    .ok, .out_of_memory => {},
                }
                return API_INSTANCE_NOT_FOUND;
            }
            switch (result) {
                .ok => |val| {
                    out_flag.* = val;
                    return API_OK;
                },
                .exception => |exception| {
                    const stored = apiStore(op.id, exception, out_exception);
                    return if (stored == API_OK) 1 else stored;
                },
                .out_of_memory => return API_OUT_OF_MEMORY,
            }
        }
    };
}
