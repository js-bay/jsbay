/* QuickJS-NG-only ABI adapters; common normalization lives in quickjs_common. */
#include "quickjs.h"

JSClassID jsbay_qjs_JS_NewClassID(JSRuntime *rt, JSClassID *pclass_id) {
    return JS_NewClassID(rt, pclass_id);
}

/* Exported by quickjs.c but absent from quickjs.h. */
extern bool JS_IsRegisteredClass(JSRuntime *rt, JSClassID class_id);

int jsbay_qjs_JS_IsRegisteredClass(JSRuntime *rt, JSClassID class_id) {
    return JS_IsRegisteredClass(rt, class_id);
}

int jsbay_qjs_JS_IsPromise(JSContext *ctx, JSValueConst val) {
    (void)ctx;
    return JS_IsPromise(val);
}

JSValue jsbay_qjs_JS_NewArrayBuffer(JSContext *ctx, uint8_t *buf, size_t len,
                               size_t max_len,
                               JSReallocArrayBufferDataFunc *realloc_func,
                               void *opaque, int is_shared) {
    return JS_NewArrayBuffer(ctx, buf, len, max_len, realloc_func, opaque,
                             is_shared != 0);
}

int jsbay_qjs_JS_IsArrayBuffer(JSContext *ctx, JSValueConst val) {
    (void)ctx;
    return JS_IsArrayBuffer(val);
}

int jsbay_qjs_JS_GetTypedArrayType(JSContext *ctx, JSValueConst val) {
    (void)ctx;
    return JS_GetTypedArrayType(val);
}

int jsbay_qjs_JS_IsDate(JSContext *ctx, JSValueConst val) {
    (void)ctx;
    return JS_IsDate(val);
}

int jsbay_qjs_JS_IsProxy(JSContext *ctx, JSValueConst val) {
    (void)ctx;
    return JS_IsProxy(val);
}

int jsbay_qjs_JS_ToBigUint64(JSContext *ctx, uint64_t *out, JSValueConst val) {
    return JS_ToBigUint64(ctx, out, val);
}

JSValue jsbay_qjs_JS_GetPropertyValue(JSContext *ctx, JSValueConst obj, JSValue key) {
    return JS_GetPropertyValue(ctx, obj, key);
}

int jsbay_qjs_JS_SetPropertyValue(JSContext *ctx, JSValueConst obj, JSValue key,
                             JSValue val, int flags) {
    return JS_SetPropertyValue(ctx, obj, key, val, flags);
}
