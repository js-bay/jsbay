#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

#include "jsbay.h"

/* This is an external-C regression consumer.  It deliberately uses only the public header and requires a fixed C ABI, rather than reaching into Zig test helpers. */

static jsbay_utf8_t utf8(const char *text, size_t length) {
    jsbay_utf8_t value = { (const uint8_t *)text, length };
    return value;
}

#define JSBAY_TEXT(text) utf8((text), sizeof(text) - 1)
#define FAIL() do { fprintf(stderr, "Value contract failed at line %d\n", __LINE__); goto done; } while (0)

static int number_is(jsbay_value_t value, double expected) {
    double actual = 0;
    return jsbay_value_to_number(value, &actual) == JSBAY_OK && actual == expected;
}

static int strict_this(int id, int mode) {
    jsbay_value_t fn = 0, receiver = 0, result = 0, exception = 0;
    bool matches = false;
    jsbay_utf8_t source = mode == 0 ? JSBAY_TEXT("(function(){'use strict';return this===undefined})")
        : mode == 1 ? JSBAY_TEXT("(function(){'use strict';return this===null})")
        : JSBAY_TEXT("(function(){'use strict';return this===5})");
    int failed = 1;
    if (jsbay_engine_evaluate(id, source, JSBAY_TEXT("strict-this.js"), NULL, &fn, &exception) != JSBAY_OK) goto cleanup;
    /* The JSC path must use the intrinsic captured during context creation, not a mutable global Function.prototype.apply. */
    if (mode == 0 &&
        (jsbay_engine_evaluate(id, JSBAY_TEXT("Function.prototype.apply=function(){throw 99}"),
                                JSBAY_TEXT("mutate-apply.js"), NULL, &result, &exception) != JSBAY_OK ||
         jsbay_value_release(result) != JSBAY_OK)) goto cleanup;
    result = 0;
    jsbay_status_t status = mode == 0 ? jsbay_value_undefined(id, &receiver)
        : mode == 1 ? jsbay_value_null(id, &receiver)
        : jsbay_value_new_number(id, 5, &receiver);
    if (status != JSBAY_OK) goto cleanup;
    if (jsbay_value_call(fn, receiver, NULL, 0, &result, &exception) != JSBAY_OK) goto cleanup;
    if (jsbay_value_to_bool(result, &matches) != JSBAY_OK || !matches) goto cleanup;
    failed = 0;
cleanup:
    if (exception) (void)jsbay_value_release(exception);
    if (result) (void)jsbay_value_release(result);
    if (receiver) (void)jsbay_value_release(receiver);
    if (fn) (void)jsbay_value_release(fn);
    return failed;
}

static jsbay_status_t release_target(
    int instance_id, void *user_data, jsbay_value_t this_value,
    size_t argc, const jsbay_value_t *args, jsbay_value_t *out_value,
    jsbay_value_t *out_exception) {
    jsbay_value_t *target = (jsbay_value_t *)user_data;
    (void)this_value;
    (void)argc;
    (void)args;
    *out_exception = 0;
    if (*target != 0 && jsbay_value_release(*target) == JSBAY_OK) {
        *target = 0;
        return jsbay_value_undefined(instance_id, out_value);
    }
    return JSBAY_INVALID_ARGUMENT;
}

static jsbay_status_t return_undefined(
    int instance_id, void *user_data, jsbay_value_t this_value,
    size_t argc, const jsbay_value_t *args, jsbay_value_t *out_value,
    jsbay_value_t *out_exception) {
    (void)user_data;
    (void)this_value;
    (void)argc;
    (void)args;
    *out_exception = 0;
    return jsbay_value_undefined(instance_id, out_value);
}

static jsbay_status_t throw_undefined(
    int instance_id, void *user_data, jsbay_value_t this_value,
    size_t argc, const jsbay_value_t *args, jsbay_value_t *out_value,
    jsbay_value_t *out_exception) {
    (void)user_data;
    (void)this_value;
    (void)argc;
    (void)args;
    *out_value = 0;
    if (jsbay_value_undefined(instance_id, out_exception) != JSBAY_OK) return JSBAY_INVALID_ARGUMENT;
    return JSBAY_EXCEPTION;
}

static jsbay_status_t destroy_new_status = JSBAY_INVALID_ARGUMENT;
static jsbay_status_t bind_stub(int id, void *u, jsbay_value_t t, size_t n, const jsbay_value_t *a, jsbay_value_t *v, jsbay_value_t *e) {
    (void)u; (void)t; (void)n; (void)a; *e = 0; return jsbay_value_undefined(id, v);
}
static int failed_bind_finalized = 0;
static void bind_finalize(void *u) { (void)u; failed_bind_finalized++; }


static jsbay_status_t destroy_in_callback(
    int instance_id, void *user_data, jsbay_value_t this_value,
    size_t argc, const jsbay_value_t *args, jsbay_value_t *out_value,
    jsbay_value_t *out_exception) {
    (void)user_data;
    (void)this_value;
    (void)argc;
    (void)args;
    *out_value = 0;
    *out_exception = 0;
    jsbay_engine_destroy(instance_id);
    jsbay_value_t after_destroy = 77;
    destroy_new_status = jsbay_value_new_number(instance_id, 1, &after_destroy);
    if (after_destroy != 0) destroy_new_status = JSBAY_INVALID_ARGUMENT;
    return JSBAY_INVALID_ARGUMENT;
}

int main(void) {
    const int id = 713;
    jsbay_value_t exception = 0;
    jsbay_value_t global = 0;
    jsbay_value_t receiver = 0;
    jsbay_value_t function = 0;
    jsbay_value_t argument = 0;
    jsbay_value_t this_value = 0;
    jsbay_value_t value = 0;
    jsbay_value_t target = 0;
    jsbay_bytes_t bytes = { 0, 0 };
    int result = 1;

    if (!jsbay_engine_create(id, NULL, NULL)) FAIL();
    /* A throwing global setter preserves its original throw and does not transfer failed-bind userdata/finalization ownership. */
    if (jsbay_engine_evaluate(id, JSBAY_TEXT("Object.defineProperty(globalThis,'__jsbay_bind_fail',{set(){throw 42},configurable:true})"), JSBAY_TEXT("bind-setter.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_release(value) != JSBAY_OK ||
        jsbay_engine_bind(id, JSBAY_TEXT("__jsbay_bind_fail"), bind_stub, NULL, bind_finalize, &value, &exception) != JSBAY_EXCEPTION ||
        value != 0 || exception == 0 || !number_is(exception, 42) || failed_bind_finalized != 0)
        FAIL();
    if (jsbay_value_release(exception) != JSBAY_OK) FAIL();
    exception = value = 0;

    /* Construction must define an own, non-enumerable data property. An inherited setter must neither run nor leave a pending QuickJS throw. */
    if (jsbay_engine_evaluate(id,
                               JSBAY_TEXT("Object.defineProperty(Error.prototype,'message',{set(){throw 17},configurable:true})"),
                               JSBAY_TEXT("poison-error-message.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_release(value) != JSBAY_OK ||
        jsbay_value_new_error(id, JSBAY_TEXT("m"), &value) != JSBAY_OK ||
        jsbay_engine_global(id, &global) != JSBAY_OK ||
        jsbay_value_set(global, JSBAY_TEXT("createdError"), value, &exception) != JSBAY_OK ||
        jsbay_value_release(value) != JSBAY_OK || jsbay_value_release(global) != JSBAY_OK ||
        jsbay_engine_evaluate(id,
                               JSBAY_TEXT("createdError.message === 'm' && !Object.prototype.propertyIsEnumerable.call(createdError,'message')"),
                               JSBAY_TEXT("check-error-message.js"), NULL, &value, &exception) != JSBAY_OK)
        FAIL();
    { bool ok = false; if (jsbay_value_to_bool(value, &ok) != JSBAY_OK || !ok) FAIL(); }
    if (jsbay_value_release(value) != JSBAY_OK ||
        jsbay_engine_evaluate(id, JSBAY_TEXT("40+2"), JSBAY_TEXT("error-recovery.js"), NULL, &value, &exception) != JSBAY_OK ||
        !number_is(value, 42) || jsbay_value_release(value) != JSBAY_OK)
        FAIL();
    value = global = 0;

    /* Source, filename and binding names have one scalar UTF-8 contract and clear outputs before rejecting malformed input. */
    {
        static const uint8_t invalid_utf8[] = { 0xff };
        jsbay_utf8_t invalid = { invalid_utf8, sizeof(invalid_utf8) };
        value = 123; exception = 456;
        if (jsbay_engine_evaluate(id, invalid, JSBAY_TEXT("valid.js"), NULL, &value, &exception) != JSBAY_INVALID_ARGUMENT || value != 0 || exception != 0)
            FAIL();
        value = 123; exception = 456;
        if (jsbay_engine_evaluate(id, JSBAY_TEXT("1"), invalid, NULL, &value, &exception) != JSBAY_INVALID_ARGUMENT || value != 0 || exception != 0)
            FAIL();
        value = 123; exception = 456;
        if (jsbay_engine_bind(id, invalid, bind_stub, NULL, bind_finalize, &value, &exception) != JSBAY_INVALID_ARGUMENT || value != 0 || exception != 0 || failed_bind_finalized != 0)
            FAIL();
    }

    for (int mode = 0; mode < 3; ++mode) if (strict_this(id, mode) != 0) FAIL();

    /* Undefined/null use internal JSC sentinels. Every C boundary must retain their JavaScript identity rather than forwarding a raw null pointer. */
    if (jsbay_engine_bind(id, JSBAY_TEXT("returnUndefined"), return_undefined,
                           NULL, NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_release(value) != JSBAY_OK ||
        jsbay_engine_bind(id, JSBAY_TEXT("throwUndefined"), throw_undefined,
                           NULL, NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_release(value) != JSBAY_OK)
        FAIL();
    value = 0;
    if (jsbay_engine_evaluate(id, JSBAY_TEXT("returnUndefined() === undefined"),
                               JSBAY_TEXT("undefined-return.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_to_bool(value, &(bool){false}) != JSBAY_OK)
        FAIL();
    { bool is_undefined = false; if (jsbay_value_to_bool(value, &is_undefined) != JSBAY_OK || !is_undefined) FAIL(); }
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_engine_evaluate(id, JSBAY_TEXT("(()=>{try{throwUndefined();return false}catch(e){return e===undefined}})()"),
                               JSBAY_TEXT("undefined-throw.js"), NULL, &value, &exception) != JSBAY_OK)
        FAIL();
    { bool is_undefined = false; if (jsbay_value_to_bool(value, &is_undefined) != JSBAY_OK || !is_undefined) FAIL(); }
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_engine_global(id, &global) != JSBAY_OK ||
        jsbay_value_undefined(id, &value) != JSBAY_OK ||
        jsbay_value_set(global, JSBAY_TEXT("abiUndefined"), value, &exception) != JSBAY_OK ||
        jsbay_value_release(value) != JSBAY_OK ||
        jsbay_engine_evaluate(id, JSBAY_TEXT("abiUndefined === undefined"), JSBAY_TEXT("undefined-set.js"), NULL, &value, &exception) != JSBAY_OK)
        FAIL();
    { bool is_undefined = false; if (jsbay_value_to_bool(value, &is_undefined) != JSBAY_OK || !is_undefined) FAIL(); }
    if (jsbay_value_release(value) != JSBAY_OK || jsbay_value_release(global) != JSBAY_OK) FAIL();
    value = global = 0;
    if (jsbay_value_undefined(id, &value) != JSBAY_OK ||
        jsbay_value_to_utf8(value, &bytes, &exception) != JSBAY_OK || bytes.len != 9 ||
        memcmp(bytes.data, "undefined", 9) != 0 || exception != 0)
        FAIL();
    jsbay_free_bytes(bytes); bytes.data = NULL; bytes.len = 0;
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_value_null(id, &value) != JSBAY_OK ||
        jsbay_value_to_utf8(value, &bytes, &exception) != JSBAY_OK || bytes.len != 4 ||
        memcmp(bytes.data, "null", 4) != 0 || exception != 0)
        FAIL();
    jsbay_free_bytes(bytes); bytes.data = NULL; bytes.len = 0;
    if (jsbay_value_to_json(value, &bytes, &exception) != JSBAY_OK || bytes.len != 4 ||
        memcmp(bytes.data, "null", 4) != 0 || exception != 0)
        FAIL();
    jsbay_free_bytes(bytes); bytes.data = NULL; bytes.len = 0;
    if (jsbay_value_get(value, JSBAY_TEXT("x"), &target, &exception) != JSBAY_EXCEPTION || target != 0 || exception == 0)
        FAIL();
    if (jsbay_value_release(exception) != JSBAY_OK || jsbay_value_release(value) != JSBAY_OK) FAIL();
    exception = value = 0;

    /* Public UTF-8 is scalar-value UTF-8: unpaired UTF-16 halves become U+FFFD, while a valid emoji pair and embedded NUL retain their bytes. */
    if (jsbay_engine_evaluate(id, JSBAY_TEXT("String.fromCharCode(0xD800)"), JSBAY_TEXT("lone-high.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_to_utf8(value, &bytes, &exception) != JSBAY_OK || bytes.len != 3 ||
        bytes.data[0] != 0xEF || bytes.data[1] != 0xBF || bytes.data[2] != 0xBD)
        FAIL();
    jsbay_free_bytes(bytes); bytes.data = NULL; bytes.len = 0;
    if (jsbay_value_release(value) != JSBAY_OK ||
        jsbay_engine_evaluate(id, JSBAY_TEXT("String.fromCharCode(0xDC00)"), JSBAY_TEXT("lone-low.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_to_utf8(value, &bytes, &exception) != JSBAY_OK || bytes.len != 3 ||
        bytes.data[0] != 0xEF || bytes.data[1] != 0xBF || bytes.data[2] != 0xBD)
        FAIL();
    jsbay_free_bytes(bytes); bytes.data = NULL; bytes.len = 0;
    if (jsbay_value_release(value) != JSBAY_OK ||
        jsbay_engine_evaluate(id, JSBAY_TEXT("String.fromCodePoint(0x1F600)"), JSBAY_TEXT("emoji.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_to_utf8(value, &bytes, &exception) != JSBAY_OK || bytes.len != 4 ||
        bytes.data[0] != 0xF0 || bytes.data[1] != 0x9F || bytes.data[2] != 0x98 || bytes.data[3] != 0x80)
        FAIL();
    jsbay_free_bytes(bytes); bytes.data = NULL; bytes.len = 0;
    if (jsbay_value_release(value) != JSBAY_OK ||
        jsbay_engine_evaluate(id, JSBAY_TEXT("'a\\u0000b'"), JSBAY_TEXT("nul.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_to_utf8(value, &bytes, &exception) != JSBAY_OK || bytes.len != 3 ||
        bytes.data[0] != 'a' || bytes.data[1] != 0 || bytes.data[2] != 'b')
        FAIL();
    jsbay_free_bytes(bytes); bytes.data = NULL; bytes.len = 0;
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;

    /* ToObject behavior and call failures have the same status on all engines. */
    if (jsbay_value_new_string(id, JSBAY_TEXT("abc"), &value) != JSBAY_OK ||
        jsbay_value_get(value, JSBAY_TEXT("length"), &target, &exception) != JSBAY_OK || !number_is(target, 3) ||
        jsbay_value_release(target) != JSBAY_OK || jsbay_value_release(value) != JSBAY_OK ||
        jsbay_value_undefined(id, &value) != JSBAY_OK ||
        jsbay_value_set(value, JSBAY_TEXT("x"), value, &exception) != JSBAY_EXCEPTION || exception == 0)
        FAIL();
    if (jsbay_value_release(exception) != JSBAY_OK || jsbay_value_release(value) != JSBAY_OK ||
        jsbay_value_new_number(id, 1, &value) != JSBAY_OK ||
        jsbay_value_undefined(id, &this_value) != JSBAY_OK ||
        jsbay_value_call(value, this_value, NULL, 0, &target, &exception) != JSBAY_EXCEPTION || target != 0 || exception == 0)
        FAIL();
    if (jsbay_value_release(exception) != JSBAY_OK || jsbay_value_release(value) != JSBAY_OK ||
        jsbay_value_release(this_value) != JSBAY_OK) FAIL();
    exception = value = target = this_value = 0;
    if (jsbay_engine_bind(id, JSBAY_TEXT("releaseTarget"), release_target,
                           &target, NULL, &value, &exception) != JSBAY_OK)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;

    if (jsbay_engine_evaluate(id, JSBAY_TEXT("globalThis.jsonSymbol=Symbol('x')"),
                               JSBAY_TEXT("json-symbol.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_release(value) != JSBAY_OK ||
        jsbay_engine_global(id, &global) != JSBAY_OK ||
        jsbay_value_get(global, JSBAY_TEXT("jsonSymbol"), &value, &exception) != JSBAY_OK ||
        jsbay_value_to_json(value, &bytes, &exception) != JSBAY_INVALID_ARGUMENT ||
        bytes.data != NULL || bytes.len != 0 || exception != 0)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK || jsbay_value_release(global) != JSBAY_OK) FAIL();
    value = global = 0;

    /* A script may replace global JSON.  Typed JSON remains native and safe. */
    if (jsbay_engine_evaluate(id, JSBAY_TEXT("JSON=13"), JSBAY_TEXT("json-mutate.js"),
                               NULL, &value, &exception) != JSBAY_OK)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_value_new_json(id, JSBAY_TEXT("{\"ok\":true}"), &value, &exception) != JSBAY_OK)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;

    /* JSON.stringify has no top-level JSON text for undefined. */
    if (jsbay_value_undefined(id, &value) != JSBAY_OK) FAIL();
    if (jsbay_value_to_json(value, &bytes, &exception) != JSBAY_INVALID_ARGUMENT ||
        bytes.data != NULL || bytes.len != 0 || exception != 0)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;

    /* toJSON may itself erase the top-level representation. Those results follow the same INVALID/empty contract as a direct undefined/function/ symbol input; a throw remains the original thrown Value. */
    if (jsbay_engine_evaluate(id,
                               JSBAY_TEXT("globalThis.jsonToUndefined={toJSON(){return undefined}};"
                                           "globalThis.jsonToFunction={toJSON(){return function(){}}};"
                                           "globalThis.jsonToSymbol={toJSON(){return Symbol('x')}};"
                                           "globalThis.jsonThrow={toJSON(){throw 7}};"
                                           "globalThis.jsonCycle={};jsonCycle.self=jsonCycle"),
                               JSBAY_TEXT("json-top-level.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_release(value) != JSBAY_OK || jsbay_engine_global(id, &global) != JSBAY_OK)
        FAIL();
    value = 0;
    if (jsbay_value_get(global, JSBAY_TEXT("jsonToUndefined"), &value, &exception) != JSBAY_OK ||
        jsbay_value_to_json(value, &bytes, &exception) != JSBAY_INVALID_ARGUMENT || bytes.data != NULL || bytes.len != 0 || exception != 0)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_value_get(global, JSBAY_TEXT("jsonToFunction"), &value, &exception) != JSBAY_OK ||
        jsbay_value_to_json(value, &bytes, &exception) != JSBAY_INVALID_ARGUMENT || bytes.data != NULL || bytes.len != 0 || exception != 0)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_value_get(global, JSBAY_TEXT("jsonToSymbol"), &value, &exception) != JSBAY_OK ||
        jsbay_value_to_json(value, &bytes, &exception) != JSBAY_INVALID_ARGUMENT || bytes.data != NULL || bytes.len != 0 || exception != 0)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_value_get(global, JSBAY_TEXT("jsonThrow"), &value, &exception) != JSBAY_OK ||
        jsbay_value_to_json(value, &bytes, &exception) != JSBAY_EXCEPTION || exception == 0 || !number_is(exception, 7))
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK || jsbay_value_release(exception) != JSBAY_OK) FAIL();
    value = exception = 0;
    if (jsbay_value_get(global, JSBAY_TEXT("jsonCycle"), &value, &exception) != JSBAY_OK ||
        jsbay_value_to_json(value, &bytes, &exception) != JSBAY_EXCEPTION || exception == 0)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK || jsbay_value_release(exception) != JSBAY_OK ||
        jsbay_value_release(global) != JSBAY_OK)
        FAIL();
    value = exception = global = 0;

    if (jsbay_engine_global(id, &global) != JSBAY_OK) FAIL();
    /* These values have no global property retaining them.  The callback's release is therefore the last public reference while the operation is still executing. */
    if (jsbay_engine_evaluate(id, JSBAY_TEXT("({get x(){releaseTarget();return 42}})"),
                               JSBAY_TEXT("pin-receiver.js"), NULL, &receiver, &exception) != JSBAY_OK)
        FAIL();

    /* A getter releases the only public receiver reference while get is live. */
    target = receiver;
    receiver = 0;
    if (jsbay_value_get(target, JSBAY_TEXT("x"), &value, &exception) != JSBAY_OK ||
        !number_is(value, 42))
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;

    if (jsbay_engine_evaluate(id, JSBAY_TEXT("(function(a){releaseTarget();return a+1})"),
                               JSBAY_TEXT("pin-function.js"), NULL, &function, &exception) != JSBAY_OK ||
        jsbay_value_new_number(id, 2, &argument) != JSBAY_OK ||
        jsbay_value_undefined(id, &this_value) != JSBAY_OK)
        FAIL();
    /* A call releases the function itself while the backend call is active. */
    target = function;
    function = 0;
    if (jsbay_value_call(target, this_value, &argument, 1, &value, &exception) != JSBAY_OK ||
        !number_is(value, 3))
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_value_release(argument) != JSBAY_OK ||
        jsbay_value_release(this_value) != JSBAY_OK)
        FAIL();
    argument = this_value = 0;

    if (jsbay_engine_evaluate(id, JSBAY_TEXT("(function(a){releaseTarget();return a+1})"),
                               JSBAY_TEXT("pin-argument.js"), NULL, &function, &exception) != JSBAY_OK ||
        jsbay_value_new_number(id, 2, &argument) != JSBAY_OK ||
        jsbay_value_undefined(id, &this_value) != JSBAY_OK)
        FAIL();
    /* A call releases its only public argument reference while still using it. */
    target = argument;
    argument = 0;
    if (jsbay_value_call(function, this_value, &target, 1, &value, &exception) != JSBAY_OK ||
        !number_is(value, 3))
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK ||
        jsbay_value_release(function) != JSBAY_OK ||
        jsbay_value_release(this_value) != JSBAY_OK)
        FAIL();
    value = function = this_value = 0;

    if (jsbay_engine_evaluate(id, JSBAY_TEXT("(function(){releaseTarget();return 7})"),
                               JSBAY_TEXT("pin-this.js"), NULL, &function, &exception) != JSBAY_OK ||
        jsbay_value_new_object(id, &this_value) != JSBAY_OK)
        FAIL();
    /* A call releases its receiver while the backend still needs it as this. */
    target = this_value;
    this_value = 0;
    if (jsbay_value_call(function, target, NULL, 0, &value, &exception) != JSBAY_OK ||
        !number_is(value, 7))
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK ||
        jsbay_value_release(function) != JSBAY_OK)
        FAIL();
    value = function = 0;

    /* A call preserves its return value, then drains its queued microtask. */
    if (jsbay_engine_evaluate(id,
                               JSBAY_TEXT("globalThis.m=0;globalThis.micro=()=>{queueMicrotask(()=>m=1);return m}"),
                               JSBAY_TEXT("micro.js"), NULL, &value, &exception) != JSBAY_OK)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_value_get(global, JSBAY_TEXT("micro"), &function, &exception) != JSBAY_OK ||
        jsbay_value_undefined(id, &this_value) != JSBAY_OK)
        FAIL();
    if (jsbay_value_call(function, this_value, NULL, 0, &value, &exception) != JSBAY_OK ||
        !number_is(value, 0))
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK ||
        jsbay_value_release(function) != JSBAY_OK ||
        jsbay_value_release(this_value) != JSBAY_OK)
        FAIL();
    value = function = this_value = 0;
    if (jsbay_value_get(global, JSBAY_TEXT("m"), &value, &exception) != JSBAY_OK ||
        !number_is(value, 1))
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;

    {
        uint8_t input[] = { 1, 2, 3, 4 };
        if (jsbay_value_new_array_buffer(id, input, sizeof(input), &value) != JSBAY_OK) FAIL();
        input[0] = 9;
        if (jsbay_value_copy_buffer(value, &bytes, &exception) != JSBAY_OK || bytes.len != 4 ||
            bytes.data[0] != 1 || bytes.data[1] != 2 || bytes.data[2] != 3 || bytes.data[3] != 4)
            FAIL();
        jsbay_free_bytes(bytes);
        bytes.data = NULL; bytes.len = 0;
        if (jsbay_value_release(value) != JSBAY_OK) FAIL();
        value = 0;
    }

    if (jsbay_engine_evaluate(
            id, JSBAY_TEXT("globalThis.binaryView=new Uint8Array([9,1,2,3]).subarray(1,3);"
                            "globalThis.binaryDataView=new DataView(new Uint8Array([8,4,5,6]).buffer,1,2)"),
            JSBAY_TEXT("binary-view.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_release(value) != JSBAY_OK)
        FAIL();
    value = 0;
    if (jsbay_value_get(global, JSBAY_TEXT("binaryView"), &value, &exception) != JSBAY_OK ||
        jsbay_value_copy_buffer(value, &bytes, &exception) != JSBAY_OK || bytes.len != 2 ||
        bytes.data[0] != 1 || bytes.data[1] != 2)
        FAIL();
    jsbay_free_bytes(bytes);
    bytes.data = NULL; bytes.len = 0;
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_value_get(global, JSBAY_TEXT("binaryDataView"), &value, &exception) != JSBAY_OK ||
        jsbay_value_copy_buffer(value, &bytes, &exception) != JSBAY_OK || bytes.len != 2 ||
        bytes.data[0] != 4 || bytes.data[1] != 5)
        FAIL();
    jsbay_free_bytes(bytes);
    bytes.data = NULL; bytes.len = 0;
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_value_new_array_buffer(id, NULL, 1, &value) != JSBAY_INVALID_ARGUMENT || value != 0)
        FAIL();
    if (jsbay_value_new_array_buffer(id, NULL, 0, &value) != JSBAY_OK ||
        jsbay_value_copy_buffer(value, &bytes, &exception) != JSBAY_OK || bytes.len != 0 || exception != 0)
        FAIL();
    jsbay_free_bytes(bytes);
    bytes.data = NULL; bytes.len = 0;
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_value_new_number(id, 1, &value) != JSBAY_OK ||
        jsbay_value_copy_buffer(value, &bytes, &exception) != JSBAY_INVALID_ARGUMENT ||
        bytes.data != NULL || bytes.len != 0 || exception != 0)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_engine_global(id, &global) != JSBAY_OK ||
        jsbay_engine_evaluate(id, JSBAY_TEXT("globalThis.binarySpoof={buffer:new ArrayBuffer(2),byteOffset:0,byteLength:2}"),
                               JSBAY_TEXT("binary-spoof.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_release(value) != JSBAY_OK ||
        jsbay_value_get(global, JSBAY_TEXT("binarySpoof"), &value, &exception) != JSBAY_OK ||
        jsbay_value_copy_buffer(value, &bytes, &exception) != JSBAY_INVALID_ARGUMENT ||
        bytes.data != NULL || bytes.len != 0 || exception != 0)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK || jsbay_value_release(global) != JSBAY_OK) FAIL();
    value = global = 0;

    /* Native array creation and kind detection do not consult global Array. */
    if (jsbay_engine_evaluate(id, JSBAY_TEXT("globalThis.savedNativeArray=[];globalThis.Array=13"),
                               JSBAY_TEXT("array-mutate.js"), NULL, &value, &exception) != JSBAY_OK ||
        jsbay_value_release(value) != JSBAY_OK || jsbay_value_new_array(id, &value) != JSBAY_OK)
        FAIL();
    { jsbay_value_kind_t kind; if (jsbay_value_type(value, &kind) != JSBAY_OK || kind != JSBAY_VALUE_ARRAY) FAIL(); }
    if (jsbay_value_release(value) != JSBAY_OK || jsbay_engine_global(id, &global) != JSBAY_OK ||
        jsbay_value_get(global, JSBAY_TEXT("savedNativeArray"), &value, &exception) != JSBAY_OK)
        FAIL();
    { jsbay_value_kind_t kind; if (jsbay_value_type(value, &kind) != JSBAY_OK || kind != JSBAY_VALUE_ARRAY) FAIL(); }
    if (jsbay_value_release(value) != JSBAY_OK || jsbay_value_release(global) != JSBAY_OK) FAIL();
    value = global = 0;

    /* A revoked Proxy makes classic QuickJS JS_IsArray return -1. value_type has no exception output, so it must use its stable object fallback and leave the following public call usable. */
    if (jsbay_engine_evaluate(id, JSBAY_TEXT("(()=>{let p=Proxy.revocable([],{});p.revoke();return p.proxy})()"),
                               JSBAY_TEXT("revoked-proxy.js"), NULL, &value, &exception) != JSBAY_OK)
        FAIL();
    { jsbay_value_kind_t kind; if (jsbay_value_type(value, &kind) != JSBAY_OK || kind != JSBAY_VALUE_OBJECT) FAIL(); }
    if (jsbay_value_release(value) != JSBAY_OK ||
        jsbay_engine_evaluate(id, JSBAY_TEXT("6*7"), JSBAY_TEXT("revoked-proxy-recovery.js"), NULL, &value, &exception) != JSBAY_OK ||
        !number_is(value, 42) || jsbay_value_release(value) != JSBAY_OK)
        FAIL();
    value = 0;

    /* Callable proxies remain functions; non-callable array proxies are deliberately opaque objects for a backend-independent native kind. */
    if (jsbay_engine_evaluate(id, JSBAY_TEXT("new Proxy(function(){}, {})"),
                               JSBAY_TEXT("callable-proxy.js"), NULL, &value, &exception) != JSBAY_OK)
        FAIL();
    { jsbay_value_kind_t kind; if (jsbay_value_type(value, &kind) != JSBAY_OK || kind != JSBAY_VALUE_FUNCTION) FAIL(); }
    if (jsbay_value_release(value) != JSBAY_OK ||
        jsbay_engine_evaluate(id, JSBAY_TEXT("new Proxy([], {})"), JSBAY_TEXT("array-proxy.js"), NULL, &value, &exception) != JSBAY_OK)
        FAIL();
    { jsbay_value_kind_t kind; if (jsbay_value_type(value, &kind) != JSBAY_OK || kind != JSBAY_VALUE_OBJECT) FAIL(); }
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;

    if (jsbay_engine_bind(id, JSBAY_TEXT("destroyNow"), destroy_in_callback,
                           NULL, NULL, &value, &exception) != JSBAY_OK)
        FAIL();
    if (jsbay_value_release(value) != JSBAY_OK) FAIL();
    value = 0;
    if (jsbay_engine_evaluate(id, JSBAY_TEXT("destroyNow()"), JSBAY_TEXT("destroy.js"),
                               NULL, &value, &exception) != JSBAY_INSTANCE_NOT_FOUND ||
        value != 0 || exception != 0 || destroy_new_status != JSBAY_INSTANCE_NOT_FOUND)
        FAIL();
    result = 0;

done:
    if (bytes.data != NULL) jsbay_free_bytes(bytes);
    if (exception != 0) (void)jsbay_value_release(exception);
    if (value != 0) (void)jsbay_value_release(value);
    if (this_value != 0) (void)jsbay_value_release(this_value);
    if (argument != 0) (void)jsbay_value_release(argument);
    if (function != 0) (void)jsbay_value_release(function);
    if (receiver != 0) (void)jsbay_value_release(receiver);
    if (target != 0) (void)jsbay_value_release(target);
    if (global != 0) (void)jsbay_value_release(global);
    jsbay_engine_destroy(id);
    return result;
}
