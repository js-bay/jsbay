#include "jsbay.h"
#include <dlfcn.h>
#include <jni.h>
#include <stdatomic.h>
#include <unistd.h>
static atomic_ulong finalizers, finalizer_tid;
static void (*reset_core)(void);
static uint64_t (*read_core)(uint32_t);
static void finalize(void *data) {
    (void)data;
    atomic_fetch_add(&finalizers, 1);
    atomic_store(&finalizer_tid, (unsigned long)gettid());
}
static jsbay_status_t callback(int id, void *data, jsbay_value_t receiver, size_t argc,
                               const jsbay_value_t *argv, jsbay_value_t *out,
                               jsbay_value_t *exception) {
    (void)id;
    (void)data;
    (void)receiver;
    (void)argc;
    (void)argv;
    *out = 0;
    *exception = 0;
    return JSBAY_INVALID_ARGUMENT;
}
JNIEXPORT void JNICALL Java_io_jsbay_OwnerDestroyMain_probeReset(JNIEnv *env, jobject self,
                                                                 jint id) {
    (void)self;
    reset_core = dlsym(RTLD_DEFAULT, "jsbay_test_owner_destroy_reset");
    read_core = dlsym(RTLD_DEFAULT, "jsbay_test_owner_destroy_read");
    jsbay_value_t fn = 0, exception = 0;
    const uint8_t name[] = "ownerReleaseProbe";
    if (!reset_core || !read_core ||
        jsbay_engine_bind(id, (jsbay_utf8_t){name, sizeof(name) - 1}, callback, NULL, finalize, &fn,
                          &exception) != JSBAY_OK ||
        !fn || exception || jsbay_value_release(fn) != JSBAY_OK) {
        (*env)->ThrowNew(env, (*env)->FindClass(env, "java/lang/IllegalStateException"),
                         "Diagnostic release probe setup failed");
        return;
    }
    reset_core();
    atomic_store(&finalizers, 0);
    atomic_store(&finalizer_tid, 0);
}
JNIEXPORT jlongArray JNICALL Java_io_jsbay_OwnerDestroyMain_probeStats(JNIEnv *env, jobject self) {
    (void)self;
    jlong data[] = {(jlong)read_core(0), (jlong)read_core(1), (jlong)read_core(2),
                    (jlong)atomic_load(&finalizers), (jlong)atomic_load(&finalizer_tid)};
    jlongArray out = (*env)->NewLongArray(env, 5);
    if (out)
        (*env)->SetLongArrayRegion(env, out, 0, 5, data);
    return out;
}
JNIEXPORT jlong JNICALL Java_io_jsbay_OwnerDestroyMain_probeTid(JNIEnv *env, jobject self) {
    (void)env;
    (void)self;
    return gettid();
}
JNIEXPORT jstring JNICALL Java_io_jsbay_OwnerDestroyMain_probeCommit(JNIEnv *env, jobject self) {
    (void)self;
    jsbay_engine_version_info_t v = {.struct_size = sizeof(v)};
    if (!jsbay_engine_version(&v))
        return NULL;
    return (*env)->NewStringUTF(env, v.commit ? v.commit : "");
}
