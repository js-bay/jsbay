/* Independent public-header consumer for the synchronous native-call extension. */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include "jsbay.h"
#include "jsbay_sync.h"
#include <pthread.h>
#include <stdio.h>
#include <time.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); return 1; } } while (0)
#define TEXT(x) ((jsbay_utf8_t){(const uint8_t *)(x), sizeof(x) - 1})

struct state { uint64_t request; pthread_t thread; long long deadline_start_ms; int deadline_armed; };
static long long now_ms(void);
static void *complete(void *data) {
  struct state *state = (struct state *)data;
  if (jsbay_sync_complete(state->request, JSBAY_OK, JSBAY_SYNC_PAYLOAD_UTF8_STRING, TEXT("41")) != JSBAY_OK) return (void *)1;
  return NULL;
}
static void start(int id, void *data, uint64_t request, jsbay_value_t receiver, size_t argc, const jsbay_value_t *args) {
  (void)id; (void)receiver; (void)argc; (void)args;
  struct state *state = (struct state *)data; state->request = request;
  (void)pthread_create(&state->thread, NULL, complete, state);
}
static void start_short_deadline(int id, void *data, uint64_t request, jsbay_value_t receiver, size_t argc, const jsbay_value_t *args) {
  (void)request; (void)receiver; (void)argc; (void)args;
  struct state *state = (struct state *)data;
  state->deadline_start_ms = now_ms();
  state->deadline_armed = jsbay_engine_set_execution_time_limit(id, 5);
}
static long long now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
int main(void) {
  const int id = 8841;
  struct state state;
  jsbay_value_t fn = 0, value = 0, exception = 0;
  double number = 0;
  memset(&state, 0, sizeof(state));
  CHECK(jsbay_engine_create(id, NULL, NULL));
  CHECK(jsbay_engine_bind_sync(id, TEXT("nativeSync"), start, &state, NULL, 100, &fn, &exception) == JSBAY_OK);
  CHECK(jsbay_value_release(fn) == JSBAY_OK);
  CHECK(jsbay_engine_evaluate(id, TEXT("const wx={test:nativeSync}; const x=wx.test(); Number(x)+1"), TEXT("native-sync.js"), NULL, &value, &exception) == JSBAY_OK);
  CHECK(jsbay_value_to_number(value, &number) == JSBAY_OK && number == 42);
  CHECK(jsbay_value_release(value) == JSBAY_OK);
  void *completion_result = NULL;
  CHECK(pthread_join(state.thread, &completion_result) == 0 && completion_result == NULL);
  CHECK(jsbay_sync_complete(state.request, JSBAY_OK, JSBAY_SYNC_PAYLOAD_UTF8_STRING, TEXT("42")) == JSBAY_STALE_VALUE);
  CHECK(jsbay_engine_bind_sync(id, TEXT("deadlineSync"), start_short_deadline, &state, NULL, 80, &fn, &exception) == JSBAY_OK);
  CHECK(jsbay_value_release(fn) == JSBAY_OK);
  CHECK(jsbay_engine_evaluate(id, TEXT("deadlineSync()"), TEXT("native-sync.js"), NULL, &value, &exception) == JSBAY_EXCEPTION);
  CHECK(state.deadline_armed);
  const long long deadline_elapsed_ms = now_ms() - state.deadline_start_ms;
  if (deadline_elapsed_ms >= 50) fprintf(stderr, "native_sync_deadline_elapsed_ms=%lld\n", deadline_elapsed_ms);
  CHECK(deadline_elapsed_ms < 50);
  CHECK(jsbay_value_release(exception) == JSBAY_OK);
  CHECK(jsbay_engine_clear_interrupt(id));
  CHECK(jsbay_engine_set_execution_time_limit(id, 0));
  CHECK(jsbay_engine_evaluate(id, TEXT("6*7"), TEXT("native-sync.js"), NULL, &value, &exception) == JSBAY_OK);
  CHECK(jsbay_value_to_number(value, &number) == JSBAY_OK && number == 42);
  CHECK(jsbay_value_release(value) == JSBAY_OK);
  jsbay_engine_destroy(id);
  puts("JSBAY_NATIVE_SYNC_CONSUMER_PASS");
  return 0;
}
