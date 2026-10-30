//! Create-time select dispatch for packed backends.
//!
//! Shared hot paths remain monomorphic on `build_options.backend` (pack primary). Non-primary packed instances store erased runtime/context pointers and call through these helpers for bare lifecycle: create, eval (string or typed value), destroy, timers, and typed value ops (retain/release/type/to_bool/to_number/to_utf8/get/set/call/construct/has/delete/keys/instanceof/new_*/global/array_buffer/JSON/copy_buffer/new_error).

const std = @import("std");
const backend = @import("backend.zig");
const types = @import("types.zig");
const multi_pack = @import("multi_pack.zig");

pub const Backend = backend.BackendType;

fn erasePtr(p: anytype) usize {
    const T = @TypeOf(p);
    switch (@typeInfo(T)) {
        .optional => {
            const v = p orelse return 0;
            return erasePtr(v);
        },
        .pointer => return @intFromPtr(p),
        else => @compileError("erasePtr expects a pointer or optional pointer"),
    }
}

fn restorePtr(comptime P: type, addr: usize) P {
    if (addr == 0) {
        switch (@typeInfo(P)) {
            .optional => return null,
            .pointer => return @ptrFromInt(addr),
            else => @compileError("restorePtr expects a pointer or optional pointer"),
        }
    }
    switch (@typeInfo(P)) {
        .optional => |o| {
            const child: o.child = restorePtr(o.child, addr);
            return child;
        },
        .pointer => return @ptrFromInt(addr),
        else => @compileError("restorePtr expects a pointer or optional pointer"),
    }
}

pub const Handles = struct {
    runtime_addr: usize,
    ctx_addr: usize,
};

fn createReal(comptime tag: Backend) ?Handles {
    if (comptime !multi_pack.isPacked(tag)) return null;
    const E = backend.Engine(tag);
    const rt = E.newRuntime() orelse return null;
    const ctx = E.newContext(rt) orelse {
        E.freeRuntime(rt);
        return null;
    };
    return .{
        .runtime_addr = erasePtr(rt),
        .ctx_addr = erasePtr(ctx),
    };
}

pub fn createPacked(tag: Backend) ?Handles {
    if (!multi_pack.isPacked(tag)) return null;
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand)) return createReal(cand);
            return null;
        }
    }
    return null;
}

pub fn finishCreate(tag: Backend, handles: Handles, instance_id: i32, max_stack_size: usize) void {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand)) {
                const E = backend.Engine(cand);
                const rt = restorePtr(E.Runtime, handles.runtime_addr);
                const ctx = restorePtr(E.Context, handles.ctx_addr);
                E.setMaxStackSize(rt, max_stack_size);
                E.setContextOpaque(ctx, @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(instance_id))))));
                E.registerConsole(ctx);
                E.registerTimers(ctx);
            }
            return;
        }
    }
}

/// Largest packed-engine Value footprint (QJS JSValue is 16B; JSC JSValueRef is a pointer).
/// Only measure engines that are actually linked — otherwise mono-JSC pulls `qjs` via Engine(.quickjs_ng).
pub const value_storage_size: usize = blk: {
    var m: usize = @sizeOf(usize);
    if (multi_pack.isPacked(.quickjs_ng) or backend.active_backend == .quickjs_ng) {
        m = @max(m, @sizeOf(backend.Engine(.quickjs_ng).Value));
    }
    if (multi_pack.isPacked(.quickjs) or backend.active_backend == .quickjs) {
        m = @max(m, @sizeOf(backend.Engine(.quickjs).Value));
    }
    if (multi_pack.isPacked(.jsc) or backend.active_backend == .jsc) {
        m = @max(m, @sizeOf(backend.Engine(.jsc).Value));
    }
    break :blk m;
};

pub fn valueByteSize(tag: Backend) usize {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                return @sizeOf(backend.Engine(cand).Value);
            }
            return 0;
        }
    }
    return 0;
}

fn loadValue(comptime E: type, bytes: []const u8) E.Value {
    var v: E.Value = undefined;
    @memcpy(std.mem.asBytes(&v), bytes);
    return v;
}

fn storeValue(comptime E: type, value: E.Value, out: []u8) usize {
    const raw = std.mem.asBytes(&value);
    @memcpy(out[0..raw.len], raw);
    return raw.len;
}

pub fn timerIsFunction(tag: Backend, ctx_addr: usize, callback_bytes: []const u8) bool {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                const E = backend.Engine(cand);
                if (callback_bytes.len != @sizeOf(E.Value)) return false;
                const ctx = restorePtr(E.Context, ctx_addr);
                return E.isFunction(ctx, loadValue(E, callback_bytes));
            }
            return false;
        }
    }
    return false;
}

pub fn timerDupValue(tag: Backend, ctx_addr: usize, callback_bytes: []const u8, out: []u8) ?usize {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                const E = backend.Engine(cand);
                if (callback_bytes.len != @sizeOf(E.Value) or out.len < @sizeOf(E.Value)) return null;
                const ctx = restorePtr(E.Context, ctx_addr);
                const duped = E.dupValue(ctx, loadValue(E, callback_bytes));
                return storeValue(E, duped, out);
            }
            return null;
        }
    }
    return null;
}

pub fn timerFreeValue(tag: Backend, ctx_addr: usize, callback_bytes: []const u8) void {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                const E = backend.Engine(cand);
                if (callback_bytes.len != @sizeOf(E.Value)) return;
                const ctx = restorePtr(E.Context, ctx_addr);
                E.freeValue(ctx, loadValue(E, callback_bytes));
            }
            return;
        }
    }
}

pub fn timerStoreUndefined(tag: Backend, out: []u8) usize {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                const E = backend.Engine(cand);
                if (out.len < @sizeOf(E.Value)) return 0;
                return storeValue(E, E.undefinedValue(), out);
            }
            return 0;
        }
    }
    return 0;
}

pub fn timerCallNoArgs(tag: Backend, ctx_addr: usize, callback_bytes: []const u8) ?[]const u8 {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                const E = backend.Engine(cand);
                if (callback_bytes.len != @sizeOf(E.Value)) return null;
                const ctx = restorePtr(E.Context, ctx_addr);
                return E.callFunctionNoArgs(ctx, loadValue(E, callback_bytes));
            }
            return null;
        }
    }
    return null;
}

pub fn destroyPacked(tag: Backend, handles: Handles) void {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand)) {
                const E = backend.Engine(cand);
                const ctx = restorePtr(E.Context, handles.ctx_addr);
                const rt = restorePtr(E.Runtime, handles.runtime_addr);
                if (handles.ctx_addr != 0) {
                    E.runGc(rt);
                    E.freeContext(ctx);
                    E.runGc(rt);
                }
                if (handles.runtime_addr != 0) E.freeRuntime(rt);
            }
            return;
        }
    }
}

pub fn evalPacked(tag: Backend, handles: Handles, script: []const u8, filename: []const u8) types.EvalResult {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand)) {
                const E = backend.Engine(cand);
                const ctx = restorePtr(E.Context, handles.ctx_addr);
                return E.eval(ctx, script, filename);
            }
            return .{ .result = null, .err = "backend not packed", .err_is_heap = false };
        }
    }
    return .{ .result = null, .err = "unknown backend", .err_is_heap = false };
}

pub fn processPendingJobsPacked(tag: Backend, handles: Handles) void {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand)) {
                const E = backend.Engine(cand);
                const ctx = restorePtr(E.Context, handles.ctx_addr);
                E.processPendingJobs(ctx);
            }
            return;
        }
    }
}

pub fn runGcPacked(tag: Backend, handles: Handles) void {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                if (comptime backend.isQuickJsApiBackend(cand)) {
                    const E = backend.Engine(cand);
                    const Mod = backend.EngineModule(cand);
                    const rt = restorePtr(E.Runtime, handles.runtime_addr);
                    Mod.qjsRunGc(rt);
                } else {
                    const jsc_mod = @import("backend/jsc.zig");
                    const E = backend.Engine(cand);
                    const ctx = restorePtr(E.Context, handles.ctx_addr);
                    jsc_mod.jscRunGc(@ptrCast(ctx));
                }
            }
            return;
        }
    }
}

pub const ErasedValue = struct {
    bytes: [value_storage_size]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const ErasedValue) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const EvalValueResult = struct {
    value: ?ErasedValue = null,
    exception: ?ErasedValue = null,
    out_of_memory: bool = false,
};

fn storeErased(comptime E: type, value: E.Value) ErasedValue {
    var out: ErasedValue = .{};
    out.len = @intCast(storeValue(E, value, out.bytes[0..]));
    return out;
}

fn evalValueReal(comptime tag: Backend, handles: Handles, source: []const u8, filename: []const u8) EvalValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    const ctx = restorePtr(E.Context, handles.ctx_addr);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        if (!Mod.lifecycle.enterJs(ctx)) return .{ .out_of_memory = true };
    }
    defer if (comptime backend.isQuickJsApiBackend(tag)) Mod.lifecycle.leaveJs(ctx);

    defer E.processPendingJobs(ctx);

    if (comptime backend.isQuickJsApiBackend(tag)) {
        const gpa = std.heap.c_allocator;
        const filename_z = gpa.dupeSentinel(u8, filename, 0) catch return .{ .out_of_memory = true };
        defer gpa.free(filename_z);
        const source_z = gpa.dupeSentinel(u8, source, 0) catch return .{ .out_of_memory = true };
        defer gpa.free(source_z);
        if (@hasDecl(Mod.lifecycle, "syncStackTopForJs")) Mod.lifecycle.syncStackTopForJs(ctx);
        const raw = Mod.qjs.JS_Eval(ctx, source_z.ptr, source_z.len, filename_z.ptr, Mod.qjs.JS_EVAL_TYPE_GLOBAL);
        if (Mod.c_api.jsIsException(raw)) {
            const exc = Mod.qjs.JS_GetException(ctx);
            return .{ .exception = storeErased(E, exc) };
        }
        return .{ .value = storeErased(E, raw) };
    } else {
        // JSC
        const jsc = Mod.jsc;
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const source_string = blk: {
            const chars = std.unicode.utf8ToUtf16LeAlloc(std.heap.c_allocator, source) catch return .{ .out_of_memory = true };
            defer std.heap.c_allocator.free(chars);
            const empty = [_]u16{0};
            break :blk jsc.JSStringCreateWithCharacters(if (chars.len == 0) &empty else chars.ptr, chars.len);
        };
        if (source_string == null) return .{ .out_of_memory = true };
        defer jsc.JSStringRelease(source_string);
        const filename_string = blk: {
            const chars = std.unicode.utf8ToUtf16LeAlloc(std.heap.c_allocator, filename) catch return .{ .out_of_memory = true };
            defer std.heap.c_allocator.free(chars);
            const empty = [_]u16{0};
            break :blk jsc.JSStringCreateWithCharacters(if (chars.len == 0) &empty else chars.ptr, chars.len);
        };
        if (filename_string == null) return .{ .out_of_memory = true };
        defer jsc.JSStringRelease(filename_string);
        var exception: jsc.JSValueRef = null;
        const result = jsc.JSEvaluateScript(ctx_ref, source_string, null, filename_string, 1, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (result == null) return .{ .out_of_memory = true };
        jsc.JSValueProtect(ctx_ref, result);
        return .{ .value = storeErased(E, result) };
    }
}

pub fn evalValuePacked(tag: Backend, handles: Handles, source: []const u8, filename: []const u8) EvalValueResult {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand)) return evalValueReal(cand, handles, source, filename);
            return .{ .out_of_memory = true };
        }
    }
    return .{ .out_of_memory = true };
}

pub fn enterJsPacked(tag: Backend, ctx_addr: usize) bool {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                if (comptime backend.isQuickJsApiBackend(cand)) {
                    const E = backend.Engine(cand);
                    const Mod = backend.EngineModule(cand);
                    const ctx = restorePtr(E.Context, ctx_addr);
                    return Mod.lifecycle.enterJs(ctx);
                }
                return true;
            }
            return false;
        }
    }
    return false;
}

pub fn leaveJsPacked(tag: Backend, ctx_addr: usize) void {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime (multi_pack.isPacked(cand) or cand == backend.active_backend) and backend.isQuickJsApiBackend(cand)) {
                const E = backend.Engine(cand);
                const Mod = backend.EngineModule(cand);
                const ctx = restorePtr(E.Context, ctx_addr);
                Mod.lifecycle.leaveJs(ctx);
            }
            return;
        }
    }
}

pub fn valueTypeKind(tag: Backend, ctx_addr: usize, callback_bytes: []const u8) c_int {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                const E = backend.Engine(cand);
                if (callback_bytes.len != @sizeOf(E.Value)) return 5;
                const ctx = restorePtr(E.Context, ctx_addr);
                const v = loadValue(E, callback_bytes);
                if (E.isUndefined(ctx, v)) return 0;
                if (E.isNull(ctx, v)) return 1;
                if (E.isBool(ctx, v)) return 2;
                if (E.isNumber(ctx, v)) return 3;
                if (E.isString(ctx, v)) return 4;
                if (E.isArray(ctx, v)) return 6;
                if (E.isFunction(ctx, v)) return 7;
                if (E.isSymbol(ctx, v)) return 8;
                if (E.isBigInt(ctx, v)) return 9;
                return 5;
            }
            return 5;
        }
    }
    return 5;
}

pub fn valueIsNumber(tag: Backend, ctx_addr: usize, callback_bytes: []const u8) bool {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                const E = backend.Engine(cand);
                if (callback_bytes.len != @sizeOf(E.Value)) return false;
                return E.isNumber(restorePtr(E.Context, ctx_addr), loadValue(E, callback_bytes));
            }
            return false;
        }
    }
    return false;
}

pub fn valueToFloat64(tag: Backend, ctx_addr: usize, callback_bytes: []const u8) ?f64 {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                const E = backend.Engine(cand);
                if (callback_bytes.len != @sizeOf(E.Value)) return null;
                return E.toFloat64(restorePtr(E.Context, ctx_addr), loadValue(E, callback_bytes));
            }
            return null;
        }
    }
    return null;
}

pub fn valueToUtf8(tag: Backend, ctx_addr: usize, callback_bytes: []const u8) BytesValueResult {
    return dispatchBytesValue(tag, valueToUtf8Real, .{ ctx_addr, callback_bytes });
}

fn valueToUtf8Real(comptime tag: Backend, ctx_addr: usize, value_bytes: []const u8) BytesValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    if (value_bytes.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
    const ctx = restorePtr(E.Context, ctx_addr);
    const value = loadValue(E, value_bytes);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        // Mirror api_backend.qjsBytes: ToCStringLen does ToString and surfaces throws.
        var len: usize = 0;
        const text = Mod.qjs.JS_ToCStringLen(ctx, &len, value) orelse return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        defer Mod.qjs.JS_FreeCString(ctx, text);
        const bytes = std.heap.c_allocator.dupe(u8, text[0..len]) catch return .{ .out_of_memory = true };
        return .{ .bytes = bytes };
    } else {
        const common = @import("backend/jsc/common.zig");
        const jsc = Mod.jsc;
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        var exception: jsc.JSValueRef = null;
        const string = jsc.JSValueToStringCopy(ctx_ref, common.liftValue(ctx_ref, value), &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        const text = string orelse return .{ .out_of_memory = true };
        defer jsc.JSStringRelease(text);
        return .{ .bytes = common.jsStringToOwnedAlloc(std.heap.c_allocator, text) orelse return .{ .out_of_memory = true } };
    }
}

pub fn valueGetProperty(tag: Backend, ctx_addr: usize, object_bytes: []const u8, key: [:0]const u8) EvalValueResult {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                const E = backend.Engine(cand);
                const Mod = backend.EngineModule(cand);
                if (object_bytes.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
                const ctx = restorePtr(E.Context, ctx_addr);
                const object = loadValue(E, object_bytes);
                if (comptime backend.isQuickJsApiBackend(cand)) {
                    const value = Mod.qjs.JS_GetPropertyStr(ctx, object, key.ptr);
                    if (Mod.c_api.jsIsException(value)) {
                        return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
                    }
                    return .{ .value = storeErased(E, value) };
                } else {
                    // Mirror api_backend.jscGet: ToObject first, then surface getter throws.
                    // Do not use getPropertyVal here — it collapses exceptions into "missing".
                    const jsc = Mod.jsc;
                    const common = @import("backend/jsc/common.zig");
                    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
                    var exception: jsc.JSValueRef = null;
                    const target = jsc.JSValueToObject(ctx_ref, common.liftValue(ctx_ref, object), &exception);
                    if (exception != null) {
                        jsc.JSValueProtect(ctx_ref, exception);
                        return .{ .exception = storeErased(E, exception) };
                    }
                    if (target == null) return .{ .out_of_memory = true };
                    const name = common.jsStringFromSlice(key) orelse return .{ .out_of_memory = true };
                    defer jsc.JSStringRelease(name);
                    const value = jsc.JSObjectGetProperty(ctx_ref, target, name, &exception);
                    if (exception != null) {
                        jsc.JSValueProtect(ctx_ref, exception);
                        return .{ .exception = storeErased(E, exception) };
                    }
                    if (value == null) return .{ .out_of_memory = true };
                    jsc.JSValueProtect(ctx_ref, value);
                    return .{ .value = storeErased(E, value) };
                }
            }
            return .{ .out_of_memory = true };
        }
    }
    return .{ .out_of_memory = true };
}

fn valueNewPrimitiveReal(comptime tag: Backend, ctx_addr: usize, kind: enum { undefined_v, null_v, bool_v, number_v }, bool_val: bool, number_val: f64) EvalValueResult {
    const E = backend.Engine(tag);
    const ctx = restorePtr(E.Context, ctx_addr);
    const made = switch (kind) {
        .undefined_v => E.undefinedValue(),
        .null_v => E.nullValue(),
        .bool_v => E.newBoolVal(ctx, bool_val),
        .number_v => E.newFloat64Val(ctx, number_val),
    };
    if (comptime !backend.isQuickJsApiBackend(tag)) {
        // JSC newBool/newFloat can return null on pathological failure.
        if (kind == .bool_v or kind == .number_v) {
            if (made == null) return .{ .out_of_memory = true };
        }
    }
    return .{ .value = storeErased(E, made) };
}

fn valueNewStringReal(comptime tag: Backend, ctx_addr: usize, input: []const u8) EvalValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    const ctx = restorePtr(E.Context, ctx_addr);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        const value = E.newStringVal(ctx, input);
        if (Mod.c_api.jsIsException(value)) {
            // Constructor APIs publish OOM, not a live exception.
            E.freeValue(ctx, value);
            const exc = Mod.qjs.JS_GetException(ctx);
            E.freeValue(ctx, exc);
            return .{ .out_of_memory = true };
        }
        return .{ .value = storeErased(E, value) };
    } else {
        const value = E.newStringVal(ctx, input);
        if (value == null) return .{ .out_of_memory = true };
        return .{ .value = storeErased(E, value) };
    }
}

fn valueNewObjectReal(comptime tag: Backend, ctx_addr: usize) EvalValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    const ctx = restorePtr(E.Context, ctx_addr);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        const value = E.newObject(ctx);
        if (Mod.c_api.jsIsException(value)) {
            E.freeValue(ctx, value);
            const exc = Mod.qjs.JS_GetException(ctx);
            E.freeValue(ctx, exc);
            return .{ .out_of_memory = true };
        }
        return .{ .value = storeErased(E, value) };
    } else {
        const value = E.newObject(ctx) orelse return .{ .out_of_memory = true };
        return .{ .value = storeErased(E, value) };
    }
}

fn valueNewArrayReal(comptime tag: Backend, ctx_addr: usize) EvalValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    const ctx = restorePtr(E.Context, ctx_addr);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        const value = E.newArray(ctx, 0) orelse return .{ .out_of_memory = true };
        if (Mod.c_api.jsIsException(value)) {
            E.freeValue(ctx, value);
            const exc = Mod.qjs.JS_GetException(ctx);
            E.freeValue(ctx, exc);
            return .{ .out_of_memory = true };
        }
        return .{ .value = storeErased(E, value) };
    } else {
        const value = E.newArray(ctx, 0) orelse return .{ .out_of_memory = true };
        return .{ .value = storeErased(E, value) };
    }
}

fn valueGetGlobalReal(comptime tag: Backend, ctx_addr: usize) EvalValueResult {
    const E = backend.Engine(tag);
    const ctx = restorePtr(E.Context, ctx_addr);
    return .{ .value = storeErased(E, E.getGlobalObject(ctx)) };
}

fn valueNewArrayBufferReal(comptime tag: Backend, ctx_addr: usize, bytes: []const u8) EvalValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    const ctx = restorePtr(E.Context, ctx_addr);
    const value = E.newArrayBufferCopyVal(ctx, bytes);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        if (Mod.c_api.jsIsException(value)) {
            return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        }
        return .{ .value = storeErased(E, value) };
    } else {
        if (value == null) return .{ .out_of_memory = true };
        return .{ .value = storeErased(E, value) };
    }
}

/// `value_bytes` must be an owned duplicate; this consumes it on every path (success, throw, OOM).
fn valueSetPropertyReal(comptime tag: Backend, ctx_addr: usize, object_bytes: []const u8, key: [:0]const u8, value_bytes: []const u8) EvalValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    const ctx = restorePtr(E.Context, ctx_addr);
    if (object_bytes.len != @sizeOf(E.Value) or value_bytes.len != @sizeOf(E.Value)) {
        if (value_bytes.len == @sizeOf(E.Value)) E.freeValue(ctx, loadValue(E, value_bytes));
        return .{ .out_of_memory = true };
    }
    const object = loadValue(E, object_bytes);
    const value = loadValue(E, value_bytes);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        if (Mod.qjs.JS_SetPropertyStr(ctx, object, key.ptr, value) < 0) {
            return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        }
        return .{};
    } else {
        // Mirror api_backend.jscSet: consume the duplicate ourselves; JSC assignment does not steal protect.
        defer E.freeValue(ctx, value);
        const jsc = Mod.jsc;
        const common = @import("backend/jsc/common.zig");
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        var exception: jsc.JSValueRef = null;
        const target = jsc.JSValueToObject(ctx_ref, common.liftValue(ctx_ref, object), &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (target == null) return .{ .out_of_memory = true };
        const name = common.jsStringFromSlice(key) orelse return .{ .out_of_memory = true };
        defer jsc.JSStringRelease(name);
        jsc.JSObjectSetProperty(ctx_ref, target, name, common.liftValue(ctx_ref, value), 0, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        return .{};
    }
}

fn valueCallReal(comptime tag: Backend, ctx_addr: usize, func_bytes: []const u8, this_bytes: []const u8, arg_slices: []const []const u8) EvalValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    if (func_bytes.len != @sizeOf(E.Value) or this_bytes.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
    for (arg_slices) |a| {
        if (a.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
    }
    const ctx = restorePtr(E.Context, ctx_addr);
    const function = loadValue(E, func_bytes);
    const this_value = loadValue(E, this_bytes);
    var args = std.ArrayList(E.Value).empty;
    defer args.deinit(std.heap.c_allocator);
    args.ensureTotalCapacityPrecise(std.heap.c_allocator, arg_slices.len) catch return .{ .out_of_memory = true };
    for (arg_slices) |a| args.appendAssumeCapacity(loadValue(E, a));

    if (comptime backend.isQuickJsApiBackend(tag)) {
        if (@hasDecl(Mod.lifecycle, "syncStackTopForJs")) Mod.lifecycle.syncStackTopForJs(ctx);
        const raw = Mod.qjs.JS_Call(ctx, function, this_value, @intCast(args.items.len), @constCast(args.items.ptr));
        if (Mod.c_api.jsIsException(raw)) {
            return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        }
        return .{ .value = storeErased(E, raw) };
    } else {
        const jsc = Mod.jsc;
        const common = @import("backend/jsc/common.zig");
        const value_mod = @import("backend/jsc/value.zig");
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const lifted_function = common.liftValue(ctx_ref, function);
        if (!jsc.JSValueIsObject(ctx_ref, lifted_function)) {
            var type_error: jsc.JSValueRef = null;
            const boxed = jsc.JSValueToObject(ctx_ref, lifted_function, &type_error);
            if (type_error != null) {
                jsc.JSValueProtect(ctx_ref, type_error);
                return .{ .exception = storeErased(E, type_error) };
            }
            if (boxed == null) return .{ .out_of_memory = true };
            _ = jsc.JSObjectCallAsFunction(ctx_ref, boxed, jsc.JSContextGetGlobalObject(ctx_ref), 0, null, &type_error);
            if (type_error != null) {
                jsc.JSValueProtect(ctx_ref, type_error);
                return .{ .exception = storeErased(E, type_error) };
            }
            return .{ .out_of_memory = true };
        }
        const target: jsc.JSObjectRef = @ptrCast(@constCast(lifted_function));
        const apply = value_mod.functionApply(ctx) orelse return .{ .out_of_memory = true };
        var exception: jsc.JSValueRef = null;
        var lifted_args = std.ArrayList(jsc.JSValueRef).empty;
        defer lifted_args.deinit(std.heap.c_allocator);
        lifted_args.ensureTotalCapacityPrecise(std.heap.c_allocator, args.items.len) catch return .{ .out_of_memory = true };
        for (args.items) |arg| lifted_args.appendAssumeCapacity(common.liftValue(ctx_ref, arg));
        const arg_array = jsc.JSObjectMakeArray(ctx_ref, lifted_args.items.len, lifted_args.items.ptr, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (arg_array == null) return .{ .out_of_memory = true };
        const apply_args = [_]jsc.JSValueRef{ common.liftValue(ctx_ref, this_value), arg_array };
        const result = jsc.JSObjectCallAsFunction(ctx_ref, apply, target, apply_args.len, &apply_args, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (result == null) return .{ .out_of_memory = true };
        jsc.JSValueProtect(ctx_ref, result);
        return .{ .value = storeErased(E, result) };
    }
}

fn valueConstructReal(comptime tag: Backend, ctx_addr: usize, func_bytes: []const u8, arg_slices: []const []const u8) EvalValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    if (func_bytes.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
    for (arg_slices) |a| {
        if (a.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
    }
    const ctx = restorePtr(E.Context, ctx_addr);
    const function = loadValue(E, func_bytes);
    var args = std.ArrayList(E.Value).empty;
    defer args.deinit(std.heap.c_allocator);
    args.ensureTotalCapacityPrecise(std.heap.c_allocator, arg_slices.len) catch return .{ .out_of_memory = true };
    for (arg_slices) |a| args.appendAssumeCapacity(loadValue(E, a));

    if (comptime backend.isQuickJsApiBackend(tag)) {
        if (@hasDecl(Mod.lifecycle, "syncStackTopForJs")) Mod.lifecycle.syncStackTopForJs(ctx);
        const raw = Mod.qjs.JS_CallConstructor(ctx, function, @intCast(args.items.len), @constCast(args.items.ptr));
        if (Mod.c_api.jsIsException(raw)) {
            return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        }
        return .{ .value = storeErased(E, raw) };
    } else {
        const jsc = Mod.jsc;
        const common = @import("backend/jsc/common.zig");
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const lifted_function = common.liftValue(ctx_ref, function);
        if (!jsc.JSValueIsObject(ctx_ref, lifted_function) or !jsc.JSObjectIsConstructor(ctx_ref, @ptrCast(@constCast(lifted_function)))) {
            const msg_val = common.makeStringValue(ctx_ref, "value is not a constructor") orelse return .{ .out_of_memory = true };
            var args_err = [_]jsc.JSValueRef{msg_val};
            var inner: jsc.JSValueRef = null;
            const err = jsc.JSObjectMakeError(ctx_ref, 1, &args_err, &inner);
            if (err == null) return .{ .out_of_memory = true };
            jsc.JSValueProtect(ctx_ref, err);
            return .{ .exception = storeErased(E, err) };
        }
        var lifted_args = std.ArrayList(jsc.JSValueRef).empty;
        defer lifted_args.deinit(std.heap.c_allocator);
        lifted_args.ensureTotalCapacityPrecise(std.heap.c_allocator, args.items.len) catch return .{ .out_of_memory = true };
        for (args.items) |arg| lifted_args.appendAssumeCapacity(common.liftValue(ctx_ref, arg));
        var exception: jsc.JSValueRef = null;
        const result = jsc.JSObjectCallAsConstructor(ctx_ref, @ptrCast(@constCast(lifted_function)), lifted_args.items.len, lifted_args.items.ptr, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (result == null) return .{ .out_of_memory = true };
        jsc.JSValueProtect(ctx_ref, result);
        return .{ .value = storeErased(E, result) };
    }
}

fn dispatchEvalValue(tag: Backend, comptime real: anytype, args: anytype) EvalValueResult {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                return @call(.auto, real, .{cand} ++ args);
            }
            return .{ .out_of_memory = true };
        }
    }
    return .{ .out_of_memory = true };
}

pub fn valueNewUndefined(tag: Backend, ctx_addr: usize) EvalValueResult {
    return dispatchEvalValue(tag, valueNewPrimitiveReal, .{ ctx_addr, .undefined_v, false, 0 });
}

pub fn valueNewNull(tag: Backend, ctx_addr: usize) EvalValueResult {
    return dispatchEvalValue(tag, valueNewPrimitiveReal, .{ ctx_addr, .null_v, false, 0 });
}

pub fn valueNewBool(tag: Backend, ctx_addr: usize, input: bool) EvalValueResult {
    return dispatchEvalValue(tag, valueNewPrimitiveReal, .{ ctx_addr, .bool_v, input, 0 });
}

pub fn valueNewNumber(tag: Backend, ctx_addr: usize, input: f64) EvalValueResult {
    return dispatchEvalValue(tag, valueNewPrimitiveReal, .{ ctx_addr, .number_v, false, input });
}

pub fn valueNewString(tag: Backend, ctx_addr: usize, input: []const u8) EvalValueResult {
    return dispatchEvalValue(tag, valueNewStringReal, .{ ctx_addr, input });
}

pub fn valueNewObject(tag: Backend, ctx_addr: usize) EvalValueResult {
    return dispatchEvalValue(tag, valueNewObjectReal, .{ctx_addr});
}

pub fn valueNewArray(tag: Backend, ctx_addr: usize) EvalValueResult {
    return dispatchEvalValue(tag, valueNewArrayReal, .{ctx_addr});
}

pub fn valueGetGlobal(tag: Backend, ctx_addr: usize) EvalValueResult {
    return dispatchEvalValue(tag, valueGetGlobalReal, .{ctx_addr});
}

pub fn valueNewArrayBuffer(tag: Backend, ctx_addr: usize, bytes: []const u8) EvalValueResult {
    return dispatchEvalValue(tag, valueNewArrayBufferReal, .{ ctx_addr, bytes });
}

/// Consumes `value_bytes` (owned duplicate) on every path.
pub fn valueSetProperty(tag: Backend, ctx_addr: usize, object_bytes: []const u8, key: [:0]const u8, value_bytes: []const u8) EvalValueResult {
    return dispatchEvalValue(tag, valueSetPropertyReal, .{ ctx_addr, object_bytes, key, value_bytes });
}

pub fn valueCall(tag: Backend, ctx_addr: usize, func_bytes: []const u8, this_bytes: []const u8, arg_slices: []const []const u8) EvalValueResult {
    return dispatchEvalValue(tag, valueCallReal, .{ ctx_addr, func_bytes, this_bytes, arg_slices });
}

pub fn valueConstruct(tag: Backend, ctx_addr: usize, func_bytes: []const u8, arg_slices: []const []const u8) EvalValueResult {
    return dispatchEvalValue(tag, valueConstructReal, .{ ctx_addr, func_bytes, arg_slices });
}

pub const BoolValueResult = struct {
    value: bool = false,
    exception: ?ErasedValue = null,
    out_of_memory: bool = false,
};

pub const BytesValueResult = struct {
    bytes: ?[]u8 = null,
    exception: ?ErasedValue = null,
    out_of_memory: bool = false,
    invalid_argument: bool = false,
};

fn dispatchBoolValue(tag: Backend, comptime real: anytype, args: anytype) BoolValueResult {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                return @call(.auto, real, .{cand} ++ args);
            }
            return .{ .out_of_memory = true };
        }
    }
    return .{ .out_of_memory = true };
}

fn dispatchBytesValue(tag: Backend, comptime real: anytype, args: anytype) BytesValueResult {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                return @call(.auto, real, .{cand} ++ args);
            }
            return .{ .out_of_memory = true };
        }
    }
    return .{ .out_of_memory = true };
}

pub fn valueIsBool(tag: Backend, ctx_addr: usize, callback_bytes: []const u8) bool {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                const E = backend.Engine(cand);
                if (callback_bytes.len != @sizeOf(E.Value)) return false;
                return E.isBool(restorePtr(E.Context, ctx_addr), loadValue(E, callback_bytes));
            }
            return false;
        }
    }
    return false;
}

pub fn valueToBool(tag: Backend, ctx_addr: usize, callback_bytes: []const u8) ?bool {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime multi_pack.isPacked(cand) or cand == backend.active_backend) {
                const E = backend.Engine(cand);
                if (callback_bytes.len != @sizeOf(E.Value)) return null;
                return E.toBool(restorePtr(E.Context, ctx_addr), loadValue(E, callback_bytes));
            }
            return null;
        }
    }
    return null;
}

fn valueHasReal(comptime tag: Backend, ctx_addr: usize, object_bytes: []const u8, key: [:0]const u8) BoolValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    if (object_bytes.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
    const ctx = restorePtr(E.Context, ctx_addr);
    const object = loadValue(E, object_bytes);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        if (!E.isObjectVal(ctx, object)) {
            _ = Mod.qjs.JS_ThrowTypeError(ctx, "%s", @as([*:0]const u8, "cannot use 'in' operator to search for a key in a non-object"));
            return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        }
        const atom = Mod.qjs.JS_NewAtomLen(ctx, key.ptr, key.len);
        if (atom == 0) {
            E.freeValue(ctx, Mod.qjs.JS_GetException(ctx));
            return .{ .out_of_memory = true };
        }
        defer Mod.qjs.JS_FreeAtom(ctx, atom);
        const found = Mod.qjs.JS_HasProperty(ctx, object, atom);
        if (found < 0) return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        return .{ .value = found != 0 };
    } else {
        const common = @import("backend/jsc/common.zig");
        const jsc = Mod.jsc;
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const intrinsics = @import("backend/jsc/object_intrinsics.zig").get(@ptrCast(ctx)) orelse return .{ .out_of_memory = true };
        const text = common.jsStringFromSlice(key) orelse return .{ .out_of_memory = true };
        defer jsc.JSStringRelease(text);
        const key_value = jsc.JSValueMakeString(ctx_ref, text);
        const args = [_]jsc.JSValueRef{ common.liftValue(ctx_ref, object), key_value };
        var exception: jsc.JSValueRef = null;
        const value = jsc.JSObjectCallAsFunction(ctx_ref, intrinsics.has, null, args.len, &args, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (value == null) return .{ .out_of_memory = true };
        return .{ .value = jsc.JSValueToBoolean(ctx_ref, value) };
    }
}

fn valueDeleteReal(comptime tag: Backend, ctx_addr: usize, object_bytes: []const u8, key: [:0]const u8) BoolValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    if (object_bytes.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
    const ctx = restorePtr(E.Context, ctx_addr);
    const object = loadValue(E, object_bytes);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        const target = Mod.qjs.JS_ToObject(ctx, object);
        if (Mod.c_api.jsIsException(target)) return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        defer Mod.qjs.JS_FreeValue(ctx, target);
        const atom = Mod.qjs.JS_NewAtomLen(ctx, key.ptr, key.len);
        if (atom == 0) {
            E.freeValue(ctx, Mod.qjs.JS_GetException(ctx));
            return .{ .out_of_memory = true };
        }
        defer Mod.qjs.JS_FreeAtom(ctx, atom);
        const deleted = Mod.qjs.JS_DeleteProperty(ctx, target, atom, 0);
        if (deleted < 0) return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        return .{ .value = deleted != 0 };
    } else {
        const common = @import("backend/jsc/common.zig");
        const jsc = Mod.jsc;
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const intrinsics = @import("backend/jsc/object_intrinsics.zig").get(@ptrCast(ctx)) orelse return .{ .out_of_memory = true };
        const text = common.jsStringFromSlice(key) orelse return .{ .out_of_memory = true };
        defer jsc.JSStringRelease(text);
        const key_value = jsc.JSValueMakeString(ctx_ref, text);
        const args = [_]jsc.JSValueRef{ common.liftValue(ctx_ref, object), key_value };
        var exception: jsc.JSValueRef = null;
        const value = jsc.JSObjectCallAsFunction(ctx_ref, intrinsics.delete, null, args.len, &args, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (value == null) return .{ .out_of_memory = true };
        return .{ .value = jsc.JSValueToBoolean(ctx_ref, value) };
    }
}

fn valueKeysReal(comptime tag: Backend, ctx_addr: usize, object_bytes: []const u8) EvalValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    if (object_bytes.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
    const ctx = restorePtr(E.Context, ctx_addr);
    const object = loadValue(E, object_bytes);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        const target = Mod.qjs.JS_ToObject(ctx, object);
        if (Mod.c_api.jsIsException(target)) return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        defer Mod.qjs.JS_FreeValue(ctx, target);
        var table: [*c]Mod.qjs.JSPropertyEnum = null;
        var count: u32 = 0;
        if (Mod.qjs.JS_GetOwnPropertyNames(ctx, &table, &count, target, Mod.qjs.JS_GPN_STRING_MASK | Mod.qjs.JS_GPN_ENUM_ONLY) < 0) {
            return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        }
        defer Mod.qjs.JS_FreePropertyEnum(ctx, table, count);
        const array = Mod.qjs.JS_NewArray(ctx);
        if (Mod.c_api.jsIsException(array)) return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            const name = Mod.qjs.JS_AtomToString(ctx, table[index].atom);
            if (Mod.c_api.jsIsException(name)) {
                Mod.qjs.JS_FreeValue(ctx, array);
                return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
            }
            if (Mod.qjs.JS_DefinePropertyValueUint32(ctx, array, index, name, Mod.qjs.JS_PROP_C_W_E | Mod.qjs.JS_PROP_THROW) < 0) {
                Mod.qjs.JS_FreeValue(ctx, array);
                return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
            }
        }
        return .{ .value = storeErased(E, array) };
    } else {
        const common = @import("backend/jsc/common.zig");
        const jsc = Mod.jsc;
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const intrinsics = @import("backend/jsc/object_intrinsics.zig").get(@ptrCast(ctx)) orelse return .{ .out_of_memory = true };
        const args = [_]jsc.JSValueRef{common.liftValue(ctx_ref, object)};
        var exception: jsc.JSValueRef = null;
        const value = jsc.JSObjectCallAsFunction(ctx_ref, intrinsics.keys, null, args.len, &args, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (value == null) return .{ .out_of_memory = true };
        jsc.JSValueProtect(ctx_ref, value);
        return .{ .value = storeErased(E, value) };
    }
}

fn valueInstanceOfReal(comptime tag: Backend, ctx_addr: usize, value_bytes: []const u8, ctor_bytes: []const u8) BoolValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    if (value_bytes.len != @sizeOf(E.Value) or ctor_bytes.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
    const ctx = restorePtr(E.Context, ctx_addr);
    const value = loadValue(E, value_bytes);
    const constructor = loadValue(E, ctor_bytes);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        const result = Mod.JS_IsInstanceOf(ctx, value, constructor);
        if (result < 0) return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        return .{ .value = result != 0 };
    } else {
        const common = @import("backend/jsc/common.zig");
        const jsc = Mod.jsc;
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const intrinsics = @import("backend/jsc/object_intrinsics.zig").get(@ptrCast(ctx)) orelse return .{ .out_of_memory = true };
        const args = [_]jsc.JSValueRef{ common.liftValue(ctx_ref, value), common.liftValue(ctx_ref, constructor) };
        var exception: jsc.JSValueRef = null;
        const out = jsc.JSObjectCallAsFunction(ctx_ref, intrinsics.instance_of, null, args.len, &args, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (out == null) return .{ .out_of_memory = true };
        return .{ .value = jsc.JSValueToBoolean(ctx_ref, out) };
    }
}

fn valueNewJsonReal(comptime tag: Backend, ctx_addr: usize, input: []const u8) EvalValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    const ctx = restorePtr(E.Context, ctx_addr);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        const bytes = std.heap.c_allocator.dupeSentinel(u8, input, 0) catch return .{ .out_of_memory = true };
        defer std.heap.c_allocator.free(bytes);
        const value = Mod.qjs.JS_ParseJSON(ctx, bytes.ptr, bytes.len, "<json>");
        if (Mod.c_api.jsIsException(value)) return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        return .{ .value = storeErased(E, value) };
    } else {
        const common = @import("backend/jsc/common.zig");
        const jsc = Mod.jsc;
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const text = common.jsStringFromSlice(input) orelse return .{ .out_of_memory = true };
        defer jsc.JSStringRelease(text);
        const value = jsc.JSValueMakeFromJSONString(ctx_ref, text);
        if (value == null) {
            // Match primary: synthesize an Error("invalid JSON") as the exception.
            const msg = common.jsStringFromSlice("invalid JSON") orelse return .{ .out_of_memory = true };
            defer jsc.JSStringRelease(msg);
            const argument = jsc.JSValueMakeString(ctx_ref, msg);
            var inner: jsc.JSValueRef = null;
            const err = jsc.JSObjectMakeError(ctx_ref, 1, &argument, &inner);
            if (err == null) return .{ .out_of_memory = true };
            jsc.JSValueProtect(ctx_ref, err);
            return .{ .exception = storeErased(E, err) };
        }
        jsc.JSValueProtect(ctx_ref, value);
        return .{ .value = storeErased(E, value) };
    }
}

fn valueNewErrorReal(comptime tag: Backend, ctx_addr: usize, message: []const u8) EvalValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    const ctx = restorePtr(E.Context, ctx_addr);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        const error_value = Mod.qjs.JS_NewError(ctx);
        if (Mod.c_api.jsIsException(error_value)) {
            E.freeValue(ctx, error_value);
            const exc = Mod.qjs.JS_GetException(ctx);
            E.freeValue(ctx, exc);
            return .{ .out_of_memory = true };
        }
        const text = Mod.qjs.JS_NewStringLen(ctx, message.ptr, message.len);
        if (Mod.c_api.jsIsException(text)) {
            Mod.qjs.JS_FreeValue(ctx, error_value);
            E.freeValue(ctx, Mod.qjs.JS_GetException(ctx));
            return .{ .out_of_memory = true };
        }
        const flags = Mod.qjs.JS_PROP_WRITABLE | Mod.qjs.JS_PROP_CONFIGURABLE;
        if (Mod.qjs.JS_DefinePropertyValueStr(ctx, error_value, "message", text, flags) < 0) {
            Mod.qjs.JS_FreeValue(ctx, error_value);
            E.freeValue(ctx, Mod.qjs.JS_GetException(ctx));
            return .{ .out_of_memory = true };
        }
        return .{ .value = storeErased(E, error_value) };
    } else {
        const common = @import("backend/jsc/common.zig");
        const jsc = Mod.jsc;
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const text = common.jsStringFromSlice(message) orelse return .{ .out_of_memory = true };
        defer jsc.JSStringRelease(text);
        const argument = jsc.JSValueMakeString(ctx_ref, text);
        var exception: jsc.JSValueRef = null;
        const value = jsc.JSObjectMakeError(ctx_ref, 1, &argument, &exception);
        if (exception != null) {
            // Constructor APIs flatten throws to OOM.
            jsc.JSValueProtect(ctx_ref, exception);
            E.freeValue(ctx, exception);
            return .{ .out_of_memory = true };
        }
        if (value == null) return .{ .out_of_memory = true };
        jsc.JSValueProtect(ctx_ref, value);
        return .{ .value = storeErased(E, value) };
    }
}

fn valueToJsonReal(comptime tag: Backend, ctx_addr: usize, value_bytes: []const u8) BytesValueResult {
    const E = backend.Engine(tag);
    const Mod = backend.EngineModule(tag);
    if (value_bytes.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
    const ctx = restorePtr(E.Context, ctx_addr);
    const value = loadValue(E, value_bytes);
    // Cross-backend contract: undefined and function have no top-level JSON form.
    if (E.isUndefined(ctx, value) or E.isFunction(ctx, value)) return .{ .invalid_argument = true };
    if (comptime backend.isQuickJsApiBackend(tag)) {
        const json = Mod.qjs.JS_JSONStringify(ctx, value, Mod.c_api.JS_UNDEFINED, Mod.c_api.JS_UNDEFINED);
        if (Mod.c_api.jsIsException(json)) return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        defer Mod.qjs.JS_FreeValue(ctx, json);
        if (Mod.c_api.jsIsUndefined(json)) return .{ .invalid_argument = true };
        var len: usize = 0;
        const text = Mod.qjs.JS_ToCStringLen(ctx, &len, json) orelse return .{ .exception = storeErased(E, Mod.qjs.JS_GetException(ctx)) };
        defer Mod.qjs.JS_FreeCString(ctx, text);
        const bytes = std.heap.c_allocator.dupe(u8, text[0..len]) catch return .{ .out_of_memory = true };
        return .{ .bytes = bytes };
    } else {
        const common = @import("backend/jsc/common.zig");
        const jsc = Mod.jsc;
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        var exception: jsc.JSValueRef = null;
        const result = jsc.JSValueCreateJSONString(ctx_ref, common.liftValue(ctx_ref, value), 0, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        const text = result orelse return .{ .invalid_argument = true };
        defer jsc.JSStringRelease(text);
        return .{ .bytes = common.jsStringToOwnedAlloc(std.heap.c_allocator, text) orelse return .{ .out_of_memory = true } };
    }
}

fn valueCopyBufferReal(comptime tag: Backend, ctx_addr: usize, value_bytes: []const u8) BytesValueResult {
    const E = backend.Engine(tag);
    if (value_bytes.len != @sizeOf(E.Value)) return .{ .out_of_memory = true };
    const ctx = restorePtr(E.Context, ctx_addr);
    const value = loadValue(E, value_bytes);
    if (comptime backend.isQuickJsApiBackend(tag)) {
        const source: []const u8 = if (E.getArrayBufferSliceVal(ctx, value)) |bytes|
            bytes
        else if (E.getTypedArrayBytesVal(ctx, value)) |view|
            view.bytes
        else if (E.dataViewInfo(ctx, value)) |view|
            view.bytes[view.byte_offset .. view.byte_offset + view.byte_length]
        else
            return .{ .invalid_argument = true };
        return .{ .bytes = std.heap.c_allocator.dupe(u8, source) catch return .{ .out_of_memory = true } };
    } else {
        const Mod = backend.EngineModule(tag);
        const jsc = Mod.jsc;
        const common = @import("backend/jsc/common.zig");
        const intrinsics = @import("backend/jsc/value.zig");
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const effective = common.liftValue(ctx_ref, value);
        if (!jsc.JSValueIsObject(ctx_ref, effective)) return .{ .invalid_argument = true };

        var exception: jsc.JSValueRef = null;
        const kind = jsc.JSValueGetTypedArrayType(ctx_ref, effective, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            // TypeError from buffer APIs maps to invalid_argument on primary.
            if (intrinsics.typeErrorPrototype(@ptrCast(ctx))) |prototype| {
                if (jsc.JSValueIsObject(ctx_ref, exception) and jsc.JSValueIsStrictEqual(ctx_ref, jsc.JSObjectGetPrototype(ctx_ref, @constCast(exception)), prototype)) {
                    E.freeValue(ctx, exception);
                    return .{ .invalid_argument = true };
                }
            }
            return .{ .exception = storeErased(E, exception) };
        }

        var buffer: jsc.JSObjectRef = undefined;
        var byte_offset: usize = 0;
        var byte_length: usize = 0;
        if (kind == jsc.kJSTypedArrayTypeArrayBuffer) {
            buffer = @constCast(effective);
            byte_length = jsc.JSObjectGetArrayBufferByteLength(ctx_ref, buffer, &exception);
            if (exception != null) {
                jsc.JSValueProtect(ctx_ref, exception);
                return .{ .exception = storeErased(E, exception) };
            }
        } else {
            buffer = jsc.JSObjectGetTypedArrayBuffer(ctx_ref, @constCast(effective), &exception);
            if (exception != null) {
                jsc.JSValueProtect(ctx_ref, exception);
                return .{ .exception = storeErased(E, exception) };
            }
            if (buffer == null) return .{ .invalid_argument = true };
            const validator = if (kind == jsc.kJSTypedArrayTypeNone)
                intrinsics.dataViewByteLengthGetter(@ptrCast(ctx))
            else
                intrinsics.typedArrayValues(@ptrCast(ctx));
            const validate = validator orelse return .{ .out_of_memory = true };
            const validation_result = jsc.JSObjectCallAsFunction(ctx_ref, validate, @constCast(effective), 0, null, &exception);
            if (exception != null) {
                jsc.JSValueProtect(ctx_ref, exception);
                return .{ .exception = storeErased(E, exception) };
            }
            if (validation_result == null) return .{ .out_of_memory = true };
            byte_offset = jsc.JSObjectGetTypedArrayByteOffset(ctx_ref, @constCast(effective), &exception);
            if (exception != null) {
                jsc.JSValueProtect(ctx_ref, exception);
                return .{ .exception = storeErased(E, exception) };
            }
            byte_length = jsc.JSObjectGetTypedArrayByteLength(ctx_ref, @constCast(effective), &exception);
            if (exception != null) {
                jsc.JSValueProtect(ctx_ref, exception);
                return .{ .exception = storeErased(E, exception) };
            }
        }
        jsc.JSValueProtect(ctx_ref, buffer);
        defer jsc.JSValueUnprotect(ctx_ref, buffer);

        exception = null;
        const source = jsc.JSObjectMakeTypedArrayWithArrayBufferAndOffset(ctx_ref, @intCast(jsc.kJSTypedArrayTypeUint8Array), buffer, byte_offset, byte_length, &exception);
        if (source == null or exception != null) {
            if (exception != null) {
                jsc.JSValueProtect(ctx_ref, exception);
                return .{ .exception = storeErased(E, exception) };
            }
            return .{ .out_of_memory = true };
        }
        jsc.JSValueProtect(ctx_ref, source);
        defer jsc.JSValueUnprotect(ctx_ref, source);

        exception = null;
        const destination = jsc.JSObjectMakeTypedArray(ctx_ref, @intCast(jsc.kJSTypedArrayTypeUint8Array), byte_length, &exception);
        if (destination == null or exception != null) {
            if (exception != null) {
                jsc.JSValueProtect(ctx_ref, exception);
                return .{ .exception = storeErased(E, exception) };
            }
            return .{ .out_of_memory = true };
        }
        jsc.JSValueProtect(ctx_ref, destination);
        defer jsc.JSValueUnprotect(ctx_ref, destination);

        const set_fn = intrinsics.typedArraySet(@ptrCast(ctx)) orelse return .{ .out_of_memory = true };
        const args = [_]jsc.JSValueRef{source};
        exception = null;
        const set_result = jsc.JSObjectCallAsFunction(ctx_ref, set_fn, destination, args.len, &args, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (set_result == null) return .{ .out_of_memory = true };

        exception = null;
        const copied_len = jsc.JSObjectGetTypedArrayByteLength(ctx_ref, destination, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (copied_len != byte_length) return .{ .out_of_memory = true };
        const ptr = jsc.JSObjectGetTypedArrayBytesPtr(ctx_ref, destination, &exception);
        if (exception != null) {
            jsc.JSValueProtect(ctx_ref, exception);
            return .{ .exception = storeErased(E, exception) };
        }
        if (ptr == null and copied_len != 0) return .{ .out_of_memory = true };
        const source_bytes: []const u8 = if (copied_len == 0) &.{} else @as([*]const u8, @ptrCast(ptr.?))[0..copied_len];
        return .{ .bytes = std.heap.c_allocator.dupe(u8, source_bytes) catch return .{ .out_of_memory = true } };
    }
}

pub fn valueHas(tag: Backend, ctx_addr: usize, object_bytes: []const u8, key: [:0]const u8) BoolValueResult {
    return dispatchBoolValue(tag, valueHasReal, .{ ctx_addr, object_bytes, key });
}

pub fn valueDelete(tag: Backend, ctx_addr: usize, object_bytes: []const u8, key: [:0]const u8) BoolValueResult {
    return dispatchBoolValue(tag, valueDeleteReal, .{ ctx_addr, object_bytes, key });
}

pub fn valueKeys(tag: Backend, ctx_addr: usize, object_bytes: []const u8) EvalValueResult {
    return dispatchEvalValue(tag, valueKeysReal, .{ ctx_addr, object_bytes });
}

pub fn valueInstanceOf(tag: Backend, ctx_addr: usize, value_bytes: []const u8, ctor_bytes: []const u8) BoolValueResult {
    return dispatchBoolValue(tag, valueInstanceOfReal, .{ ctx_addr, value_bytes, ctor_bytes });
}

pub fn valueNewJson(tag: Backend, ctx_addr: usize, input: []const u8) EvalValueResult {
    return dispatchEvalValue(tag, valueNewJsonReal, .{ ctx_addr, input });
}

pub fn valueNewError(tag: Backend, ctx_addr: usize, message: []const u8) EvalValueResult {
    return dispatchEvalValue(tag, valueNewErrorReal, .{ ctx_addr, message });
}

pub fn valueToJson(tag: Backend, ctx_addr: usize, value_bytes: []const u8) BytesValueResult {
    return dispatchBytesValue(tag, valueToJsonReal, .{ ctx_addr, value_bytes });
}

pub fn valueCopyBuffer(tag: Backend, ctx_addr: usize, value_bytes: []const u8) BytesValueResult {
    return dispatchBytesValue(tag, valueCopyBufferReal, .{ ctx_addr, value_bytes });
}

test "backend_dispatch: create/eval/destroy via erased handles for each packed tag" {
    const testing = std.testing;
    const tags = [_]Backend{ .quickjs_ng, .quickjs, .jsc };
    for (tags) |tag| {
        if (!multi_pack.isPacked(tag)) continue;
        const handles = createPacked(tag) orelse return error.CreatePackedFailed;
        finishCreate(tag, handles, 42, 256 * 1024);
        const res = evalPacked(tag, handles, "1+1", "<backend_dispatch>");
        defer {
            if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
            if (res.err_is_heap) {
                if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
            }
        }
        try testing.expect(res.err == null);
        try testing.expectEqualStrings("2", res.result.?);
        processPendingJobsPacked(tag, handles);
        destroyPacked(tag, handles);
    }
}

test "backend_dispatch: refused when tag not packed" {
    // On a single-pack Linux NG build, jsc is not packed.
    if (comptime multi_pack.isPacked(.jsc)) return error.SkipZigTest;
    try std.testing.expect(createPacked(.jsc) == null);
}
