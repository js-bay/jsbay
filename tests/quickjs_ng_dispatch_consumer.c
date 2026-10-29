/* Exercise location dispatch changes while an outer interpreter frame is live. */
#include "quickjs.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#ifndef JSBAY_DISPATCH_PROBE
#error "quickjs_ng_dispatch_consumer.c requires JSBAY_DISPATCH_PROBE"
#endif

JS_EXTERN uint64_t JS_GetLocationDispatchProbe(JSRuntime *rt);

#ifndef JSBAY_TEST_INCLUDE_QUICKJS_C
#error "quickjs_ng_dispatch_consumer.c needs quickjs.c in this test translation unit"
#endif

/* This lets the test corrupt an otherwise opaque compiled script bytecode. */
#include "quickjs.c"

static unsigned outer_lines;
static int nested_calls;
static int in_nested;
static int expecting_cold_outer_frame;
static uint64_t cold_probe;

static void eval_nested(JSContext *ctx) {
    const char *source = "1 + 2";
    JSValue result = JS_Eval(ctx, source, strlen(source), "nested.js", JS_EVAL_TYPE_GLOBAL);
    assert(!JS_IsException(result));
    JS_FreeValue(ctx, result);
    nested_calls++;
}

static void location(JSContext *ctx, const char *filename, int line, int column, int depth,
                     uint64_t script_tag, void *opaque) {
    (void)column;
    (void)depth;
    (void)script_tag;
    (void)opaque;
    if (strcmp(filename, "outer.js") != 0)
        return;
    assert(line > 0 && line < 32);
    outer_lines |= 1u << line;
    if (!in_nested) {
        in_nested = 1;
        eval_nested(ctx);
        in_nested = 0;
    }
}

static JSValue turn_on(JSContext *ctx, JSValueConst this_value, int argc, JSValueConst *argv) {
    (void)this_value;
    (void)argc;
    (void)argv;
    JSRuntime *rt = JS_GetRuntime(ctx);
    if (expecting_cold_outer_frame) {
        /* The preceding turnOff must have restored the active outer frame to the cold table. */
        assert(JS_GetLocationDispatchProbe(rt) == cold_probe);
        expecting_cold_outer_frame = 0;
    }
    uint64_t before = JS_GetLocationDispatchProbe(rt);
    JS_SetLocationHandler(rt, location, NULL);
    eval_nested(ctx);
    assert(JS_GetLocationDispatchProbe(rt) > before);
    return JS_UNDEFINED;
}

static JSValue turn_off(JSContext *ctx, JSValueConst this_value, int argc, JSValueConst *argv) {
    (void)this_value;
    (void)argc;
    (void)argv;
    JSRuntime *rt = JS_GetRuntime(ctx);
    JS_SetLocationHandler(rt, NULL, NULL);
    uint64_t before = JS_GetLocationDispatchProbe(rt);
    eval_nested(ctx);
    /* The nested call is already cold; the outer frame is checked at the next turnOn/final exit. */
    assert(JS_GetLocationDispatchProbe(rt) == before);
    cold_probe = before;
    expecting_cold_outer_frame = 1;
    return JS_UNDEFINED;
}

static void assert_hot_invalid_opcode_uses_cold_error_path(JSContext *ctx) {
    JSRuntime *rt = JS_GetRuntime(ctx);
    JSValue compiled = JS_Eval(ctx, "0;", 2, "bad-opcode.js",
                               JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    assert(!JS_IsException(compiled));
    assert(JS_VALUE_GET_TAG(compiled) == JS_TAG_FUNCTION_BYTECODE);
    JSFunctionBytecode *bytecode = JS_VALUE_GET_PTR(compiled);
    assert(bytecode && bytecode->byte_code_len > 0);
    bytecode->byte_code_buf[0] = 0xff;

    JS_SetLocationHandler(rt, location, NULL);
    uint64_t before = JS_GetLocationDispatchProbe(rt);
    JSValue result = JS_EvalFunction(ctx, compiled);
    assert(JS_IsException(result));
    assert(JS_GetLocationDispatchProbe(rt) == before);
    JS_FreeValue(ctx, result);

    JSValue exception = JS_GetException(ctx);
    const char *message = JS_ToCString(ctx, exception);
    assert(message && strstr(message, "invalid opcode: pc=0 opcode=0xff"));
    JS_FreeCString(ctx, message);
    JS_FreeValue(ctx, exception);
    JS_SetLocationHandler(rt, NULL, NULL);
}

int main(void) {
    JSRuntime *rt = JS_NewRuntime();
    JSContext *ctx = JS_NewContext(rt);
    assert(rt && ctx);
    JSValue global = JS_GetGlobalObject(ctx);
    assert(JS_SetPropertyStr(ctx, global, "turnOn", JS_NewCFunction(ctx, turn_on, "turnOn", 0)) >=
           0);
    assert(JS_SetPropertyStr(ctx, global, "turnOff",
                             JS_NewCFunction(ctx, turn_off, "turnOff", 0)) >= 0);
    JS_FreeValue(ctx, global);
    const char *source =
        "turnOn();\nglobalThis.first = Math.abs(1);\nturnOff();\nglobalThis.second = "
        "Math.abs(2);\nturnOn();\nglobalThis.third = Math.abs(3);\nturnOff();\nfirst + second + "
        "third;\n";
    JSValue result = JS_Eval(ctx, source, strlen(source), "outer.js", JS_EVAL_TYPE_GLOBAL);
    assert(!JS_IsException(result));
    int32_t sum = 0;
    assert(JS_ToInt32(ctx, &sum, result) == 0 && sum == 6);
    assert((outer_lines & (1u << 2)) && (outer_lines & (1u << 6)));
    assert(!(outer_lines & (1u << 4)) && !(outer_lines & (1u << 8)));
    assert(nested_calls >= 6);
    assert(expecting_cold_outer_frame);
    assert(JS_GetLocationDispatchProbe(rt) == cold_probe);
    assert_hot_invalid_opcode_uses_cold_error_path(ctx);
    JS_FreeValue(ctx, result);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    puts("PASS: live outer frame dispatch toggles and invalid opcode path");
    return 0;
}
