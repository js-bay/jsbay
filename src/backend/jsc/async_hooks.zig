//! JSC does not expose the JS caller to `JSContextCreateBacktrace` from a native callback. Scheduling stacks are captured in JS wrappers (`new Error().stack`) and replayed when the callback runs.

const std = @import("std");
const async_stack = @import("../../inspector/async_stack.zig");
const backtrace = @import("backtrace.zig");
const common = @import("common.zig");

const jsc = common.jsc;

const CallbackBox = struct {
    instance_id: i32,
    description: []const u8,
    callback: jsc.JSObjectRef,
    trace: ?async_stack.Trace,
};

var callback_class: ?jsc.JSClassRef = null;

const installer =
    \\(function(){
    \\  var previous = globalThis.__jsbay_qjsAsyncState;
    \\  if (previous && previous.installed) return;
    \\  var depth = globalThis.__jsbay_qjsAsyncDepth;
    \\  var bind = globalThis.__jsbay_qjsBindAsync;
    \\  var nativeThen = (Promise && Promise.prototype) ? Promise.prototype.then : null;
    \\  var hadMicro = Object.prototype.hasOwnProperty.call(globalThis, "queueMicrotask");
    \\  var originalMicro = globalThis.queueMicrotask;
    \\  var nativeMicro = typeof originalMicro === "function" ? originalMicro : null;
    \\  var state = { installed: true, depth: depth, bind: bind, nativeThen: nativeThen, hadMicro: hadMicro, originalMicro: originalMicro, nativeMicro: nativeMicro };
    \\  globalThis.__jsbay_qjsAsyncState = state;
    \\  if (nativeMicro) {
    \\    state.microWrapper = function(fn) {
    \\      if (globalThis.__jsbay_qjsAsyncDepth !== depth || !depth()) return nativeMicro(fn);
    \\      return nativeMicro(bind(fn, (new Error()).stack, "queueMicrotask"));
    \\    };
    \\    globalThis.queueMicrotask = state.microWrapper;
    \\  }
    \\  if (typeof queueMicrotask !== "function" && nativeThen) {
    \\    state.microWrapper = function(fn) {
    \\      var wrapped = globalThis.__jsbay_qjsAsyncDepth === depth && depth() ? bind(fn, (new Error()).stack, "queueMicrotask") : fn;
    \\      return nativeThen.call(Promise.resolve(), wrapped);
    \\    };
    \\    globalThis.queueMicrotask = state.microWrapper;
    \\  }
    \\  if (nativeThen) {
    \\    state.thenWrapper = function(a, b) {
    \\      if (globalThis.__jsbay_qjsAsyncDepth !== depth || !depth()) return nativeThen.call(this, a, b);
    \\      var stack = (new Error()).stack;
    \\      var wrap = function(fn) {
    \\        return (typeof fn === "function") ? bind(fn, stack, "Promise") : fn;
    \\      };
    \\      return nativeThen.call(this, wrap(a), wrap(b));
    \\    };
    \\    Promise.prototype.then = state.thenWrapper;
    \\  }
    \\})();
;

const uninstaller =
    \\(function(){
    \\  var state = globalThis.__jsbay_qjsAsyncState;
    \\  if (!state || !state.installed) return;
    \\  if (state.thenWrapper && typeof Promise !== "undefined" && Promise && Promise.prototype && Promise.prototype.then === state.thenWrapper) Promise.prototype.then = state.nativeThen;
    \\  if (state.microWrapper && globalThis.queueMicrotask === state.microWrapper) { if (state.hadMicro) globalThis.queueMicrotask = state.originalMicro; else delete globalThis.queueMicrotask; }
    \\  if (globalThis.__jsbay_qjsAsyncDepth === state.depth) delete globalThis.__jsbay_qjsAsyncDepth;
    \\  if (globalThis.__jsbay_qjsBindAsync === state.bind) delete globalThis.__jsbay_qjsBindAsync;
    \\  if (globalThis.__jsbay_qjsAsyncState === state) delete globalThis.__jsbay_qjsAsyncState;
    \\})();
;

pub fn setDepth(ctx: jsc.JSGlobalContextRef, instance_id: i32, max_depth: u32) void {
    const was_enabled = async_stack.depth(instance_id) != 0;
    async_stack.setDepth(instance_id, max_depth);
    const is_enabled = async_stack.depth(instance_id) != 0;
    if (!was_enabled and is_enabled) install(ctx) else if (was_enabled and !is_enabled) uninstall(ctx);
}

fn install(ctx: jsc.JSGlobalContextRef) void {
    const jsc_ctx: jsc.JSContextRef = @ptrCast(ctx);
    const source = common.jsStringFromSlice(installer) orelse return;
    defer jsc.JSStringRelease(source);
    const global = jsc.JSContextGetGlobalObject(jsc_ctx);
    const depth = common.makeFunction(jsc_ctx, "__jsbay_qjsAsyncDepth", jsDepth) orelse return;
    const bind = common.makeFunction(jsc_ctx, "__jsbay_qjsBindAsync", jsBind) orelse return;
    common.setProperty(jsc_ctx, global, "__jsbay_qjsAsyncDepth", depth);
    common.setProperty(jsc_ctx, global, "__jsbay_qjsBindAsync", bind);
    var exc: jsc.JSValueRef = null;
    _ = jsc.JSEvaluateScript(jsc_ctx, source, null, null, 1, &exc);
}

fn uninstall(ctx: jsc.JSGlobalContextRef) void {
    const jsc_ctx: jsc.JSContextRef = @ptrCast(ctx);
    const source = common.jsStringFromSlice(uninstaller) orelse return;
    defer jsc.JSStringRelease(source);
    var exc: jsc.JSValueRef = null;
    _ = jsc.JSEvaluateScript(jsc_ctx, source, null, null, 1, &exc);
}

pub fn traceFromStack(text: []const u8) ?async_stack.Trace {
    const parsed = backtrace.parse(text);
    if (parsed.len == 0) return null;
    const frames = std.heap.c_allocator.alloc(async_stack.Frame, parsed.len) catch {
        backtrace.freeFrames(parsed);
        return null;
    };
    for (parsed, 0..) |frame, i| {
        frames[i] = .{
            .name = frame.name,
            .url = frame.url,
            .line = frame.line,
            .column = frame.column,
        };
    }
    std.heap.c_allocator.free(parsed);
    return .{ .frames = frames };
}

fn jsDepth(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*c]const jsc.JSValueRef,
    _: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = common.instanceIdFromCtx(@constCast(ctx));
    return jsc.JSValueMakeBoolean(ctx, async_stack.depth(id) != 0);
}

fn jsBind(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argument_count: usize,
    arguments: [*c]const jsc.JSValueRef,
    _: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argument_count < 1 or arguments[0] == null) return jsc.JSValueMakeUndefined(ctx);
    if (argument_count < 2 or !jsc.JSValueIsString(ctx, arguments[1])) return arguments[0];
    var exc: jsc.JSValueRef = null;
    const fn_obj = jsc.JSValueToObject(ctx, arguments[0], &exc);
    if (exc != null or fn_obj == null) return arguments[0];
    const text_ref = jsc.JSValueToStringCopy(ctx, arguments[1], &exc);
    if (text_ref == null) return arguments[0];
    defer jsc.JSStringRelease(text_ref);
    const text = common.jsStringToOwned(text_ref) orelse return arguments[0];
    defer std.heap.c_allocator.free(text);
    const description: []const u8 = if (argument_count >= 3 and jsc.JSValueIsString(ctx, arguments[2]))
        kindText(ctx, arguments[2])
    else
        "Promise";
    const box = std.heap.c_allocator.create(CallbackBox) catch return arguments[0];
    box.* = .{
        .instance_id = common.instanceIdFromCtx(@constCast(ctx)),
        .description = description,
        .callback = fn_obj,
        .trace = traceFromStack(text),
    };
    const wrapped = jsc.JSObjectMake(ctx, callbackClass(), @ptrCast(box));
    common.setProperty(ctx, wrapped, "fn", arguments[0]);
    return wrapped;
}

fn kindText(ctx: jsc.JSContextRef, value: jsc.JSValueRef) []const u8 {
    var exc: jsc.JSValueRef = null;
    const text_ref = jsc.JSValueToStringCopy(ctx, value, &exc) orelse return "Promise";
    defer jsc.JSStringRelease(text_ref);
    const text = common.jsStringToOwned(text_ref) orelse return "Promise";
    defer std.heap.c_allocator.free(text);
    if (std.mem.eql(u8, text, "queueMicrotask")) return "queueMicrotask";
    return "Promise";
}

fn callbackClass() jsc.JSClassRef {
    if (callback_class) |cls| return cls;
    var def = jsc.kJSClassDefinitionEmpty;
    def.className = "JsBayQjsAsyncCallback";
    def.callAsFunction = callbackCall;
    def.finalize = callbackFinalize;
    callback_class = jsc.JSClassCreate(&def);
    return callback_class.?;
}

fn callbackCall(
    ctx: jsc.JSContextRef,
    function: jsc.JSObjectRef,
    this_object: jsc.JSObjectRef,
    argument_count: usize,
    arguments: [*c]const jsc.JSValueRef,
    exception: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const raw = jsc.JSObjectGetPrivate(function) orelse return jsc.JSValueMakeUndefined(ctx);
    const box: *CallbackBox = @ptrCast(@alignCast(raw));
    const entered = if (box.trace) |parent| async_stack.enter(box.instance_id, box.description, parent) else false;
    defer if (entered) async_stack.leave(box.instance_id);
    return jsc.JSObjectCallAsFunction(ctx, box.callback, this_object, argument_count, arguments, exception);
}

fn callbackFinalize(obj: jsc.JSObjectRef) callconv(.c) void {
    const raw = jsc.JSObjectGetPrivate(obj) orelse return;
    const box: *CallbackBox = @ptrCast(@alignCast(raw));
    if (box.trace) |parent| async_stack.freeTrace(parent);
    _ = jsc.JSObjectSetPrivate(obj, null);
    std.heap.c_allocator.destroy(box);
}
