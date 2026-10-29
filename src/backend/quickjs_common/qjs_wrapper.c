/* C ABI normalization shared by the QuickJS backends. */
#include "quickjs.h"

JSValue jsbay_qjs_JS_NewString(JSContext *ctx, const char *str) { return JS_NewString(ctx, str); }
JSValue jsbay_qjs_JS_NewBool(JSContext *ctx, int val) { return JS_NewBool(ctx, val); }
JSValue jsbay_qjs_JS_NewInt32(JSContext *ctx, int32_t val) { return JS_NewInt32(ctx, val); }
JSValue jsbay_qjs_JS_NewFloat64(JSContext *ctx, double val) { return JS_NewFloat64(ctx, val); }
JSValue jsbay_qjs_JS_NewCFunction(JSContext *ctx, JSCFunction *func, const char *name, int length) {
    return JS_NewCFunction(ctx, func, name, length);
}
JSValue jsbay_qjs_JS_NewCFunctionMagic(JSContext *ctx, JSCFunctionMagic *func, const char *name,
                                  int length, JSCFunctionEnum cproto, int magic) {
    return JS_NewCFunctionMagic(ctx, func, name, length, cproto, magic);
}
typedef JSValue jsbay_qjs_JSCFunctionData(JSContext *, JSValueConst, int, JSValueConst *, int, JSValueConst *);
JSValue jsbay_qjs_JS_NewCFunctionData(JSContext *ctx, jsbay_qjs_JSCFunctionData *func,
                                 const char *name, int length, JSValue data) {
    JSValue fn = JS_NewCFunctionData(ctx, (JSCFunctionData *)func, length, 0, 1,
                                     (JSValueConst *)&data);
    if (JS_IsException(fn)) return fn;

    JSValue name_value = JS_NewString(ctx, name);
    if (JS_IsException(name_value)) {
        JS_FreeValue(ctx, fn);
        return name_value;
    }
    if (JS_DefinePropertyValueStr(ctx, fn, "name", name_value,
                                  JS_PROP_CONFIGURABLE) < 0) {
        JS_FreeValue(ctx, fn);
        return JS_EXCEPTION;
    }
    return fn;
}
int jsbay_qjs_JS_IsFunction(JSContext *ctx, JSValue val) { return JS_IsFunction(ctx, val); }
const char *jsbay_qjs_JS_ToCString(JSContext *ctx, JSValue val) { return JS_ToCString(ctx, val); }
JSValue jsbay_qjs_JS_DupValue(JSContext *ctx, JSValue val) { return JS_DupValue(ctx, val); }
void jsbay_qjs_JS_FreeValue(JSContext *ctx, JSValue val) { JS_FreeValue(ctx, val); }
void jsbay_qjs_JS_FreeCString(JSContext *ctx, const char *ptr) { JS_FreeCString(ctx, ptr); }
int jsbay_qjs_JS_IsBool(JSValue val) { return JS_IsBool(val); }
int jsbay_qjs_JS_IsNumber(JSValue val) { return JS_IsNumber(val); }
int jsbay_qjs_JS_IsString(JSValue val) { return JS_IsString(val); }
int jsbay_qjs_JS_IsSymbol(JSValue val) { return JS_IsSymbol(val); }
int jsbay_qjs_JS_IsObject(JSValue val) { return JS_IsObject(val); }

JSValue jsbay_qjs_JS_NewDate(JSContext *ctx, double epoch_ms) { return JS_NewDate(ctx, epoch_ms); }
JSValue jsbay_qjs_JS_NewSymbol(JSContext *ctx, const char *description, int is_global) {
    return JS_NewSymbol(ctx, description, is_global);
}
