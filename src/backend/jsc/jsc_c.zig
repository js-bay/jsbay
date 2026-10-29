//! Hand-written bindings for the JavaScriptCore C API used by this backend. Declarations follow the SDK headers. `JSClassDefinition` must preserve the C field order and types because native handles copy it by value.

// ---- Opaque reference types (JSBase.h) ----
//
// C's const and mutable opaque pointers become `?*const T` and `?*T` pairs.

pub const OpaqueJSContextGroup = opaque {};
pub const JSContextGroupRef = ?*const OpaqueJSContextGroup;

pub const OpaqueJSContext = opaque {};
pub const JSContextRef = ?*const OpaqueJSContext;
pub const JSGlobalContextRef = ?*OpaqueJSContext;

pub const OpaqueJSString = opaque {};
pub const JSStringRef = ?*OpaqueJSString;

pub const OpaqueJSClass = opaque {};
pub const JSClassRef = ?*OpaqueJSClass;

pub const OpaqueJSPropertyNameAccumulator = opaque {};
pub const JSPropertyNameAccumulatorRef = ?*OpaqueJSPropertyNameAccumulator;

pub const OpaqueJSValue = opaque {};
pub const JSValueRef = ?*const OpaqueJSValue;
pub const JSObjectRef = ?*OpaqueJSValue;

pub const JSTypedArrayBytesDeallocator = ?*const fn (bytes: ?*anyopaque, deallocatorContext: ?*anyopaque) callconv(.c) void;

// ---- Script evaluation / GC (JSBase.h) ----

pub extern fn JSEvaluateScript(ctx: JSContextRef, script: JSStringRef, thisObject: JSObjectRef, sourceURL: JSStringRef, startingLineNumber: c_int, exception: [*c]JSValueRef) JSValueRef;
pub extern fn JSGarbageCollect(ctx: JSContextRef) void;

// ---- Contexts (JSContextRef.h) ----

pub extern fn JSContextGroupCreate() JSContextGroupRef;
pub extern fn JSContextGroupRelease(group: JSContextGroupRef) void;
pub extern fn JSGlobalContextCreateInGroup(group: JSContextGroupRef, globalObjectClass: JSClassRef) JSGlobalContextRef;
pub extern fn JSGlobalContextRelease(ctx: JSGlobalContextRef) void;
pub extern fn JSContextGetGlobalObject(ctx: JSContextRef) JSObjectRef;
pub extern fn JSContextGetGroup(ctx: JSContextRef) JSContextGroupRef;

// ---- Strings (JSStringRef.h) ----

pub const JSChar = u16;
pub extern fn JSStringCreateWithCharacters(chars: [*c]const JSChar, numChars: usize) JSStringRef;
pub extern fn JSStringCreateWithUTF8CString(string: [*c]const u8) JSStringRef;
pub extern fn JSStringRelease(string: JSStringRef) void;
pub extern fn JSStringGetLength(string: JSStringRef) usize;
pub extern fn JSStringGetCharactersPtr(string: JSStringRef) [*c]const JSChar;
pub extern fn JSStringGetMaximumUTF8CStringSize(string: JSStringRef) usize;
pub extern fn JSStringGetUTF8CString(string: JSStringRef, buffer: [*c]u8, bufferSize: usize) usize;

// ---- Values (JSValueRef.h) ----

pub const JSType = c_uint;

pub extern fn JSValueIsUndefined(ctx: JSContextRef, value: JSValueRef) bool;
pub extern fn JSValueIsNull(ctx: JSContextRef, value: JSValueRef) bool;
pub extern fn JSValueIsBoolean(ctx: JSContextRef, value: JSValueRef) bool;
pub extern fn JSValueIsNumber(ctx: JSContextRef, value: JSValueRef) bool;
pub extern fn JSValueIsString(ctx: JSContextRef, value: JSValueRef) bool;
pub extern fn JSValueIsSymbol(ctx: JSContextRef, value: JSValueRef) bool;
pub extern fn JSValueIsObject(ctx: JSContextRef, value: JSValueRef) bool;
pub extern fn JSValueIsArray(ctx: JSContextRef, value: JSValueRef) bool;
pub extern fn JSValueIsObjectOfClass(ctx: JSContextRef, value: JSValueRef, jsClass: JSClassRef) bool;
pub extern fn JSValueIsDate(ctx: JSContextRef, value: JSValueRef) bool;
pub extern fn JSValueGetTypedArrayType(ctx: JSContextRef, value: JSValueRef, exception: [*c]JSValueRef) JSTypedArrayType;
pub extern fn JSValueIsInstanceOfConstructor(ctx: JSContextRef, value: JSValueRef, constructor: JSObjectRef, exception: [*c]JSValueRef) bool;

pub extern fn JSValueMakeUndefined(ctx: JSContextRef) JSValueRef;
pub extern fn JSValueMakeNull(ctx: JSContextRef) JSValueRef;
pub extern fn JSValueMakeBoolean(ctx: JSContextRef, boolean: bool) JSValueRef;
pub extern fn JSValueMakeNumber(ctx: JSContextRef, number: f64) JSValueRef;
pub extern fn JSValueMakeString(ctx: JSContextRef, string: JSStringRef) JSValueRef;

pub extern fn JSValueMakeFromJSONString(ctx: JSContextRef, string: JSStringRef) JSValueRef;
pub extern fn JSValueCreateJSONString(ctx: JSContextRef, value: JSValueRef, indent: c_uint, exception: [*c]JSValueRef) JSStringRef;

pub extern fn JSValueToBoolean(ctx: JSContextRef, value: JSValueRef) bool;
pub extern fn JSValueToNumber(ctx: JSContextRef, value: JSValueRef, exception: [*c]JSValueRef) f64;
pub extern fn JSValueToStringCopy(ctx: JSContextRef, value: JSValueRef, exception: [*c]JSValueRef) JSStringRef;
pub extern fn JSValueToObject(ctx: JSContextRef, value: JSValueRef, exception: [*c]JSValueRef) JSObjectRef;

pub extern fn JSValueProtect(ctx: JSContextRef, value: JSValueRef) void;
pub extern fn JSValueUnprotect(ctx: JSContextRef, value: JSValueRef) void;
pub extern fn JSValueIsStrictEqual(ctx: JSContextRef, a: JSValueRef, b: JSValueRef) bool;

// ---- Property attributes (JSObjectRef.h) ----

pub const JSPropertyAttributes = c_uint;
pub const kJSPropertyAttributeReadOnly: c_int = 1 << 1;
pub const kJSPropertyAttributeDontEnum: c_int = 1 << 2;
pub const kJSPropertyAttributeDontDelete: c_int = 1 << 3;

pub const JSClassAttributes = c_uint;

// ---- Object callbacks and class definition (JSObjectRef.h) ----
//
// These callback typedefs and the JSStaticValue/JSStaticFunction/ JSClassDefinition structs only need to exist with the right shape — call sites assign plain Zig functions to the JSClassDefinition fields directly (implicit fn-pointer coercion), they don't reference most of these type names. JSObjectCallAsFunctionCallback is used as a parameter type in common.zig, so it stays reachable under its real name like the others for consistency.

pub const JSObjectInitializeCallback = ?*const fn (ctx: JSContextRef, object: JSObjectRef) callconv(.c) void;
pub const JSObjectFinalizeCallback = ?*const fn (object: JSObjectRef) callconv(.c) void;
pub const JSObjectHasPropertyCallback = ?*const fn (ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef) callconv(.c) bool;
pub const JSObjectGetPropertyCallback = ?*const fn (ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef, exception: [*c]JSValueRef) callconv(.c) JSValueRef;
pub const JSObjectSetPropertyCallback = ?*const fn (ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef, value: JSValueRef, exception: [*c]JSValueRef) callconv(.c) bool;
pub const JSObjectDeletePropertyCallback = ?*const fn (ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef, exception: [*c]JSValueRef) callconv(.c) bool;
pub const JSObjectGetPropertyNamesCallback = ?*const fn (ctx: JSContextRef, object: JSObjectRef, propertyNames: JSPropertyNameAccumulatorRef) callconv(.c) void;
pub const JSObjectCallAsFunctionCallback = ?*const fn (ctx: JSContextRef, function: JSObjectRef, thisObject: JSObjectRef, argumentCount: usize, arguments: [*c]const JSValueRef, exception: [*c]JSValueRef) callconv(.c) JSValueRef;
pub const JSObjectCallAsConstructorCallback = ?*const fn (ctx: JSContextRef, constructor: JSObjectRef, argumentCount: usize, arguments: [*c]const JSValueRef, exception: [*c]JSValueRef) callconv(.c) JSObjectRef;
pub const JSObjectHasInstanceCallback = ?*const fn (ctx: JSContextRef, constructor: JSObjectRef, possibleInstance: JSValueRef, exception: [*c]JSValueRef) callconv(.c) bool;
pub const JSObjectConvertToTypeCallback = ?*const fn (ctx: JSContextRef, object: JSObjectRef, @"type": JSType, exception: [*c]JSValueRef) callconv(.c) JSValueRef;

pub const JSStaticValue = extern struct {
    name: [*c]const u8 = null,
    getProperty: JSObjectGetPropertyCallback = null,
    setProperty: JSObjectSetPropertyCallback = null,
    attributes: JSPropertyAttributes = 0,
};

pub const JSStaticFunction = extern struct {
    name: [*c]const u8 = null,
    callAsFunction: JSObjectCallAsFunctionCallback = null,
    attributes: JSPropertyAttributes = 0,
};

/// Field order and types must exactly match the real `JSClassDefinition` from JSObjectRef.h — see the module-level doc comment for why.
pub const JSClassDefinition = extern struct {
    version: c_int = 0,
    attributes: JSClassAttributes = 0,
    className: [*c]const u8 = null,
    parentClass: JSClassRef = null,
    staticValues: [*c]const JSStaticValue = null,
    staticFunctions: [*c]const JSStaticFunction = null,
    initialize: JSObjectInitializeCallback = null,
    finalize: JSObjectFinalizeCallback = null,
    hasProperty: JSObjectHasPropertyCallback = null,
    getProperty: JSObjectGetPropertyCallback = null,
    setProperty: JSObjectSetPropertyCallback = null,
    deleteProperty: JSObjectDeletePropertyCallback = null,
    getPropertyNames: JSObjectGetPropertyNamesCallback = null,
    callAsFunction: JSObjectCallAsFunctionCallback = null,
    callAsConstructor: JSObjectCallAsConstructorCallback = null,
    hasInstance: JSObjectHasInstanceCallback = null,
    convertToType: JSObjectConvertToTypeCallback = null,
};

pub extern const kJSClassDefinitionEmpty: JSClassDefinition;

pub extern fn JSClassCreate(definition: [*c]const JSClassDefinition) JSClassRef;

// ---- Objects (JSObjectRef.h) ----

pub extern fn JSObjectMake(ctx: JSContextRef, jsClass: JSClassRef, data: ?*anyopaque) JSObjectRef;
pub extern fn JSObjectMakeFunctionWithCallback(ctx: JSContextRef, name: JSStringRef, callAsFunction: JSObjectCallAsFunctionCallback) JSObjectRef;
pub extern fn JSObjectMakeConstructor(ctx: JSContextRef, jsClass: JSClassRef, callAsConstructor: JSObjectCallAsConstructorCallback) JSObjectRef;
pub extern fn JSObjectMakeArray(ctx: JSContextRef, argumentCount: usize, arguments: [*c]const JSValueRef, exception: [*c]JSValueRef) JSObjectRef;
pub extern fn JSObjectMakeDate(ctx: JSContextRef, argumentCount: usize, arguments: [*c]const JSValueRef, exception: [*c]JSValueRef) JSObjectRef;
pub extern fn JSObjectMakeError(ctx: JSContextRef, argumentCount: usize, arguments: [*c]const JSValueRef, exception: [*c]JSValueRef) JSObjectRef;
pub extern fn JSObjectMakeDeferredPromise(ctx: JSContextRef, resolve: [*c]JSObjectRef, reject: [*c]JSObjectRef, exception: [*c]JSValueRef) JSObjectRef;

pub extern fn JSObjectSetPrototype(ctx: JSContextRef, object: JSObjectRef, value: JSValueRef) void;
pub extern fn JSObjectHasProperty(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef) bool;
pub extern fn JSObjectGetProperty(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef, exception: [*c]JSValueRef) JSValueRef;
pub extern fn JSObjectSetProperty(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef, value: JSValueRef, attributes: JSPropertyAttributes, exception: [*c]JSValueRef) void;
pub extern fn JSObjectDeleteProperty(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef, exception: [*c]JSValueRef) bool;
pub extern fn JSObjectGetPropertyAtIndex(ctx: JSContextRef, object: JSObjectRef, propertyIndex: c_uint, exception: [*c]JSValueRef) JSValueRef;
pub extern fn JSObjectSetPropertyAtIndex(ctx: JSContextRef, object: JSObjectRef, propertyIndex: c_uint, value: JSValueRef, exception: [*c]JSValueRef) void;

pub extern fn JSObjectGetPrivate(object: JSObjectRef) ?*anyopaque;
pub extern fn JSObjectSetPrivate(object: JSObjectRef, data: ?*anyopaque) bool;

pub extern fn JSObjectIsFunction(ctx: JSContextRef, object: JSObjectRef) bool;
pub extern fn JSObjectIsConstructor(ctx: JSContextRef, object: JSObjectRef) bool;
pub extern fn JSObjectCallAsFunction(ctx: JSContextRef, object: JSObjectRef, thisObject: JSObjectRef, argumentCount: usize, arguments: [*c]const JSValueRef, exception: [*c]JSValueRef) JSValueRef;
pub extern fn JSObjectCallAsConstructor(ctx: JSContextRef, object: JSObjectRef, argumentCount: usize, arguments: [*c]const JSValueRef, exception: [*c]JSValueRef) JSObjectRef;
pub extern fn JSObjectGetPrototype(ctx: JSContextRef, object: JSObjectRef) JSValueRef;

// ---- Typed arrays / array buffers (JSTypedArray.h) ----

pub const JSTypedArrayType = c_uint;
pub const kJSTypedArrayTypeInt8Array: c_int = 0;
pub const kJSTypedArrayTypeInt16Array: c_int = 1;
pub const kJSTypedArrayTypeInt32Array: c_int = 2;
pub const kJSTypedArrayTypeUint8Array: c_int = 3;
pub const kJSTypedArrayTypeUint8ClampedArray: c_int = 4;
pub const kJSTypedArrayTypeUint16Array: c_int = 5;
pub const kJSTypedArrayTypeUint32Array: c_int = 6;
pub const kJSTypedArrayTypeFloat32Array: c_int = 7;
pub const kJSTypedArrayTypeFloat64Array: c_int = 8;
pub const kJSTypedArrayTypeArrayBuffer: c_int = 9;
pub const kJSTypedArrayTypeNone: c_int = 10;
pub const kJSTypedArrayTypeBigInt64Array: c_int = 11;
pub const kJSTypedArrayTypeBigUint64Array: c_int = 12;

pub extern fn JSObjectMakeTypedArray(ctx: JSContextRef, arrayType: JSTypedArrayType, length: usize, exception: [*c]JSValueRef) JSObjectRef;
pub extern fn JSObjectMakeTypedArrayWithArrayBuffer(ctx: JSContextRef, arrayType: JSTypedArrayType, buffer: JSObjectRef, exception: [*c]JSValueRef) JSObjectRef;
pub extern fn JSObjectMakeTypedArrayWithArrayBufferAndOffset(ctx: JSContextRef, arrayType: JSTypedArrayType, buffer: JSObjectRef, byteOffset: usize, length: usize, exception: [*c]JSValueRef) JSObjectRef;
pub extern fn JSObjectGetTypedArrayBytesPtr(ctx: JSContextRef, object: JSObjectRef, exception: [*c]JSValueRef) ?*anyopaque;
pub extern fn JSObjectGetTypedArrayByteLength(ctx: JSContextRef, object: JSObjectRef, exception: [*c]JSValueRef) usize;
pub extern fn JSObjectGetTypedArrayByteOffset(ctx: JSContextRef, object: JSObjectRef, exception: [*c]JSValueRef) usize;
pub extern fn JSObjectGetTypedArrayBuffer(ctx: JSContextRef, object: JSObjectRef, exception: [*c]JSValueRef) JSObjectRef;

pub extern fn JSObjectMakeArrayBufferWithBytesNoCopy(ctx: JSContextRef, bytes: ?*anyopaque, byteLength: usize, bytesDeallocator: JSTypedArrayBytesDeallocator, deallocatorContext: ?*anyopaque, exception: [*c]JSValueRef) JSObjectRef;
pub extern fn JSObjectGetArrayBufferBytesPtr(ctx: JSContextRef, object: JSObjectRef, exception: [*c]JSValueRef) ?*anyopaque;
pub extern fn JSObjectGetArrayBufferByteLength(ctx: JSContextRef, object: JSObjectRef, exception: [*c]JSValueRef) usize;
