/* Independent consumer of the public contract: no backend or private headers. */
#include "jsbay.h"
#include <stdio.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); return 1; } } while (0)
#define TEXT(text) ((jsbay_utf8_t){(const uint8_t *)(text), sizeof(text) - 1})

static jsbay_status_t stop_loop(int id, void *user, jsbay_value_t receiver,
    size_t argc, const jsbay_value_t *args, jsbay_value_t *out, jsbay_value_t *exception) {
    (void)user; (void)receiver; (void)argc; (void)args; (void)exception;
    if (!jsbay_engine_stop_loop(id)) return JSBAY_INVALID_ARGUMENT;
    return jsbay_value_undefined(id, out);
}

static jsbay_value_t captured_borrow = 0;
static jsbay_value_t captured_owned = 0;
static int finalized_bindings = 0;
static jsbay_value_t foreign_value = 0;

static jsbay_status_t return_foreign(int id, void *user, jsbay_value_t receiver,
                                     size_t argc, const jsbay_value_t *args,
                                     jsbay_value_t *out, jsbay_value_t *exception) {
    (void)id; (void)user; (void)receiver; (void)argc; (void)args; (void)exception;
    return jsbay_value_retain(foreign_value, out);
}

struct CloseProbe { int in_callback; int finalized; int early; };
static void close_finalized(void *data) {
    struct CloseProbe *probe = data;
    probe->early += probe->in_callback;
    ++probe->finalized;
}
static jsbay_status_t close_from_callback(int id, void *user, jsbay_value_t receiver,
                                          size_t argc, const jsbay_value_t *args,
                                          jsbay_value_t *out, jsbay_value_t *exception) {
    (void)receiver; (void)argc; (void)args; (void)exception;
    struct CloseProbe *probe = user;
    jsbay_status_t status = jsbay_value_undefined(id, out);
    if (status != JSBAY_OK) return status;
    probe->in_callback = 1;
    jsbay_engine_destroy(id);
    probe->early += probe->finalized;
    probe->in_callback = 0;
    return JSBAY_OK;
}

static void finalized(void *user) {
    ++*(int *)user;
}

static jsbay_status_t echo(int id, void *user, jsbay_value_t receiver,
                            size_t argc, const jsbay_value_t *args,
                            jsbay_value_t *out, jsbay_value_t *exception) {
    (void)id; (void)user; (void)receiver; (void)exception;
    if (argc != 1) return JSBAY_INVALID_ARGUMENT;
    captured_borrow = args[0];
    jsbay_status_t status = jsbay_value_retain(args[0], &captured_owned);
    if (status != JSBAY_OK) return status;
    return jsbay_value_retain(args[0], out);
}

static jsbay_status_t throw_number(int id, void *user, jsbay_value_t receiver,
                                    size_t argc, const jsbay_value_t *args,
                                    jsbay_value_t *out, jsbay_value_t *exception) {
    (void)user; (void)receiver; (void)argc; (void)args; (void)out;
    jsbay_status_t status = jsbay_value_new_number(id, 7, exception);
    return status == JSBAY_OK ? JSBAY_EXCEPTION : status;
}

/* True when the Value's JSON text equals `expected`; always frees the bytes. */
static int json_equals(jsbay_value_t value, const char *expected) {
    jsbay_bytes_t bytes = {NULL, 0};
    jsbay_value_t exception = 0;
    if (jsbay_value_to_json(value, &bytes, &exception) != JSBAY_OK) return 0;
    int equal = bytes.len == strlen(expected) && memcmp(bytes.data, expected, bytes.len) == 0;
    jsbay_free_bytes(bytes);
    return equal;
}

static int check_id(int id) {
    jsbay_value_t value = 0, exception = 0, duplicate = 0;
    jsbay_value_kind_t kind;
    CHECK(jsbay_engine_create(id, NULL, NULL));
    CHECK(!jsbay_engine_create(id, NULL, NULL));
    CHECK(jsbay_engine_evaluate(id, TEXT("undefined"), TEXT("id.js"), NULL, &value, &exception) == JSBAY_OK);
    CHECK(value != 0 && exception == 0);
    CHECK(jsbay_value_type(value, &kind) == JSBAY_OK && kind == JSBAY_VALUE_UNDEFINED);
    CHECK(jsbay_value_retain(value, &duplicate) == JSBAY_OK && duplicate != value);
    CHECK(jsbay_value_release(value) == JSBAY_OK);
    CHECK(jsbay_value_release(value) == JSBAY_STALE_VALUE);
    CHECK(jsbay_value_type(duplicate, &kind) == JSBAY_OK);
    jsbay_engine_destroy(id);
    CHECK(jsbay_engine_create(id, NULL, NULL));
    CHECK(jsbay_value_type(duplicate, &kind) == JSBAY_STALE_VALUE);
    jsbay_engine_destroy(id);
    return 0;
}

int main(void) {
    CHECK(check_id(0) == 0);
    CHECK(check_id(-17) == 0);
    const int id = 73941;
    jsbay_value_t value = 0, exception = 0, fn = 0, item = 0;
    jsbay_value_kind_t kind;
    jsbay_bytes_t bytes = {NULL, 0};
    double number = 0;
    bool boolean = false;
    CHECK(jsbay_engine_create(id, NULL, NULL));
    CHECK(jsbay_engine_bind(id, TEXT("stopLoop"), stop_loop, NULL, NULL, &fn, &exception) == JSBAY_OK);
    CHECK(jsbay_value_release(fn) == JSBAY_OK);
    CHECK(jsbay_engine_bind(id, TEXT("nativeEcho"), echo, &finalized_bindings, finalized, &fn, &exception) == JSBAY_OK);
    CHECK(jsbay_value_release(fn) == JSBAY_OK);
    CHECK(jsbay_engine_bind(id, TEXT("nativeThrow"), throw_number, &finalized_bindings, finalized, &fn, &exception) == JSBAY_OK);
    CHECK(jsbay_value_release(fn) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id,
        TEXT("globalThis.obj = {run(){return 42}}; nativeEcho(obj) === obj"),
        TEXT("identity.js"), NULL, &value, &exception) == JSBAY_OK);
    CHECK(jsbay_value_to_bool(value, &boolean) == JSBAY_OK && boolean);
    CHECK(jsbay_value_release(value) == JSBAY_OK);
    CHECK(jsbay_value_type(captured_borrow, &kind) == JSBAY_STALE_VALUE);
    CHECK(jsbay_value_type(captured_owned, &kind) == JSBAY_OK && kind == JSBAY_VALUE_OBJECT);
    CHECK(jsbay_value_get(captured_owned, TEXT("run"), &fn, &exception) == JSBAY_OK);
    CHECK(jsbay_value_type(fn, &kind) == JSBAY_OK && kind == JSBAY_VALUE_FUNCTION);
    CHECK(jsbay_value_call(fn, captured_owned, NULL, 0, &value, &exception) == JSBAY_OK);
    CHECK(jsbay_value_to_number(value, &number) == JSBAY_OK && number == 42);
    CHECK(jsbay_value_release(value) == JSBAY_OK);
    CHECK(jsbay_value_release(fn) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id, TEXT("nativeThrow()"), TEXT("throw.js"), NULL, &value, &exception) == JSBAY_EXCEPTION);
    CHECK(value == 0 && exception != 0);
    CHECK(jsbay_value_to_number(exception, &number) == JSBAY_OK && number == 7);
    CHECK(jsbay_value_release(exception) == JSBAY_OK);
    CHECK(jsbay_engine_bind(id, TEXT("nativeEcho"), echo, &finalized_bindings, finalized, &fn, &exception) == JSBAY_OK);
    CHECK(jsbay_value_release(fn) == JSBAY_OK);
    CHECK(finalized_bindings == 0);

    /* Symbol and BigInt report their own kinds; the numeric values are ABI and the original eight keep their positions. */
    CHECK(JSBAY_VALUE_FUNCTION == 7 && JSBAY_VALUE_SYMBOL == 8 && JSBAY_VALUE_BIGINT == 9);
    CHECK(jsbay_engine_evaluate(id, TEXT("Symbol('kind')"), TEXT("symbol-kind.js"), NULL, &value, &exception) == JSBAY_OK);
    CHECK(jsbay_value_type(value, &kind) == JSBAY_OK && kind == JSBAY_VALUE_SYMBOL);
    CHECK(jsbay_value_release(value) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id, TEXT("123456789012345678901234567890n"), TEXT("bigint-kind.js"), NULL, &value, &exception) == JSBAY_OK);
    CHECK(jsbay_value_type(value, &kind) == JSBAY_OK && kind == JSBAY_VALUE_BIGINT);
    CHECK(jsbay_value_release(value) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id, TEXT("Object(Symbol('boxed'))"), TEXT("boxed-kind.js"), NULL, &value, &exception) == JSBAY_OK);
    CHECK(jsbay_value_type(value, &kind) == JSBAY_OK && kind == JSBAY_VALUE_OBJECT);
    CHECK(jsbay_value_release(value) == JSBAY_OK);

    /* Object operations: construct, has, delete, keys and instanceof. */
    jsbay_value_t klass = 0, instance = 0, subject = 0, arg_value = 0;
    CHECK(jsbay_engine_evaluate(id,
        TEXT("globalThis.Point = class Point { constructor(x) { if (x < 0) throw 'negative'; this.x = x; } };"
             "const proto = { inherited: 1 };"
             "const subject = Object.create(proto);"
             "subject[2] = 'b'; subject[1] = 'a'; subject.z = 1; subject.y = 2;"
             "Object.defineProperty(subject, 'hidden', { value: 1, enumerable: false });"
             "Object.defineProperty(subject, 'fixed', { value: 1, enumerable: true, configurable: false });"
             "subject[Symbol('s')] = 3;"
             "globalThis.subject = subject; Point"),
        TEXT("object-ops-setup.js"), NULL, &klass, &exception) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id, TEXT("subject"), TEXT("object-ops-subject.js"), NULL, &subject, &exception) == JSBAY_OK);

    CHECK(jsbay_value_new_number(id, 7, &arg_value) == JSBAY_OK);
    CHECK(jsbay_value_construct(klass, &arg_value, 1, &instance, &exception) == JSBAY_OK);
    CHECK(exception == 0 && json_equals(instance, "{\"x\":7}"));
    CHECK(jsbay_value_instance_of(instance, klass, &boolean, &exception) == JSBAY_OK && boolean && exception == 0);
    CHECK(jsbay_value_instance_of(subject, klass, &boolean, &exception) == JSBAY_OK && !boolean);
    CHECK(jsbay_value_release(instance) == JSBAY_OK);
    CHECK(jsbay_value_release(arg_value) == JSBAY_OK);

    /* A throwing constructor and a non-constructor both report through out_exception. */
    CHECK(jsbay_value_new_number(id, -1, &arg_value) == JSBAY_OK);
    CHECK(jsbay_value_construct(klass, &arg_value, 1, &instance, &exception) == JSBAY_EXCEPTION);
    CHECK(instance == 0 && exception != 0 && json_equals(exception, "\"negative\""));
    CHECK(jsbay_value_release(exception) == JSBAY_OK);
    CHECK(jsbay_value_release(arg_value) == JSBAY_OK);
    CHECK(jsbay_value_construct(klass, NULL, 1, &instance, &exception) == JSBAY_INVALID_ARGUMENT);
    CHECK(instance == 0 && exception == 0);
    CHECK(jsbay_value_get(subject, TEXT("hasOwnProperty"), &fn, &exception) == JSBAY_OK);
    CHECK(jsbay_value_construct(fn, NULL, 0, &instance, &exception) == JSBAY_EXCEPTION);
    CHECK(instance == 0 && exception != 0);
    CHECK(jsbay_value_release(exception) == JSBAY_OK);
    CHECK(jsbay_value_release(fn) == JSBAY_OK);

    /* has follows the prototype chain; a primitive is a TypeError, not false. */
    CHECK(jsbay_value_has(subject, TEXT("y"), &boolean, &exception) == JSBAY_OK && boolean && exception == 0);
    CHECK(jsbay_value_has(subject, TEXT("inherited"), &boolean, &exception) == JSBAY_OK && boolean);
    CHECK(jsbay_value_has(subject, TEXT("missing"), &boolean, &exception) == JSBAY_OK && !boolean);
    CHECK(jsbay_value_new_number(id, 1, &arg_value) == JSBAY_OK);
    boolean = true;
    CHECK(jsbay_value_has(arg_value, TEXT("y"), &boolean, &exception) == JSBAY_EXCEPTION);
    CHECK(!boolean && exception != 0);
    CHECK(jsbay_value_release(exception) == JSBAY_OK);
    CHECK(jsbay_value_has(subject, (jsbay_utf8_t){(const uint8_t *)"a\0b", 3}, &boolean, &exception) == JSBAY_INVALID_ARGUMENT);
    CHECK(!boolean && exception == 0);

    /* keys is Object.keys: integer keys ascending, then creation order; no inherited, hidden or Symbol keys. The non-configurable key stays listed. */
    CHECK(jsbay_value_keys(subject, &instance, &exception) == JSBAY_OK && exception == 0);
    CHECK(json_equals(instance, "[\"1\",\"2\",\"z\",\"y\",\"fixed\"]"));
    CHECK(jsbay_value_type(instance, &kind) == JSBAY_OK && kind == JSBAY_VALUE_ARRAY);
    CHECK(jsbay_value_release(instance) == JSBAY_OK);
    CHECK(jsbay_value_keys(arg_value, &instance, &exception) == JSBAY_OK);
    CHECK(json_equals(instance, "[]"));
    CHECK(jsbay_value_release(instance) == JSBAY_OK);
    CHECK(jsbay_value_release(arg_value) == JSBAY_OK);

    /* delete is non-strict: missing is true, non-configurable is false and silent. */
    CHECK(jsbay_value_delete(subject, TEXT("y"), &boolean, &exception) == JSBAY_OK && boolean && exception == 0);
    CHECK(jsbay_value_has(subject, TEXT("y"), &boolean, &exception) == JSBAY_OK && !boolean);
    CHECK(jsbay_value_delete(subject, TEXT("missing"), &boolean, &exception) == JSBAY_OK && boolean);
    CHECK(jsbay_value_delete(subject, TEXT("fixed"), &boolean, &exception) == JSBAY_OK && !boolean && exception == 0);
    CHECK(jsbay_value_has(subject, TEXT("fixed"), &boolean, &exception) == JSBAY_OK && boolean);
    CHECK(jsbay_value_delete(subject, TEXT("inherited"), &boolean, &exception) == JSBAY_OK && boolean);
    CHECK(jsbay_value_has(subject, TEXT("inherited"), &boolean, &exception) == JSBAY_OK && boolean);

    /* A non-callable right-hand side is a TypeError; the result stays false. */
    boolean = true;
    CHECK(jsbay_value_instance_of(subject, subject, &boolean, &exception) == JSBAY_EXCEPTION);
    CHECK(!boolean && exception != 0);
    CHECK(jsbay_value_release(exception) == JSBAY_OK);
    CHECK(jsbay_value_release(subject) == JSBAY_OK);
    CHECK(jsbay_value_release(klass) == JSBAY_OK);

    /* Length-based strings must preserve both a NUL and a supplementary code point. */
    const uint8_t input[] = {'a', 0, 0xf0, 0x9f, 0x98, 0x80};
    CHECK(jsbay_value_new_string(id, (jsbay_utf8_t){input, sizeof(input)}, &value) == JSBAY_OK);
    CHECK(jsbay_value_to_utf8(value, &bytes, &exception) == JSBAY_OK);
    CHECK(bytes.len == sizeof(input) && memcmp(bytes.data, input, bytes.len) == 0);
    jsbay_free_bytes(bytes);
    CHECK(jsbay_value_release(value) == JSBAY_OK);

    CHECK(jsbay_engine_evaluate(id,
        TEXT("globalThis.fired=0; setTimeout(()=>{queueMicrotask(()=>{fired=42;stopLoop()})},10); typeof require"),
        TEXT("timer.js"), NULL, &value, &exception) == JSBAY_OK);
    CHECK(jsbay_value_to_utf8(value, &bytes, &exception) == JSBAY_OK);
    CHECK(bytes.len == 9 && memcmp(bytes.data, "undefined", bytes.len) == 0);
    jsbay_free_bytes(bytes);
    CHECK(jsbay_value_release(value) == JSBAY_OK);
    CHECK(jsbay_engine_run_loop(id) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id, TEXT("fired"), TEXT("timer-result.js"), NULL, &value, &exception) == JSBAY_OK);
    CHECK(jsbay_value_to_number(value, &number) == JSBAY_OK && number == 42);
    CHECK(jsbay_value_release(value) == JSBAY_OK);

    CHECK(jsbay_engine_create(id + 1, NULL, NULL));
    CHECK(jsbay_value_new_number(id + 1, 5, &item) == JSBAY_OK);
    CHECK(jsbay_value_set(captured_owned, TEXT("foreign"), item, &exception) == JSBAY_STALE_VALUE);
    CHECK(exception == 0);
    foreign_value = item;
    CHECK(jsbay_engine_bind(id, TEXT("nativeForeign"), return_foreign, NULL, NULL, &fn, &exception) == JSBAY_OK);
    CHECK(jsbay_value_release(fn) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id, TEXT("nativeForeign()"), TEXT("foreign.js"), NULL, &value, &exception) == JSBAY_EXCEPTION);
    CHECK(value == 0 && exception != 0);
    CHECK(jsbay_value_release(exception) == JSBAY_OK);
    CHECK(jsbay_value_to_number(item, &number) == JSBAY_OK && number == 5);
    CHECK(jsbay_value_release(item) == JSBAY_OK);
    jsbay_engine_destroy(id + 1);
    jsbay_engine_destroy(id);
    CHECK(finalized_bindings == 3);
    CHECK(jsbay_value_release(captured_owned) == JSBAY_STALE_VALUE);

    struct CloseProbe close_probe = {0, 0, 0};
    CHECK(jsbay_engine_create(id, NULL, NULL));
    CHECK(jsbay_engine_bind(id, TEXT("closeFromNative"), close_from_callback, &close_probe, close_finalized, &fn, &exception) == JSBAY_OK);
    CHECK(jsbay_value_release(fn) == JSBAY_OK);
    CHECK(jsbay_engine_evaluate(id, TEXT("closeFromNative()"), TEXT("close.js"), NULL, &value, &exception) == JSBAY_INSTANCE_NOT_FOUND);
    CHECK(value == 0 && exception == 0);
    CHECK(close_probe.finalized == 1 && close_probe.early == 0);
    CHECK(jsbay_engine_create(id, NULL, NULL));
    jsbay_engine_destroy(id);
    CHECK(close_probe.finalized == 1);
    puts("JSBAY_VALUE_CONTRACT_PASS");
    return 0;
}
