#include <node_api.h>

static int cleanup_failure_aborts = 0;
static int cleanup_failure_hooks = 0;

static napi_status rejectCleanupHook(napi_env, napi_cleanup_hook, void *) {
    ++cleanup_failure_hooks;
    return napi_generic_failure;
}

static napi_status recordSubmissionRelease(napi_threadsafe_function function,
                                           napi_threadsafe_function_release_mode mode) {
    if (mode == napi_tsfn_abort)
        ++cleanup_failure_aborts;
    return napi_release_threadsafe_function(function, mode);
}

static napi_value cleanupAbortCount(napi_env env, napi_callback_info) {
    napi_value result;
    napi_create_int32(env, cleanup_failure_aborts, &result);
    return result;
}

static napi_value cleanupHookCount(napi_env env, napi_callback_info) {
    napi_value result;
    napi_create_int32(env, cleanup_failure_hooks, &result);
    return result;
}

static napi_status defineWithCleanupProbe(napi_env env, napi_value object, size_t count,
                                          const napi_property_descriptor *properties) {
    const auto status = napi_define_properties(env, object, count, properties);
    if (status != napi_ok)
        return status;
    const napi_property_descriptor probes[] = {
        {"cleanupFailureAbortCount", nullptr, cleanupAbortCount, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"cleanupFailureHookCount", nullptr, cleanupHookCount, nullptr, nullptr, nullptr,
         napi_default, nullptr}};
    return napi_define_properties(env, object, 2, probes);
}

#define napi_add_env_cleanup_hook rejectCleanupHook
#define napi_release_threadsafe_function recordSubmissionRelease
#define napi_define_properties defineWithCleanupProbe
#include "../../sdk/harmony/src/main/cpp/jsbay_harmony.cpp"
