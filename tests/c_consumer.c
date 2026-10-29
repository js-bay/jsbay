/* Thin external consumer of the normal typed public C API. */
#include "jsbay.h"

#include <string.h>

#define TEXT(value) ((jsbay_utf8_t){(const uint8_t *)(value), sizeof(value) - 1})

static int expect_short_options_rejected(int instance_id) {
    union {
        jsbay_engine_evaluate_options_t aligned;
        unsigned char bytes[sizeof(jsbay_engine_evaluate_options_t)];
    } short_options;
    unsigned char before[sizeof(short_options.bytes)];
    jsbay_value_t value = 99;
    jsbay_value_t exception = 98;

    memset(short_options.bytes, 0xa5, sizeof(short_options.bytes));
    ((uint32_t *)short_options.bytes)[0] = 0;
    memcpy(before, short_options.bytes, sizeof(before));
    if (jsbay_engine_evaluate(instance_id, TEXT("1"), TEXT("short-options.js"),
                               &short_options.aligned, &value, &exception) != JSBAY_INVALID_ARGUMENT ||
        value != 0 || exception != 0 ||
        memcmp(before, short_options.bytes, sizeof(before)) != 0) return 1;
    return 0;
}

static int expect_constructor_oom_clears_outputs(int instance_id) {
    jsbay_value_t value = 99;
    jsbay_value_t exception = 98;
    jsbay_value_t held[128];
    size_t held_count;
    int saw_oom;
    jsbay_status_t status;
    char source[] = "6 * 7";

    if (!jsbay_engine_set_memory_limit(instance_id, 1)) return 0; /* JSC has no public heap cap. */
    held_count = 0;
    saw_oom = 0;
    while (held_count < sizeof(held) / sizeof(held[0])) {
        value = 99;
        status = jsbay_value_new_string(instance_id, TEXT("allocation-must-fail"), &value);
        if (status == JSBAY_OK && value != 0) {
            held[held_count++] = value;
            continue;
        }
        if (status != JSBAY_OUT_OF_MEMORY || value != 0) return 1;
        saw_oom = 1;
        break;
    }
    while (held_count) jsbay_value_release(held[--held_count]);
    if (!saw_oom) return 1;

    held_count = 0;
    saw_oom = 0;
    while (held_count < sizeof(held) / sizeof(held[0])) {
        value = 99;
        status = jsbay_value_new_object(instance_id, &value);
        if (status == JSBAY_OK && value != 0) {
            held[held_count++] = value;
            continue;
        }
        if (status != JSBAY_OUT_OF_MEMORY || value != 0) return 1;
        saw_oom = 1;
        break;
    }
    while (held_count) jsbay_value_release(held[--held_count]);
    if (!saw_oom) return 1;

    held_count = 0;
    saw_oom = 0;
    while (held_count < sizeof(held) / sizeof(held[0])) {
        value = 99;
        status = jsbay_value_new_array(instance_id, &value);
        if (status == JSBAY_OK && value != 0) {
            held[held_count++] = value;
            continue;
        }
        if (status != JSBAY_OUT_OF_MEMORY || value != 0) return 1;
        saw_oom = 1;
        break;
    }
    while (held_count) jsbay_value_release(held[--held_count]);
    if (!saw_oom) return 1;
    if (!jsbay_engine_set_memory_limit(instance_id, 0)) return 1;
    if (jsbay_engine_evaluate(instance_id, (jsbay_utf8_t){(const uint8_t *)source, sizeof(source) - 1},
                               TEXT("after-constructor-oom.js"), NULL, &value, &exception) != JSBAY_OK || value == 0 || exception != 0) return 1;
    if (jsbay_value_release(value) != JSBAY_OK) return 1;
    return 0;
}

int main(void) {
    const int instance_id = 1;
    jsbay_value_t value = 0;
    jsbay_value_t exception = 0;
    double number = 0;
    int result = 1;

    if (!jsbay_engine_create(instance_id, NULL, NULL)) return result;
    if (expect_short_options_rejected(instance_id) != 0) goto done;
    if (expect_constructor_oom_clears_outputs(instance_id) != 0) goto done;
    if (jsbay_engine_evaluate(instance_id, TEXT("40 + 2"), TEXT("consumer.js"), NULL,
                               &value, &exception) != JSBAY_OK ||
        jsbay_value_to_number(value, &number) != JSBAY_OK || number != 42) goto done;
    result = 0;
done:
    if (value) jsbay_value_release(value);
    if (exception) jsbay_value_release(exception);
    jsbay_engine_destroy(instance_id);
    return result;
}
