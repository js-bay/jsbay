#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef void (*jsbay_loop_task)(void *);

struct jsbay_apple_run_loop;

struct jsbay_apple_timer_ticket {
    struct jsbay_apple_run_loop *loop;
    uint64_t generation;
};

struct jsbay_apple_run_loop {
    pthread_mutex_t mutex;
    CFRunLoopRef run_loop;
    CFRunLoopSourceRef source;
    CFRunLoopTimerRef timer;
    jsbay_loop_task task;
    void *task_data;
    CFAbsoluteTime deadline;
    uint64_t generation;
    bool stopped;
    bool failed;
};

static void jsbay_apple_timer_ticket_release(const void *info) {
    free((void *)info);
}

static void jsbay_apple_timer_fire(CFRunLoopTimerRef timer, void *info) {
    struct jsbay_apple_timer_ticket *ticket = info;
    struct jsbay_apple_run_loop *loop = ticket->loop;
    jsbay_loop_task task = NULL;
    void *task_data = NULL;
    bool owns_timer = false;

    pthread_mutex_lock(&loop->mutex);
    if (loop->timer == timer) {
        loop->timer = NULL;
        owns_timer = true;
        if (!loop->stopped && loop->generation == ticket->generation) {
            task = loop->task;
            task_data = loop->task_data;
            loop->task = NULL;
            loop->task_data = NULL;
        }
    }
    pthread_mutex_unlock(&loop->mutex);

    if (owns_timer) {
        CFRunLoopTimerInvalidate(timer);
        CFRelease(timer);
    }
    if (task)
        task(task_data);
}

static void jsbay_apple_source_perform(void *info) {
    struct jsbay_apple_run_loop *loop = info;
    struct jsbay_apple_timer_ticket *ticket = NULL;
    CFRunLoopTimerRef timer = NULL;

    pthread_mutex_lock(&loop->mutex);
    if (loop->timer) {
        CFRunLoopTimerInvalidate(loop->timer);
        CFRelease(loop->timer);
        loop->timer = NULL;
    }
    if (loop->stopped || !loop->task) {
        pthread_mutex_unlock(&loop->mutex);
        return;
    }

    ticket = malloc(sizeof(*ticket));
    if (!ticket) {
        loop->failed = true;
        loop->stopped = true;
        pthread_mutex_unlock(&loop->mutex);
        CFRunLoopStop(loop->run_loop);
        return;
    }
    ticket->loop = loop;
    ticket->generation = loop->generation;
    CFRunLoopTimerContext context = {
        .version = 0,
        .info = ticket,
        .retain = NULL,
        .release = jsbay_apple_timer_ticket_release,
        .copyDescription = NULL,
    };
    timer = CFRunLoopTimerCreate(kCFAllocatorDefault, loop->deadline, 0, 0, 0,
                                 jsbay_apple_timer_fire, &context);
    if (!timer) {
        free(ticket);
        loop->failed = true;
        loop->stopped = true;
        pthread_mutex_unlock(&loop->mutex);
        CFRunLoopStop(loop->run_loop);
        return;
    }
    loop->timer = timer;
    CFRunLoopAddTimer(loop->run_loop, timer, kCFRunLoopCommonModes);
    pthread_mutex_unlock(&loop->mutex);
}

struct jsbay_apple_run_loop *jsbay_apple_run_loop_create(void) {
    struct jsbay_apple_run_loop *loop = calloc(1, sizeof(*loop));
    if (!loop)
        return NULL;
    if (pthread_mutex_init(&loop->mutex, NULL) != 0) {
        free(loop);
        return NULL;
    }
    loop->run_loop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
    CFRunLoopSourceContext context = {
        .version = 0,
        .info = loop,
        .retain = NULL,
        .release = NULL,
        .copyDescription = NULL,
        .equal = NULL,
        .hash = NULL,
        .schedule = NULL,
        .cancel = NULL,
        .perform = jsbay_apple_source_perform,
    };
    loop->source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
    if (!loop->source) {
        CFRelease(loop->run_loop);
        pthread_mutex_destroy(&loop->mutex);
        free(loop);
        return NULL;
    }
    CFRunLoopAddSource(loop->run_loop, loop->source, kCFRunLoopCommonModes);
    return loop;
}

bool jsbay_apple_run_loop_schedule(struct jsbay_apple_run_loop *loop, uint64_t delay_ms,
                                   jsbay_loop_task task, void *task_data) {
    if (!loop || !task)
        return false;
    pthread_mutex_lock(&loop->mutex);
    if (loop->stopped || loop->failed) {
        pthread_mutex_unlock(&loop->mutex);
        return false;
    }
    loop->generation += 1;
    loop->deadline = CFAbsoluteTimeGetCurrent() + ((CFTimeInterval)delay_ms / 1000.0);
    loop->task = task;
    loop->task_data = task_data;
    pthread_mutex_unlock(&loop->mutex);
    CFRunLoopSourceSignal(loop->source);
    CFRunLoopWakeUp(loop->run_loop);
    return true;
}

void jsbay_apple_run_loop_cancel(struct jsbay_apple_run_loop *loop) {
    if (!loop)
        return;
    pthread_mutex_lock(&loop->mutex);
    loop->generation += 1;
    loop->task = NULL;
    loop->task_data = NULL;
    pthread_mutex_unlock(&loop->mutex);
    CFRunLoopSourceSignal(loop->source);
    CFRunLoopWakeUp(loop->run_loop);
}

bool jsbay_apple_run_loop_run(struct jsbay_apple_run_loop *loop) {
    if (!loop)
        return false;
    CFRunLoopRun();
    pthread_mutex_lock(&loop->mutex);
    const bool ok = loop->stopped && !loop->failed;
    pthread_mutex_unlock(&loop->mutex);
    return ok;
}

void jsbay_apple_run_loop_stop(struct jsbay_apple_run_loop *loop) {
    if (!loop)
        return;
    pthread_mutex_lock(&loop->mutex);
    loop->stopped = true;
    loop->generation += 1;
    loop->task = NULL;
    loop->task_data = NULL;
    if (loop->timer) {
        CFRunLoopTimerInvalidate(loop->timer);
        CFRelease(loop->timer);
        loop->timer = NULL;
    }
    pthread_mutex_unlock(&loop->mutex);
    CFRunLoopStop(loop->run_loop);
}

void jsbay_apple_run_loop_destroy(struct jsbay_apple_run_loop *loop) {
    if (!loop)
        return;
    jsbay_apple_run_loop_stop(loop);
    CFRunLoopRemoveSource(loop->run_loop, loop->source, kCFRunLoopCommonModes);
    CFRelease(loop->source);
    CFRelease(loop->run_loop);
    pthread_mutex_destroy(&loop->mutex);
    free(loop);
}

#ifdef JSBAY_APPLE_RUN_LOOP_TEST
struct jsbay_apple_run_loop_cancel_test {
    struct jsbay_apple_run_loop *loop;
    CFRunLoopObserverRef observer;
    bool cancel_issued;
    bool cancelled_task_fired;
};

static void jsbay_apple_run_loop_external_stop_task(void *context) {
    struct jsbay_apple_run_loop *loop = context;
    CFRunLoopStop(loop->run_loop);
}

static void jsbay_apple_run_loop_cancelled_task(void *context) {
    struct jsbay_apple_run_loop_cancel_test *test = context;
    test->cancelled_task_fired = true;
}

static void jsbay_apple_run_loop_cancel_observer(CFRunLoopObserverRef observer,
                                                 CFRunLoopActivity activity, void *context) {
    (void)observer;
    if (activity != kCFRunLoopBeforeWaiting)
        return;
    struct jsbay_apple_run_loop_cancel_test *test = context;
    if (test->cancel_issued)
        return;
    test->cancel_issued = true;
    jsbay_apple_run_loop_cancel(test->loop);
}

static void jsbay_apple_run_loop_cancel_test_stop(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    jsbay_apple_run_loop_stop(context);
}

bool jsbay_apple_run_loop_test_external_stop_fails(struct jsbay_apple_run_loop *loop) {
    if (!jsbay_apple_run_loop_schedule(loop, 0, jsbay_apple_run_loop_external_stop_task, loop))
        return false;
    return !jsbay_apple_run_loop_run(loop);
}

bool jsbay_apple_run_loop_test_cancel_armed_timer(struct jsbay_apple_run_loop *loop) {
    struct jsbay_apple_run_loop_cancel_test test = {.loop = loop};
    CFRunLoopObserverContext observer_context = {
        .version = 0,
        .info = &test,
        .retain = NULL,
        .release = NULL,
        .copyDescription = NULL,
    };
    test.observer =
        CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 0,
                                jsbay_apple_run_loop_cancel_observer, &observer_context);
    if (!test.observer)
        return false;
    CFRunLoopAddObserver(loop->run_loop, test.observer, kCFRunLoopCommonModes);

    CFRunLoopTimerContext timer_context = {
        .version = 0,
        .info = loop,
        .retain = NULL,
        .release = NULL,
        .copyDescription = NULL,
    };
    CFRunLoopTimerRef stop_timer =
        CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.05, 0, 0, 0,
                             jsbay_apple_run_loop_cancel_test_stop, &timer_context);
    if (!stop_timer) {
        CFRunLoopRemoveObserver(loop->run_loop, test.observer, kCFRunLoopCommonModes);
        CFRelease(test.observer);
        return false;
    }
    CFRunLoopAddTimer(loop->run_loop, stop_timer, kCFRunLoopCommonModes);
    CFRelease(stop_timer);

    const bool scheduled =
        jsbay_apple_run_loop_schedule(loop, 20, jsbay_apple_run_loop_cancelled_task, &test);
    const bool ran = scheduled && jsbay_apple_run_loop_run(loop);
    CFRunLoopRemoveObserver(loop->run_loop, test.observer, kCFRunLoopCommonModes);
    CFRelease(test.observer);
    return ran && test.cancel_issued && !test.cancelled_task_fired;
}
#endif
