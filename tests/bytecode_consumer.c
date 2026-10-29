/* External smoke for the documented typed expert bytecode interface. */
#include "jsbay.h"
#include "jsbay_bytecode.h"

#define TEXT(value) ((jsbay_utf8_t){(const uint8_t *)(value), sizeof(value) - 1})

int main(void) {
    const int instance_id = 3;
    jsbay_bytes_t bytecode = {NULL, 0};
    jsbay_value_t value = 0;
    jsbay_value_t exception = 0;
    double number = 0;
    int status = 1;

    if (!jsbay_engine_create(instance_id, NULL, NULL)) return status;
    int compile = jsbay_engine_compile_bytecode(instance_id, TEXT("40 + 2"), TEXT("bytecode-consumer.js"),
                                                  &bytecode, &exception);
    if (compile == JSBAY_UNSUPPORTED) {
        status = bytecode.data == NULL && exception == 0 ? 0 : status;
        goto done;
    }
    if (compile != JSBAY_OK || bytecode.data == NULL || exception != 0) goto done;
    if (jsbay_engine_run_bytecode(instance_id, bytecode.data, bytecode.len, &value, &exception) != JSBAY_OK ||
        value == 0 || exception != 0 || jsbay_value_to_number(value, &number) != JSBAY_OK || number != 42) goto done;
    status = 0;
done:
    jsbay_free_bytes(bytecode);
    if (value) jsbay_value_release(value);
    if (exception) jsbay_value_release(exception);
    jsbay_engine_destroy(instance_id);
    return status;
}
