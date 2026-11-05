//! Compat shim — prefer native_handle.zig.
const impl = @import("native_handle.zig");
pub const Context = impl.Context;
pub const Value = impl.Value;
pub const CallFn = impl.CallFn;
pub const FinalizeFn = impl.FinalizeFn;
pub const MethodFn = impl.MethodFn;
pub const HandleData = impl.HandleData;
pub const MethodEntry = impl.MethodEntry;
pub const init = impl.init;
pub const initWithRuntime = impl.initWithRuntime;
pub const create = impl.create;
pub const createWithMethods = impl.createWithMethods;
pub const setMethod = impl.setMethod;
pub const setStringProp = impl.setStringProp;
pub const setIntProp = impl.setIntProp;
pub const getOpaque = impl.getOpaque;
pub const getClassId = impl.getClassId;
