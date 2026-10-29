//! Pristine ECMAScript object operations for the typed Value ABI.
//!
//! The JSC C API cannot report exceptions from property enumeration or `has`, and its own-key enumeration includes inherited properties. These helpers are evaluated once per context, before user code can replace `Object.keys` or the global environment, so `has`, `delete`, `keys` and `instanceof` run with exact ECMAScript semantics and real exceptions.

const std = @import("std");
const common = @import("common.zig");
const sync = @import("zev");

const jsc = common.jsc;

pub const Context = jsc.JSGlobalContextRef;

pub const Intrinsics = struct {
    has: jsc.JSObjectRef,
    delete: jsc.JSObjectRef,
    keys: jsc.JSObjectRef,
    instance_of: jsc.JSObjectRef,
};

const field_count = @typeInfo(Intrinsics).@"struct".field_names.len;

var by_context = std.AutoHashMap(usize, Intrinsics).init(std.heap.c_allocator);
var mutex: sync.Mutex = .{};

// Sloppy-mode helpers on purpose: `delete` on a non-configurable property must report false instead of throwing, matching non-strict `delete o[k]`.
const source =
    "[function(o,k){return k in o;}," ++
    "function(o,k){return delete o[k];}," ++
    "Object.keys," ++
    "function(v,c){return v instanceof c;}]";

pub fn capture(ctx: Context) bool {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const text = common.jsStringFromSlice(source) orelse return false;
    defer jsc.JSStringRelease(text);
    var exception: jsc.JSValueRef = null;
    const value = jsc.JSEvaluateScript(ctx_ref, text, null, null, 1, &exception);
    if (exception != null or value == null or !jsc.JSValueIsObject(ctx_ref, value)) return false;
    jsc.JSValueProtect(ctx_ref, value);
    defer jsc.JSValueUnprotect(ctx_ref, value);
    const array: jsc.JSObjectRef = @ptrCast(@constCast(value));
    var functions: [field_count]jsc.JSObjectRef = undefined;
    var protected: usize = 0;
    for (&functions, 0..) |*slot, index| {
        const element = jsc.JSObjectGetPropertyAtIndex(ctx_ref, array, @intCast(index), &exception);
        if (exception != null or element == null or !jsc.JSValueIsObject(ctx_ref, element)) {
            unprotectAll(ctx_ref, functions[0..protected]);
            return false;
        }
        const object: jsc.JSObjectRef = @ptrCast(@constCast(element));
        if (!jsc.JSObjectIsFunction(ctx_ref, object)) {
            unprotectAll(ctx_ref, functions[0..protected]);
            return false;
        }
        jsc.JSValueProtect(ctx_ref, element);
        slot.* = object;
        protected += 1;
    }
    mutex.lock();
    defer mutex.unlock();
    by_context.put(@intFromPtr(ctx), .{
        .has = functions[0],
        .delete = functions[1],
        .keys = functions[2],
        .instance_of = functions[3],
    }) catch {
        unprotectAll(ctx_ref, &functions);
        return false;
    };
    return true;
}

fn unprotectAll(ctx_ref: jsc.JSContextRef, functions: []const jsc.JSObjectRef) void {
    for (functions) |function| jsc.JSValueUnprotect(ctx_ref, function);
}

pub fn release(ctx: Context) void {
    mutex.lock();
    const entry = by_context.fetchRemove(@intFromPtr(ctx));
    mutex.unlock();
    const removed = entry orelse return;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    unprotectAll(ctx_ref, &.{ removed.value.has, removed.value.delete, removed.value.keys, removed.value.instance_of });
}

pub fn get(ctx: Context) ?Intrinsics {
    mutex.lock();
    defer mutex.unlock();
    return by_context.get(@intFromPtr(ctx));
}
