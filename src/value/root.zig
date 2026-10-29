//! Unified value layer — backend-agnostic argument access and return values.
//!
//! This module provides the abstraction that eliminates per-backend code in consumers. A native function handler receives NativeArgs (read arguments as JSON/string/number) and returns NativeResult (null/bool/number/string/json/error). The engine handles all backend-specific marshalling internally.
//!
//! The implementation is split across `src/value/`:
//!   - `value/types.zig`         — TypedArray / ArrayBuffer / DataView payloads
//!   - `value/native_result.zig` — NativeResult tagged union
//!   - `value/native_args.zig`   — NativeArgs accessor + freeString
//!   - `value/dispatch.zig`      — Date/BigInt/Map/Set/DataView/TypedArray helpers
//!   - `value/registry.zig`      — registerFunction + comptime backend trampolines
//!   - `value/init.zig`          — valueInit comptime constructor
//!
//! This file re-exports the value API exposed by the package root.

const types = @import("types.zig");
const native_result = @import("native_result.zig");
const native_args = @import("native_args.zig");
const dispatch = @import("dispatch.zig");
const registry = @import("registry.zig");
const init_mod = @import("init.zig");

// ---- Plain-data payload types ----

pub const TypedArrayKind = types.TypedArrayKind;
pub const TypedArrayView = types.TypedArrayView;
pub const ArrayBufferPayload = types.ArrayBufferPayload;
pub const TypedArrayPayload = types.TypedArrayPayload;
pub const DataViewPayload = types.DataViewPayload;

// ---- Native callback contract ----

pub const NativeResult = native_result.NativeResult;
pub const NativeArgs = native_args.NativeArgs;
pub const freeString = native_args.freeString;

// ---- Date / BigInt / Map / Set / DataView / TypedArray dispatch ----

pub const MapForEachFn = dispatch.MapForEachFn;
pub const SetForEachFn = dispatch.SetForEachFn;

pub const newTypedArrayFromBytes = dispatch.newTypedArrayFromBytes;
pub const newTypedArray = dispatch.newTypedArray;
pub const newDataView = dispatch.newDataView;

pub const isDateVal = dispatch.isDateVal;
pub const toDateMsVal = dispatch.toDateMsVal;
pub const newDateVal = dispatch.newDateVal;

pub const isBigIntVal = dispatch.isBigIntVal;
pub const toBigIntI64Val = dispatch.toBigIntI64Val;
pub const toBigIntU64Val = dispatch.toBigIntU64Val;
pub const newBigIntI64Val = dispatch.newBigIntI64Val;
pub const newBigIntU64Val = dispatch.newBigIntU64Val;

pub const isMapVal = dispatch.isMapVal;
pub const isSetVal = dispatch.isSetVal;
pub const mapSetToJsonVal = dispatch.mapSetToJsonVal;
pub const newMapFromJsonVal = dispatch.newMapFromJsonVal;
pub const newSetFromJsonVal = dispatch.newSetFromJsonVal;

pub const mapForEachVal = dispatch.mapForEachVal;
pub const setForEachVal = dispatch.setForEachVal;
pub const mapSizeVal = dispatch.mapSizeVal;
pub const setSizeVal = dispatch.setSizeVal;

pub const newMap = dispatch.newMap;
pub const newSet = dispatch.newSet;
pub const mapSet = dispatch.mapSet;
pub const setAdd = dispatch.setAdd;

pub const isDataViewVal = dispatch.isDataViewVal;

// ---- Native function registration ----

pub const NativeHandler = registry.NativeHandler;
pub const FunctionEntry = registry.FunctionEntry;
pub const registerFunction = registry.registerFunction;
pub const registerObjectWithFunctions = registry.registerObjectWithFunctions;

// ---- Comptime value constructor ----

pub const valueInit = init_mod.valueInit;

/// `strictEquals(instance_id, a, b) bool` — JavaScript `===` on the host.
pub const strictEquals = dispatch.strictEquals;

/// `isConstructor(instance_id, v) bool` — ES IsConstructor.
pub const isConstructor = dispatch.isConstructor;

/// `newArray(instance_id, len) ?Value` — `new Array(len)`. Caller frees it.
pub const newArray = dispatch.newArray;

/// `arrayGet(instance_id, arr, index) ?Value` — hole is `undefined`, not null.
pub const arrayGet = dispatch.arrayGet;

/// `arraySet(instance_id, arr, index, val) bool` — does not consume `val`.
pub const arraySet = dispatch.arraySet;

/// `arrayLength(instance_id, arr) ?u32`.
pub const arrayLength = dispatch.arrayLength;

/// `arrayClear(instance_id, arr) bool` — sets `length` to 0.
pub const arrayClear = dispatch.arrayClear;

/// `defineDataProperty(instance_id, obj, key, val, writable) bool`. Data descriptor. `writable == false` throws on strict assignment.
pub const defineDataProperty = dispatch.defineDataProperty;
