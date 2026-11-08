/* Measures a precompiled JavaScript function while an inspector listener is live. */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "jsbay.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define TEXT(value) ((jsbay_utf8_t){(const uint8_t *)(value), sizeof(value) - 1u})
#define WORKLOAD_CALLS 10u
#define WARMUP_CALLS 2u

enum command { COMMAND_NONE, COMMAND_MEASURE, COMMAND_QUIT };

struct state {
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    int ready;
    int failed;
    enum command command;
    int completed;
    int instance_id;
    uint16_t port;
    jsbay_value_t function;
    jsbay_value_t undefined_this;
};

static uint64_t now_ns(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0)
        return 0;
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

static int call_workload(struct state *state, unsigned calls, uint64_t *out_sum) {
    uint64_t sum = 0;
    for (unsigned i = 0; i < calls; ++i) {
        jsbay_value_t value = 0;
        jsbay_value_t exception = 0;
        double result = 0;
        const int ok = jsbay_value_call(state->function, state->undefined_this, NULL, 0, &value,
                                        &exception) == JSBAY_OK &&
                       jsbay_value_to_number(value, &result) == JSBAY_OK && result == 499500;
        if (value)
            jsbay_value_release(value);
        if (exception)
            jsbay_value_release(exception);
        if (!ok)
            return 0;
        sum += (uint64_t)result;
    }
    *out_sum = sum;
    return 1;
}

static int condition_hits(struct state *state, uint64_t *out_hits) {
    jsbay_value_t value = 0;
    jsbay_value_t exception = 0;
    double hits = 0;
    const jsbay_status_t status =
        jsbay_engine_evaluate(state->instance_id, TEXT("globalThis.__debugConditionHits || 0"),
                              TEXT("debugger-benchmark-check.js"), NULL, &value, &exception);
    const int ok =
        status == JSBAY_OK && jsbay_value_to_number(value, &hits) == JSBAY_OK && hits >= 0;
    if (value)
        jsbay_value_release(value);
    if (exception)
        jsbay_value_release(exception);
    if (!ok)
        return 0;
    *out_hits = (uint64_t)hits;
    return 1;
}

static void *owner_main(void *opaque) {
    struct state *state = opaque;
    jsbay_value_t exception = 0;
    int created = 0;
    int inspector_started = 0;
    const char source[] = "(() => {\nfunction workload() {\nlet sum = 0;\nfor (let i = 0; i < "
                          "1000; i++) {\nsum += i;\n}\nreturn sum;\n}\nfunction "
                          "unusedBreakpointTarget() { return 0; }\nreturn workload;\n})()";
    if (!jsbay_engine_create(state->instance_id, NULL, NULL))
        state->failed = 1;
    else
        created = 1;
    if (!state->failed && !jsbay_engine_inspector_start(state->instance_id, 0, &state->port))
        state->failed = 1;
    else if (!state->failed)
        inspector_started = 1;
    if (!state->failed &&
        (jsbay_value_undefined(state->instance_id, &state->undefined_this) != JSBAY_OK ||
         jsbay_engine_evaluate(
             state->instance_id, (jsbay_utf8_t){(const uint8_t *)source, sizeof(source) - 1u},
             TEXT("debugger-benchmark.js"), NULL, &state->function, &exception) != JSBAY_OK ||
         !state->function))
        state->failed = 1;
    if (exception)
        jsbay_value_release(exception);
    pthread_mutex_lock(&state->mutex);
    state->ready = 1;
    pthread_cond_broadcast(&state->changed);
    pthread_mutex_unlock(&state->mutex);
    if (state->failed)
        goto done;
    for (;;) {
        const jsbay_status_t loop_status = jsbay_engine_run_loop(state->instance_id);
        pthread_mutex_lock(&state->mutex);
        const enum command command = state->command;
        pthread_mutex_unlock(&state->mutex);
        if (loop_status != JSBAY_OK || command == COMMAND_QUIT) {
            if (loop_status != JSBAY_OK) {
                pthread_mutex_lock(&state->mutex);
                state->failed = 1;
                state->completed = 1;
                pthread_cond_broadcast(&state->changed);
                pthread_mutex_unlock(&state->mutex);
            }
            break;
        }
        if (command == COMMAND_MEASURE) {
            uint64_t sum = 0, elapsed = 0, hits = 0;
            int ok = call_workload(state, WARMUP_CALLS, &sum);
            const uint64_t start = now_ns();
            if (ok)
                ok = call_workload(state, WORKLOAD_CALLS, &sum);
            const uint64_t end = now_ns();
            if (ok)
                ok = condition_hits(state, &hits);
            elapsed = start != 0 && end > start ? end - start : 0;
            pthread_mutex_lock(&state->mutex);
            printf("RESULT %d %llu %llu %llu\n", ok && elapsed != 0, (unsigned long long)elapsed,
                   (unsigned long long)sum, (unsigned long long)hits);
            fflush(stdout);
            state->command = COMMAND_NONE;
            state->completed = 1;
            pthread_cond_broadcast(&state->changed);
            pthread_mutex_unlock(&state->mutex);
        }
    }
done:
    if (state->function)
        jsbay_value_release(state->function);
    if (state->undefined_this)
        jsbay_value_release(state->undefined_this);
    if (inspector_started)
        jsbay_engine_inspector_stop(state->instance_id);
    if (created)
        jsbay_engine_destroy(state->instance_id);
    return NULL;
}

int main(void) {
    struct state state;
    memset(&state, 0, sizeof(state));
    state.instance_id = 744001;
    pthread_mutex_init(&state.mutex, NULL);
    pthread_cond_init(&state.changed, NULL);
    pthread_t owner;
    if (pthread_create(&owner, NULL, owner_main, &state) != 0)
        return 2;
    pthread_mutex_lock(&state.mutex);
    while (!state.ready)
        pthread_cond_wait(&state.changed, &state.mutex);
    const int failed = state.failed;
    const uint16_t port = state.port;
    pthread_mutex_unlock(&state.mutex);
    if (failed) {
        pthread_join(owner, NULL);
        pthread_cond_destroy(&state.changed);
        pthread_mutex_destroy(&state.mutex);
        return 2;
    }
    printf("READY %u\n", (unsigned)port);
    fflush(stdout);
    char command[32];
    while (fgets(command, sizeof(command), stdin)) {
        const enum command next = strcmp(command, "MEASURE\n") == 0 ? COMMAND_MEASURE
                                  : strcmp(command, "QUIT\n") == 0  ? COMMAND_QUIT
                                                                    : COMMAND_NONE;
        if (next == COMMAND_NONE)
            continue;
        pthread_mutex_lock(&state.mutex);
        state.command = next;
        state.completed = 0;
        pthread_mutex_unlock(&state.mutex);
        if (!jsbay_engine_stop_loop(state.instance_id))
            break;
        pthread_mutex_lock(&state.mutex);
        while (!state.completed && next != COMMAND_QUIT)
            pthread_cond_wait(&state.changed, &state.mutex);
        pthread_mutex_unlock(&state.mutex);
        if (next == COMMAND_QUIT)
            break;
    }
    pthread_mutex_lock(&state.mutex);
    state.command = COMMAND_QUIT;
    pthread_mutex_unlock(&state.mutex);
    jsbay_engine_stop_loop(state.instance_id);
    pthread_join(owner, NULL);
    const int final_failed = state.failed;
    pthread_cond_destroy(&state.changed);
    pthread_mutex_destroy(&state.mutex);
    return final_failed ? 2 : 0;
}
