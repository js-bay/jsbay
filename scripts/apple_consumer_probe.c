#include "jsbay.h"

#include <string.h>

int jsbay_apple_consumer_probe(void) {
    const int instance_id = 9173;
    jsbay_value_t error = 0;
    jsbay_value_t result = 0;
    const char source[] = "40 + 2";
    const char filename[] = "apple-consumer-probe.js";
    double answer = 0;
    int status = 0;

    if (!jsbay_engine_create(instance_id, NULL, NULL)) return 10;
    if (jsbay_engine_evaluate(instance_id,
            (jsbay_utf8_t){(const uint8_t *)source, sizeof(source) - 1},
            (jsbay_utf8_t){(const uint8_t *)filename, sizeof(filename) - 1},
            NULL, &result, &error) != JSBAY_OK || error ||
        jsbay_value_to_number(result, &answer) != JSBAY_OK || answer != 42) status = 11;
    if (result) jsbay_value_release(result);
    if (error) jsbay_value_release(error);
    jsbay_engine_destroy(instance_id);
    return status;
}

#ifndef JSBAY_APPLE_CONSUMER_NO_MAIN
int main(void) {
    return jsbay_apple_consumer_probe();
}
#endif
