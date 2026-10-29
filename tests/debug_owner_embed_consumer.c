/* Focused contract: engine create/inspector/run_loop/destroy stay on one owner
 * pthread; the launching thread only stop_loop. Compile like other C consumers
 * against an installed libjsbay.a, or use `zig build debug-owner-embed-test`. */
#include "jsbay.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    int id;
    uint16_t port;
    bool ready;
    bool failed;
    jsbay_status_t loop_status;
    pthread_mutex_t mu;
    pthread_cond_t cv;
} ctx_t;

static void signal_ready(ctx_t *ctx, bool failed) {
    pthread_mutex_lock(&ctx->mu);
    ctx->failed = failed;
    ctx->ready = true;
    pthread_cond_signal(&ctx->cv);
    pthread_mutex_unlock(&ctx->mu);
}

static void *owner(void *arg) {
    ctx_t *ctx = arg;
    if (!jsbay_engine_create(ctx->id, NULL, NULL)) {
        signal_ready(ctx, true);
        return NULL;
    }
    if (!jsbay_engine_inspector_start(ctx->id, 0, &ctx->port)) {
        jsbay_engine_destroy(ctx->id);
        signal_ready(ctx, true);
        return NULL;
    }
    signal_ready(ctx, false);
    ctx->loop_status = jsbay_engine_run_loop(ctx->id);
    jsbay_engine_inspector_stop(ctx->id);
    jsbay_engine_destroy(ctx->id);
    return NULL;
}

int main(void) {
    ctx_t ctx;
    memset(&ctx, 0, sizeof ctx);
    ctx.id = 9043;
    ctx.loop_status = JSBAY_LOOP_FAILED;
    pthread_mutex_init(&ctx.mu, NULL);
    pthread_cond_init(&ctx.cv, NULL);

    pthread_t thread;
    if (pthread_create(&thread, NULL, owner, &ctx)) return 1;

    pthread_mutex_lock(&ctx.mu);
    while (!ctx.ready) pthread_cond_wait(&ctx.cv, &ctx.mu);
    const bool failed = ctx.failed;
    const uint16_t port = ctx.port;
    pthread_mutex_unlock(&ctx.mu);

    if (failed || port == 0) {
        pthread_join(thread, NULL);
        return 2;
    }

    usleep(50 * 1000);
    if (!jsbay_engine_stop_loop(ctx.id)) {
        pthread_join(thread, NULL);
        return 3;
    }
    pthread_join(thread, NULL);
    pthread_mutex_destroy(&ctx.mu);
    pthread_cond_destroy(&ctx.cv);
    if (ctx.loop_status != JSBAY_OK) return 4;
    printf("PASS debug_owner_embed_consumer port=%u\n", (unsigned)port);
    return 0;
}
