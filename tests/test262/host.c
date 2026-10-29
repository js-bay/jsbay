/* A fresh public-C-ABI engine per Test262 variant. The parent owns the wall clock deadline, including synchronous scripts on watchdog-limited hosts. */
#include "jsbay.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TEXT(s) ((jsbay_utf8_t){(const uint8_t *)(s), strlen(s)})
static unsigned done_count;
static int done_failed;
static jsbay_value_t type_check;
static jsbay_value_t undefined_this;
extern bool jsbay_test262_watch(int instance_id);
extern size_t jsbay_test262_unhandled(void);

static void diagnostic(jsbay_value_t value) {
    jsbay_bytes_t text = {0};
    jsbay_value_t exception = 0;
    if (jsbay_value_to_utf8(value, &text, &exception) == JSBAY_OK) {
        fwrite(text.data, 1, text.len, stderr);
        fputc('\n', stderr);
        jsbay_free_bytes(text);
    }
    if (exception)
        jsbay_value_release(exception);
}

static jsbay_status_t done(int id, void *data, jsbay_value_t self, size_t argc,
                            const jsbay_value_t *args, jsbay_value_t *out,
                            jsbay_value_t *error) {
    (void)data;
    (void)self;
    (void)error;
    done_count++;
    (void)jsbay_engine_stop_loop(id);
    if (argc) {
        jsbay_value_kind_t kind;
        if (jsbay_value_type(args[0], &kind) != JSBAY_OK || kind != JSBAY_VALUE_UNDEFINED) {
            done_failed = 1;
            diagnostic(args[0]);
        }
    }
    return jsbay_value_undefined(id, out);
}

/* Reused across Test262 files so the runner avoids per-file malloc. */
static uint8_t *source_buf;
static size_t source_cap;

static uint8_t *alloc_source_buf(size_t cap) {
    return malloc(cap);
}
static uint8_t *ensure_source_buf(size_t need) {
    if (need <= source_cap)
        return source_buf;
    if (!source_buf) {
        size_t cap = 4096u;
        while (cap < need)
            cap *= 2u;
        source_buf = alloc_source_buf(cap);
        if (!source_buf)
            return NULL;
        source_cap = cap;
        return source_buf;
    }
    while (source_cap < need) {
        uint8_t *grown = realloc(source_buf, source_cap * 2);
        if (!grown)
            return NULL;
        source_buf = grown;
        source_cap *= 2;
    }
    return source_buf;
}

static int run_file(int id, const char *path, const char *expected) {
    FILE *file = fopen(path, "rb");
    if (!file)
        return 2;
    if (fseek(file, 0, SEEK_END)) {
        fclose(file);
        return 2;
    }
    long size = ftell(file);
    if (size < 0 || size > 32 * 1024 * 1024 || fseek(file, 0, SEEK_SET)) {
        fclose(file);
        return 2;
    }
    uint8_t *source = ensure_source_buf((size_t)size + 1);
    if (!source) {
        fclose(file);
        return 2;
    }
    int read_ok = fread(source, 1, (size_t)size, file) == (size_t)size;
    fclose(file);
    if (!read_ok)
        return 2;
    jsbay_value_t value = 0, exception = 0;
    jsbay_status_t status = jsbay_engine_evaluate(id, (jsbay_utf8_t){source, (size_t)size},
                                                    TEXT(path), NULL, &value, &exception);
    int result = 1;
    if (expected[0]) {
        if (status == JSBAY_EXCEPTION && exception) {
            jsbay_value_t type_name = 0, nested = 0, checked = 0;
            if (jsbay_value_new_string(id, TEXT(expected), &type_name) == JSBAY_OK) {
                jsbay_value_t args[] = {exception, type_name};
                bool matches = false;
                if (jsbay_value_call(type_check, undefined_this, args, 2, &checked, &nested) ==
                        JSBAY_OK &&
                    jsbay_value_to_bool(checked, &matches) == JSBAY_OK && matches)
                    result = 0;
                jsbay_value_release(type_name);
            }
            if (checked)
                jsbay_value_release(checked);
            if (nested)
                jsbay_value_release(nested);
        }
    } else if (status == JSBAY_OK)
        result = 0;
    if (result && exception)
        diagnostic(exception);
    if (value)
        jsbay_value_release(value);
    if (exception)
        jsbay_value_release(exception);
    return result;
}

int main(int argc, char **argv) {
    int capabilities = argc == 2 && !strcmp(argv[1], "--capabilities");
    if (argc != 6 && !capabilities)
        return 2;
    const int id = 262;
    if (!jsbay_engine_create(id, NULL, NULL))
        return 2;
    bool rejection_tracking = jsbay_test262_watch(id);
    if (capabilities) {
        printf("{\"unhandledPromiseRejection\":%s}\n", rejection_tracking ? "true" : "false");
        jsbay_engine_destroy(id);
        return 0;
    }
    jsbay_value_t function = 0, exception = 0;
    int result = 2;
    /* Capture constructors and the intrinsic before harness or test code can replace globals. A writable .name is insufficient evidence of type. */
    const char *checker_source =
        "(function(){const "
        "types={Error,EvalError,RangeError,ReferenceError,SyntaxError,TypeError,URIError};"
        "const apply=Reflect.apply,hasInstance=Function.prototype[Symbol.hasInstance];"
        "return function(value,name){const C=types[name];return typeof "
        "C==='function'&&apply(hasInstance,C,[value]);};})()";
    if (jsbay_value_undefined(id, &undefined_this) != JSBAY_OK ||
        jsbay_engine_evaluate(id, TEXT(checker_source), TEXT("error-type-check.js"), NULL,
                               &type_check, &exception) != JSBAY_OK)
        goto cleanup;
    if (jsbay_engine_bind(id, TEXT("$DONE"), done, NULL, NULL, &function, &exception) != JSBAY_OK)
        goto cleanup;
    jsbay_value_release(function);
    result = run_file(id, argv[1], "");
    if (result)
        goto cleanup;
    result = run_file(id, argv[2], argv[4]);
    if (result)
        goto cleanup;
    if (argv[5][0]) {
        jsbay_value_t marker = 0, nested = 0;
        bool entered = true;
        if (jsbay_engine_evaluate(id,
                                   TEXT("typeof globalThis.__jsbayTest262Entered !== 'undefined'"),
                                   TEXT("phase-check.js"), NULL, &marker, &nested) != JSBAY_OK ||
            jsbay_value_to_bool(marker, &entered) != JSBAY_OK ||
            entered != (strcmp(argv[5], "runtime") == 0))
            result = 1;
        if (marker)
            jsbay_value_release(marker);
        if (nested)
            jsbay_value_release(nested);
        if (result)
            goto cleanup;
    }
    if (!strcmp(argv[3], "async")) {
        /* The event loop executes callbacks on its owner; the parent bounds a test that never completes. */
        if (!done_count && jsbay_engine_run_loop(id) != JSBAY_OK) {
            result = 2;
            goto cleanup;
        }
        result = done_failed || done_count != 1 ? 1 : 0;
    }
    if (jsbay_test262_unhandled())
        result = 1;
cleanup:
    if (type_check)
        jsbay_value_release(type_check);
    if (undefined_this)
        jsbay_value_release(undefined_this);
    if (exception)
        jsbay_value_release(exception);
    jsbay_engine_destroy(id);
    return result;
}
