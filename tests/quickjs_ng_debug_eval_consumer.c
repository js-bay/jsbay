/* Exercise the per-context debugger expression helper cache. */
#include "quickjs.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#ifndef JSBAY_TEST_INCLUDE_QUICKJS_C
#error "quickjs_ng_debug_eval_consumer.c needs quickjs.c in this test translation unit"
#endif

#include "quickjs.c"

static const char helper_source[] =
    "(function(__jsbayScope,__jsbayExpression){"
    "return (function(){with(__jsbayScope){return eval(__jsbayExpression);}}).call(this);"
    "})";

static unsigned helper_compiles;

static uint64_t script_tag(JSContext *ctx, const char *filename, const char *source,
                           size_t source_len, void *opaque) {
    (void)ctx;
    (void)opaque;
    if (strcmp(filename, "<debugger>") == 0 && source_len == sizeof(helper_source) - 1 &&
        memcmp(source, helper_source, source_len) == 0)
        helper_compiles++;
    return 1;
}

static void expect_int(JSContext *ctx, JSValue value, int expected, const char *label) {
    int actual = 0;
    if (JS_IsException(value)) {
        JSValue exception = JS_GetException(ctx);
        const char *text = JS_ToCString(ctx, exception);
        fprintf(stderr, "%s: %s\n", label, text ? text : "exception");
        JS_FreeCString(ctx, text);
        JS_FreeValue(ctx, exception);
        assert(0);
    }
    assert(JS_ToInt32(ctx, &actual, value) == 0);
    if (actual != expected)
        fprintf(stderr, "%s: expected %d, got %d\n", label, expected, actual);
    assert(actual == expected);
    JS_FreeValue(ctx, value);
}

static JSValue probe(JSContext *ctx, JSValueConst this_value, int argc, JSValueConst *argv) {
    int expected_realm = 0;
    int expected_local = 0;
    JSValue value;
    (void)this_value;

    assert(argc == 2);
    assert(JS_ToInt32(ctx, &expected_realm, argv[0]) == 0);
    assert(JS_ToInt32(ctx, &expected_local, argv[1]) == 0);

    value = JS_EvalInDebugFrame(ctx, 1, "local + realmValue", sizeof("local + realmValue") - 1);
    expect_int(ctx, value, expected_realm, "realm");

    value = JS_EvalInDebugFrame(ctx, 1, "(", 1);
    assert(JS_IsException(value));
    JS_FreeValue(ctx, value);
    value = JS_GetException(ctx);
    assert(!JS_IsException(value));
    JS_FreeValue(ctx, value);

    value = JS_EvalInDebugFrame(ctx, 1, "local", sizeof("local") - 1);
    expect_int(ctx, value, expected_local, "local");
    return JS_NewInt32(ctx, 0);
}

static void install_probe(JSContext *ctx) {
    JSValue global = JS_GetGlobalObject(ctx);
    assert(JS_SetPropertyStr(ctx, global, "__probe", JS_NewCFunction(ctx, probe, "__probe", 1)) >=
           0);
    JS_FreeValue(ctx, global);
}

static void invoke(JSContext *ctx, int realm_value, int local) {
    char source[192];
    const int written = snprintf(source, sizeof(source),
                                 "globalThis.realmValue = %d; function invoke() { let local = %d; "
                                 "return __probe(%d, %d); } invoke();",
                                 realm_value, local, local + realm_value, local);
    JSValue result;
    assert(written > 0 && (size_t)written < sizeof(source));
    result = JS_Eval(ctx, source, (size_t)written, "debug-eval-consumer.js", JS_EVAL_TYPE_GLOBAL);
    expect_int(ctx, result, 0, "invoke");
}

int main(void) {
    JSRuntime *rt = JS_NewRuntime();
    JSContext *first = JS_NewContext(rt);
    JSContext *second = JS_NewContext(rt);
    assert(rt && first && second);
    JS_SetScriptTagHandler(rt, script_tag, NULL);
    install_probe(first);
    install_probe(second);

    invoke(first, 1, 40);
    assert(helper_compiles == 1);
    JS_RunGC(rt);
    invoke(first, 1, 50);
    assert(helper_compiles == 1);

    invoke(second, 2, 60);
    assert(helper_compiles == 2);

    JS_SetScriptTagHandler(rt, NULL, NULL);
    JS_FreeContext(first);
    JS_FreeContext(second);
    JS_RunGC(rt);
    JS_FreeRuntime(rt);
    puts("PASS: debugger eval helper cache is per context and survives GC");
    return 0;
}
