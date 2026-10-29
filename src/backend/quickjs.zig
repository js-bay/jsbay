//! QuickJS backend — aggregate entry point.
//!
//! Per-responsibility implementation lives under `quickjs/*.zig`; this file provides the backend interface consumed by the engine and public module.
//!
//! The split:
//! * `quickjs/c_api.zig` — cImport, externs, type constants, JS_UNDEFINED/JS_NULL/JS_EXCEPTION, tag-only predicates.
//! * `quickjs/lifecycle.zig` — QuickJsBackend struct (Runtime/Context create/free, eval, console+timers registration, callFunctionNoArgs).
//! * `quickjs/value.zig` — value-method mixin forwarded into QuickJsBackend via explicit `pub const`.
//!   * `quickjs/console.zig`        — `jsConsoleLog` callback.
//!   * `quickjs/timers.zig`         — setTimeout/Interval/clearTimer.
//! * `quickjs/exception.zig` — getAndFormatException, jsonStringify, valueToString.
//!   * `quickjs/datetime.zig`       — Date + BigInt helpers.
//!   * `quickjs/collections.zig`    — Map/Set + iteration.
//!   * `quickjs/dataview.zig`       — DataView ctor/info.
//!   * `quickjs/external.zig`       — opaque external pointers.
//!   * `quickjs/module.zig`         — ES module loader.
//!   * `quickjs/bytecode.zig`       — bytecode compile / run.
//!   * `quickjs/errors.zig`         — structured Error API.
//!   * `quickjs/runtime_control.zig`— interrupt + GC + memory snapshot.
//!   * `quickjs/buffers.zig`        — zero-copy ArrayBuffer / Uint8Array view.
//!   * `quickjs/weak.zig`           — true-weak (`reference.Weak(T)`) support.
//!   * `quickjs/weakcb.zig`         — napi_wrap-style finalizer attachment.
//!   * `quickjs/cjs.zig`            — CommonJS eval-to-value.

// ---- Submodules: re-exported at this namespace (explicit, see module docs above) ----
pub const c_api = @import("quickjs/c_api.zig");
pub const lifecycle = @import("quickjs/lifecycle.zig");
pub const value = @import("quickjs/value.zig");
pub const exception = @import("quickjs/exception.zig");
const datetime = @import("quickjs/datetime.zig");
const collections = @import("quickjs/collections.zig");
const dataview = @import("quickjs/dataview.zig");
const external = @import("quickjs/external.zig");
const module = @import("quickjs/module.zig");
const bytecode = @import("quickjs/bytecode.zig");
const errors = @import("quickjs/errors.zig");
const runtime_control = @import("quickjs/runtime_control.zig");
const buffers = @import("quickjs/buffers.zig");
pub const weak = @import("quickjs/weak.zig");
const weakcb = @import("quickjs/weakcb.zig");
const cjs = @import("quickjs/cjs.zig");
pub const host_abi = @import("quickjs/host_abi.zig");

// from quickjs/c_api.zig
pub const qjs = c_api.qjs;
pub const JSReallocArrayBufferDataFunc = c_api.JSReallocArrayBufferDataFunc;
pub const QJS_TYPED_ARRAY_UINT8C = c_api.QJS_TYPED_ARRAY_UINT8C;
pub const QJS_TYPED_ARRAY_INT8 = c_api.QJS_TYPED_ARRAY_INT8;
pub const QJS_TYPED_ARRAY_UINT8 = c_api.QJS_TYPED_ARRAY_UINT8;
pub const QJS_TYPED_ARRAY_INT16 = c_api.QJS_TYPED_ARRAY_INT16;
pub const QJS_TYPED_ARRAY_UINT16 = c_api.QJS_TYPED_ARRAY_UINT16;
pub const QJS_TYPED_ARRAY_INT32 = c_api.QJS_TYPED_ARRAY_INT32;
pub const QJS_TYPED_ARRAY_UINT32 = c_api.QJS_TYPED_ARRAY_UINT32;
pub const QJS_TYPED_ARRAY_BIG_INT64 = c_api.QJS_TYPED_ARRAY_BIG_INT64;
pub const QJS_TYPED_ARRAY_BIG_UINT64 = c_api.QJS_TYPED_ARRAY_BIG_UINT64;
pub const QJS_TYPED_ARRAY_FLOAT16 = c_api.QJS_TYPED_ARRAY_FLOAT16;
pub const QJS_TYPED_ARRAY_FLOAT32 = c_api.QJS_TYPED_ARRAY_FLOAT32;
pub const QJS_TYPED_ARRAY_FLOAT64 = c_api.QJS_TYPED_ARRAY_FLOAT64;
pub const mkval = c_api.mkval;
pub const JS_UNDEFINED = c_api.JS_UNDEFINED;
pub const JS_NULL = c_api.JS_NULL;
pub const JS_EXCEPTION = c_api.JS_EXCEPTION;
pub const jsIsException = c_api.jsIsException;
pub const jsIsUndefined = c_api.jsIsUndefined;
pub const jsIsNull = c_api.jsIsNull;
pub const jsIsObject = c_api.jsIsObject;
pub const jsbay_qjs_JS_NewString = c_api.jsbay_qjs_JS_NewString;
pub const jsbay_qjs_JS_NewBool = c_api.jsbay_qjs_JS_NewBool;
pub const jsbay_qjs_JS_NewInt32 = c_api.jsbay_qjs_JS_NewInt32;
pub const jsbay_qjs_JS_NewFloat64 = c_api.jsbay_qjs_JS_NewFloat64;
pub const jsbay_qjs_JS_NewCFunction = c_api.jsbay_qjs_JS_NewCFunction;
pub const jsbay_qjs_JS_NewCFunctionMagic = c_api.jsbay_qjs_JS_NewCFunctionMagic;
pub const jsbay_qjs_JS_IsFunction = c_api.jsbay_qjs_JS_IsFunction;
pub const jsbay_qjs_JS_ToCString = c_api.jsbay_qjs_JS_ToCString;
pub const jsbay_qjs_JS_DupValue = c_api.jsbay_qjs_JS_DupValue;
pub const jsbay_qjs_JS_FreeValue = c_api.jsbay_qjs_JS_FreeValue;
pub const jsbay_qjs_JS_FreeCString = c_api.jsbay_qjs_JS_FreeCString;
pub const jsbay_qjs_JS_IsBool = c_api.jsbay_qjs_JS_IsBool;
pub const jsbay_qjs_JS_IsNumber = c_api.jsbay_qjs_JS_IsNumber;
pub const jsbay_qjs_JS_IsString = c_api.jsbay_qjs_JS_IsString;
pub const jsbay_qjs_JS_IsObject = c_api.jsbay_qjs_JS_IsObject;
pub const JS_NewArrayBuffer = c_api.JS_NewArrayBuffer;
pub const JS_NewArrayBufferCopy = c_api.JS_NewArrayBufferCopy;
pub const JS_GetArrayBuffer = c_api.JS_GetArrayBuffer;
pub const JS_IsArrayBuffer = c_api.JS_IsArrayBuffer;
pub const JS_NewTypedArray = c_api.JS_NewTypedArray;
pub const JS_GetTypedArrayBuffer = c_api.JS_GetTypedArrayBuffer;
pub const JS_GetTypedArrayType = c_api.JS_GetTypedArrayType;
pub const JS_NewDate = c_api.JS_NewDate;
pub const JS_IsDate = c_api.JS_IsDate;
pub const JS_NewBigInt64 = c_api.JS_NewBigInt64;
pub const JS_NewBigUint64 = c_api.JS_NewBigUint64;
pub const JS_ToBigInt64 = c_api.JS_ToBigInt64;
pub const JS_ToBigUint64 = c_api.JS_ToBigUint64;
pub const JS_IsInstanceOf = c_api.JS_IsInstanceOf;
// from quickjs/lifecycle.zig
pub const processPendingJobsImpl = lifecycle.processPendingJobsImpl;
pub const debugStackAnchorThread = lifecycle.debugStackAnchorThread;
pub const debugStackAnchorSp = lifecycle.debugStackAnchorSp;
pub const QuickJsBackend = lifecycle.QuickJsBackend;
pub const Backend = QuickJsBackend;
// from quickjs/exception.zig
pub const getAndFormatException = exception.getAndFormatException;
pub const jsonStringify = exception.jsonStringify;
pub const valueToString = exception.valueToString;
// from quickjs/datetime.zig
pub const qjsIsDate = datetime.qjsIsDate;
pub const qjsToDateMs = datetime.qjsToDateMs;
pub const qjsNewDate = datetime.qjsNewDate;
pub const qjsIsBigInt = datetime.qjsIsBigInt;
pub const qjsToBigIntI64 = datetime.qjsToBigIntI64;
pub const qjsToBigIntU64 = datetime.qjsToBigIntU64;
pub const qjsNewBigIntI64 = datetime.qjsNewBigIntI64;
pub const qjsNewBigIntU64 = datetime.qjsNewBigIntU64;
// from quickjs/collections.zig
pub const qjsIsMap = collections.qjsIsMap;
pub const qjsIsSet = collections.qjsIsSet;
pub const qjsMapSetToJson = collections.qjsMapSetToJson;
pub const qjsNewMapFromJson = collections.qjsNewMapFromJson;
pub const qjsNewSetFromJson = collections.qjsNewSetFromJson;
pub const QjsMapForEachFn = collections.QjsMapForEachFn;
pub const QjsSetForEachFn = collections.QjsSetForEachFn;
pub const qjsMapForEach = collections.qjsMapForEach;
pub const qjsSetForEach = collections.qjsSetForEach;
pub const qjsMapSize = collections.qjsMapSize;
pub const qjsSetSize = collections.qjsSetSize;
pub const qjsNewMap = collections.qjsNewMap;
pub const qjsNewSet = collections.qjsNewSet;
pub const qjsMapSet = collections.qjsMapSet;
pub const qjsSetAdd = collections.qjsSetAdd;
// from quickjs/dataview.zig
pub const QjsDataViewInfo = dataview.QjsDataViewInfo;
pub const qjsIsDataView = dataview.qjsIsDataView;
pub const qjsDataViewInfo = dataview.qjsDataViewInfo;
pub const qjsNewDataView = dataview.qjsNewDataView;
// from quickjs/external.zig
pub const QjsExternalFinalizer = external.QjsExternalFinalizer;
pub const qjsNewExternal = external.qjsNewExternal;
pub const qjsGetExternal = external.qjsGetExternal;
pub const qjsIsExternal = external.qjsIsExternal;
// from quickjs/module.zig
pub const QJS_EVAL_TYPE_MODULE = module.QJS_EVAL_TYPE_MODULE;
pub const QJS_EVAL_FLAG_COMPILE_ONLY = module.QJS_EVAL_FLAG_COMPILE_ONLY;
pub const installModuleLoader = module.installModuleLoader;
pub const evalAsModule = module.evalAsModule;
pub const importModuleBySpecifier = module.importModuleBySpecifier;
// from quickjs/bytecode.zig
pub const QJS_WRITE_OBJ_BYTECODE = bytecode.QJS_WRITE_OBJ_BYTECODE;
pub const QJS_READ_OBJ_BYTECODE = bytecode.QJS_READ_OBJ_BYTECODE;
pub const QjsCompileResult = bytecode.QjsCompileResult;
pub const qjsCompileBytecode = bytecode.qjsCompileBytecode;
pub const qjsFreeBytecode = bytecode.qjsFreeBytecode;
pub const qjsRunBytecode = bytecode.qjsRunBytecode;
pub const qjsRunBytecodeToFn = bytecode.qjsRunBytecodeToFn;
// from quickjs/errors.zig
pub const QjsErrorKind = errors.QjsErrorKind;
pub const qjsNewTypedError = errors.qjsNewTypedError;
pub const qjsIsError = errors.qjsIsError;
pub const qjsThrowValue = errors.qjsThrowValue;
// from quickjs/runtime_control.zig
pub const QjsInterruptState = runtime_control.QjsInterruptState;
pub const qjsInstallInterruptHandler = runtime_control.qjsInstallInterruptHandler;
pub const qjsUninstallInterruptHandler = runtime_control.qjsUninstallInterruptHandler;
pub const qjsRunGc = runtime_control.qjsRunGc;
pub const qjsSetMemoryLimit = runtime_control.qjsSetMemoryLimit;
pub const qjsMemoryUsage = runtime_control.qjsMemoryUsage;
pub const QjsMemoryUsageSnapshot = runtime_control.QjsMemoryUsageSnapshot;
// from quickjs/buffers.zig
pub const QjsBufferFinalizer = buffers.QjsBufferFinalizer;
pub const qjsNewArrayBufferFromBytes = buffers.qjsNewArrayBufferFromBytes;
pub const qjsNewUint8ArrayFromBytes = buffers.qjsNewUint8ArrayFromBytes;
pub const qjsGetBufferView = buffers.qjsGetBufferView;
// from quickjs/weak.zig
pub const jsbay_qjsWeakAttach = weak.jsbay_qjsWeakAttach;
pub const jsbay_qjsWeakGetLive = weak.jsbay_qjsWeakGetLive;
pub const jsbay_qjsWeakRelease = weak.jsbay_qjsWeakRelease;
// from quickjs/weakcb.zig
pub const QjsWeakFinalizeCallback = weakcb.QjsWeakFinalizeCallback;
pub const qjsWeakAttachFinalizer = weakcb.qjsWeakAttachFinalizer;
pub const qjsWeakNextFinalizerKeyForTesting = weakcb.nextWeakFinalizerKeyForTesting;
pub const qjsHostObjectCreate = @import("quickjs/host_object.zig").create;
pub const qjsSymbol = @import("quickjs/symbol.zig");
// from quickjs/cjs.zig
pub const qjsCjsEvalToValue = cjs.qjsCjsEvalToValue;
