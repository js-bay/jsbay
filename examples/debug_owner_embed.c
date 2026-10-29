/*
 * Pauseable DevTools embed: engine on a dedicated owner thread (C ABI).
 *
 * Owner thread: create → inspector_start → (optional prime) → run_loop →
 *               inspector_stop → destroy.
 * Main / host client thread: print the inspect URL, then only stop_loop
 * (and wait for the owner to finish). Treat Node.js / UI main as this
 * client — never as the pauseable engine owner.
 *
 * jsbay_engine_attach_loop on a Node.js (or similar) main thread plus
 * blocking Debugger.pause / debugger; deadlocks: pause holds the owner
 * while the host loop that would deliver resume CDP cannot run.
 *
 * Usage:
 *   zig build -Dbackend=quickjs_ng   # installs zig-out/bin/debug-owner-embed-*
 *   zig build debug-owner-embed -Dbackend=quickjs_ng -- --port 9229
 *   zig build debug-owner-embed-test -Dbackend=quickjs_ng
 *
 * Prefer -Dbackend=quickjs_ng when Sources / breakpoints matter; plain
 * quickjs advertises no Debugger domain. --port 0 binds an ephemeral port.
 */

#include "jsbay.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TEXT(value) ((jsbay_utf8_t){(const uint8_t *)(value), sizeof(value) - 1})

typedef struct {
    int instance_id;
    uint16_t port_request;
    uint16_t port_bound;
    bool self_test;
    bool create_ok;
    bool inspector_ok;
    bool primed;
    jsbay_status_t loop_status;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    bool ready;
    bool failed_before_loop;
} owner_ctx_t;

static void log_handler(int instance_id, jsbay_log_level_t level, const char *message, void *user_data) {
    (void)user_data;
    const char *tag = "log";
    switch (level) {
        case JSBAY_LOG_DEBUG: tag = "debug"; break;
        case JSBAY_LOG_INFO: tag = "info"; break;
        case JSBAY_LOG_WARN: tag = "warn"; break;
        case JSBAY_LOG_ERROR: tag = "error"; break;
    }
    fprintf(stderr, "[js %d %s] %s\n", instance_id, tag, message ? message : "");
}

static void signal_ready(owner_ctx_t *ctx, bool failed_before_loop) {
    pthread_mutex_lock(&ctx->mu);
    ctx->failed_before_loop = failed_before_loop;
    ctx->ready = true;
    pthread_cond_signal(&ctx->cv);
    pthread_mutex_unlock(&ctx->mu);
}

static void wait_ready(owner_ctx_t *ctx) {
    pthread_mutex_lock(&ctx->mu);
    while (!ctx->ready) pthread_cond_wait(&ctx->cv, &ctx->mu);
    pthread_mutex_unlock(&ctx->mu);
}

static bool prime_heartbeat(int instance_id) {
    jsbay_value_t value = 0;
    jsbay_value_t exception = 0;
    const jsbay_status_t status = jsbay_engine_evaluate(
        instance_id,
        TEXT("setInterval(() => { console.log('heartbeat ' + Date.now()); }, 1000);"),
        TEXT("examples/debug_owner_embed.c"),
        NULL,
        &value,
        &exception);
    if (value) jsbay_value_release(value);
    if (exception) jsbay_value_release(exception);
    return status == JSBAY_OK;
}

static void *owner_main(void *arg) {
    owner_ctx_t *ctx = arg;

    ctx->create_ok = jsbay_engine_create(ctx->instance_id, ctx->self_test ? NULL : log_handler, NULL);
    if (!ctx->create_ok) {
        signal_ready(ctx, true);
        return NULL;
    }

    ctx->inspector_ok = jsbay_engine_inspector_start(ctx->instance_id, ctx->port_request, &ctx->port_bound);
    if (!ctx->inspector_ok) {
        jsbay_engine_destroy(ctx->instance_id);
        signal_ready(ctx, true);
        return NULL;
    }

    ctx->primed = prime_heartbeat(ctx->instance_id);
    signal_ready(ctx, false);

    /* Blocks until jsbay_engine_stop_loop from another thread (or a prior stop). */
    ctx->loop_status = jsbay_engine_run_loop(ctx->instance_id);

    jsbay_engine_inspector_stop(ctx->instance_id);
    jsbay_engine_destroy(ctx->instance_id);
    return NULL;
}

static void usage(const char *argv0) {
    fprintf(stderr,
            "Usage: %s [--port N] [--self-test]\n"
            "  Owner thread owns create/inspector/run_loop/destroy.\n"
            "  Main thread only calls stop_loop (client role).\n"
            "  --port 0 binds an ephemeral port (default under --self-test).\n"
            "  --self-test: stop shortly after READY; exit nonzero on failure.\n",
            argv0);
}

int main(int argc, char **argv) {
    owner_ctx_t ctx;
    memset(&ctx, 0, sizeof ctx);
    ctx.instance_id = 9042;
    ctx.port_request = 9229;
    bool port_set = false;
    ctx.loop_status = JSBAY_LOOP_FAILED;
    pthread_mutex_init(&ctx.mu, NULL);
    pthread_cond_init(&ctx.cv, NULL);

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--port")) {
            if (i + 1 >= argc) {
                usage(argv[0]);
                return 2;
            }
            char *end = NULL;
            long port = strtol(argv[++i], &end, 10);
            if (!end || *end || port < 0 || port > 65535) {
                fprintf(stderr, "invalid --port (use 0 for ephemeral)\n");
                return 2;
            }
            ctx.port_request = (uint16_t)port;
            port_set = true;
        } else if (!strcmp(argv[i], "--self-test")) {
            ctx.self_test = true;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (ctx.self_test && !port_set) ctx.port_request = 0;

    setvbuf(stdout, NULL, _IONBF, 0);

    pthread_t owner;
    if (pthread_create(&owner, NULL, owner_main, &ctx) != 0) {
        fprintf(stderr, "pthread_create failed\n");
        return 1;
    }

    wait_ready(&ctx);
    if (ctx.failed_before_loop) {
        fprintf(stderr, "owner failed before run_loop (create=%d inspector=%d)\n",
                (int)ctx.create_ok, (int)ctx.inspector_ok);
        pthread_join(owner, NULL);
        pthread_mutex_destroy(&ctx.mu);
        pthread_cond_destroy(&ctx.cv);
        return 1;
    }

    printf("READY %u\n", (unsigned)ctx.port_bound);
    printf("LOOP_OWNER_RUNNING\n");
    printf("inspector: chrome://inspect → Configure → localhost:%u\n", (unsigned)ctx.port_bound);
    printf("main thread is client-only; call stop_loop to end (Enter, or --self-test).\n");
    fflush(stdout);

    if (ctx.self_test) {
        /* Brief settle so listeners can bind; no CDP required for smoke. */
        usleep(150 * 1000);
        if (!jsbay_engine_stop_loop(ctx.instance_id)) {
            fprintf(stderr, "stop_loop failed\n");
            pthread_join(owner, NULL);
            pthread_mutex_destroy(&ctx.mu);
            pthread_cond_destroy(&ctx.cv);
            return 1;
        }
    } else {
        char line[8];
        if (!fgets(line, sizeof line, stdin)) {
            /* EOF: still stop cleanly. */
        }
        if (!jsbay_engine_stop_loop(ctx.instance_id)) {
            fprintf(stderr, "stop_loop failed\n");
            pthread_join(owner, NULL);
            pthread_mutex_destroy(&ctx.mu);
            pthread_cond_destroy(&ctx.cv);
            return 1;
        }
    }

    pthread_join(owner, NULL);
    pthread_mutex_destroy(&ctx.mu);
    pthread_cond_destroy(&ctx.cv);

    if (ctx.loop_status != JSBAY_OK) {
        fprintf(stderr, "run_loop status %d\n", (int)ctx.loop_status);
        return 1;
    }
    if (!ctx.primed) {
        fprintf(stderr, "prime evaluate failed\n");
        return 1;
    }

    puts("CLEAN_EXIT");
    return 0;
}
