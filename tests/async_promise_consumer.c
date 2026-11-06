/* Native Promise settlement through the installed public C interface. */
#include "jsbay_async.h"

#define TEXT(value) ((jsbay_utf8_t){(const uint8_t *)(value), sizeof(value) - 1})

int main(void) {
    const int instance_id = 1;
    uint64_t request = 0;
    jsbay_value_t promise = 0, exception = 0, global = 0, result = 0, number = 0;
    double observed = 0;
    int status = 1;
    if (!jsbay_engine_create(instance_id, NULL, NULL))
        return status;
    if (jsbay_promise_create(instance_id, &request, &promise, &exception) != JSBAY_OK ||
        request == 0 || promise == 0 || exception != 0)
        goto done;
    if (jsbay_engine_global(instance_id, &global) != JSBAY_OK)
        goto done;
    if (jsbay_value_set(global, TEXT("nativePromise"), promise, &exception) != JSBAY_OK)
        goto done;
    if (jsbay_engine_evaluate(instance_id,
                              TEXT("globalThis.observed = 0; nativePromise.then(value => { "
                                   "observed = value; }); void 0"),
                              TEXT("promise.js"), NULL, &result, &exception) != JSBAY_OK)
        goto done;
    jsbay_value_release(result);
    result = 0;
    if (jsbay_value_new_number(instance_id, 42, &number) != JSBAY_OK)
        goto done;
    if (jsbay_promise_settle(request, JSBAY_OK, number) != JSBAY_OK)
        goto done;
    if (jsbay_promise_settle(request, JSBAY_OK, number) != JSBAY_STALE_VALUE)
        goto done;
    if (jsbay_engine_evaluate(instance_id, TEXT("observed"), TEXT("promise.js"), NULL, &result,
                              &exception) != JSBAY_OK)
        goto done;
    if (jsbay_value_to_number(result, &observed) != JSBAY_OK || observed != 42)
        goto done;
    status = 0;
done:
    if (number)
        jsbay_value_release(number);
    if (result)
        jsbay_value_release(result);
    if (exception)
        jsbay_value_release(exception);
    if (global)
        jsbay_value_release(global);
    if (promise)
        jsbay_value_release(promise);
    jsbay_engine_destroy(instance_id);
    return status;
}
