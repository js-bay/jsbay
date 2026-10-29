// Generic callable object class for JS Bay.
//
// Provides NativeHandle: a QuickJS class whose instances are directly callable from JavaScript and carry native state with automatic cleanup.
//
// Usage from Zig:
//   1. NativeHandle.init(rt) — register the class (once per runtime)
//   2. NativeHandle.create(ctx, .{ ... }) — create a callable JS object
//   3. NativeHandle.setMethod(ctx, obj, "name", fn, argc) — add methods
//   4. Return the c.JSValue to JS
//
// Usage from JavaScript: const handle = someNativeCall(); handle("action", arg1); // direct call → dispatches to call_fn handle.close(); // method call handle.someProperty; // property access (if set)
//
// GC safety:
//   - The finalizer releases native resources when JS collects the object.
// - If native code stores JSValues (e.g. callbacks) inside the opaque data, it MUST set gc_mark_fn so the GC can trace those references.
// - Methods added via setMethod use JS_NewCFunctionData with a reference to the parent object, ensuring `this` is always the handle even when the method is detached (e.g. `const fn = handle.close; fn()`).
//
// This file is a pub re-export entry point. The implementation lives in `native_handle/` per-responsibility submodules:
//   * types.zig            — HandleData, MethodFn, JS_UNDEFINED
//   * class.zig            — class_id + QuickJS class registration
// * handle.zig — create / createWithProto / createWithMethods, setStringProp / setIntProp / getOpaque
//   * method.zig           — bound-method trampoline + setMethod
//   * callback_store.zig   — CallbackStore (named JS callback registry)

const types = @import("native_handle/types.zig");
const class = @import("native_handle/class.zig");
const handle = @import("native_handle/handle.zig");
const method = @import("native_handle/method.zig");
const callback_store_mod = @import("native_handle/callback_store.zig");

// ── Public types ──────────────────────────────────────────────────────────

pub const HandleData = types.HandleData;
pub const MethodFn = types.MethodFn;

// ── Public functions ──────────────────────────────────────────────────────

pub const init = class.init;
pub const getClassId = class.getClassId;

pub const create = handle.create;
pub const createWithProto = handle.createWithProto;
pub const createWithMethods = handle.createWithMethods;
pub const setStringProp = handle.setStringProp;
pub const setIntProp = handle.setIntProp;
pub const getOpaque = handle.getOpaque;

pub const setMethod = method.setMethod;

// ── Callback store ────────────────────────────────────────────────────────

pub const MAX_CALLBACKS = callback_store_mod.MAX_CALLBACKS;
pub const MAX_NAME_LEN = callback_store_mod.MAX_NAME_LEN;
pub const CallbackEntry = callback_store_mod.CallbackEntry;
pub const CallbackStore = callback_store_mod.CallbackStore;
