#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200112L
#endif

#include "jsbay.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>

#define TEXT(value) ((jsbay_utf8_t){(const uint8_t *)(value), sizeof(value) - 1u})
/* Match the native engine owner stack so Debug inspector calls retain their stack budget. */
#define OWNER_STACK_BYTES (128u * 1024u * 1024u)

enum command { COMMAND_NONE, COMMAND_RUN, COMMAND_GC, COMMAND_RESET, COMMAND_QUIT };

struct state {
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    enum command command;
    int ready;
    int complete;
    int failed;
    int engine_started;
    int generation;
    int instance_id;
    uint16_t port;
};

static int start_engine(struct state *state) {
    jsbay_value_t value = 0;
    jsbay_value_t exception = 0;
    char source[512];
    const int realm = ++state->generation * 100;
    const int length = snprintf(
        source, sizeof(source),
        "globalThis.contractRealm = %d;\nglobalThis.contractSequence = 0;\nglobalThis.invoke = "
        "function invoke() {\n  const sequence = ++globalThis.contractSequence;\n  const "
        "outerClosure = sequence * 10;\n  const receiver = { value: sequence * 100 };\n  return "
        "(function frame() {\n    const local = sequence;\n    return local + outerClosure + "
        "this.value + globalThis.contractRealm;\n  }).call(receiver);\n};\n",
        realm);
    if (length < 0 || (size_t)length >= sizeof(source))
        return 0;
    if (!jsbay_engine_create(state->instance_id, NULL, NULL))
        return 0;
    if (!jsbay_engine_inspector_start(state->instance_id, 0, &state->port))
        goto failed;
    if (jsbay_engine_evaluate(state->instance_id,
                              (jsbay_utf8_t){(const uint8_t *)source, (size_t)length},
                              TEXT("debug-eval-contract.js"), NULL, &value, &exception) != JSBAY_OK)
        goto failed;
    jsbay_value_release(value);
    state->engine_started = 1;
    return 1;
failed:
    if (value)
        jsbay_value_release(value);
    if (exception)
        jsbay_value_release(exception);
    jsbay_engine_inspector_stop(state->instance_id);
    jsbay_engine_destroy(state->instance_id);
    return 0;
}

static void stop_engine(struct state *state) {
    if (!state->engine_started)
        return;
    jsbay_engine_inspector_stop(state->instance_id);
    jsbay_engine_destroy(state->instance_id);
    state->engine_started = 0;
}

static int run_frame(struct state *state) {
    jsbay_value_t value = 0;
    jsbay_value_t exception = 0;
    double result = 0;
    const jsbay_status_t status =
        jsbay_engine_evaluate(state->instance_id, TEXT("globalThis.invoke()"),
                              TEXT("debug-eval-contract-run.js"), NULL, &value, &exception);
    const int ok = status == JSBAY_OK && jsbay_value_to_number(value, &result) == JSBAY_OK;
    if (value)
        jsbay_value_release(value);
    if (exception)
        jsbay_value_release(exception);
    if (!ok)
        return 0;
    printf("RESULT %.0f\n", result);
    fflush(stdout);
    return 1;
}

static void signal_ready(struct state *state) {
    pthread_mutex_lock(&state->mutex);
    state->ready = 1;
    state->complete = 1;
    pthread_cond_broadcast(&state->changed);
    pthread_mutex_unlock(&state->mutex);
    printf("READY %u\n", (unsigned)state->port);
    fflush(stdout);
}

static void signal_complete(struct state *state, int failed) {
    pthread_mutex_lock(&state->mutex);
    if (failed)
        state->failed = 1;
    state->complete = 1;
    pthread_cond_broadcast(&state->changed);
    pthread_mutex_unlock(&state->mutex);
}

static void *owner_main(void *opaque) {
    struct state *state = opaque;
    if (!start_engine(state)) {
        pthread_mutex_lock(&state->mutex);
        state->failed = 1;
        state->ready = 1;
        pthread_cond_broadcast(&state->changed);
        pthread_mutex_unlock(&state->mutex);
        return NULL;
    }
    signal_ready(state);
    for (;;) {
        if (jsbay_engine_run_loop(state->instance_id) != JSBAY_OK) {
            signal_complete(state, 1);
            break;
        }
        pthread_mutex_lock(&state->mutex);
        const enum command command = state->command;
        state->command = COMMAND_NONE;
        pthread_mutex_unlock(&state->mutex);
        if (command == COMMAND_QUIT)
            break;
        int failed = 0;
        if (command == COMMAND_RUN) {
            failed = !run_frame(state);
        } else if (command == COMMAND_GC) {
            if (!jsbay_engine_run_gc(state->instance_id))
                failed = 1;
            else {
                puts("GC");
                fflush(stdout);
            }
        } else if (command == COMMAND_RESET) {
            stop_engine(state);
            if (!start_engine(state)) {
                signal_complete(state, 1);
                break;
            }
            signal_ready(state);
            continue;
        }
        signal_complete(state, failed);
        if (failed)
            break;
    }
    stop_engine(state);
    return NULL;
}

int main(void) {
    struct state state;
    pthread_t owner;
    pthread_attr_t attributes;
    char line[32];
    memset(&state, 0, sizeof(state));
    state.instance_id = 744002;
    pthread_mutex_init(&state.mutex, NULL);
    pthread_cond_init(&state.changed, NULL);
    if (pthread_attr_init(&attributes) != 0)
        return 2;
    if (pthread_attr_setstacksize(&attributes, OWNER_STACK_BYTES) != 0)
        return 2;
    if (pthread_create(&owner, &attributes, owner_main, &state) != 0)
        return 2;
    pthread_attr_destroy(&attributes);
    pthread_mutex_lock(&state.mutex);
    while (!state.ready)
        pthread_cond_wait(&state.changed, &state.mutex);
    const int initial_failed = state.failed;
    pthread_mutex_unlock(&state.mutex);
    if (initial_failed) {
        pthread_join(owner, NULL);
        return 2;
    }
    while (fgets(line, sizeof(line), stdin)) {
        const enum command command = strcmp(line, "RUN\n") == 0     ? COMMAND_RUN
                                     : strcmp(line, "GC\n") == 0    ? COMMAND_GC
                                     : strcmp(line, "RESET\n") == 0 ? COMMAND_RESET
                                     : strcmp(line, "QUIT\n") == 0  ? COMMAND_QUIT
                                                                    : COMMAND_NONE;
        if (command == COMMAND_NONE)
            continue;
        pthread_mutex_lock(&state.mutex);
        state.command = command;
        state.complete = 0;
        pthread_mutex_unlock(&state.mutex);
        if (!jsbay_engine_stop_loop(state.instance_id))
            break;
        if (command == COMMAND_QUIT)
            break;
        pthread_mutex_lock(&state.mutex);
        while (!state.complete && !state.failed)
            pthread_cond_wait(&state.changed, &state.mutex);
        const int failed = state.failed;
        pthread_mutex_unlock(&state.mutex);
        if (failed)
            break;
    }
    pthread_mutex_lock(&state.mutex);
    state.command = COMMAND_QUIT;
    pthread_mutex_unlock(&state.mutex);
    jsbay_engine_stop_loop(state.instance_id);
    pthread_join(owner, NULL);
    pthread_cond_destroy(&state.changed);
    pthread_mutex_destroy(&state.mutex);
    return state.failed ? 2 : 0;
}
