#include "jsbay.h"
#include <node_api.h>

#include <dlfcn.h>
#include <string.h>

static napi_value check_backend(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    char path[4096];
    char name[32];
    size_t length;
    if (napi_get_cb_info(env, info, &argc, args, NULL, NULL) != napi_ok || argc != 2 ||
        napi_get_value_string_utf8(env, args[0], path, sizeof(path), &length) != napi_ok ||
        napi_get_value_string_utf8(env, args[1], name, sizeof(name), &length) != napi_ok) {
        napi_throw_error(env, NULL, "Expected addon path and backend name");
        return NULL;
    }
    jsbay_backend_t expected;
    if (strcmp(name, "quickjs") == 0)
        expected = JSBAY_BACKEND_QUICKJS;
    else if (strcmp(name, "quickjsng") == 0)
        expected = JSBAY_BACKEND_QUICKJS_NG;
    else if (strcmp(name, "jsc") == 0)
        expected = JSBAY_BACKEND_JSC;
    else {
        napi_throw_error(env, NULL, "Unknown engine backend");
        return NULL;
    }
    void *addon = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (!addon) {
        napi_throw_error(env, NULL, dlerror());
        return NULL;
    }
    jsbay_backend_t (*backend)(void) =
        (jsbay_backend_t (*)(void))dlsym(addon, "jsbay_library_backend");
    if (!backend || backend() != expected) {
        napi_throw_error(env, NULL, "Installed addon has the wrong engine backend");
        return NULL;
    }
    napi_value result;
    if (napi_get_boolean(env, true, &result) != napi_ok)
        return NULL;
    return result;
}

NAPI_MODULE_INIT() {
    napi_value function;
    if (napi_create_function(env, "checkBackend", NAPI_AUTO_LENGTH, check_backend, NULL,
                             &function) != napi_ok)
        return NULL;
    return function;
}
