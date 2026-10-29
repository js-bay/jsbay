/* QuickJS compatibility wrappers for the shared Zig ABI. */
#include "quickjs.h"
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>

typedef void *JSReallocArrayBufferDataFunc(JSRuntime *rt, void *opaque, void *ptr, size_t size);
typedef void *JSReallocArrayBufferDataFunc2(JSRuntime *rt, void *opaque, void *ptr, size_t size);
struct QjsBufferFreeData {
    JSReallocArrayBufferDataFunc2 *func;
    void *opaque;
};
static void qjs_buffer_free(JSRuntime *rt, void *opaque, void *ptr) {
    struct QjsBufferFreeData *data = opaque;
    (void)data->func(rt, data->opaque, ptr, 0);
    js_free_rt(rt, data);
}
JSValue jsbay_qjs_JS_NewArrayBuffer(JSContext *ctx, uint8_t *buf, size_t len,
                               size_t max_len, JSReallocArrayBufferDataFunc2 *func,
                               void *opaque, int is_shared) {
    (void)max_len;
    if (!func) return JS_NewArrayBuffer(ctx, buf, len, NULL, NULL, is_shared);
    struct QjsBufferFreeData *data = js_malloc(ctx, sizeof(*data));
    if (!data) return JS_EXCEPTION;
    data->func = func;
    data->opaque = opaque;
    JSValue val = JS_NewArrayBuffer(ctx, buf, len, qjs_buffer_free, data, is_shared);
    if (JS_IsException(val)) js_free(ctx, data);
    return val;
}

static atomic_flag qjs_class_ids_lock = ATOMIC_FLAG_INIT;
static _Atomic JSClassID qjs_array_buffer_class_id;
static _Atomic JSClassID qjs_typed_array_class_ids[12];
static _Atomic JSClassID qjs_date_class_id;
static _Atomic JSClassID qjs_proxy_class_id;
static void qjs_ensure_class_ids(JSContext *ctx) {
    if (atomic_load_explicit(&qjs_array_buffer_class_id, memory_order_acquire)) return;
    while (atomic_flag_test_and_set_explicit(&qjs_class_ids_lock, memory_order_acquire)) { }
    if (!atomic_load_explicit(&qjs_array_buffer_class_id, memory_order_relaxed)) {
        JSValue v = JS_NewArrayBufferCopy(ctx, NULL, 0);
        if (!JS_IsException(v)) {
            atomic_store_explicit(&qjs_array_buffer_class_id, JS_GetClassID(v), memory_order_release);
            JS_FreeValue(ctx, v);
        }
        for (int i = 0; i < 12; i++) {
            JSValue length = JS_NewInt32(ctx, 0);
            JSValue ta = JS_NewTypedArray(ctx, 1, &length, (JSTypedArrayEnum)i);
            JS_FreeValue(ctx, length);
            if (!JS_IsException(ta)) {
                atomic_store_explicit(&qjs_typed_array_class_ids[i], JS_GetClassID(ta), memory_order_release);
                JS_FreeValue(ctx, ta);
            }
        }
        JSValue date = JS_NewDate(ctx, 0);
        if (!JS_IsException(date)) {
            atomic_store_explicit(&qjs_date_class_id, JS_GetClassID(date), memory_order_release);
            JS_FreeValue(ctx, date);
        }
        JSValue global = JS_GetGlobalObject(ctx);
        JSValue proxy_ctor = JS_GetPropertyStr(ctx, global, "Proxy");
        JSValue target = JS_NewObject(ctx);
        JSValue handler = JS_NewObject(ctx);
        JSValue args[2] = { target, handler };
        JSValue proxy = JS_CallConstructor(ctx, proxy_ctor, 2, args);
        if (!JS_IsException(proxy)) {
            atomic_store_explicit(&qjs_proxy_class_id, JS_GetClassID(proxy), memory_order_release);
            JS_FreeValue(ctx, proxy);
        } else {
            JSValue exc = JS_GetException(ctx);
            JS_FreeValue(ctx, exc);
        }
        JS_FreeValue(ctx, target);
        JS_FreeValue(ctx, handler);
        JS_FreeValue(ctx, proxy_ctor);
        JS_FreeValue(ctx, global);
    }
    atomic_flag_clear_explicit(&qjs_class_ids_lock, memory_order_release);
}
int jsbay_qjs_JS_IsArrayBuffer(JSContext *ctx, JSValueConst val) {
    qjs_ensure_class_ids(ctx);
    JSClassID id = atomic_load_explicit(&qjs_array_buffer_class_id, memory_order_acquire);
    return id != 0 && JS_GetClassID(val) == id;
}
int jsbay_qjs_JS_GetTypedArrayType(JSContext *ctx, JSValueConst val) {
    qjs_ensure_class_ids(ctx);
    JSClassID id = JS_GetClassID(val);
    for (int i = 0; i < 12; i++) {
        JSClassID typed_id = atomic_load_explicit(&qjs_typed_array_class_ids[i], memory_order_acquire);
        if (typed_id != 0 && typed_id == id) return i;
    }
    return -1;
}
int jsbay_qjs_JS_IsDate(JSContext *ctx, JSValueConst val) {
    qjs_ensure_class_ids(ctx);
    JSClassID id = atomic_load_explicit(&qjs_date_class_id, memory_order_acquire);
    return id != 0 && JS_GetClassID(val) == id;
}
int jsbay_qjs_JS_IsProxy(JSContext *ctx, JSValueConst val) {
    qjs_ensure_class_ids(ctx);
    JSClassID id = atomic_load_explicit(&qjs_proxy_class_id, memory_order_acquire);
    return id != 0 && JS_GetClassID(val) == id;
}
int jsbay_qjs_JS_ToBigUint64(JSContext *ctx, uint64_t *out, JSValueConst val) {
    int64_t signed_value = 0;
    int result = JS_ToBigInt64(ctx, &signed_value, val);
    if (result == 0) *out = (uint64_t)signed_value;
    return result;
}

JSClassID jsbay_qjs_JS_NewClassID(JSRuntime *rt, JSClassID *pclass_id) {
    (void)rt;
    return JS_NewClassID(pclass_id);
}
int jsbay_qjs_JS_IsPromise(JSContext *ctx, JSValueConst val) {
    return JS_PromiseState(ctx, val) != -1;
}
JSValue jsbay_qjs_JS_GetPropertyValue(JSContext *ctx, JSValueConst obj, JSValue key) {
    JSAtom atom = JS_ValueToAtom(ctx, key);
    JS_FreeValue(ctx, key);
    if (atom == JS_ATOM_NULL) return JS_EXCEPTION;
    JSValue result = JS_GetProperty(ctx, obj, atom);
    JS_FreeAtom(ctx, atom);
    return result;
}
int jsbay_qjs_JS_SetPropertyValue(JSContext *ctx, JSValueConst obj, JSValue key, JSValue val, int flags) {
    JSAtom atom = JS_ValueToAtom(ctx, key);
    JS_FreeValue(ctx, key);
    if (atom == JS_ATOM_NULL) { JS_FreeValue(ctx, val); return -1; }
    int result = JS_SetProperty(ctx, obj, atom, val);
    JS_FreeAtom(ctx, atom);
    if (result < 0 && (flags & JS_PROP_THROW)) return -1;
    return result;
}

static JSValue qjs_queue_microtask_job(JSContext *ctx, int argc, JSValueConst *argv) {
    (void)argc;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue result = JS_Call(ctx, argv[0], global, 0, NULL);
    JS_FreeValue(ctx, global);
    return result;
}

static JSValue qjs_queue_microtask(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsFunction(ctx, argv[0]))
        return JS_ThrowTypeError(ctx, "queueMicrotask requires a function");
#if JSBAY_INSPECTOR
    JS_SetNextJobKind(ctx, "queueMicrotask");
#endif
    if (JS_EnqueueJob(ctx, qjs_queue_microtask_job, 1, argv) < 0)
        return JS_EXCEPTION;
    return JS_UNDEFINED;
}

int jsbay_qjs_JS_InstallQueueMicrotask(JSContext *ctx) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue function = JS_NewCFunction(ctx, qjs_queue_microtask, "queueMicrotask", 1);
    int result = JS_SetPropertyStr(ctx, global, "queueMicrotask", function);
    JS_FreeValue(ctx, global);
    return result;
}

typedef void JSRuntimeFinalizer(JSRuntime *, void *);
typedef struct QjsRuntimeFinalizerNode {
    JSRuntime *rt;
    JSRuntimeFinalizer *func;
    void *opaque;
    struct QjsRuntimeFinalizerNode *next;
} QjsRuntimeFinalizerNode;
static QjsRuntimeFinalizerNode *qjs_runtime_finalizers;
static QjsRuntimeFinalizerNode *qjs_runtime_finalizer_freelist;
static atomic_flag qjs_runtime_finalizers_lock = ATOMIC_FLAG_INIT;
static void qjs_finalizer_lock(void) {
    while (atomic_flag_test_and_set_explicit(&qjs_runtime_finalizers_lock, memory_order_acquire)) { }
}
static void qjs_finalizer_unlock(void) {
    atomic_flag_clear_explicit(&qjs_runtime_finalizers_lock, memory_order_release);
}
/* Thin overflow allocator: freelist covers reuse; cold path stays a return-wrapper. */
static QjsRuntimeFinalizerNode *qjs_alloc_finalizer_node(void) {
    return malloc(sizeof(QjsRuntimeFinalizerNode));
}
static QjsRuntimeFinalizerNode *qjs_take_finalizer_node(void) {
    qjs_finalizer_lock();
    QjsRuntimeFinalizerNode *node = qjs_runtime_finalizer_freelist;
    if (node) qjs_runtime_finalizer_freelist = node->next;
    qjs_finalizer_unlock();
    if (node) {
        node->next = NULL;
        return node;
    }
    return qjs_alloc_finalizer_node();
}
static void qjs_release_finalizer_node(QjsRuntimeFinalizerNode *node) {
    qjs_finalizer_lock();
    node->next = qjs_runtime_finalizer_freelist;
    qjs_runtime_finalizer_freelist = node;
    qjs_finalizer_unlock();
}
int JS_AddRuntimeFinalizer(JSRuntime *rt, JSRuntimeFinalizer *func, void *opaque) {
    QjsRuntimeFinalizerNode *node = qjs_take_finalizer_node();
    if (!node) return -1;
    node->rt = rt;
    node->func = func;
    node->opaque = opaque;
    qjs_finalizer_lock();
    node->next = qjs_runtime_finalizers;
    qjs_runtime_finalizers = node;
    qjs_finalizer_unlock();
    return 0;
}
void jsbay_qjs_JS_RunRuntimeFinalizers(JSRuntime *rt) {
    QjsRuntimeFinalizerNode *owned = NULL;
    qjs_finalizer_lock();
    QjsRuntimeFinalizerNode **cursor = &qjs_runtime_finalizers;
    while (*cursor) {
        QjsRuntimeFinalizerNode *node = *cursor;
        if (node->rt == rt) {
            *cursor = node->next;
            node->next = owned;
            owned = node;
        } else {
            cursor = &node->next;
        }
    }
    qjs_finalizer_unlock();
    while (owned) {
        QjsRuntimeFinalizerNode *node = owned;
        owned = node->next;
        node->func(rt, node->opaque);
        qjs_release_finalizer_node(node);
    }
}

bool JS_IsSameValue(JSContext *ctx, JSValueConst a, JSValueConst b) { return JS_SameValue(ctx, a, b); }

static JSValue qjs_new_error_by_name(JSContext *ctx, const char *name) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue ctor = JS_GetPropertyStr(ctx, global, name);
    JSValue message = JS_NewString(ctx, "");
    JSValue args[1] = { message };
    JSValue result = JS_CallConstructor(ctx, ctor, 1, args);
    JS_FreeValue(ctx, message);
    JS_FreeValue(ctx, ctor);
    JS_FreeValue(ctx, global);
    return result;
}
/* Current callers request an empty native error, then replace its message. */
JSValue JS_NewTypeError(JSContext *ctx, const char *fmt, ...) { (void)fmt; return qjs_new_error_by_name(ctx, "TypeError"); }
JSValue JS_NewRangeError(JSContext *ctx, const char *fmt, ...) { (void)fmt; return qjs_new_error_by_name(ctx, "RangeError"); }
JSValue JS_NewReferenceError(JSContext *ctx, const char *fmt, ...) { (void)fmt; return qjs_new_error_by_name(ctx, "ReferenceError"); }
JSValue JS_NewSyntaxError(JSContext *ctx, const char *fmt, ...) { (void)fmt; return qjs_new_error_by_name(ctx, "SyntaxError"); }
JSValue JS_NewInternalError(JSContext *ctx, const char *fmt, ...) {
    (void)fmt;
    JSValue error = JS_NewError(ctx);
    if (JS_IsException(error)) return error;

    JSValue name = JS_NewString(ctx, "InternalError");
    if (JS_IsException(name)) {
        JS_FreeValue(ctx, error);
        return name;
    }
    if (JS_DefinePropertyValueStr(ctx, error, "name", name,
                                  JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE) < 0) {
        JS_FreeValue(ctx, error);
        return JS_EXCEPTION;
    }
    return error;
}

#if JSBAY_INSPECTOR
typedef void JSLocationHandler(JSContext *, const char *, int, int, int, void *);
typedef void JSExceptionHandler(JSContext *, int, void *);
typedef void JSDebuggerHandler(JSContext *, void *);
void JS_SetLocationHandler(JSRuntime *rt, JSLocationHandler *cb, void *opaque) { (void)rt; (void)cb; (void)opaque; }
void JS_RequestLocationCallback(JSRuntime *rt) { (void)rt; }
void JS_SetExceptionHandler(JSRuntime *rt, JSExceptionHandler *cb, void *opaque) { (void)rt; (void)cb; (void)opaque; }
void JS_SetDebuggerHandler(JSRuntime *rt, JSDebuggerHandler *cb, void *opaque) { (void)rt; (void)cb; (void)opaque; }
JSValue JS_CopyDebugScope(JSContext *ctx, int frame_index, int scope) { (void)frame_index; (void)scope; return JS_UNDEFINED; }
JSValue JS_EvalInDebugFrame(JSContext *ctx, int frame_index, const char *expr, size_t len) {
    (void)frame_index; (void)expr; (void)len;
    return JS_ThrowTypeError(ctx, "%s", "Frame evaluation is unavailable in QuickJS");
}
#endif
