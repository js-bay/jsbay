/* Harmony device P0 keep-alive harness (C ABI + soft Host cancel).
 * Used as HAP libentry native.run() and as a standalone ohos ELF. */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include "jsbay.h"
#include "jsbay_sync.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define TEXT(x) ((jsbay_utf8_t){(const uint8_t *)(x), sizeof(x) - 1})
#define BYTES(p, n) ((jsbay_utf8_t){(const uint8_t *)(p), (size_t)(n)})

static int g_failures = 0;
static void fail_at(const char *file, int line, const char *expr) {
    fprintf(stderr, "FAIL %s:%d: %s\n", file, line, expr);
    g_failures++;
}
#define CHECK(x) do { if (!(x)) fail_at(__FILE__, __LINE__, #x); } while (0)

typedef struct SoftHost {
    pthread_mutex_t mu;
    uint64_t generation;
    uint64_t delay_ms;
    jsbay_loop_task_t task;
    void *task_data;
    int has_task;
    size_t schedule_count;
    size_t cancel_count;
    int alive; /* hard-cancel sets 0 — soft cancel must leave 1 */
} SoftHost;

static bool soft_schedule(void *user_data, uint64_t delay_ms, jsbay_loop_task_t task, void *task_data) {
    SoftHost *h = (SoftHost *)user_data;
    if (!h->alive) return false;
    pthread_mutex_lock(&h->mu);
    h->generation++;
    h->delay_ms = delay_ms;
    h->task = task;
    h->task_data = task_data;
    h->has_task = 1;
    h->schedule_count++;
    pthread_mutex_unlock(&h->mu);
    return true;
}

static void soft_cancel(void *user_data) {
    SoftHost *h = (SoftHost *)user_data;
    pthread_mutex_lock(&h->mu);
    h->generation++;
    h->has_task = 0;
    h->task = NULL;
    h->task_data = NULL;
    h->cancel_count++;
    /* soft: do NOT clear alive */
    pthread_mutex_unlock(&h->mu);
}

static int soft_run_next(SoftHost *h) {
    jsbay_loop_task_t task = NULL;
    void *data = NULL;
    uint64_t delay = 0;
    uint64_t gen = 0;
    pthread_mutex_lock(&h->mu);
    if (!h->has_task) {
        pthread_mutex_unlock(&h->mu);
        return 0;
    }
    task = h->task;
    data = h->task_data;
    delay = h->delay_ms;
    gen = h->generation;
    h->has_task = 0;
    h->task = NULL;
    h->task_data = NULL;
    pthread_mutex_unlock(&h->mu);
    if (delay > 0) {
        struct timespec ts;
        ts.tv_sec = (time_t)(delay / 1000);
        ts.tv_nsec = (long)((delay % 1000) * 1000000L);
        nanosleep(&ts, NULL);
    }
    pthread_mutex_lock(&h->mu);
    int still = (h->generation == gen);
    pthread_mutex_unlock(&h->mu);
    if (still && task) task(data);
    return 1;
}

static void soft_init(SoftHost *h) {
    memset(h, 0, sizeof(*h));
    pthread_mutex_init(&h->mu, NULL);
    h->alive = 1;
}

static void soft_deinit(SoftHost *h) {
    pthread_mutex_destroy(&h->mu);
}

static jsbay_status_t after_resume_cb(int instance_id, void *user_data,
    jsbay_value_t this_value, size_t argc, const jsbay_value_t *args,
    jsbay_value_t *out_value, jsbay_value_t *out_exception) {
    (void)instance_id; (void)this_value; (void)argc; (void)args; (void)out_exception;
    int *fired = (int *)user_data;
    *fired = 1;
    return jsbay_value_undefined(instance_id, out_value);
}

static void sleep_ms(unsigned ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

static int test_suspend_resume(void) {
    const int id = 9201;
    SoftHost host;
    int fired = 0;
    jsbay_value_t fn = 0, val = 0, exc = 0;
    soft_init(&host);
    CHECK(jsbay_engine_create(id, NULL, NULL));
    CHECK(jsbay_engine_attach_loop(id, soft_schedule, soft_cancel, &host) == JSBAY_OK);
    /* drain initial attach schedule if any */
    soft_run_next(&host);

    CHECK(jsbay_engine_bind(id, TEXT("afterResume"), after_resume_cb, &fired, NULL, &fn, &exc) == JSBAY_OK);
    CHECK(jsbay_value_release(fn) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id, TEXT("globalThis.__p0Keep = 42"), TEXT("keep.js"), NULL, &val, &exc) == JSBAY_OK);
    CHECK(jsbay_value_release(val) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id, TEXT("setTimeout(afterResume, 50)"), TEXT("timer.js"), NULL, &val, &exc) == JSBAY_OK);
    CHECK(jsbay_value_release(val) == JSBAY_OK);

    size_t cancels_before = host.cancel_count;
    size_t schedules_before = host.schedule_count;
    CHECK(jsbay_engine_suspend(id));
    CHECK(jsbay_engine_is_suspended(id));
    CHECK(host.cancel_count == cancels_before + 1);
    CHECK(host.alive == 1);
    CHECK(host.has_task == 0);

    sleep_ms(120);
    CHECK(fired == 0);

    CHECK(jsbay_engine_evaluate(id, TEXT("globalThis.__p0Keep"), TEXT("keep-check.js"), NULL, &val, &exc) == JSBAY_OK);
    {
        double n = 0;
        CHECK(jsbay_value_to_number(val, &n) == JSBAY_OK);
        CHECK(n == 42.0);
        CHECK(jsbay_value_release(val) == JSBAY_OK);
    }

    CHECK(jsbay_engine_resume(id));
    CHECK(!jsbay_engine_is_suspended(id));
    CHECK(host.schedule_count > schedules_before);
    CHECK(jsbay_engine_loop_status(id) == JSBAY_OK);

    {
        int spins = 0;
        while (!fired && spins < 64) {
            if (!soft_run_next(&host)) sleep_ms(5);
            spins++;
        }
    }
    CHECK(fired == 1);
    CHECK(jsbay_engine_loop_status(id) == JSBAY_OK);

    CHECK(jsbay_engine_evaluate(id, TEXT("1+1"), TEXT("alive.js"), NULL, &val, &exc) == JSBAY_OK);
    {
        double n = 0;
        CHECK(jsbay_value_to_number(val, &n) == JSBAY_OK);
        CHECK(n == 2.0);
        CHECK(jsbay_value_release(val) == JSBAY_OK);
    }

    CHECK(jsbay_engine_detach_loop(id) == JSBAY_OK);
    jsbay_engine_destroy(id);
    soft_deinit(&host);
    if (g_failures == 0) puts("PASS: harmony device suspend/resume keep-alive");
    return g_failures ? 1 : 0;
}

static int test_admission_obs(void) {
    const int id = 9202;
    jsbay_admission_class_t cls = JSBAY_ADMISSION_BACKGROUND;
    jsbay_resource_global_usage_t global;
    jsbay_instance_snapshot_t snap;
    int ids[8];
    size_t n;
    memset(&global, 0, sizeof(global));
    global.struct_size = sizeof(global);
    memset(&snap, 0, sizeof(snap));
    snap.struct_size = sizeof(snap);

    CHECK(jsbay_engine_create(id, NULL, NULL));
    CHECK(jsbay_engine_get_admission_class(id, &cls));
    CHECK(cls == JSBAY_ADMISSION_FOREGROUND);
    CHECK(jsbay_engine_set_admission_class(id, JSBAY_ADMISSION_BACKGROUND));
    CHECK(jsbay_engine_get_admission_class(id, &cls));
    CHECK(cls == JSBAY_ADMISSION_BACKGROUND);
    CHECK(jsbay_resource_global_usage(&global));
    CHECK(global.fg_headroom_timers > 0 || global.max_timers < 4);
    CHECK(global.bg_effective_max_timers <= global.max_timers);
    CHECK(jsbay_engine_set_admission_class(id, JSBAY_ADMISSION_FOREGROUND));
    n = jsbay_engine_list(ids, 8);
    {
        size_t i;
        int found = 0;
        for (i = 0; i < n && i < 8; i++) if (ids[i] == id) found = 1;
        CHECK(found);
    }
    CHECK(jsbay_engine_snapshot(id, &snap));
    CHECK(snap.instance_id == id);
    CHECK(snap.admission_class == JSBAY_ADMISSION_FOREGROUND);
    jsbay_engine_destroy(id);
    if (g_failures == 0) puts("PASS: harmony device admission class + list/snapshot");
    return g_failures ? 1 : 0;
}

struct SyncState {
    uint64_t request;
    pthread_t thread;
    int kind; /* 0 string, 1 bytes */
};

static void *sync_complete_thread(void *data) {
    struct SyncState *st = (struct SyncState *)data;
    if (st->kind == 0) {
        if (jsbay_sync_complete(st->request, JSBAY_OK, JSBAY_SYNC_PAYLOAD_UTF8_STRING, TEXT("typed-ok")) != JSBAY_OK)
            return (void *)1;
    } else {
        static const uint8_t bytes[] = {9, 8, 7};
        if (jsbay_sync_complete(st->request, JSBAY_OK, JSBAY_SYNC_PAYLOAD_BYTES, BYTES(bytes, 3)) != JSBAY_OK)
            return (void *)1;
    }
    return NULL;
}

static void sync_start(int instance_id, void *user_data, uint64_t request_id,
    jsbay_value_t this_value, size_t argc, const jsbay_value_t *args) {
    (void)instance_id; (void)this_value; (void)argc; (void)args;
    struct SyncState *st = (struct SyncState *)user_data;
    st->request = request_id;
    (void)pthread_create(&st->thread, NULL, sync_complete_thread, st);
}

static int test_bind_sync(void) {
    const int id = 9203;
    struct SyncState st;
    jsbay_value_t fn = 0, val = 0, exc = 0;
    void *join_rc = NULL;
    memset(&st, 0, sizeof(st));
    CHECK(jsbay_engine_create(id, NULL, NULL));

    st.kind = 0;
    CHECK(jsbay_engine_bind_sync(id, TEXT("p0SyncStr"), sync_start, &st, NULL, 2000, &fn, &exc) == JSBAY_OK);
    CHECK(jsbay_value_release(fn) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id, TEXT("p0SyncStr()"), TEXT("sync-str.js"), NULL, &val, &exc) == JSBAY_OK);
    {
        jsbay_bytes_t bytes = {0};
        CHECK(jsbay_value_to_utf8(val, &bytes, &exc) == JSBAY_OK);
        CHECK(bytes.len == 8 && memcmp(bytes.data, "typed-ok", 8) == 0);
        jsbay_free_bytes(bytes);
        CHECK(jsbay_value_release(val) == JSBAY_OK);
    }
    CHECK(pthread_join(st.thread, &join_rc) == 0 && join_rc == NULL);

    st.kind = 1;
    CHECK(jsbay_engine_bind_sync(id, TEXT("p0SyncBytes"), sync_start, &st, NULL, 2000, &fn, &exc) == JSBAY_OK);
    CHECK(jsbay_value_release(fn) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id,
        TEXT("(function(){ var u = new Uint8Array(p0SyncBytes()); return u.length===3 && u[0]===9 && u[1]===8 && u[2]===7; })()"),
        TEXT("sync-bytes.js"), NULL, &val, &exc) == JSBAY_OK);
    {
        bool ok = false;
        CHECK(jsbay_value_to_bool(val, &ok) == JSBAY_OK);
        CHECK(ok);
        CHECK(jsbay_value_release(val) == JSBAY_OK);
    }
    CHECK(pthread_join(st.thread, &join_rc) == 0 && join_rc == NULL);

    jsbay_engine_destroy(id);
    if (g_failures == 0) puts("PASS: harmony device bindSync ResolveString/ResolveBytes");
    return g_failures ? 1 : 0;
}

int jsbay_p0_keepalive_run(void) {
    g_failures = 0;
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    puts("JSBAY_P0_HARMONY_START");
    if (test_suspend_resume()) return 1;
    if (test_admission_obs()) return 1;
    if (test_bind_sync()) return 1;
    if (g_failures) {
        printf("JSBAY_P0_HARMONY_FAIL failures=%d\n", g_failures);
        return 1;
    }
    puts("PASS: Harmony device P0 keep-alive");
    puts("JSBAY_P0_HARMONY_PASS");
    return 0;
}

#ifdef JSBAY_P0_STANDALONE
int main(void) { return jsbay_p0_keepalive_run(); }
#endif
