#include "jsbay.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

extern void jsbay_test_owner_destroy_reset(void);
extern uint64_t jsbay_test_owner_destroy_read(uint32_t index);
static const int id = 94201;
static uint64_t generation;
static pthread_t creator;
static atomic_int finalizers;
#define CHECK(x)                                                                                   \
    do {                                                                                           \
        if (!(x)) {                                                                                \
            fprintf(stderr, "FAIL line=%d expression=%s\n", __LINE__, #x);                         \
            abort();                                                                               \
        }                                                                                          \
    } while (0)
static jsbay_status_t callback(int i, void *p, jsbay_value_t r, size_t n, const jsbay_value_t *a,
                               jsbay_value_t *out, jsbay_value_t *exception) {
    (void)i;
    (void)p;
    (void)r;
    (void)n;
    (void)a;
    *out = 0;
    *exception = 0;
    return JSBAY_INVALID_ARGUMENT;
}
static void finalize(void *p) {
    (void)p;
    CHECK(pthread_equal(creator, pthread_self()));
    CHECK(atomic_fetch_add(&finalizers, 1) == 0);
    CHECK(jsbay_engine_request_destroy(id, generation) == JSBAY_DESTROY_PENDING);
    CHECK(jsbay_engine_destroy_status(id, generation) == JSBAY_DESTROY_PENDING);
    CHECK(jsbay_engine_drain_destroy(id, generation) == JSBAY_DESTROY_PENDING);
}
static void *request(void *p) {
    (void)p;
    for (int n = 0; n < 16; ++n) {
        CHECK(jsbay_engine_request_destroy(id, generation) == JSBAY_DESTROY_PENDING);
        CHECK(jsbay_engine_destroy_status(id, generation) == JSBAY_DESTROY_PENDING);
        CHECK(jsbay_engine_drain_destroy(id, generation) == JSBAY_DESTROY_WRONG_THREAD);
    }
    return NULL;
}
int main(void) {
    creator = pthread_self();
    for (int round = 0; round < 8; ++round) {
        uint64_t old_generation = generation;
        CHECK(jsbay_engine_create(id, NULL, NULL));
        jsbay_instance_snapshot_t snap = {.struct_size = sizeof(snap)};
        CHECK(jsbay_engine_snapshot(id, &snap));
        generation = snap.generation;
        CHECK(generation && generation != old_generation);
        if (old_generation)
            CHECK(jsbay_engine_request_destroy(id, old_generation) == JSBAY_DESTROY_STALE);
        jsbay_value_t fn = 0, exception = 0;
        const char *name = "ownerSanitizerProbe";
        CHECK(jsbay_engine_bind(id, (jsbay_utf8_t){(const uint8_t *)name, strlen(name)}, callback,
                                NULL, finalize, &fn, &exception) == JSBAY_OK);
        CHECK(fn && !exception && jsbay_value_release(fn) == JSBAY_OK);
        atomic_store(&finalizers, 0);
        jsbay_test_owner_destroy_reset();
        pthread_t threads[8];
        for (int i = 0; i < 8; ++i)
            CHECK(!pthread_create(&threads[i], NULL, request, NULL));
        for (int i = 0; i < 8; ++i)
            CHECK(!pthread_join(threads[i], NULL));
        CHECK(!atomic_load(&finalizers));
        CHECK(!jsbay_test_owner_destroy_read(0) && !jsbay_test_owner_destroy_read(1));
        CHECK(jsbay_engine_drain_destroy(id, generation) == JSBAY_DESTROY_COMPLETE);
        CHECK(atomic_load(&finalizers) == 1);
        CHECK(jsbay_test_owner_destroy_read(0) == 1);
        CHECK(jsbay_test_owner_destroy_read(1) == 1);
        CHECK(jsbay_test_owner_destroy_read(2) == (uint64_t)syscall(SYS_gettid));
        CHECK(jsbay_engine_request_destroy(id, generation) == JSBAY_DESTROY_COMPLETE);
        CHECK(jsbay_engine_drain_destroy(id, generation) == JSBAY_DESTROY_COMPLETE);
    }
    puts("PASS: 8 creator-drained generations, 64 pthreads, 1024 requests, owner finalizers and "
         "separate backend-free counts");
    return 0;
}
