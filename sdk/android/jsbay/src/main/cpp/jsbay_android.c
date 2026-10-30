#include "jsbay.h"
#include "jsbay_sync.h"
#include <jni.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* This adapter is deliberately separate from libjsbay: RegisterNatives binds the library-owned io.jsbay.Native class and the core exports no Java symbol. */
static jlongArray result(JNIEnv *e, int status, uint64_t value, uint64_t exception) {
    jlong a[4] = {status, (jlong)value, (jlong)exception, 0};
    jlongArray out = (*e)->NewLongArray(e, 4);
    if (out)
        (*e)->SetLongArrayRegion(e, out, 0, 4, a);
    return out;
}
static jsbay_utf8_t utf(JNIEnv *e, jstring s, jbyteArray *hold) {
    *hold = NULL;
    if (!s)
        return (jsbay_utf8_t){NULL, 0};
    jclass c = (*e)->FindClass(e, "java/lang/String");
    jmethodID m = (*e)->GetMethodID(e, c, "getBytes", "(Ljava/lang/String;)[B");
    (*e)->DeleteLocalRef(e, c);
    jstring n = (*e)->NewStringUTF(e, "UTF-8");
    if (!n || (*e)->ExceptionCheck(e)) {
        if ((*e)->ExceptionCheck(e))
            (*e)->ExceptionClear(e);
        return (jsbay_utf8_t){NULL, 1};
    }
    *hold = (jbyteArray)(*e)->CallObjectMethod(e, s, m, n);
    if ((*e)->ExceptionCheck(e)) {
        (*e)->ExceptionClear(e);
        *hold = NULL;
    }
    (*e)->DeleteLocalRef(e, n);
    if (!*hold)
        return (jsbay_utf8_t){NULL, 1};
    jsize z = (*e)->GetArrayLength(e, *hold);
    jbyte *p = z ? (*e)->GetByteArrayElements(e, *hold, NULL) : NULL;
    return (jsbay_utf8_t){(const uint8_t *)p, (size_t)z};
}
static void done(JNIEnv *e, jbyteArray h, jsbay_utf8_t v) {
    if (h && v.data)
        (*e)->ReleaseByteArrayElements(e, h, (jbyte *)v.data, JNI_ABORT);
    if (h)
        (*e)->DeleteLocalRef(e, h);
}
typedef struct {
    JavaVM *vm;
    jobject log;   /* global ref or NULL */
    jobject event; /* global ref or NULL */
    jmethodID log_mid;
    jmethodID event_mid;
} host_hooks;

#define HOST_HOOKS_CAP 64
static host_hooks g_hooks[HOST_HOOKS_CAP];
static int g_hook_ids[HOST_HOOKS_CAP];
static uint8_t g_hook_used[HOST_HOOKS_CAP];
static pthread_mutex_t g_hooks_lock = PTHREAD_MUTEX_INITIALIZER;

static host_hooks *hooks_find(int id) {
    for (int i = 0; i < HOST_HOOKS_CAP; i++) {
        if (g_hook_used[i] && g_hook_ids[i] == id)
            return &g_hooks[i];
    }
    return NULL;
}
static host_hooks *hooks_alloc(int id) {
    host_hooks *existing = hooks_find(id);
    if (existing)
        return existing;
    for (int i = 0; i < HOST_HOOKS_CAP; i++) {
        if (!g_hook_used[i]) {
            g_hook_used[i] = 1;
            g_hook_ids[i] = id;
            memset(&g_hooks[i], 0, sizeof(g_hooks[i]));
            return &g_hooks[i];
        }
    }
    return NULL;
}
static void hooks_clear(JNIEnv *e, int id) {
    pthread_mutex_lock(&g_hooks_lock);
    for (int i = 0; i < HOST_HOOKS_CAP; i++) {
        if (!g_hook_used[i] || g_hook_ids[i] != id)
            continue;
        if (g_hooks[i].log)
            (*e)->DeleteGlobalRef(e, g_hooks[i].log);
        if (g_hooks[i].event)
            (*e)->DeleteGlobalRef(e, g_hooks[i].event);
        memset(&g_hooks[i], 0, sizeof(g_hooks[i]));
        g_hook_ids[i] = 0;
        g_hook_used[i] = 0;
        break;
    }
    pthread_mutex_unlock(&g_hooks_lock);
}

static JNIEnv *hooks_env(host_hooks *h, bool *attached) {
    JNIEnv *env = NULL;
    *attached = false;
    if ((*h->vm)->GetEnv(h->vm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
#if defined(__ANDROID__)
        if ((*h->vm)->AttachCurrentThread(h->vm, &env, NULL) != JNI_OK)
#else
        if ((*h->vm)->AttachCurrentThread(h->vm, (void **)&env, NULL) != JNI_OK)
#endif
            return NULL;
        *attached = true;
    }
    return env;
}

static void jni_log_handler(int instance_id, jsbay_log_level_t level, const char *message,
                            void *user_data) {
    host_hooks *h = user_data;
    if (!h || !h->log || !h->log_mid)
        return;
    bool attached = false;
    JNIEnv *e = hooks_env(h, &attached);
    if (!e)
        return;
    jstring msg = (*e)->NewStringUTF(e, message ? message : "");
    (*e)->CallVoidMethod(e, h->log, h->log_mid, (jint)instance_id, (jint)level, msg);
    if ((*e)->ExceptionCheck(e))
        (*e)->ExceptionClear(e);
    if (msg)
        (*e)->DeleteLocalRef(e, msg);
    if (attached)
        (*h->vm)->DetachCurrentThread(h->vm);
}

static void jni_event_handler(const jsbay_engine_event_t *event, void *user_data) {
    host_hooks *h = user_data;
    if (!h || !h->event || !h->event_mid || !event)
        return;
    bool attached = false;
    JNIEnv *e = hooks_env(h, &attached);
    if (!e)
        return;
    jstring msg = event->message ? (*e)->NewStringUTF(e, event->message) : NULL;
    (*e)->CallVoidMethod(e, h->event, h->event_mid, (jint)event->kind, (jint)event->instance_id,
                         (jint)event->status, (jlong)event->detail, msg);
    if ((*e)->ExceptionCheck(e))
        (*e)->ExceptionClear(e);
    if (msg)
        (*e)->DeleteLocalRef(e, msg);
    if (attached)
        (*h->vm)->DetachCurrentThread(h->vm);
}

static jboolean install_event_handler(JNIEnv *e, host_hooks *h, jint id, jobject eventHandler) {
    if (h->event) {
        (*e)->DeleteGlobalRef(e, h->event);
        h->event = NULL;
        h->event_mid = NULL;
    }
    if (!eventHandler) {
        return jsbay_engine_set_event_handler(id, NULL, NULL);
    }
    jclass cls = (*e)->GetObjectClass(e, eventHandler);
    h->event_mid = cls ? (*e)->GetMethodID(e, cls, "onEvent", "(IIIJLjava/lang/String;)V") : NULL;
    if (cls)
        (*e)->DeleteLocalRef(e, cls);
    if (!h->event_mid)
        return JNI_FALSE;
    h->event = (*e)->NewGlobalRef(e, eventHandler);
    if (!h->event)
        return JNI_FALSE;
    return jsbay_engine_set_event_handler(id, jni_event_handler, h);
}

static jboolean create(JNIEnv *e, jclass c, jint id) {
    (void)e;
    (void)c;
    return jsbay_engine_create(id, NULL, NULL);
}
static bool fill_limits(jsbay_resource_limits_t *out, jlong max_timers, jlong max_tsfn_handles,
                        jlong max_pending_calls, jlong max_pending_bytes, jlong max_pending_tasks) {
    if (max_timers < 0 || max_tsfn_handles < 0 || max_pending_calls < 0 || max_pending_bytes < 0 ||
        max_pending_tasks < 0)
        return false;
    *out = (jsbay_resource_limits_t){
        .struct_size = sizeof(*out),
        .max_timers = (size_t)max_timers,
        .max_tsfn_handles = (size_t)max_tsfn_handles,
        .max_pending_calls = (size_t)max_pending_calls,
        .max_pending_bytes = (size_t)max_pending_bytes,
        .max_pending_tasks = (size_t)max_pending_tasks,
    };
    return true;
}
static jboolean create_with_limits(JNIEnv *e, jclass c, jint id, jlong max_timers,
                                   jlong max_tsfn_handles, jlong max_pending_calls,
                                   jlong max_pending_bytes, jlong max_pending_tasks) {
    (void)e;
    (void)c;
    jsbay_resource_limits_t limits;
    if (!fill_limits(&limits, max_timers, max_tsfn_handles, max_pending_calls, max_pending_bytes,
                     max_pending_tasks))
        return JNI_FALSE;
    return jsbay_engine_create_with_limits(id, NULL, NULL, &limits);
}
static jboolean set_resource_limits(JNIEnv *e, jclass c, jint id, jlong max_timers,
                                    jlong max_tsfn_handles, jlong max_pending_calls,
                                    jlong max_pending_bytes, jlong max_pending_tasks) {
    (void)e;
    (void)c;
    jsbay_resource_limits_t limits;
    if (!fill_limits(&limits, max_timers, max_tsfn_handles, max_pending_calls, max_pending_bytes,
                     max_pending_tasks))
        return JNI_FALSE;
    return jsbay_engine_set_resource_limits(id, &limits);
}
static jlongArray pack_longs(JNIEnv *e, const jlong *values, jsize n) {
    jlongArray out = (*e)->NewLongArray(e, n);
    if (!out)
        return NULL;
    (*e)->SetLongArrayRegion(e, out, 0, n, values);
    return out;
}
static jlongArray resource_usage(JNIEnv *e, jclass c, jint id) {
    (void)c;
    jsbay_resource_usage_t usage = {.struct_size = sizeof(usage)};
    if (!jsbay_engine_get_resource_usage(id, &usage))
        return NULL;
    jlong values[] = {(jlong)usage.timers,
                      (jlong)usage.tsfn_handles,
                      (jlong)usage.pending_calls,
                      (jlong)usage.native_tasks,
                      (jlong)usage.script_tasks,
                      (jlong)usage.pending_bytes,
                      (jlong)usage.max_timers,
                      (jlong)usage.max_tsfn_handles,
                      (jlong)usage.max_pending_calls,
                      (jlong)usage.max_pending_bytes,
                      (jlong)usage.max_pending_tasks};
    return pack_longs(e, values, (jsize)(sizeof(values) / sizeof(values[0])));
}
static jlongArray global_resource_usage(JNIEnv *e, jclass c) {
    (void)c;
    jsbay_resource_global_usage_t usage = {.struct_size = sizeof(usage)};
    if (!jsbay_resource_global_usage(&usage))
        return NULL;
    jlong values[] = {(jlong)usage.timers,
                      (jlong)usage.tsfn_handles,
                      (jlong)usage.pending_calls,
                      (jlong)usage.native_tasks,
                      (jlong)usage.script_tasks,
                      (jlong)usage.pending_bytes,
                      (jlong)usage.max_timers,
                      (jlong)usage.max_tsfn_handles,
                      (jlong)usage.max_pending_calls,
                      (jlong)usage.max_native_tasks,
                      (jlong)usage.max_script_tasks,
                      (jlong)usage.max_pending_bytes,
                      (jlong)usage.fg_headroom_timers,
                      (jlong)usage.fg_headroom_tsfn_handles,
                      (jlong)usage.fg_headroom_pending_calls,
                      (jlong)usage.fg_headroom_native_tasks,
                      (jlong)usage.fg_headroom_script_tasks,
                      (jlong)usage.fg_headroom_pending_bytes,
                      (jlong)usage.bg_effective_max_timers,
                      (jlong)usage.bg_effective_max_tsfn_handles,
                      (jlong)usage.bg_effective_max_pending_calls,
                      (jlong)usage.bg_effective_max_native_tasks,
                      (jlong)usage.bg_effective_max_script_tasks,
                      (jlong)usage.bg_effective_max_pending_bytes};
    return pack_longs(e, values, (jsize)(sizeof(values) / sizeof(values[0])));
}
static jboolean create_with_handlers(JNIEnv *e, jclass c, jint id, jobject logHandler,
                                     jobject eventHandler) {
    (void)c;
    JavaVM *vm = NULL;
    if ((*e)->GetJavaVM(e, &vm) != JNI_OK)
        return JNI_FALSE;
    pthread_mutex_lock(&g_hooks_lock);
    host_hooks *h = hooks_alloc(id);
    if (!h) {
        pthread_mutex_unlock(&g_hooks_lock);
        return JNI_FALSE;
    }
    h->vm = vm;
    jsbay_log_handler_t log_cb = NULL;
    void *log_ud = NULL;
    if (logHandler) {
        jclass cls = (*e)->GetObjectClass(e, logHandler);
        h->log_mid = cls ? (*e)->GetMethodID(e, cls, "onLog", "(IILjava/lang/String;)V") : NULL;
        if (cls)
            (*e)->DeleteLocalRef(e, cls);
        if (!h->log_mid) {
            pthread_mutex_unlock(&g_hooks_lock);
            hooks_clear(e, id);
            return JNI_FALSE;
        }
        h->log = (*e)->NewGlobalRef(e, logHandler);
        if (!h->log) {
            pthread_mutex_unlock(&g_hooks_lock);
            hooks_clear(e, id);
            return JNI_FALSE;
        }
        log_cb = jni_log_handler;
        log_ud = h;
    }
    pthread_mutex_unlock(&g_hooks_lock);
    if (!jsbay_engine_create(id, log_cb, log_ud)) {
        hooks_clear(e, id);
        return JNI_FALSE;
    }
    if (eventHandler) {
        pthread_mutex_lock(&g_hooks_lock);
        h = hooks_find(id);
        jboolean ok = h ? install_event_handler(e, h, id, eventHandler) : JNI_FALSE;
        pthread_mutex_unlock(&g_hooks_lock);
        if (!ok) {
            jsbay_engine_destroy(id);
            hooks_clear(e, id);
            return JNI_FALSE;
        }
    }
    return JNI_TRUE;
}
static void destroy(JNIEnv *e, jclass c, jint id) {
    (void)c;
    jsbay_engine_destroy(id);
    hooks_clear(e, id);
}
static jboolean set_event_handler(JNIEnv *e, jclass c, jint id, jobject eventHandler) {
    (void)c;
    JavaVM *vm = NULL;
    if ((*e)->GetJavaVM(e, &vm) != JNI_OK)
        return JNI_FALSE;
    pthread_mutex_lock(&g_hooks_lock);
    host_hooks *h = hooks_find(id);
    if (!h) {
        h = hooks_alloc(id);
        if (!h) {
            pthread_mutex_unlock(&g_hooks_lock);
            return JNI_FALSE;
        }
        h->vm = vm;
    }
    jboolean ok = install_event_handler(e, h, id, eventHandler);
    pthread_mutex_unlock(&g_hooks_lock);
    return ok;
}
static jlongArray get_memory_usage(JNIEnv *e, jclass c, jint id) {
    (void)c;
    jsbay_memory_usage_t u;
    memset(&u, 0, sizeof(u));
    u.struct_size = (uint32_t)sizeof(u);
    if (!jsbay_engine_get_memory_usage(id, &u))
        return NULL;
    jlong vals[10] = {(jlong)u.malloc_count,      (jlong)u.malloc_size,      (jlong)u.malloc_limit,
                      (jlong)u.memory_used_count, (jlong)u.memory_used_size, (jlong)u.atom_count,
                      (jlong)u.atom_size,         (jlong)u.obj_count,        (jlong)u.obj_size,
                      (jlong)u.shape_count};
    jlongArray out = (*e)->NewLongArray(e, 10);
    if (out)
        (*e)->SetLongArrayRegion(e, out, 0, 10, vals);
    return out;
}
static jboolean run_gc(JNIEnv *e, jclass c, jint id) {
    (void)e;
    (void)c;
    return jsbay_engine_run_gc(id);
}
static jboolean ri(JNIEnv *e, jclass c, jint id) {
    (void)e;
    (void)c;
    return jsbay_engine_request_interrupt(id);
}
static jboolean ci(JNIEnv *e, jclass c, jint id) {
    (void)e;
    (void)c;
    return jsbay_engine_clear_interrupt(id);
}
static jboolean limit(JNIEnv *e, jclass c, jint id, jlong n) {
    (void)e;
    (void)c;
    return n >= 0 && jsbay_engine_set_execution_time_limit(id, (uint64_t)n);
}
static jboolean mem(JNIEnv *e, jclass c, jint id, jlong n) {
    (void)e;
    (void)c;
    return n >= 0 && jsbay_engine_set_memory_limit(id, (uint64_t)n);
}
typedef struct {
    JavaVM *vm;
    jobject driver;
    jmethodID schedule, cancel, shutdown;
    pthread_mutex_t lock;
    bool active;
    uint64_t generation;
    jsbay_loop_task_t task;
    void *task_data;
} loop_binding;
static loop_binding *loop_binding_freelist;
static atomic_flag loop_binding_freelist_lock = ATOMIC_FLAG_INIT;
static void loop_binding_freelist_acquire(void) {
    while (atomic_flag_test_and_set_explicit(&loop_binding_freelist_lock, memory_order_acquire)) {
    }
}
static void loop_binding_freelist_release_lock(void) {
    atomic_flag_clear_explicit(&loop_binding_freelist_lock, memory_order_release);
}
static loop_binding *loop_binding_alloc(void) {
    return calloc(1, sizeof(loop_binding));
}
static loop_binding *loop_binding_take(void) {
    loop_binding_freelist_acquire();
    loop_binding *binding = loop_binding_freelist;
    if (binding)
        loop_binding_freelist = *(loop_binding **)binding;
    loop_binding_freelist_release_lock();
    if (binding) {
        memset(binding, 0, sizeof(*binding));
        return binding;
    }
    return loop_binding_alloc();
}
static void loop_binding_release(loop_binding *binding) {
    if (!binding)
        return;
    loop_binding_freelist_acquire();
    *(loop_binding **)binding = loop_binding_freelist;
    loop_binding_freelist = binding;
    loop_binding_freelist_release_lock();
}
static JNIEnv *loop_env(loop_binding *binding, bool *attached) {
    JNIEnv *env = NULL;
    *attached = false;
    if ((*binding->vm)->GetEnv(binding->vm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
#if defined(__ANDROID__)
        if ((*binding->vm)->AttachCurrentThread(binding->vm, &env, NULL) != JNI_OK)
#else
        if ((*binding->vm)->AttachCurrentThread(binding->vm, (void **)&env, NULL) != JNI_OK)
#endif
            return NULL;
        *attached = true;
    }
    return env;
}
static bool loop_schedule(void *data, uint64_t delay, jsbay_loop_task_t task, void *task_data) {
    loop_binding *binding = data;
    if (!binding || delay > INT64_MAX)
        return false;
    pthread_mutex_lock(&binding->lock);
    if (!binding->active) {
        pthread_mutex_unlock(&binding->lock);
        return false;
    }
    binding->task = task;
    binding->task_data = task_data;
    uint64_t generation = ++binding->generation;
    pthread_mutex_unlock(&binding->lock);
    bool attached;
    JNIEnv *env = loop_env(binding, &attached);
    if (!env)
        return false;
    jboolean scheduled = (*env)->CallBooleanMethod(env, binding->driver, binding->schedule,
                                                   (jlong)delay, (jlong)generation);
    bool ok = !(*env)->ExceptionCheck(env) && scheduled;
    if ((*env)->ExceptionCheck(env))
        (*env)->ExceptionClear(env);
    if (attached)
        (*binding->vm)->DetachCurrentThread(binding->vm);
    return ok;
}
/* Soft cancel: drop the pending callback and bump generation. Binding stays active so suspend/resume can schedule again. Hard teardown is loop_shutdown, used only from detach_loop. */
static void loop_cancel(void *data) {
    loop_binding *binding = data;
    if (!binding)
        return;
    pthread_mutex_lock(&binding->lock);
    if (!binding->active) {
        pthread_mutex_unlock(&binding->lock);
        return;
    }
    ++binding->generation;
    binding->task = NULL;
    binding->task_data = NULL;
    pthread_mutex_unlock(&binding->lock);
    bool attached;
    JNIEnv *env = loop_env(binding, &attached);
    if (!env)
        return;
    (*env)->CallVoidMethod(env, binding->driver, binding->cancel);
    if ((*env)->ExceptionCheck(env))
        (*env)->ExceptionClear(env);
    if (attached)
        (*binding->vm)->DetachCurrentThread(binding->vm);
}
static void loop_shutdown(JNIEnv *env, loop_binding *binding) {
    if (!binding)
        return;
    pthread_mutex_lock(&binding->lock);
    binding->active = false;
    ++binding->generation;
    binding->task = NULL;
    binding->task_data = NULL;
    pthread_mutex_unlock(&binding->lock);
    if (!env || !binding->driver || !binding->shutdown)
        return;
    (*env)->CallVoidMethod(env, binding->driver, binding->shutdown);
    if ((*env)->ExceptionCheck(env))
        (*env)->ExceptionClear(env);
}
static jlong attach_loop(JNIEnv *env, jclass c, jint id) {
    (void)c;
    JavaVM *vm = NULL;
    loop_binding *binding = loop_binding_take();
    if (!binding || (*env)->GetJavaVM(env, &vm) != JNI_OK) {
        loop_binding_release(binding);
        return 0;
    }
    binding->vm = vm;
    binding->active = true;
    pthread_mutex_init(&binding->lock, NULL);
    jclass cls = (*env)->FindClass(env, "io/jsbay/LoopDriver");
    jmethodID init = cls ? (*env)->GetMethodID(env, cls, "<init>", "(JI)V") : NULL;
    binding->schedule = cls ? (*env)->GetMethodID(env, cls, "schedule", "(JJ)Z") : NULL;
    binding->cancel = cls ? (*env)->GetMethodID(env, cls, "cancel", "()V") : NULL;
    binding->shutdown = cls ? (*env)->GetMethodID(env, cls, "shutdown", "()V") : NULL;
    jobject local = init ? (*env)->NewObject(env, cls, init, (jlong)(intptr_t)binding, id) : NULL;
    if (cls)
        (*env)->DeleteLocalRef(env, cls);
    if (!local || !binding->schedule || !binding->cancel || !binding->shutdown ||
        (*env)->ExceptionCheck(env)) {
        if ((*env)->ExceptionCheck(env))
            (*env)->ExceptionClear(env);
        pthread_mutex_destroy(&binding->lock);
        loop_binding_release(binding);
        return 0;
    }
    binding->driver = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!binding->driver ||
        jsbay_engine_attach_loop(id, loop_schedule, loop_cancel, binding) != JSBAY_OK) {
        if (binding->driver) {
            loop_shutdown(env, binding);
            (*env)->DeleteGlobalRef(env, binding->driver);
        }
        pthread_mutex_destroy(&binding->lock);
        loop_binding_release(binding);
        return 0;
    }
    return (jlong)(intptr_t)binding;
}
static jint detach_loop(JNIEnv *env, jclass c, jint id, jlong raw) {
    (void)c;
    loop_binding *binding = (loop_binding *)(intptr_t)raw;
    jsbay_status_t status = jsbay_engine_detach_loop(id);
    if (status != JSBAY_OK)
        return status;
    if (binding) {
        loop_shutdown(env, binding);
        (*env)->DeleteGlobalRef(env, binding->driver);
        pthread_mutex_destroy(&binding->lock);
        loop_binding_release(binding);
    }
    return status;
}
static jint loop_status(JNIEnv *env, jclass c, jint id) {
    (void)env;
    (void)c;
    return jsbay_engine_loop_status(id);
}
static jint run_loop(JNIEnv *env, jclass c, jint id) {
    (void)env;
    (void)c;
    return jsbay_engine_run_loop(id);
}
static jboolean stop_loop(JNIEnv *env, jclass c, jint id) {
    (void)env;
    (void)c;
    return jsbay_engine_stop_loop(id);
}
static jboolean suspend_loop(JNIEnv *env, jclass c, jint id) {
    (void)env;
    (void)c;
    return jsbay_engine_suspend(id);
}
static jboolean resume_loop(JNIEnv *env, jclass c, jint id) {
    (void)env;
    (void)c;
    return jsbay_engine_resume(id);
}
static jboolean is_suspended(JNIEnv *env, jclass c, jint id) {
    (void)env;
    (void)c;
    return jsbay_engine_is_suspended(id);
}
static jboolean set_admission_class(JNIEnv *env, jclass c, jint id, jint cls) {
    (void)env;
    (void)c;
    return jsbay_engine_set_admission_class(id, (jsbay_admission_class_t)cls);
}
static jint get_admission_class(JNIEnv *env, jclass c, jint id) {
    (void)env;
    (void)c;
    jsbay_admission_class_t cls = JSBAY_ADMISSION_FOREGROUND;
    if (!jsbay_engine_get_admission_class(id, &cls))
        return -1;
    return (jint)cls;
}
static void run_loop_task(JNIEnv *env, jclass c, jlong raw, jlong expected) {
    (void)env;
    (void)c;
    loop_binding *binding = (loop_binding *)(intptr_t)raw;
    if (!binding)
        return;
    pthread_mutex_lock(&binding->lock);
    if (!binding->active || binding->generation != (uint64_t)expected || !binding->task) {
        pthread_mutex_unlock(&binding->lock);
        return;
    }
    jsbay_loop_task_t task = binding->task;
    void *task_data = binding->task_data;
    binding->task = NULL;
    binding->task_data = NULL;
    pthread_mutex_unlock(&binding->lock);
    task(task_data);
}
static jlongArray eval(JNIEnv *e, jclass c, jint id, jbyteArray src, jstring name, jstring dir,
                       jstring ver) {
    (void)c;
    jsbay_value_t v = 0, x = 0;
    jbyte *p = src ? (*e)->GetByteArrayElements(e, src, NULL) : NULL;
    jsize z = src ? (*e)->GetArrayLength(e, src) : 0;
    jbyteArray h, dh, vh;
    jsbay_utf8_t f = utf(e, name, &h), d = utf(e, dir, &dh), q = utf(e, ver, &vh);
    bool hit = false;
    jsbay_engine_evaluate_options_t o = {sizeof(o), d, q, &hit};
    const jsbay_engine_evaluate_options_t *op = (dir || ver) ? &o : NULL;
    jsbay_status_t s =
        jsbay_engine_evaluate(id, (jsbay_utf8_t){(const uint8_t *)p, (size_t)z}, f, op, &v, &x);
    if (p)
        (*e)->ReleaseByteArrayElements(e, src, p, JNI_ABORT);
    done(e, h, f);
    done(e, dh, d);
    done(e, vh, q);
    jlongArray r = result(e, s, v, x);
    if (r) {
        jlong k = hit;
        (*e)->SetLongArrayRegion(e, r, 3, 1, &k);
    }
    return r;
}
static void raise_jsbay(JNIEnv *e, jobject engine, jsbay_status_t status, uint64_t exception);
static jlongArray retain(JNIEnv *e, jclass c, jlong v) {
    (void)c;
    uint64_t o = 0;
    jsbay_status_t status = jsbay_value_retain(v, &o);
    return result(e, status, o, 0);
}
static void release(JNIEnv *e, jclass c, jobject engine, jlong v) {
    (void)c;
    jsbay_status_t s = jsbay_value_release(v);
    if (s != JSBAY_OK)
        raise_jsbay(e, engine, s, 0);
}
static jint type(JNIEnv *e, jclass c, jobject engine, jlong v) {
    (void)c;
    jsbay_value_kind_t k = 0;
    jsbay_status_t s = jsbay_value_type(v, &k);
    if (s != JSBAY_OK) {
        raise_jsbay(e, engine, s, 0);
        return -1;
    }
    return (jint)k;
}
static void raise_jsbay(JNIEnv *e, jobject engine, jsbay_status_t status, uint64_t exception) {
    jclass c = (*e)->FindClass(e, "io/jsbay/Engine");
    jmethodID m =
        c ? (*e)->GetStaticMethodID(e, c, "raiseForNative", "(Lio/jsbay/Engine;IJ)V") : NULL;
    if (m)
        (*e)->CallStaticVoidMethod(e, c, m, engine, (jint)status, (jlong)exception);
    if (c)
        (*e)->DeleteLocalRef(e, c);
}
static jdouble number(JNIEnv *e, jclass c, jobject engine, jlong v) {
    (void)c;
    double n = 0;
    jsbay_status_t s = jsbay_value_to_number(v, &n);
    if (s != JSBAY_OK)
        raise_jsbay(e, engine, s, 0);
    return n;
}
static jboolean boolean(JNIEnv *e, jclass c, jobject engine, jlong v) {
    (void)c;
    bool b = false;
    jsbay_status_t s = jsbay_value_to_bool(v, &b);
    if (s != JSBAY_OK)
        raise_jsbay(e, engine, s, 0);
    return b;
}
static jstring text(JNIEnv *e, jobject engine, jlong v, int json) {
    jsbay_bytes_t b = {0};
    jsbay_value_t x = 0;
    jsbay_status_t s = json ? jsbay_value_to_json(v, &b, &x) : jsbay_value_to_utf8(v, &b, &x);
    if (s != JSBAY_OK) {
        raise_jsbay(e, engine, s, x);
        return NULL;
    }
    jbyteArray a = (*e)->NewByteArray(e, (jsize)b.len);
    if (a && b.len)
        (*e)->SetByteArrayRegion(e, a, 0, (jsize)b.len, (jbyte *)b.data);
    jclass c = (*e)->FindClass(e, "java/lang/String");
    jmethodID m = (*e)->GetMethodID(e, c, "<init>", "([BLjava/lang/String;)V");
    jstring n = (*e)->NewStringUTF(e, "UTF-8");
    jstring r = a ? (jstring)(*e)->NewObject(e, c, m, a, n) : NULL;
    if (a)
        (*e)->DeleteLocalRef(e, a);
    (*e)->DeleteLocalRef(e, n);
    (*e)->DeleteLocalRef(e, c);
    jsbay_free_bytes(b);
    return r;
}
static jstring to_utf8(JNIEnv *e, jclass c, jobject engine, jlong v) {
    (void)c;
    return text(e, engine, v, 0);
}
static jstring to_json(JNIEnv *e, jclass c, jobject engine, jlong v) {
    (void)c;
    return text(e, engine, v, 1);
}
static jlongArray get(JNIEnv *e, jclass c, jlong v, jstring key) {
    (void)c;
    jbyteArray h;
    jsbay_utf8_t k = utf(e, key, &h);
    uint64_t o = 0, x = 0;
    int s = jsbay_value_get(v, k, &o, &x);
    done(e, h, k);
    return result(e, s, o, x);
}
static void set(JNIEnv *e, jclass c, jobject engine, jlong o, jstring key, jlong v) {
    (void)c;
    jbyteArray h;
    jsbay_utf8_t k = utf(e, key, &h);
    uint64_t x = 0;
    jsbay_status_t s = jsbay_value_set(o, k, v, &x);
    done(e, h, k);
    if (s != JSBAY_OK)
        raise_jsbay(e, engine, s, x);
}
static jlongArray call(JNIEnv *e, jclass c, jlong f, jlong t, jlongArray args) {
    (void)c;
    jsize n = args ? (*e)->GetArrayLength(e, args) : 0;
    jlong *p = n ? (*e)->GetLongArrayElements(e, args, NULL) : NULL;
    uint64_t o = 0, x = 0;
    int s = jsbay_value_call(f, t, (const uint64_t *)p, n, &o, &x);
    if (p)
        (*e)->ReleaseLongArrayElements(e, args, p, JNI_ABORT);
    return result(e, s, o, x);
}
static jlongArray construct(JNIEnv *e, jclass c, jlong f, jlongArray args) {
    (void)c;
    jsize n = args ? (*e)->GetArrayLength(e, args) : 0;
    jlong *p = n ? (*e)->GetLongArrayElements(e, args, NULL) : NULL;
    uint64_t o = 0, x = 0;
    int s = jsbay_value_construct(f, (const uint64_t *)p, n, &o, &x);
    if (p)
        (*e)->ReleaseLongArrayElements(e, args, p, JNI_ABORT);
    return result(e, s, o, x);
}
/* The boolean outcome travels in the value slot so Engine.flag reads it like Engine.wrap reads a handle. */
static jlongArray has(JNIEnv *e, jclass c, jlong v, jstring key) {
    (void)c;
    jbyteArray h;
    jsbay_utf8_t k = utf(e, key, &h);
    bool b = false;
    uint64_t x = 0;
    int s = jsbay_value_has(v, k, &b, &x);
    done(e, h, k);
    return result(e, s, b, x);
}
static jlongArray delete_property(JNIEnv *e, jclass c, jlong v, jstring key) {
    (void)c;
    jbyteArray h;
    jsbay_utf8_t k = utf(e, key, &h);
    bool b = false;
    uint64_t x = 0;
    int s = jsbay_value_delete(v, k, &b, &x);
    done(e, h, k);
    return result(e, s, b, x);
}
static jlongArray keys(JNIEnv *e, jclass c, jlong v) {
    (void)c;
    uint64_t o = 0, x = 0;
    int s = jsbay_value_keys(v, &o, &x);
    return result(e, s, o, x);
}
static jlongArray instance_of(JNIEnv *e, jclass c, jlong v, jlong constructor) {
    (void)c;
    bool b = false;
    uint64_t x = 0;
    int s = jsbay_value_instance_of(v, constructor, &b, &x);
    return result(e, s, b, x);
}
static jlongArray undefined(JNIEnv *e, jclass c, jint id) {
    (void)c;
    uint64_t o = 0;
    jsbay_status_t status = jsbay_value_undefined(id, &o);
    return result(e, status, o, 0);
}
static jlongArray global(JNIEnv *e, jclass c, jint id) {
    (void)c;
    uint64_t o = 0;
    jsbay_status_t status = jsbay_engine_global(id, &o);
    return result(e, status, o, 0);
}
static jlongArray null_value(JNIEnv *e, jclass c, jint id) {
    (void)c;
    uint64_t o = 0;
    jsbay_status_t status = jsbay_value_null(id, &o);
    return result(e, status, o, 0);
}
static jlongArray new_bool(JNIEnv *e, jclass c, jint id, jboolean value) {
    (void)c;
    uint64_t o = 0;
    jsbay_status_t status = jsbay_value_new_bool(id, value, &o);
    return result(e, status, o, 0);
}
static jlongArray new_number(JNIEnv *e, jclass c, jint id, jdouble value) {
    (void)c;
    uint64_t o = 0;
    jsbay_status_t status = jsbay_value_new_number(id, value, &o);
    return result(e, status, o, 0);
}
static jlongArray string_constructor(JNIEnv *e, jint id, jstring text, int which) {
    jbyteArray h;
    jsbay_utf8_t s = utf(e, text, &h);
    uint64_t o = 0, x = 0;
    jsbay_status_t status = which == 0   ? jsbay_value_new_string(id, s, &o)
                            : which == 1 ? jsbay_value_new_json(id, s, &o, &x)
                                         : jsbay_value_new_error(id, s, &o);
    done(e, h, s);
    return result(e, status, o, x);
}
static jlongArray new_string(JNIEnv *e, jclass c, jint id, jstring text) {
    (void)c;
    return string_constructor(e, id, text, 0);
}
static jlongArray new_json(JNIEnv *e, jclass c, jint id, jstring text) {
    (void)c;
    return string_constructor(e, id, text, 1);
}
static jlongArray new_error(JNIEnv *e, jclass c, jint id, jstring text) {
    (void)c;
    return string_constructor(e, id, text, 2);
}
static jlongArray new_object(JNIEnv *e, jclass c, jint id) {
    (void)c;
    uint64_t o = 0;
    jsbay_status_t status = jsbay_value_new_object(id, &o);
    return result(e, status, o, 0);
}
static jlongArray new_array(JNIEnv *e, jclass c, jint id) {
    (void)c;
    uint64_t o = 0;
    jsbay_status_t status = jsbay_value_new_array(id, &o);
    return result(e, status, o, 0);
}
static jlongArray new_array_buffer(JNIEnv *e, jclass c, jint id, jbyteArray data) {
    (void)c;
    jsize n = data ? (*e)->GetArrayLength(e, data) : 0;
    jbyte *p = n ? (*e)->GetByteArrayElements(e, data, NULL) : NULL;
    uint64_t o = 0;
    jsbay_status_t s = jsbay_value_new_array_buffer(id, (const uint8_t *)p, (size_t)n, &o);
    if (p)
        (*e)->ReleaseByteArrayElements(e, data, p, JNI_ABORT);
    return result(e, s, o, 0);
}
static jbyteArray copy_buffer(JNIEnv *e, jclass c, jobject engine, jlong value) {
    (void)c;
    jsbay_bytes_t bytes = {0};
    uint64_t exception = 0;
    jsbay_status_t s = jsbay_value_copy_buffer(value, &bytes, &exception);
    if (s != JSBAY_OK) {
        raise_jsbay(e, engine, s, exception);
        return NULL;
    }
    jbyteArray out = (*e)->NewByteArray(e, (jsize)bytes.len);
    if (out && bytes.len)
        (*e)->SetByteArrayRegion(e, out, 0, (jsize)bytes.len, (const jbyte *)bytes.data);
    jsbay_free_bytes(bytes);
    return out;
}
typedef struct {
    JavaVM *vm;
    jobject callback;
    jobject engine;
} binding_t;
static binding_t *binding_freelist;
static atomic_flag binding_freelist_lock = ATOMIC_FLAG_INIT;
static void binding_freelist_acquire(void) {
    while (atomic_flag_test_and_set_explicit(&binding_freelist_lock, memory_order_acquire)) {
    }
}
static void binding_freelist_release_lock(void) {
    atomic_flag_clear_explicit(&binding_freelist_lock, memory_order_release);
}
static binding_t *binding_alloc(void) {
    return calloc(1, sizeof(binding_t));
}
static binding_t *binding_take(void) {
    binding_freelist_acquire();
    binding_t *binding = binding_freelist;
    if (binding)
        binding_freelist = *(binding_t **)binding;
    binding_freelist_release_lock();
    if (binding) {
        memset(binding, 0, sizeof(*binding));
        return binding;
    }
    return binding_alloc();
}
static void binding_release(binding_t *binding) {
    if (!binding)
        return;
    binding_freelist_acquire();
    *(binding_t **)binding = binding_freelist;
    binding_freelist = binding;
    binding_freelist_release_lock();
}
static jsbay_status_t callback_error(int id, const char *message, jsbay_value_t *out_exception) {
    *out_exception = 0;
    jsbay_status_t status = jsbay_value_new_error(
        id, (jsbay_utf8_t){(const uint8_t *)message, strlen(message)}, out_exception);
    return status == JSBAY_OK ? JSBAY_EXCEPTION : status;
}
static void callback_discard_outputs(jsbay_value_t *out_value, jsbay_value_t *out_exception) {
    if (*out_value)
        (void)jsbay_value_release(*out_value);
    if (*out_exception)
        (void)jsbay_value_release(*out_exception);
    *out_value = 0;
    *out_exception = 0;
}
static int jni_failed(JNIEnv *e) {
    if (!(*e)->ExceptionCheck(e))
        return 0;
    (*e)->ExceptionClear(e);
    return 1;
}
static jsbay_status_t callback_throwable_error(JNIEnv *e, int id, jobject throwable,
                                               jsbay_value_t *out_exception) {
    if (!throwable)
        return callback_error(id, "Java callback threw", out_exception);
    jclass c = (*e)->GetObjectClass(e, throwable);
    if (jni_failed(e) || !c) {
        if (c)
            (*e)->DeleteLocalRef(e, c);
        return callback_error(id, "Java callback threw", out_exception);
    }
    jmethodID text = (*e)->GetMethodID(e, c, "toString", "()Ljava/lang/String;");
    if (jni_failed(e) || !text) {
        (*e)->DeleteLocalRef(e, c);
        return callback_error(id, "Java callback threw", out_exception);
    }
    jstring message = (jstring)(*e)->CallObjectMethod(e, throwable, text);
    if (jni_failed(e) || !message) {
        if (message)
            (*e)->DeleteLocalRef(e, message);
        (*e)->DeleteLocalRef(e, c);
        return callback_error(id, "Java callback threw", out_exception);
    }
    jbyteArray hold = NULL;
    jsbay_utf8_t bytes = utf(e, message, &hold);
    if ((!bytes.data && bytes.len != 0) || jni_failed(e)) {
        done(e, hold, bytes);
        (*e)->DeleteLocalRef(e, message);
        (*e)->DeleteLocalRef(e, c);
        return callback_error(id, "Java callback threw", out_exception);
    }
    jsbay_status_t status = jsbay_value_new_error(id, bytes, out_exception);
    done(e, hold, bytes);
    (*e)->DeleteLocalRef(e, message);
    (*e)->DeleteLocalRef(e, c);
    return status == JSBAY_OK ? JSBAY_EXCEPTION : status;
}
static int same_engine(JNIEnv *e, jobject value, jobject engine) {
    if (!value || !engine)
        return 0;
    jclass c = (*e)->GetObjectClass(e, value);
    if (jni_failed(e) || !c) {
        if (c)
            (*e)->DeleteLocalRef(e, c);
        return 0;
    }
    jmethodID m = (*e)->GetMethodID(e, c, "callbackEngineForNative", "()Lio/jsbay/Engine;");
    if (jni_failed(e) || !m) {
        (*e)->DeleteLocalRef(e, c);
        return 0;
    }
    jobject actual = (*e)->CallObjectMethod(e, value, m);
    if (jni_failed(e)) {
        if (actual)
            (*e)->DeleteLocalRef(e, actual);
        (*e)->DeleteLocalRef(e, c);
        return 0;
    }
    int same = actual && (*e)->IsSameObject(e, actual, engine);
    if (actual)
        (*e)->DeleteLocalRef(e, actual);
    (*e)->DeleteLocalRef(e, c);
    return same;
}
#if defined(JSBAY_ANDROID_TEST_FAIL_STAGE)
static int jsbay_android_test_fault_remaining = 1;
#endif
static int test_fault(int stage) {
#if defined(JSBAY_ANDROID_TEST_FAIL_STAGE)
    if (JSBAY_ANDROID_TEST_FAIL_STAGE == stage && jsbay_android_test_fault_remaining) {
        jsbay_android_test_fault_remaining = 0;
        return 1;
    }
#else
    (void)stage;
#endif
    return 0;
}
static jsbay_status_t bridge(int id, void *raw, jsbay_value_t self, size_t argc,
                             const jsbay_value_t *args, jsbay_value_t *out_value,
                             jsbay_value_t *out_exception) {
    binding_t *binding = raw;
    JNIEnv *e = NULL;
    *out_value = 0;
    *out_exception = 0;
    if ((*binding->vm)->GetEnv(binding->vm, (void **)&e, JNI_VERSION_1_6) != JNI_OK)
        return JSBAY_WRONG_THREAD;
    jclass ec = NULL, listc = NULL, cc = NULL, xc = NULL, vc = NULL;
    jobject scope = NULL, returned = NULL, list = NULL, this_value = NULL, thrown = NULL,
            exception = NULL;
    jsbay_status_t status = JSBAY_EXCEPTION;
    jmethodID begin = NULL, end = NULL, borrowed = NULL;
    ec = (*e)->GetObjectClass(e, binding->engine);
    if (jni_failed(e) || !ec) {
        if (ec)
            (*e)->DeleteLocalRef(e, ec);
        return callback_error(id, "Android callback bridge is unavailable", out_exception);
    }
    begin = (*e)->GetMethodID(e, ec, "beginCallbackScopeForNative", "()Lio/jsbay/CallbackScope;");
    if (jni_failed(e) || !begin)
        goto unavailable;
    end = (*e)->GetMethodID(e, ec, "endCallbackScopeForNative", "(Lio/jsbay/CallbackScope;)V");
    if (jni_failed(e) || !end)
        goto unavailable;
    borrowed = (*e)->GetMethodID(e, ec, "borrowedForNative", "(J)Lio/jsbay/Value;");
    if (jni_failed(e) || !borrowed)
        goto unavailable;
    scope = (*e)->CallObjectMethod(e, binding->engine, begin);
    if (jni_failed(e) || !scope) {
        if (scope)
            (*e)->DeleteLocalRef(e, scope);
        goto unavailable;
    }
    if (test_fault(1))
        goto construction_failed;
    listc = (*e)->FindClass(e, "java/util/ArrayList");
    if (jni_failed(e) || !listc)
        goto construction_failed;
    jmethodID init = (*e)->GetMethodID(e, listc, "<init>", "(I)V");
    if (jni_failed(e) || !init)
        goto construction_failed;
    jmethodID add = (*e)->GetMethodID(e, listc, "add", "(Ljava/lang/Object;)Z");
    if (jni_failed(e) || !add)
        goto construction_failed;
    if (test_fault(3))
        goto construction_failed;
    list = (*e)->NewObject(e, listc, init, (jint)argc);
    if (jni_failed(e) || !list)
        goto construction_failed;
    this_value = (*e)->CallObjectMethod(e, binding->engine, borrowed, (jlong)self);
    if (jni_failed(e) || !this_value)
        goto construction_failed;
    for (size_t i = 0; i < argc; i++) {
        jobject value = (*e)->CallObjectMethod(e, binding->engine, borrowed, (jlong)args[i]);
        if (jni_failed(e) || !value) {
            if (value)
                (*e)->DeleteLocalRef(e, value);
            goto construction_failed;
        }
        (*e)->CallBooleanMethod(e, list, add, value);
        if (jni_failed(e)) {
            (*e)->DeleteLocalRef(e, value);
            goto construction_failed;
        }
        (*e)->DeleteLocalRef(e, value);
    }
    if (test_fault(2))
        goto construction_failed;
    cc = (*e)->GetObjectClass(e, binding->callback);
    if (jni_failed(e) || !cc)
        goto construction_failed;
    jmethodID invoke =
        (*e)->GetMethodID(e, cc, "invoke", "(Lio/jsbay/Value;Ljava/util/List;)Lio/jsbay/Value;");
    if (jni_failed(e) || !invoke)
        goto construction_failed;
    returned = (*e)->CallObjectMethod(e, binding->callback, invoke, this_value, list);
    if ((*e)->ExceptionCheck(e)) {
        thrown = (*e)->ExceptionOccurred(e);
        (*e)->ExceptionClear(e);
        if (!thrown)
            status = callback_error(id, "Java callback threw", out_exception);
        else {
            xc = (*e)->FindClass(e, "io/jsbay/JsBayException");
            if (jni_failed(e) || !xc) {
                if (xc) {
                    (*e)->DeleteLocalRef(e, xc);
                    xc = NULL;
                }
                status = callback_throwable_error(e, id, thrown, out_exception);
            } else {
                jboolean is_jsbay = (*e)->IsInstanceOf(e, thrown, xc);
                if (jni_failed(e))
                    status = callback_throwable_error(e, id, thrown, out_exception);
                else if (!is_jsbay)
                    status = callback_throwable_error(e, id, thrown, out_exception);
                else {
                    jmethodID value = (*e)->GetMethodID(e, xc, "getValue", "()Lio/jsbay/Value;");
                    if (jni_failed(e) || !value)
                        status = callback_error(id, "invalid callback exception", out_exception);
                    else {
                        exception = (*e)->CallObjectMethod(e, thrown, value);
                        if (jni_failed(e) || !exception) {
                            if (exception) {
                                (*e)->DeleteLocalRef(e, exception);
                                exception = NULL;
                            }
                            status =
                                callback_error(id, "invalid callback exception", out_exception);
                        } else if (!same_engine(e, exception, binding->engine))
                            status = callback_error(id, "callback threw a foreign or closed Value",
                                                    out_exception);
                        else {
                            vc = (*e)->GetObjectClass(e, exception);
                            if (jni_failed(e) || !vc) {
                                if (vc) {
                                    (*e)->DeleteLocalRef(e, vc);
                                    vc = NULL;
                                }
                                status =
                                    callback_error(id, "invalid callback exception", out_exception);
                            } else {
                                jmethodID handle = (*e)->GetMethodID(
                                    e, vc,
                                    test_fault(4) ? "missingCallbackHandleForNative"
                                                  : "callbackHandleForNative",
                                    "()J");
                                int handle_failed = jni_failed(e);
                                jlong h = !handle_failed && handle
                                              ? (*e)->CallLongMethod(e, exception, handle)
                                              : 0;
                                int call_failed = jni_failed(e);
                                if (handle_failed || call_failed || !handle || !h ||
                                    jsbay_value_retain((uint64_t)h, out_exception) != JSBAY_OK)
                                    status = callback_error(id, "invalid callback exception",
                                                            out_exception);
                                else
                                    status = JSBAY_EXCEPTION;
                            }
                        }
                    }
                }
            }
        }
    } else if (returned && same_engine(e, returned, binding->engine)) {
        vc = (*e)->GetObjectClass(e, returned);
        if (jni_failed(e) || !vc) {
            if (vc)
                (*e)->DeleteLocalRef(e, vc);
            status = callback_error(id, "invalid callback result", out_exception);
        } else {
            jmethodID handle = (*e)->GetMethodID(
                e, vc, test_fault(4) ? "missingCallbackHandleForNative" : "callbackHandleForNative",
                "()J");
            int handle_failed = jni_failed(e);
            jlong h = !handle_failed && handle ? (*e)->CallLongMethod(e, returned, handle) : 0;
            int call_failed = jni_failed(e);
            if (!handle_failed && !call_failed && handle && h &&
                jsbay_value_retain((uint64_t)h, out_value) == JSBAY_OK)
                status = JSBAY_OK;
            else
                status = callback_error(id, "invalid callback result", out_exception);
            (*e)->DeleteLocalRef(e, vc);
            vc = NULL;
        }
    } else
        status =
            callback_error(id, "callback returned a foreign, closed, or null Value", out_exception);
    goto cleanup;
construction_failed:
    status = callback_error(id, "Android callback bridge construction failed", out_exception);
    goto cleanup;
unavailable:
    status = callback_error(id, "Android callback bridge is unavailable", out_exception);
cleanup:;
    int cleanup_failed = jni_failed(e);
    if (vc)
        (*e)->DeleteLocalRef(e, vc);
    if (exception)
        (*e)->DeleteLocalRef(e, exception);
    if (thrown)
        (*e)->DeleteLocalRef(e, thrown);
    if (xc)
        (*e)->DeleteLocalRef(e, xc);
    if (cc)
        (*e)->DeleteLocalRef(e, cc);
    if (returned)
        (*e)->DeleteLocalRef(e, returned);
    if (this_value)
        (*e)->DeleteLocalRef(e, this_value);
    if (list)
        (*e)->DeleteLocalRef(e, list);
    if (listc)
        (*e)->DeleteLocalRef(e, listc);
    if (scope) {
        (*e)->CallVoidMethod(e, binding->engine, end, scope);
        if (jni_failed(e))
            cleanup_failed = 1;
        (*e)->DeleteLocalRef(e, scope);
    }
    if (ec)
        (*e)->DeleteLocalRef(e, ec);
    if (cleanup_failed) {
        callback_discard_outputs(out_value, out_exception);
        return callback_error(id, "Android callback bridge cleanup failed", out_exception);
    }
    return status;
}
static void finalize_binding(void *raw) {
    binding_t *binding = raw;
    JNIEnv *e = NULL;
    if ((*binding->vm)->GetEnv(binding->vm, (void **)&e, JNI_VERSION_1_6) == JNI_OK) {
        (*e)->DeleteGlobalRef(e, binding->callback);
        (*e)->DeleteGlobalRef(e, binding->engine);
    }
    binding_release(binding);
}
static jlongArray bind(JNIEnv *e, jclass c, jint id, jstring name, jobject callback) {
    (void)c;
    jbyteArray h;
    jsbay_utf8_t n = utf(e, name, &h);
    binding_t *binding = binding_take();
    uint64_t fn = 0, x = 0;
    if (!binding) {
        done(e, h, n);
        return result(e, JSBAY_OUT_OF_MEMORY, 0, 0);
    }
    (*e)->GetJavaVM(e, &binding->vm);
    binding->callback = (*e)->NewGlobalRef(e, callback);
    jclass enginec = (*e)->FindClass(e, "io/jsbay/Engine");
    jmethodID current =
        enginec ? (*e)->GetStaticMethodID(e, enginec, "currentForNative", "()Lio/jsbay/Engine;")
                : NULL;
    if ((*e)->ExceptionCheck(e)) {
        (*e)->ExceptionClear(e);
        current = NULL;
    }
    binding->engine = current ? (*e)->CallStaticObjectMethod(e, enginec, current) : NULL;
    if ((*e)->ExceptionCheck(e)) {
        (*e)->ExceptionClear(e);
        binding->engine = NULL;
    }
    if (enginec)
        (*e)->DeleteLocalRef(e, enginec);
    if (binding->engine) {
        jobject local = binding->engine;
        binding->engine = (*e)->NewGlobalRef(e, local);
        (*e)->DeleteLocalRef(e, local);
    }
    if (!binding->callback || !binding->engine) {
        if (binding->callback)
            (*e)->DeleteGlobalRef(e, binding->callback);
        if (binding->engine)
            (*e)->DeleteGlobalRef(e, binding->engine);
        binding_release(binding);
        done(e, h, n);
        return result(e, JSBAY_INVALID_ARGUMENT, 0, 0);
    }
    jsbay_status_t s = jsbay_engine_bind(id, n, bridge, binding, finalize_binding, &fn, &x);
    done(e, h, n);
    if (s != JSBAY_OK)
        finalize_binding(binding);
    return result(e, s, fn, x);
}
static jint inspector_start(JNIEnv *e, jclass c, jint id, jshort port) {
    (void)e;
    (void)c;
    uint16_t actual = 0;
    return jsbay_engine_inspector_start(id, (uint16_t)port, &actual) ? (jint)actual : 0;
}
static void inspector_stop(JNIEnv *e, jclass c, jint id) {
    (void)e;
    (void)c;
    jsbay_engine_inspector_stop(id);
}
static void sync_complete_error(uint64_t request) {
    static const char message[] = "Android sync starter threw";
    (void)jsbay_sync_complete(request, JSBAY_EXCEPTION, JSBAY_SYNC_PAYLOAD_UTF8_STRING,
                              (jsbay_utf8_t){(const uint8_t *)message, sizeof(message) - 1});
}
static void sync_start(int id, void *raw, uint64_t request, jsbay_value_t self, size_t argc,
                       const jsbay_value_t *args) {
    (void)id;
    binding_t *binding = raw;
    JNIEnv *e = NULL;
    if ((*binding->vm)->GetEnv(binding->vm, (void **)&e, JNI_VERSION_1_6) != JNI_OK) {
        sync_complete_error(request);
        return;
    }
    jclass ec = NULL, listc = NULL, sc = NULL, callc = NULL, cc = NULL;
    jobject scope = NULL, list = NULL, this_value = NULL, completion = NULL, call_object = NULL;
    jmethodID end = NULL;
    int failed = 1;
    ec = (*e)->GetObjectClass(e, binding->engine);
    if (jni_failed(e) || !ec)
        goto cleanup;
    jmethodID begin =
        (*e)->GetMethodID(e, ec, "beginCallbackScopeForNative", "()Lio/jsbay/CallbackScope;");
    if (jni_failed(e) || !begin)
        goto cleanup;
    end = (*e)->GetMethodID(e, ec, "endCallbackScopeForNative", "(Lio/jsbay/CallbackScope;)V");
    if (jni_failed(e) || !end)
        goto cleanup;
    jmethodID borrowed = (*e)->GetMethodID(e, ec, "borrowedForNative", "(J)Lio/jsbay/Value;");
    if (jni_failed(e) || !borrowed)
        goto cleanup;
    scope = (*e)->CallObjectMethod(e, binding->engine, begin);
    if (jni_failed(e) || !scope)
        goto cleanup;
    listc = (*e)->FindClass(e, "java/util/ArrayList");
    if (jni_failed(e) || !listc)
        goto cleanup;
    jmethodID init = (*e)->GetMethodID(e, listc, "<init>", "(I)V"),
              add = (*e)->GetMethodID(e, listc, "add", "(Ljava/lang/Object;)Z");
    if (jni_failed(e) || !init || !add)
        goto cleanup;
    list = (*e)->NewObject(e, listc, init, (jint)argc);
    if (jni_failed(e) || !list)
        goto cleanup;
    this_value = (*e)->CallObjectMethod(e, binding->engine, borrowed, (jlong)self);
    if (jni_failed(e) || !this_value)
        goto cleanup;
    for (size_t i = 0; i < argc; i++) {
        jobject value = (*e)->CallObjectMethod(e, binding->engine, borrowed, (jlong)args[i]);
        if (jni_failed(e) || !value) {
            if (value)
                (*e)->DeleteLocalRef(e, value);
            goto cleanup;
        }
        (*e)->CallBooleanMethod(e, list, add, value);
        (*e)->DeleteLocalRef(e, value);
        if (jni_failed(e))
            goto cleanup;
    }
    sc = (*e)->FindClass(e, "io/jsbay/SyncCompletion");
    if (jni_failed(e) || !sc)
        goto cleanup;
    jmethodID completion_init = (*e)->GetMethodID(e, sc, "<init>", "(J)V");
    if (jni_failed(e) || !completion_init)
        goto cleanup;
    completion = (*e)->NewObject(e, sc, completion_init, (jlong)request);
    if (jni_failed(e) || !completion)
        goto cleanup;
    callc = (*e)->FindClass(e, "io/jsbay/SyncCall");
    if (jni_failed(e) || !callc)
        goto cleanup;
    jmethodID call_init = (*e)->GetMethodID(
        e, callc, "<init>", "(Lio/jsbay/Value;Ljava/util/List;Lio/jsbay/SyncCompletion;)V");
    if (jni_failed(e) || !call_init)
        goto cleanup;
    call_object = (*e)->NewObject(e, callc, call_init, this_value, list, completion);
    if (jni_failed(e) || !call_object)
        goto cleanup;
    cc = (*e)->GetObjectClass(e, binding->callback);
    if (jni_failed(e) || !cc)
        goto cleanup;
    jmethodID invoke = (*e)->GetMethodID(e, cc, "start", "(Lio/jsbay/SyncCall;)V");
    if (jni_failed(e) || !invoke)
        goto cleanup;
    (*e)->CallVoidMethod(e, binding->callback, invoke, call_object);
    if (jni_failed(e))
        goto cleanup;
    failed = 0;
cleanup:
    if (scope && end) {
        (*e)->CallVoidMethod(e, binding->engine, end, scope);
        if (jni_failed(e))
            failed = 1;
    }
    if (cc)
        (*e)->DeleteLocalRef(e, cc);
    if (call_object)
        (*e)->DeleteLocalRef(e, call_object);
    if (completion)
        (*e)->DeleteLocalRef(e, completion);
    if (callc)
        (*e)->DeleteLocalRef(e, callc);
    if (sc)
        (*e)->DeleteLocalRef(e, sc);
    if (this_value)
        (*e)->DeleteLocalRef(e, this_value);
    if (list)
        (*e)->DeleteLocalRef(e, list);
    if (listc)
        (*e)->DeleteLocalRef(e, listc);
    if (scope)
        (*e)->DeleteLocalRef(e, scope);
    if (ec)
        (*e)->DeleteLocalRef(e, ec);
    if (failed)
        sync_complete_error(request);
}
static jlongArray bind_sync(JNIEnv *e, jclass c, jint id, jstring name, jobject starter,
                            jlong timeout) {
    (void)c;
    jbyteArray h;
    jsbay_utf8_t n = utf(e, name, &h);
    binding_t *binding = binding_take();
    uint64_t fn = 0, x = 0;
    if (!binding || timeout <= 0) {
        binding_release(binding);
        done(e, h, n);
        return result(e, JSBAY_INVALID_ARGUMENT, 0, 0);
    }
    (*e)->GetJavaVM(e, &binding->vm);
    binding->callback = (*e)->NewGlobalRef(e, starter);
    jclass enginec = (*e)->FindClass(e, "io/jsbay/Engine");
    jmethodID current =
        enginec ? (*e)->GetStaticMethodID(e, enginec, "currentForNative", "()Lio/jsbay/Engine;")
                : NULL;
    if ((*e)->ExceptionCheck(e)) {
        (*e)->ExceptionClear(e);
        current = NULL;
    }
    binding->engine = current ? (*e)->CallStaticObjectMethod(e, enginec, current) : NULL;
    if ((*e)->ExceptionCheck(e)) {
        (*e)->ExceptionClear(e);
        binding->engine = NULL;
    }
    if (enginec)
        (*e)->DeleteLocalRef(e, enginec);
    if (binding->engine) {
        jobject local = binding->engine;
        binding->engine = (*e)->NewGlobalRef(e, local);
        (*e)->DeleteLocalRef(e, local);
    }
    if (!binding->callback || !binding->engine) {
        if (binding->callback)
            (*e)->DeleteGlobalRef(e, binding->callback);
        if (binding->engine)
            (*e)->DeleteGlobalRef(e, binding->engine);
        binding_release(binding);
        done(e, h, n);
        return result(e, JSBAY_INVALID_ARGUMENT, 0, 0);
    }
    jsbay_status_t s = jsbay_engine_bind_sync(id, n, sync_start, binding, finalize_binding,
                                              (uint64_t)timeout, &fn, &x);
    done(e, h, n);
    if (s != JSBAY_OK)
        finalize_binding(binding);
    return result(e, s, fn, x);
}
static jint sync_complete(JNIEnv *e, jclass c, jlong request, jint outcome, jint kind,
                          jbyteArray data) {
    (void)c;
    jsize n = data ? (*e)->GetArrayLength(e, data) : 0;
    jbyte *p = n ? (*e)->GetByteArrayElements(e, data, NULL) : NULL;
    if (n && !p)
        return JSBAY_OUT_OF_MEMORY;
    jsbay_status_t s = jsbay_sync_complete((uint64_t)request, (jsbay_status_t)outcome,
                                           (jsbay_sync_payload_kind_t)kind,
                                           (jsbay_utf8_t){(const uint8_t *)p, (size_t)n});
    if (p)
        (*e)->ReleaseByteArrayElements(e, data, p, JNI_ABORT);
    return (jint)s;
}

static jintArray engine_list(JNIEnv *e, jclass c) {
    (void)c;
    for (;;) {
        size_t need = jsbay_engine_list(NULL, 0);
        int *buf = need ? (int *)malloc(need * sizeof(int)) : NULL;
        if (need && !buf)
            return NULL;
        size_t n = jsbay_engine_list(buf, need);
        if (n > need) {
            free(buf);
            continue;
        }
        jintArray out = (*e)->NewIntArray(e, (jsize)n);
        if (!out) {
            free(buf);
            return NULL;
        }
        if (n)
            (*e)->SetIntArrayRegion(e, out, 0, (jsize)n, (const jint *)buf);
        free(buf);
        return out;
    }
}
static jlongArray engine_snapshot(JNIEnv *e, jclass c, jint id) {
    (void)c;
    jsbay_instance_snapshot_t snap = {.struct_size = sizeof(snap)};
    if (!jsbay_engine_snapshot(id, &snap))
        return NULL;
    jlong values[] = {(jlong)snap.instance_id,
                      (jlong)snap.generation,
                      (jlong)snap.owner_thread_id,
                      (jlong)snap.loop_mode,
                      (jlong)snap.flags,
                      (jlong)snap.admission_class,
                      (jlong)snap.timers_reserved,
                      (jlong)snap.timers_registered,
                      (jlong)snap.script_tasks_queued,
                      (jlong)snap.native_tasks_queued,
                      (jlong)snap.pending_bytes,
                      (jlong)snap.max_timers,
                      (jlong)snap.max_pending_tasks,
                      (jlong)snap.max_pending_bytes};
    return pack_longs(e, values, (jsize)(sizeof(values) / sizeof(values[0])));
}
static JNINativeMethod methods[] = {
    {"create", "(I)Z", create},
    {"createWithLimits", "(IJJJJJ)Z", create_with_limits},
    {"setResourceLimits", "(IJJJJJ)Z", set_resource_limits},
    {"resourceUsage", "(I)[J", resource_usage},
    {"globalResourceUsage", "()[J", global_resource_usage},
    {"createWithHandlers", "(ILio/jsbay/LogHandler;Lio/jsbay/EventHandler;)Z",
     create_with_handlers},
    {"destroy", "(I)V", destroy},
    {"setEventHandler", "(ILio/jsbay/EventHandler;)Z", set_event_handler},
    {"getMemoryUsage", "(I)[J", get_memory_usage},
    {"runGc", "(I)Z", run_gc},
    {"requestInterrupt", "(I)Z", ri},
    {"clearInterrupt", "(I)Z", ci},
    {"timeLimit", "(IJ)Z", limit},
    {"memoryLimit", "(IJ)Z", mem},
    {"attachLoop", "(I)J", attach_loop},
    {"detachLoop", "(IJ)I", detach_loop},
    {"loopStatus", "(I)I", loop_status},
    {"runLoop", "(I)I", run_loop},
    {"stopLoop", "(I)Z", stop_loop},
    {"suspendLoop", "(I)Z", suspend_loop},
    {"resumeLoop", "(I)Z", resume_loop},
    {"isSuspended", "(I)Z", is_suspended},
    {"setAdmissionClass", "(II)Z", set_admission_class},
    {"getAdmissionClass", "(I)I", get_admission_class},
    {"listEngines", "()[I", engine_list},
    {"snapshotEngine", "(I)[J", engine_snapshot},
    {"runLoopTask", "(JJ)V", run_loop_task},
    {"evaluate", "(I[BLjava/lang/String;Ljava/lang/String;Ljava/lang/String;)[J", eval},
    {"retain", "(J)[J", retain},
    {"release", "(Lio/jsbay/Engine;J)V", release},
    {"type", "(Lio/jsbay/Engine;J)I", type},
    {"number", "(Lio/jsbay/Engine;J)D", number},
    {"bool", "(Lio/jsbay/Engine;J)Z", boolean},
    {"toUtf8", "(Lio/jsbay/Engine;J)Ljava/lang/String;", to_utf8},
    {"toJson", "(Lio/jsbay/Engine;J)Ljava/lang/String;", to_json},
    {"get", "(JLjava/lang/String;)[J", get},
    {"set", "(Lio/jsbay/Engine;JLjava/lang/String;J)V", set},
    {"call", "(JJ[J)[J", call},
    {"construct", "(J[J)[J", construct},
    {"has", "(JLjava/lang/String;)[J", has},
    {"delete", "(JLjava/lang/String;)[J", delete_property},
    {"keys", "(J)[J", keys},
    {"instanceOf", "(JJ)[J", instance_of},
    {"undefined", "(I)[J", undefined},
    {"global", "(I)[J", global},
    {"nullValue", "(I)[J", null_value},
    {"bind", "(ILjava/lang/String;Lio/jsbay/Callback;)[J", bind},
    {"newBool", "(IZ)[J", new_bool},
    {"newNumber", "(ID)[J", new_number},
    {"newString", "(ILjava/lang/String;)[J", new_string},
    {"newJson", "(ILjava/lang/String;)[J", new_json},
    {"newError", "(ILjava/lang/String;)[J", new_error},
    {"newObject", "(I)[J", new_object},
    {"newArray", "(I)[J", new_array},
    {"newArrayBuffer", "(I[B)[J", new_array_buffer},
    {"copyBuffer", "(Lio/jsbay/Engine;J)[B", copy_buffer},
    {"startInspector", "(IS)I", inspector_start},
    {"stopInspector", "(I)V", inspector_stop},
    {"bindSync", "(ILjava/lang/String;Lio/jsbay/SyncStarter;J)[J", bind_sync},
    {"syncComplete", "(JII[B)I", sync_complete},
};
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *x) {
    (void)x;
    JNIEnv *e = NULL;
    if ((*vm)->GetEnv(vm, (void **)&e, JNI_VERSION_1_6) != JNI_OK)
        return JNI_ERR;
    jclass c = (*e)->FindClass(e, "io/jsbay/Native");
    if (!c)
        return JNI_ERR;
    jint r = (*e)->RegisterNatives(e, c, methods, sizeof(methods) / sizeof(*methods));
    (*e)->DeleteLocalRef(e, c);
    return r == 0 ? JNI_VERSION_1_6 : JNI_ERR;
}
