#include "jsbay.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define WARMUP 100u
#define ITERATIONS 1000u
#define PAYLOAD_BYTES 4096u
#define TEXT(value) ((jsbay_utf8_t){(const uint8_t *)(value), sizeof(value) - 1u})

static uint64_t now_ns(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0)
        return 0;
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

static int release_value(jsbay_value_t value) {
    return value != 0 && jsbay_value_release(value) != JSBAY_OK;
}

static jsbay_status_t add_one(int instance_id, void *user_data, jsbay_value_t self, size_t argc,
                               const jsbay_value_t *args, jsbay_value_t *out_value,
                               jsbay_value_t *out_exception) {
    (void)user_data;
    (void)self;
    (void)argc;
    (void)args;
    *out_exception = 0;
    return jsbay_value_new_number(instance_id, 42, out_value);
}

static int eval_number(int id, const char *source) {
    jsbay_value_t value = 0, exception = 0;
    double number = 0;
    jsbay_status_t status =
        jsbay_engine_evaluate(id, (jsbay_utf8_t){(const uint8_t *)source, strlen(source)},
                               TEXT("interop.js"), NULL, &value, &exception);
    if (status != JSBAY_OK || jsbay_value_to_number(value, &number) != JSBAY_OK ||
        number != 42) {
        (void)release_value(value);
        (void)release_value(exception);
        return 1;
    }
    return release_value(value);
}

static int text_json(int id) {
    jsbay_value_t value = 0, exception = 0;
    jsbay_bytes_t bytes = {0};
    const char expected[] = "{\"text\":\"public interop\",\"count\":42}";
    const int failed =
        jsbay_engine_evaluate(id, TEXT("({text:'public interop', count:42})"),
                               TEXT("text-json.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_to_json(value, &bytes, &exception) != JSBAY_OK ||
        bytes.len != sizeof(expected) - 1u ||
        memcmp(bytes.data, expected, sizeof(expected) - 1u) != 0;
    jsbay_free_bytes(bytes);
    if (release_value(value) || release_value(exception))
        return 1;
    return failed;
}

static int buffer_copy(int id, const uint8_t *input) {
    jsbay_value_t value = 0, exception = 0;
    jsbay_bytes_t bytes = {0};
    const int failed =
        jsbay_value_new_array_buffer(id, input, PAYLOAD_BYTES, &value) != JSBAY_OK ||
        jsbay_value_copy_buffer(value, &bytes, &exception) != JSBAY_OK ||
        bytes.len != PAYLOAD_BYTES || memcmp(bytes.data, input, PAYLOAD_BYTES) != 0;
    jsbay_free_bytes(bytes);
    if (release_value(value) || release_value(exception))
        return 1;
    return failed;
}

static uint64_t measure_eval(int id) {
    for (unsigned i = 0; i < WARMUP; ++i)
        if (eval_number(id, "var n=0; for(var i=0;i<64;i++)n+=i; 42") != 0)
            return 0;
    uint64_t start = now_ns();
    for (unsigned i = 0; i < ITERATIONS; ++i)
        if (eval_number(id, "var n=0; for(var i=0;i<64;i++)n+=i; 42") != 0)
            return 0;
    return now_ns() - start;
}

static uint64_t measure_callback(int id) {
    for (unsigned i = 0; i < WARMUP; ++i)
        if (eval_number(id, "benchCallback()") != 0)
            return 0;
    uint64_t start = now_ns();
    for (unsigned i = 0; i < ITERATIONS; ++i)
        if (eval_number(id, "benchCallback()") != 0)
            return 0;
    return now_ns() - start;
}

static uint64_t measure_text_json(int id) {
    for (unsigned i = 0; i < WARMUP; ++i)
        if (text_json(id) != 0)
            return 0;
    uint64_t start = now_ns();
    for (unsigned i = 0; i < ITERATIONS; ++i)
        if (text_json(id) != 0)
            return 0;
    return now_ns() - start;
}

static uint64_t measure_buffer(int id) {
    uint8_t input[PAYLOAD_BYTES];
    memset(input, 7, sizeof(input));
    for (unsigned i = 0; i < WARMUP; ++i)
        if (buffer_copy(id, input) != 0)
            return 0;
    uint64_t start = now_ns();
    for (unsigned i = 0; i < ITERATIONS; ++i)
        if (buffer_copy(id, input) != 0)
            return 0;
    return now_ns() - start;
}

static uint64_t measure_lifecycle(void) {
    for (unsigned i = 0; i < WARMUP; ++i) {
        const int id = 900000 + (int)i;
        if (!jsbay_engine_create(id, NULL, NULL) || eval_number(id, "42") != 0)
            return 0;
        jsbay_engine_destroy(id);
    }
    uint64_t start = now_ns();
    for (unsigned i = 0; i < 100; ++i) {
        const int id = 900100 + (int)i;
        if (!jsbay_engine_create(id, NULL, NULL) || eval_number(id, "42") != 0)
            return 0;
        jsbay_engine_destroy(id);
    }
    return now_ns() - start;
}

int main(void) {
    const int id = 899999;
    jsbay_value_t function = 0, exception = 0;
    if (!jsbay_engine_create(id, NULL, NULL) ||
        jsbay_engine_bind(id, TEXT("benchCallback"), add_one, NULL, NULL, &function, &exception) !=
            JSBAY_OK ||
        release_value(function))
        return 2;
    const uint64_t eval = measure_eval(id);
    const uint64_t callback = measure_callback(id);
    const uint64_t text_json = measure_text_json(id);
    const uint64_t buffer = measure_buffer(id);
    jsbay_engine_destroy(id);
    const uint64_t lifecycle = measure_lifecycle();
    if (!eval || !callback || !text_json || !buffer || !lifecycle) {
        fprintf(stderr,
                "benchmark operation failed: eval=%llu callback=%llu text_json=%llu buffer=%llu "
                "lifecycle=%llu\\n",
                (unsigned long long)eval, (unsigned long long)callback,
                (unsigned long long)text_json, (unsigned long long)buffer,
                (unsigned long long)lifecycle);
        return 2;
    }
    printf("%llu %llu %llu %llu %llu\n", (unsigned long long)eval, (unsigned long long)callback,
           (unsigned long long)text_json, (unsigned long long)buffer,
           (unsigned long long)lifecycle);
    return 0;
}
