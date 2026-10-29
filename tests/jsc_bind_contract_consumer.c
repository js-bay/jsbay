/* External typed-ABI regression probe for native bind publication semantics. */
#include "jsbay.h"
#include <stdio.h>
#include <string.h>

#define TEXT(s) ((jsbay_utf8_t){ (const uint8_t *)(s), sizeof(s) - 1 })
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); return 1; } } while (0)

static int finalized;
static int noop_calls;

typedef struct {
    double value;
    int finalized;
} callback_data_t;

static void finish(void *unused) {
    (void)unused;
    ++finalized;
}

static void finish_data(void *user_data) {
    callback_data_t *data = user_data;
    ++data->finalized;
}

static jsbay_status_t noop(int id, void *unused, jsbay_value_t receiver,
                            size_t argc, const jsbay_value_t *args,
                            jsbay_value_t *out_value, jsbay_value_t *out_exception) {
    (void)unused;
    (void)receiver;
    (void)argc;
    (void)args;
    ++noop_calls;
    *out_exception = 0;
    return jsbay_value_undefined(id, out_value);
}

static jsbay_status_t number_callback(int id, void *user_data, jsbay_value_t receiver,
                                       size_t argc, const jsbay_value_t *args,
                                       jsbay_value_t *out_value, jsbay_value_t *out_exception) {
    callback_data_t *data = user_data;
    (void)receiver;
    (void)argc;
    (void)args;
    *out_exception = 0;
    return jsbay_value_new_number(id, data->value, out_value);
}

static int eval_ok(int id, const char *source) {
    jsbay_value_t value = 0, exception = 0;
    const jsbay_utf8_t input = { (const uint8_t *)source, strlen(source) };
    const jsbay_status_t status = jsbay_engine_evaluate(id, input, TEXT("bind-contract.js"), NULL, &value, &exception);
    if (status != JSBAY_OK) return 0;
    return jsbay_value_release(value) == JSBAY_OK;
}

static int eval_number(int id, const char *source, double *out) {
    jsbay_value_t value = 0, exception = 0;
    const jsbay_utf8_t input = { (const uint8_t *)source, strlen(source) };
    if (jsbay_engine_evaluate(id, input, TEXT("bind-contract.js"), NULL, &value, &exception) != JSBAY_OK) return 0;
    const int ok = jsbay_value_to_number(value, out) == JSBAY_OK;
    return jsbay_value_release(value) == JSBAY_OK && ok;
}

static int throws_number(jsbay_value_t exception, double expected) {
    double actual = 0;
    return exception != 0 && jsbay_value_to_number(exception, &actual) == JSBAY_OK && actual == expected;
}

int main(void) {
    const int id = 941;
    jsbay_value_t function = 0, exception = 0;
    CHECK(jsbay_engine_create(id, NULL, NULL));

    CHECK(eval_ok(id, "Object.defineProperty(globalThis, 'blocked', { value: 1, writable: false, configurable: false });"));
    CHECK(jsbay_engine_bind(id, TEXT("blocked"), noop, NULL, finish, &function, &exception) == JSBAY_EXCEPTION);
    CHECK(function == 0 && exception != 0 && finalized == 0);
    CHECK(jsbay_value_release(exception) == JSBAY_OK);

    function = exception = 0;
    noop_calls = 0;
    CHECK(eval_ok(id, "Object.defineProperty(globalThis, 'setter42', { set(_) { globalThis.savedSetter = _; throw 42; }, configurable: true });"));
    CHECK(jsbay_engine_bind(id, TEXT("setter42"), noop, NULL, finish, &function, &exception) == JSBAY_EXCEPTION);
    CHECK(function == 0 && throws_number(exception, 42) && finalized == 0);
    CHECK(jsbay_value_release(exception) == JSBAY_OK);
    double rejected = 0;
    CHECK(eval_number(id, "try { savedSetter(); 0; } catch (_) { 1; }", &rejected));
    CHECK(rejected == 1 && noop_calls == 0);

    function = exception = 0;
    CHECK(eval_ok(id, "Object.defineProperty(globalThis, 'getter42', { set(_) {}, get() { throw 42; }, configurable: true });"));
    CHECK(jsbay_engine_bind(id, TEXT("getter42"), noop, NULL, finish, &function, &exception) == JSBAY_EXCEPTION);
    CHECK(function == 0 && throws_number(exception, 42) && finalized == 0);
    CHECK(jsbay_value_release(exception) == JSBAY_OK);

    callback_data_t old_callback = { .value = 41, .finalized = 0 };
    callback_data_t new_callback = { .value = 42, .finalized = 0 };
    function = exception = 0;
    CHECK(jsbay_engine_bind(id, TEXT("published"), number_callback, &old_callback, finish_data, &function, &exception) == JSBAY_OK);
    CHECK(function != 0 && exception == 0);
    CHECK(jsbay_value_release(function) == JSBAY_OK);
    CHECK(eval_ok(id, "globalThis.savedPublished = published; delete globalThis.published;"));
    function = exception = 0;
    CHECK(jsbay_engine_bind(id, TEXT("published"), number_callback, &new_callback, finish_data, &function, &exception) == JSBAY_OK);
    CHECK(function != 0 && exception == 0);
    CHECK(jsbay_value_release(function) == JSBAY_OK);
    double old_value = 0, new_value = 0;
    CHECK(eval_number(id, "savedPublished()", &old_value));
    CHECK(eval_number(id, "published()", &new_value));
    CHECK(old_value == 41 && new_value == 42);

    function = exception = 0;
    CHECK(jsbay_engine_bind(id, TEXT("published"), noop, NULL, finish, &function, &exception) == JSBAY_OK);
    CHECK(function != 0 && exception == 0);
    CHECK(jsbay_value_release(function) == JSBAY_OK);
    jsbay_engine_destroy(id);
    CHECK(finalized == 1);
    CHECK(old_callback.finalized == 1 && new_callback.finalized == 1);
    return 0;
}
