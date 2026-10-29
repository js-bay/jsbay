//! JavaScriptCore backend — public facade.
//!
//! Implementation lives in `backend/jsc/` submodules; this file provides the `JscBackend` interface and shared file-level helpers.
//!
//! Submodules:
//! * common — shared `jsc` declarations, JSC_TA_* constants, opaque side table, string/JSON/exception helpers
//!   * lifecycle        — Runtime/Context create/destroy, eval
//! * value — value creation, type predicates, conversion, property access, function call, ArrayBuffer / TypedArray helpers
//!   * console          — console.{log,debug,info,warn,error} bridge
//!   * timers           — setTimeout/setInterval/clear* bridge
//!   * datatypes        — Date, BigInt, Map, Set, DataView, Map/Set iteration
//! * weak — true-weak refs (JSWeakRef extern) + per-object finalizer attachment
//!   * external         — opaque pointer wrappers (napi External parity)
//!   * module           — ES module loader (JSModuleLoaderDelegate bridge)
//!   * bytecode         — bytecode cache stubs (always returns "unsupported")
//!   * error_handling   — typed Error constructors, isError predicate
//!   * runtime_control  — interrupt handler, GC trigger
//!   * buffers          — zero-copy ArrayBuffer / Uint8Array
//!   * cjs              — CommonJS eval-to-value helper
//!
//! Bridge (invoke/publish) is NOT here — it lives in the host/app layer.

const common = @import("jsc/common.zig");
const lifecycle = @import("jsc/lifecycle.zig");
const value_mod = @import("jsc/value.zig");
const console_mod = @import("jsc/console.zig");
const timers_mod = @import("jsc/timers.zig");
const datatypes = @import("jsc/datatypes.zig");
const weak_mod = @import("jsc/weak.zig");
const external_mod = @import("jsc/external.zig");
const module_mod = @import("jsc/module.zig");
const bytecode_mod = @import("jsc/bytecode.zig");
const error_handling = @import("jsc/error_handling.zig");
const runtime_control_mod = @import("jsc/runtime_control.zig");
const buffers_mod = @import("jsc/buffers.zig");
const cjs_mod = @import("jsc/cjs.zig");

// ---- Re-exports ----------------------------------------------------------
//
// Backend users access `jsc` and JSC_TA_* constants through this module.

pub const jsc = common.jsc;

pub const JSC_TA_INT8 = common.JSC_TA_INT8;
pub const JSC_TA_INT16 = common.JSC_TA_INT16;
pub const JSC_TA_INT32 = common.JSC_TA_INT32;
pub const JSC_TA_UINT8 = common.JSC_TA_UINT8;
pub const JSC_TA_UINT8C = common.JSC_TA_UINT8C;
pub const JSC_TA_UINT16 = common.JSC_TA_UINT16;
pub const JSC_TA_UINT32 = common.JSC_TA_UINT32;
pub const JSC_TA_FLOAT32 = common.JSC_TA_FLOAT32;
pub const JSC_TA_FLOAT64 = common.JSC_TA_FLOAT64;
pub const JSC_TA_ARRAYBUFFER = common.JSC_TA_ARRAYBUFFER;
pub const JSC_TA_NONE = common.JSC_TA_NONE;
pub const JSC_TA_BIG_INT64 = common.JSC_TA_BIG_INT64;
pub const JSC_TA_BIG_UINT64 = common.JSC_TA_BIG_UINT64;

// ---- JscBackend struct ---------------------------------------------------
//
// Thin facade: every method is a re-export of the corresponding submodule function. The shape of this struct (method names + signatures) is the public contract other modules dispatch to via `ActiveEngine.<name>(...)`.
pub const JscBackend = struct {
    pub const Runtime = lifecycle.Runtime;
    pub const Context = lifecycle.Context;
    pub const Value = jsc.JSValueRef;

    // Lifecycle
    pub const newRuntime = lifecycle.newRuntime;
    pub const setMaxStackSize = lifecycle.setMaxStackSize;
    pub const newContext = lifecycle.newContext;
    pub const freeContext = lifecycle.freeContext;
    pub const freeRuntime = lifecycle.freeRuntime;
    pub const runGc = lifecycle.runGc;
    pub const eval = lifecycle.eval;
    pub const processPendingJobs = lifecycle.processPendingJobs;

    // Context opaque
    pub const setContextOpaque = common.setContextOpaque;
    pub const getContextOpaque = common.getContextOpaque;
    pub const instanceIdFromCtx = common.instanceIdFromCtx;

    // API registration
    pub const registerConsole = console_mod.registerConsole;
    pub const registerTimers = timers_mod.registerTimers;

    // Top-level value singletons + protect/unprotect
    pub const undefinedValue = value_mod.undefinedValue;
    pub const nullValue = value_mod.nullValue;
    pub const dupValue = value_mod.dupValue;
    pub const freeValue = value_mod.freeValue;

    // Function detection / no-arg call
    pub const isFunction = value_mod.isFunction;
    pub const callFunctionNoArgs = value_mod.callFunctionNoArgs;

    // Public helpers for consumers (bridge, etc.)
    pub const getGlobalObject = value_mod.getGlobalObject;
    pub const newObject = value_mod.newObject;
    pub const setProperty = common.setProperty;

    /// Parity alias matching the QuickJS backend: set a property keyed by a NUL-terminated name string.
    ///
    /// Ownership contract (cross-backend uniform): this function CONSUMES `val`. After the call the caller must NOT use `val` again, and must NOT `freeValue` it — the property slot now owns the (JSC: protected / QJS: +1 refcount) reference. Consumption happens even on failure, so callers never need an error-path free. If the caller needs to retain a usable handle after the set, pass `dupValue(ctx, val)` instead.
    pub const setPropertyStr = value_mod.setPropertyStr;

    pub const makeFunction = common.makeFunction;
    pub const makeStringValue = common.makeStringValue;
    pub const throwError = common.throwError;
    pub const jsStringFromSlice = common.jsStringFromSlice;
    pub const jsStringToOwned = common.jsStringToOwned;
    pub const valueToString = common.valueToString;
    pub const jsonStringify = common.jsonStringify;
    pub const jsonParse = common.jsonParse;
    pub const formatException = common.formatException;

    // Type predicates
    pub const isUndefined = value_mod.isUndefined;
    pub const isNull = value_mod.isNull;
    pub const isBool = value_mod.isBool;
    pub const isNumber = value_mod.isNumber;
    pub const isString = value_mod.isString;
    pub const isSymbol = value_mod.isSymbol;
    pub const isObjectVal = value_mod.isObjectVal;
    pub const isArray = value_mod.isArray;
    pub const sameValue = value_mod.sameValue;

    // Type extraction
    pub const toBool = value_mod.toBool;
    pub const toInt32 = value_mod.toInt32;
    pub const toFloat64 = value_mod.toFloat64;

    // Value creation
    pub const newBoolVal = value_mod.newBoolVal;
    pub const newInt32Val = value_mod.newInt32Val;
    pub const newFloat64Val = value_mod.newFloat64Val;
    pub const newStringVal = value_mod.newStringVal;
    pub const newNullVal = value_mod.newNullVal;
    pub const newUndefinedVal = value_mod.newUndefinedVal;
    pub const newArray = value_mod.newArray;

    // Property / array access + function call
    pub const getPropertyVal = value_mod.getPropertyVal;
    pub const hasProperty = value_mod.hasProperty;
    pub const getIndex = value_mod.getIndex;
    pub const getLength = value_mod.getLength;
    pub const callFunction = value_mod.callFunction;

    // JSON
    pub const jsonParseVal = value_mod.jsonParseVal;
    pub const jsonStringifyVal = value_mod.jsonStringifyVal;
    pub const valueToStringAlloc = value_mod.valueToStringAlloc;
    pub const valueToStringVal = value_mod.valueToStringVal;

    // ArrayBuffer / TypedArray
    pub const isArrayBufferVal = value_mod.isArrayBufferVal;
    pub const isTypedArrayVal = value_mod.isTypedArrayVal;
    pub const getArrayBufferSliceVal = value_mod.getArrayBufferSliceVal;
    pub const getTypedArrayBytesVal = value_mod.getTypedArrayBytesVal;
    pub const newArrayBufferCopyVal = value_mod.newArrayBufferCopyVal;
    pub const newArrayBufferNoCopyVal = value_mod.newArrayBufferNoCopyVal;
    pub const newTypedArrayFromBufferVal = value_mod.newTypedArrayFromBufferVal;

    // ---- Date / BigInt / Map / Set / DataView dispatch shims ----
    //
    // These thin methods forward to the file-level jscXxx helpers in `datatypes.zig`. Hoisting them onto the struct lets value.zig dispatch through `ActiveEngine.xxx(...)` instead of a per-call-site `switch` on the active backend tag. `@ptrCast(ctx)` converts `Context` (`JSGlobalContextRef`) to the helpers' `JSContextRef`.

    pub fn isDate(ctx: Context, val: Value) bool {
        return datatypes.jscIsDate(@ptrCast(ctx), val);
    }

    pub fn toDateMs(ctx: Context, val: Value) ?i64 {
        return datatypes.jscToDateMs(@ptrCast(ctx), val);
    }

    pub fn newDate(ctx: Context, ms: i64) Value {
        return datatypes.jscNewDate(@ptrCast(ctx), ms);
    }

    pub fn isBigInt(ctx: Context, val: Value) bool {
        return datatypes.jscIsBigInt(@ptrCast(ctx), val);
    }

    pub fn toBigIntI64(ctx: Context, val: Value) ?i64 {
        return datatypes.jscToBigIntI64(@ptrCast(ctx), val);
    }

    pub fn toBigIntU64(ctx: Context, val: Value) ?u64 {
        return datatypes.jscToBigIntU64(@ptrCast(ctx), val);
    }

    pub fn newBigIntI64(ctx: Context, v: i64) Value {
        return datatypes.jscNewBigIntI64(@ptrCast(ctx), v);
    }

    pub fn newBigIntU64(ctx: Context, v: u64) Value {
        return datatypes.jscNewBigIntU64(@ptrCast(ctx), v);
    }

    pub fn isMap(ctx: Context, val: Value) bool {
        return datatypes.jscIsMap(@ptrCast(ctx), val);
    }

    pub fn isSet(ctx: Context, val: Value) bool {
        return datatypes.jscIsSet(@ptrCast(ctx), val);
    }

    pub fn mapSetToJson(ctx: Context, val: Value) ?[]const u8 {
        return datatypes.jscMapSetToJson(@ptrCast(ctx), val);
    }

    pub fn newMapFromJson(ctx: Context, json: []const u8) Value {
        return datatypes.jscNewMapFromJson(@ptrCast(ctx), json);
    }

    pub fn newSetFromJson(ctx: Context, json: []const u8) Value {
        return datatypes.jscNewSetFromJson(@ptrCast(ctx), json);
    }

    pub fn mapSize(ctx: Context, val: Value) ?usize {
        return datatypes.jscMapSize(@ptrCast(ctx), val);
    }

    pub fn setSize(ctx: Context, val: Value) ?usize {
        return datatypes.jscSetSize(@ptrCast(ctx), val);
    }

    pub fn newMap(ctx: Context) Value {
        return datatypes.jscNewMap(@ptrCast(ctx));
    }

    pub fn newSet(ctx: Context) Value {
        return datatypes.jscNewSet(@ptrCast(ctx));
    }

    pub fn mapSet(ctx: Context, map: Value, key: Value, value: Value) bool {
        return datatypes.jscMapSet(@ptrCast(ctx), map, key, value);
    }

    pub fn setAdd(ctx: Context, set: Value, value: Value) bool {
        return datatypes.jscSetAdd(@ptrCast(ctx), set, value);
    }

    pub fn isDataView(ctx: Context, val: Value) bool {
        return datatypes.jscIsDataView(@ptrCast(ctx), val);
    }

    pub const BackendDataViewInfo = struct {
        bytes: []u8,
        byte_offset: usize,
        byte_length: usize,
    };

    pub fn dataViewInfo(ctx: Context, val: Value) ?BackendDataViewInfo {
        const info = datatypes.jscDataViewInfo(@ptrCast(ctx), val) orelse return null;
        return .{
            .bytes = info.bytes,
            .byte_offset = info.byte_offset,
            .byte_length = info.byte_length,
        };
    }

    pub fn newDataViewFromBuffer(
        ctx: Context,
        ab: Value,
        byte_offset: usize,
        byte_length: usize,
    ) Value {
        return datatypes.jscNewDataView(@ptrCast(ctx), ab, byte_offset, byte_length);
    }

    // ---- Map/Set iteration shims ----

    pub const MapForEachFn = fn (
        ctx: Context,
        cb_ctx: ?*anyopaque,
        key: Value,
        value: Value,
    ) callconv(.c) bool;

    pub const SetForEachFn = fn (
        ctx: Context,
        cb_ctx: ?*anyopaque,
        value: Value,
    ) callconv(.c) bool;

    pub fn mapForEach(
        ctx: Context,
        val: Value,
        cb_ctx: ?*anyopaque,
        cb: *const MapForEachFn,
    ) bool {
        const inner: *const datatypes.JscMapForEachFn = @ptrCast(cb);
        return datatypes.jscMapForEach(@ptrCast(ctx), val, cb_ctx, inner);
    }

    pub fn setForEach(
        ctx: Context,
        val: Value,
        cb_ctx: ?*anyopaque,
        cb: *const SetForEachFn,
    ) bool {
        const inner: *const datatypes.JscSetForEachFn = @ptrCast(cb);
        return datatypes.jscSetForEach(@ptrCast(ctx), val, cb_ctx, inner);
    }
};

// ---- File-level re-exports -----------------------------------------------
//
// File-level helpers used by the backend and public module.

// Date / BigInt / Map / Set / DataView free helpers
pub const jscIsDate = datatypes.jscIsDate;
pub const jscToDateMs = datatypes.jscToDateMs;
pub const jscNewDate = datatypes.jscNewDate;
pub const jscIsBigInt = datatypes.jscIsBigInt;
pub const jscToBigIntI64 = datatypes.jscToBigIntI64;
pub const jscToBigIntU64 = datatypes.jscToBigIntU64;
pub const jscNewBigIntI64 = datatypes.jscNewBigIntI64;
pub const jscNewBigIntU64 = datatypes.jscNewBigIntU64;
pub const jscIsMap = datatypes.jscIsMap;
pub const jscIsSet = datatypes.jscIsSet;
pub const jscMapSetToJson = datatypes.jscMapSetToJson;
pub const jscNewMapFromJson = datatypes.jscNewMapFromJson;
pub const jscNewSetFromJson = datatypes.jscNewSetFromJson;
pub const JscDataViewInfo = datatypes.JscDataViewInfo;
pub const jscIsDataView = datatypes.jscIsDataView;
pub const jscDataViewInfo = datatypes.jscDataViewInfo;
pub const jscNewDataView = datatypes.jscNewDataView;
pub const JscMapForEachFn = datatypes.JscMapForEachFn;
pub const JscSetForEachFn = datatypes.JscSetForEachFn;
pub const jscMapForEach = datatypes.jscMapForEach;
pub const jscSetForEach = datatypes.jscSetForEach;
pub const jscMapSize = datatypes.jscMapSize;
pub const jscSetSize = datatypes.jscSetSize;
pub const jscNewMap = datatypes.jscNewMap;
pub const jscNewSet = datatypes.jscNewSet;
pub const jscMapSet = datatypes.jscMapSet;
pub const jscSetAdd = datatypes.jscSetAdd;

// True-weak refs + finalizer attachment
pub const JSWeakCreate = weak_mod.JSWeakCreate;
pub const JSWeakRetain = weak_mod.JSWeakRetain;
pub const JSWeakRelease = weak_mod.JSWeakRelease;
pub const JSWeakGetObject = weak_mod.JSWeakGetObject;
pub const JSSynchronousGarbageCollectForDebugging = weak_mod.JSSynchronousGarbageCollectForDebugging;
pub const JSSynchronousEdenCollectForDebugging = weak_mod.JSSynchronousEdenCollectForDebugging;
pub const jsbay_qjsWeakAttach = weak_mod.jsbay_qjsWeakAttach;
pub const jsbay_qjsWeakGetLive = weak_mod.jsbay_qjsWeakGetLive;
pub const jsbay_qjsWeakRelease = weak_mod.jsbay_qjsWeakRelease;
pub const JscWeakFinalizeCallback = weak_mod.JscWeakFinalizeCallback;
pub const jscWeakAttachFinalizer = weak_mod.jscWeakAttachFinalizer;
pub const jscHostObjectCreate = @import("jsc/host_object.zig").create;
pub const jscSymbol = @import("jsc/symbol.zig");

// External value support
pub const JscExternalFinalizer = external_mod.JscExternalFinalizer;
pub const jscNewExternal = external_mod.jscNewExternal;
pub const jscGetExternal = external_mod.jscGetExternal;
pub const jscIsExternal = external_mod.jscIsExternal;

// ES module loader
pub const installModuleLoader = module_mod.installModuleLoader;
pub const uninstallModuleLoader = module_mod.uninstallModuleLoader;
pub const jscEvalModule = module_mod.jscEvalModule;
pub const jscImportModule = module_mod.jscImportModule;

// Bytecode stubs
pub const jsc_bytecode_err_msg = bytecode_mod.jsc_bytecode_err_msg;
pub const JscCompileResult = bytecode_mod.JscCompileResult;
pub const jscCompileBytecode = bytecode_mod.jscCompileBytecode;
pub const jscFreeBytecode = bytecode_mod.jscFreeBytecode;
pub const jscRunBytecode = bytecode_mod.jscRunBytecode;

// Structured errors
pub const JscErrorKind = error_handling.JscErrorKind;
pub const jscNewTypedError = error_handling.jscNewTypedError;
pub const jscIsError = error_handling.jscIsError;

// Runtime control
pub const JSShouldTerminateCallback = runtime_control_mod.JSShouldTerminateCallback;
pub const JSContextGroupSetExecutionTimeLimit = runtime_control_mod.JSContextGroupSetExecutionTimeLimit;
pub const JSContextGroupClearExecutionTimeLimit = runtime_control_mod.JSContextGroupClearExecutionTimeLimit;
pub const JscInterruptState = runtime_control_mod.JscInterruptState;
pub const jscInstallInterruptHandler = runtime_control_mod.jscInstallInterruptHandler;
pub const jscUninstallInterruptHandler = runtime_control_mod.jscUninstallInterruptHandler;
pub const jscRunGc = runtime_control_mod.jscRunGc;

// Zero-copy buffers
pub const JscBufferFinalizer = buffers_mod.JscBufferFinalizer;
pub const jscNewArrayBufferFromBytes = buffers_mod.jscNewArrayBufferFromBytes;
pub const jscNewUint8ArrayFromBytes = buffers_mod.jscNewUint8ArrayFromBytes;
pub const jscGetBufferView = buffers_mod.jscGetBufferView;

// CommonJS
pub const jscCjsEvalToValue = cjs_mod.jscCjsEvalToValue;
