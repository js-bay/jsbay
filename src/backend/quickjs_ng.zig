//! QuickJS backend — aggregate entry point.
//!
//! Per-responsibility implementation lives under `quickjs_ng/*.zig`; this file provides an independent QuickJS-NG adapter namespace used by the rest of the engine and the public consumer surface (engine.zig, atoms.zig, runtime_control.zig, errors.zig, bytecode.zig, buffers.zig, …) reach into.
//!
//! The split:
//! * `quickjs_ng/c_api.zig` — cImport, externs, type constants, JS_UNDEFINED/JS_NULL/JS_EXCEPTION, tag-only predicates.
//! * `quickjs_ng/lifecycle.zig` — QuickJsBackend struct (Runtime/Context create/free, eval, console+timers registration, callFunctionNoArgs).
//! * `quickjs_ng/value.zig` — value-method mixin forwarded into QuickJsBackend via explicit `pub const`.
//!   * `quickjs_ng/console.zig`        — `jsConsoleLog` callback.
//!   * `quickjs_ng/timers.zig`         — setTimeout/Interval/clearTimer.
//! * `quickjs_ng/exception.zig` — getAndFormatException, jsonStringify, valueToString.
//!   * `quickjs_ng/datetime.zig`       — Date + BigInt helpers.
//!   * `quickjs_ng/collections.zig`    — Map/Set + iteration.
//!   * `quickjs_ng/dataview.zig`       — DataView ctor/info.
//!   * `quickjs_ng/external.zig`       — opaque external pointers.
//!   * `quickjs_ng/module.zig`         — ES module loader.
//!   * `quickjs_ng/bytecode.zig`       — bytecode compile / run.
//!   * `quickjs_ng/errors.zig`         — structured Error API.
//!   * `quickjs_ng/runtime_control.zig`— interrupt + GC + memory snapshot.
//!   * `quickjs_ng/buffers.zig`        — zero-copy ArrayBuffer / Uint8Array view.
//!   * `quickjs_ng/weak.zig`           — true-weak (`reference.Weak(T)`) support.
//!   * `quickjs_ng/weakcb.zig`         — napi_wrap-style finalizer attachment.
//!   * `quickjs_ng/cjs.zig`            — CommonJS eval-to-value.

// ---- Submodules: re-exported at this namespace (explicit, see module docs above) ----
pub const c_api = @import("quickjs_ng/c_api.zig");
pub const lifecycle = @import("quickjs_ng/lifecycle.zig");
pub const value = @import("quickjs_ng/value.zig");
pub const exception = @import("quickjs_ng/exception.zig");
const datetime = @import("quickjs_ng/datetime.zig");
const collections = @import("quickjs_ng/collections.zig");
const dataview = @import("quickjs_ng/dataview.zig");
const external = @import("quickjs_ng/external.zig");
const module = @import("quickjs_ng/module.zig");
const bytecode = @import("quickjs_ng/bytecode.zig");
const errors = @import("quickjs_ng/errors.zig");
const runtime_control = @import("quickjs_ng/runtime_control.zig");
const buffers = @import("quickjs_ng/buffers.zig");
pub const weak = @import("quickjs_ng/weak.zig");
const weakcb = @import("quickjs_ng/weakcb.zig");
const cjs = @import("quickjs_ng/cjs.zig");
pub const host_abi = @import("quickjs_ng/host_abi.zig");

// from quickjs_ng/c_api.zig
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
// from quickjs_ng/lifecycle.zig
pub const processPendingJobsImpl = lifecycle.processPendingJobsImpl;
pub const debugStackAnchorThread = lifecycle.debugStackAnchorThread;
pub const debugStackAnchorSp = lifecycle.debugStackAnchorSp;
pub const QuickJsNgBackend = lifecycle.QuickJsNgBackend;
pub const Backend = QuickJsNgBackend;
// from quickjs_ng/exception.zig
pub const getAndFormatException = exception.getAndFormatException;
pub const jsonStringify = exception.jsonStringify;
pub const valueToString = exception.valueToString;
// from quickjs_ng/datetime.zig
pub const qjsIsDate = datetime.qjsIsDate;
pub const qjsToDateMs = datetime.qjsToDateMs;
pub const qjsNewDate = datetime.qjsNewDate;
pub const qjsIsBigInt = datetime.qjsIsBigInt;
pub const qjsToBigIntI64 = datetime.qjsToBigIntI64;
pub const qjsToBigIntU64 = datetime.qjsToBigIntU64;
pub const qjsNewBigIntI64 = datetime.qjsNewBigIntI64;
pub const qjsNewBigIntU64 = datetime.qjsNewBigIntU64;
// from quickjs_ng/collections.zig
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
// from quickjs_ng/dataview.zig
pub const QjsDataViewInfo = dataview.QjsDataViewInfo;
pub const qjsIsDataView = dataview.qjsIsDataView;
pub const qjsDataViewInfo = dataview.qjsDataViewInfo;
pub const qjsNewDataView = dataview.qjsNewDataView;
// from quickjs_ng/external.zig
pub const QjsExternalFinalizer = external.QjsExternalFinalizer;
pub const qjsNewExternal = external.qjsNewExternal;
pub const qjsGetExternal = external.qjsGetExternal;
pub const qjsIsExternal = external.qjsIsExternal;
// from quickjs_ng/module.zig
pub const QJS_EVAL_TYPE_MODULE = module.QJS_EVAL_TYPE_MODULE;
pub const QJS_EVAL_FLAG_COMPILE_ONLY = module.QJS_EVAL_FLAG_COMPILE_ONLY;
pub const installModuleLoader = module.installModuleLoader;
pub const evalAsModule = module.evalAsModule;
pub const importModuleBySpecifier = module.importModuleBySpecifier;
// from quickjs_ng/bytecode.zig
pub const QJS_WRITE_OBJ_BYTECODE = bytecode.QJS_WRITE_OBJ_BYTECODE;
pub const QJS_READ_OBJ_BYTECODE = bytecode.QJS_READ_OBJ_BYTECODE;
pub const QjsCompileResult = bytecode.QjsCompileResult;
pub const qjsCompileBytecode = bytecode.qjsCompileBytecode;
pub const qjsFreeBytecode = bytecode.qjsFreeBytecode;
pub const qjsRunBytecode = bytecode.qjsRunBytecode;
pub const qjsRunBytecodeToFn = bytecode.qjsRunBytecodeToFn;
// from quickjs_ng/errors.zig
pub const QjsErrorKind = errors.QjsErrorKind;
pub const qjsNewTypedError = errors.qjsNewTypedError;
pub const qjsIsError = errors.qjsIsError;
pub const qjsThrowValue = errors.qjsThrowValue;
// from quickjs_ng/runtime_control.zig
pub const QjsInterruptState = runtime_control.QjsInterruptState;
pub const qjsInstallInterruptHandler = runtime_control.qjsInstallInterruptHandler;
pub const qjsUninstallInterruptHandler = runtime_control.qjsUninstallInterruptHandler;
pub const qjsRunGc = runtime_control.qjsRunGc;
pub const qjsSetMemoryLimit = runtime_control.qjsSetMemoryLimit;
pub const qjsMemoryUsage = runtime_control.qjsMemoryUsage;
pub const QjsMemoryUsageSnapshot = runtime_control.QjsMemoryUsageSnapshot;
// from quickjs_ng/buffers.zig
pub const QjsBufferFinalizer = buffers.QjsBufferFinalizer;
pub const qjsNewArrayBufferFromBytes = buffers.qjsNewArrayBufferFromBytes;
pub const qjsNewUint8ArrayFromBytes = buffers.qjsNewUint8ArrayFromBytes;
pub const qjsGetBufferView = buffers.qjsGetBufferView;
// from quickjs_ng/weak.zig
pub const jsbay_qjsWeakAttach = weak.jsbay_qjsWeakAttach;
pub const jsbay_qjsWeakGetLive = weak.jsbay_qjsWeakGetLive;
pub const jsbay_qjsWeakRelease = weak.jsbay_qjsWeakRelease;
// from quickjs_ng/weakcb.zig
pub const QjsWeakFinalizeCallback = weakcb.QjsWeakFinalizeCallback;
pub const qjsWeakAttachFinalizer = weakcb.qjsWeakAttachFinalizer;
pub const qjsWeakNextFinalizerKeyForTesting = weakcb.nextWeakFinalizerKeyForTesting;
pub const qjsHostObjectCreate = @import("quickjs_ng/host_object.zig").create;
pub const qjsSymbol = @import("quickjs_ng/symbol.zig");
// from quickjs_ng/cjs.zig
pub const qjsCjsEvalToValue = cjs.qjsCjsEvalToValue;
