#include "jsbay.h"
#include "jsbay_async.h"
#include "jsbay_node_embed.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <node_api.h>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <uv.h>
#include <vector>

namespace {
#ifdef JSBAY_NODE_TESTING
static std::atomic_size_t live_engines{0}, live_completions{0};
static thread_local std::string failure_point;
#endif
static bool injectedFailure(const char *point) {
#ifdef JSBAY_NODE_TESTING
    std::string token(point);
    auto start = failure_point.find(token);
    if (start != std::string::npos && (start == 0 || failure_point[start - 1] == ',') &&
        (start + token.size() == failure_point.size() ||
         failure_point[start + token.size()] == ',')) {
        failure_point.erase(start, token.size());
        return true;
    }
#else
    (void)point;
#endif
    return false;
}
struct Engine;
struct Binding;
struct Value;
struct NodeValueState;
static void invalidateNodeValues(Engine *engine, bool release_core);
static napi_value transferNodeValue(Engine *engine, Value &value);
static constexpr napi_type_tag engineTypeTag = {0xd9255a2c1e7b4831ULL, 0xa0f34d9712ce685bULL};
struct CallbackBridge {
    std::mutex mutex;
    napi_threadsafe_function log = nullptr;
    napi_threadsafe_function event = nullptr;
    int instance_id = 0;
    uintptr_t token = 0;
    bool closed = false;
    uint64_t log_epoch = 1;
    uint64_t event_epoch = 1;
};
static std::mutex callback_bridges_mutex;
static std::unordered_map<uintptr_t, std::shared_ptr<CallbackBridge>> callback_bridges;
static std::atomic_uintptr_t next_callback_token{1};
static uintptr_t allocateCallbackToken() {
    uintptr_t token = next_callback_token.load(std::memory_order_relaxed);
    while (token != 0 && token != std::numeric_limits<uintptr_t>::max()) {
        if (next_callback_token.compare_exchange_weak(token, token + 1, std::memory_order_relaxed))
            return token;
    }
    return 0;
}
static std::shared_ptr<CallbackBridge> callbackBridge(void *opaque) {
    const uintptr_t token = reinterpret_cast<uintptr_t>(opaque);
    if (!token)
        return nullptr;
    std::lock_guard<std::mutex> lock(callback_bridges_mutex);
    auto found = callback_bridges.find(token);
    return found == callback_bridges.end() ? nullptr : found->second;
}
static void eraseCallbackBridge(uintptr_t token) {
    std::lock_guard<std::mutex> lock(callback_bridges_mutex);
    callback_bridges.erase(token);
}
struct CallbackHandle {
    uintptr_t token;
    uint64_t epoch;
    bool event;
};
struct BridgeMessage {
    int instance_id = 0;
    int level = 0;
    int kind = 0;
    int status = 0;
    uint64_t detail = 0;
    std::string message;
    bool has_message = false;
};
static void clearPendingException(napi_env env) {
    bool pending = false;
    if (napi_is_exception_pending(env, &pending) == napi_ok && pending) {
        napi_value ignored;
        (void)napi_get_and_clear_last_exception(env, &ignored);
    }
}
static void bridgeCallJs(napi_env env, napi_value callback, void *context, void *opaque) {
    std::unique_ptr<BridgeMessage> message(static_cast<BridgeMessage *>(opaque));
    if (!env || !callback || !message)
        return;
    auto *handle = static_cast<CallbackHandle *>(context);
    if (!handle)
        return;
    auto bridge = callbackBridge(reinterpret_cast<void *>(handle->token));
    if (!bridge)
        return;
    {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        const uint64_t active_epoch = handle->event ? bridge->event_epoch : bridge->log_epoch;
        if (bridge->closed || active_epoch != handle->epoch)
            return;
    }
    napi_value receiver = nullptr, args[3]{}, result = nullptr;
    if (napi_get_undefined(env, &receiver) != napi_ok)
        return;
    if (message->level >= 0) {
        if (napi_create_int32(env, message->instance_id, &args[0]) != napi_ok ||
            napi_create_int32(env, message->level, &args[1]) != napi_ok ||
            napi_create_string_utf8(env, message->message.data(), message->message.size(),
                                    &args[2]) != napi_ok) {
            clearPendingException(env);
            return;
        }
        (void)napi_call_function(env, receiver, callback, 3, args, &result);
        clearPendingException(env);
        return;
    }
    if (napi_create_object(env, &args[0]) != napi_ok) {
        clearPendingException(env);
        return;
    }
    napi_value value = nullptr;
    const auto set_int = [&](const char *name, int number) {
        return napi_create_int32(env, number, &value) == napi_ok &&
               napi_set_named_property(env, args[0], name, value) == napi_ok;
    };
    if (!set_int("kind", message->kind) || !set_int("instanceId", message->instance_id) ||
        !set_int("status", message->status) ||
        napi_create_bigint_uint64(env, message->detail, &value) != napi_ok ||
        napi_set_named_property(env, args[0], "detail", value) != napi_ok) {
        clearPendingException(env);
        return;
    }
    if (message->has_message) {
        if (napi_create_string_utf8(env, message->message.data(), message->message.size(),
                                    &value) != napi_ok) {
            clearPendingException(env);
            return;
        }
    } else if (napi_get_null(env, &value) != napi_ok) {
        clearPendingException(env);
        return;
    }
    if (napi_set_named_property(env, args[0], "message", value) != napi_ok) {
        clearPendingException(env);
        return;
    }
    (void)napi_call_function(env, receiver, callback, 1, args, &result);
    clearPendingException(env);
}
static void queueBridgeMessage(void *opaque, BridgeMessage *message, bool event) {
    auto bridge = callbackBridge(opaque);
    if (!bridge) {
        delete message;
        return;
    }
    std::lock_guard<std::mutex> lock(bridge->mutex);
    auto function = event ? bridge->event : bridge->log;
    if (!function ||
        napi_call_threadsafe_function(function, message, napi_tsfn_nonblocking) != napi_ok)
        delete message;
}
static void nodeLogHandler(int id, jsbay_log_level_t level, const char *message, void *opaque) {
    auto *copy = new (std::nothrow) BridgeMessage{};
    if (!copy)
        return;
    copy->instance_id = id;
    copy->level = static_cast<int>(level);
    try {
        if (message)
            copy->message.assign(message);
    } catch (...) {
        delete copy;
        return;
    }
    queueBridgeMessage(opaque, copy, false);
}
static void nodeEventHandler(const jsbay_engine_event_t *event, void *opaque) {
    if (!event)
        return;
    auto *copy = new (std::nothrow) BridgeMessage{};
    if (!copy)
        return;
    copy->instance_id = event->instance_id;
    copy->level = -1;
    copy->kind = static_cast<int>(event->kind);
    copy->status = event->status;
    copy->detail = event->detail;
    copy->has_message = event->message != nullptr;
    try {
        if (event->message)
            copy->message.assign(event->message);
    } catch (...) {
        delete copy;
        return;
    }
    queueBridgeMessage(opaque, copy, true);
}
static bool createCallbackFunction(napi_env env, napi_value callback, const char *name,
                                   uintptr_t token, uint64_t epoch, bool event,
                                   napi_threadsafe_function *out) {
    napi_value resource_name;
    auto *handle = new (std::nothrow) CallbackHandle{token, epoch, event};
    if (!handle)
        return false;
    const auto finalize = [](napi_env, void *data, void *) {
        std::unique_ptr<CallbackHandle> handle(static_cast<CallbackHandle *>(data));
        auto bridge = callbackBridge(reinterpret_cast<void *>(handle->token));
        if (!bridge)
            return;
        std::lock_guard<std::mutex> lock(bridge->mutex);
        auto &function = handle->event ? bridge->event : bridge->log;
        auto &active_epoch = handle->event ? bridge->event_epoch : bridge->log_epoch;
        if (active_epoch == handle->epoch)
            function = nullptr;
    };
    if (napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_threadsafe_function(env, callback, nullptr, resource_name, 1024, 1, handle,
                                        finalize, handle, bridgeCallJs, out) != napi_ok) {
        delete handle;
        return false;
    }
    if (napi_unref_threadsafe_function(env, *out) != napi_ok) {
        napi_release_threadsafe_function(*out, napi_tsfn_abort);
        *out = nullptr;
        return false;
    }
    return true;
}
static bool replaceCallbackFunction(napi_env env, const std::shared_ptr<CallbackBridge> &bridge,
                                    napi_value callback, bool event) {
    if (!bridge)
        return false;
    uint64_t previous_epoch = 0;
    {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        if (bridge->closed)
            return false;
        previous_epoch = event ? bridge->event_epoch : bridge->log_epoch;
    }
    if (previous_epoch == std::numeric_limits<uint64_t>::max())
        return false;
    const uint64_t next_epoch = previous_epoch + 1;
    napi_threadsafe_function replacement = nullptr;
    if (callback && !createCallbackFunction(env, callback, event ? "JsBayEvent" : "JsBayLog",
                                            bridge->token, next_epoch, event, &replacement))
        return false;
    napi_threadsafe_function previous = nullptr;
    bool installed = false;
    {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        auto &active_epoch = event ? bridge->event_epoch : bridge->log_epoch;
        auto &function = event ? bridge->event : bridge->log;
        if (!bridge->closed && active_epoch == previous_epoch) {
            previous = function;
            active_epoch = next_epoch;
            function = replacement;
            installed = true;
        }
    }
    if (!installed) {
        if (replacement)
            napi_release_threadsafe_function(replacement, napi_tsfn_abort);
        return false;
    }
    if (previous)
        napi_release_threadsafe_function(previous, napi_tsfn_abort);
    return true;
}
static void releaseBridge(const std::shared_ptr<CallbackBridge> &bridge) {
    if (!bridge)
        return;
    napi_threadsafe_function log = nullptr, event = nullptr;
    {
        std::lock_guard<std::mutex> lock(bridge->mutex);
        bridge->closed = true;
        log = bridge->log;
        event = bridge->event;
        bridge->log = nullptr;
        bridge->event = nullptr;
    }
    if (log)
        napi_release_threadsafe_function(log, napi_tsfn_abort);
    if (event)
        napi_release_threadsafe_function(event, napi_tsfn_abort);
}
struct SubmissionState {
    std::atomic_uint refs{2};
    std::mutex mutex;
    bool function_open = true;
    napi_env env = nullptr;
    napi_deferred deferred = nullptr;
    napi_threadsafe_function function = nullptr;
    jsbay_submission_status_t status = JSBAY_SUBMISSION_CANCELLED;
    std::string error;
    bool has_error = false;
};
static void releaseSubmissionState(SubmissionState *state) {
    if (state && state->refs.fetch_sub(1, std::memory_order_acq_rel) == 1)
        delete state;
}
static void submissionFinalize(napi_env, void *data, void *) {
    auto *state = static_cast<SubmissionState *>(data);
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->function_open = false;
        state->function = nullptr;
    }
    releaseSubmissionState(state);
}
static void submissionCallJs(napi_env env, napi_value, void *context, void *data) {
    auto *state = static_cast<SubmissionState *>(context);
    if (!env || !state || data != state)
        return;
    napi_value result = nullptr, status = nullptr, error = nullptr;
    const char *name = state->status == JSBAY_SUBMISSION_COMPLETED   ? "completed"
                       : state->status == JSBAY_SUBMISSION_EXCEPTION ? "exception"
                                                                     : "cancelled";
    napi_status converted = napi_create_object(env, &result);
    if (converted == napi_ok)
        converted = napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &status);
    if (converted == napi_ok) {
        converted = state->has_error ? napi_create_string_utf8(env, state->error.data(),
                                                               state->error.size(), &error)
                                     : napi_get_null(env, &error);
    }
    if (converted == napi_ok)
        converted = napi_set_named_property(env, result, "status", status);
    if (converted == napi_ok)
        converted = napi_set_named_property(env, result, "error", error);
    if (converted == napi_ok && napi_resolve_deferred(env, state->deferred, result) == napi_ok) {
        napi_release_threadsafe_function(state->function, napi_tsfn_release);
        return;
    }
    napi_value fallback = nullptr;
    bool pending = false;
    if (napi_is_exception_pending(env, &pending) == napi_ok && pending)
        (void)napi_get_and_clear_last_exception(env, &fallback);
    if (!fallback && napi_get_undefined(env, &fallback) == napi_ok)
        (void)napi_reject_deferred(env, state->deferred, fallback);
    else if (fallback)
        (void)napi_reject_deferred(env, state->deferred, fallback);
    napi_release_threadsafe_function(state->function, napi_tsfn_release);
}
static void submissionCallback(int, uint64_t, jsbay_submission_status_t status,
                               const uint8_t *error_data, size_t error_len, void *opaque) {
    auto *state = static_cast<SubmissionState *>(opaque);
    state->status = status;
    try {
        if (error_data && error_len) {
            state->error.assign(reinterpret_cast<const char *>(error_data), error_len);
            state->has_error = true;
        }
    } catch (...) {
        state->has_error = false;
    }
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->function_open)
            (void)napi_call_threadsafe_function(state->function, state, napi_tsfn_nonblocking);
    }
    releaseSubmissionState(state);
}
struct Loop {
    uv_async_t async{};
    uv_timer_t timer{};
    std::mutex mutex;
    jsbay_loop_task_t task = nullptr;
    void *task_data = nullptr;
    uint64_t delay = 0;
    bool closing = false;
    unsigned open_handles = 0;
    bool async_ready = false, timer_ready = false;
    Engine *owner = nullptr;
};
struct Completion;
struct Engine {
#ifdef JSBAY_NODE_TESTING
    Engine() {
        ++live_engines;
    }
    ~Engine() {
        --live_engines;
    }
#endif
    napi_env env = nullptr;
    int id = 0;
    std::thread::id owner;
    bool closed = false, destroy_pending = false, destroyed = false;
    bool core_destroy_requested = false;
    uint64_t core_generation = 0;
    bool last_cache_hit = false;
    bool wrapper_finalized = false, cleanup_hook_registered = false,
         environment_cleaning_up = false;
    bool close_completion_active = false;
    unsigned active_operations = 0;
    Loop *loop = nullptr;
    std::unordered_map<uint64_t, napi_deferred> observers;
    std::vector<napi_deferred> close_waiters;
    std::unordered_set<Completion *> completions;
    std::unordered_set<NodeValueState *> node_values;
    uint64_t observer_id = 0;
    jsbay_value_t dispatch_ok = 0, dispatch_error = 0, bind_function = 0;
    jsbay_value_t get_prototype = 0, object_is = 0, object_prototype = 0;
    jsbay_value_t get_descriptor = 0, has_own = 0, error_constructor = 0;
    jsbay_value_t create_object = 0, define_property = 0;
    napi_ref promise_then = nullptr, host_stack_getter = nullptr;
    napi_ref async_resource = nullptr, wrapper = nullptr;
    napi_ref node_value_constructor = nullptr;
    napi_async_context async_context = nullptr;
    bool observer_retained = false;
    bool close_loop_referenced = false;
    std::shared_ptr<CallbackBridge> callbacks;
    void *embed_user_data = nullptr;
    void (*embed_destroy_callback)(void *) = nullptr;
    void *embed_task_observer_data = nullptr;
    void (*embed_task_observer)(void *, bool) = nullptr;
    jsbay_value_t guest_promise = 0, guest_resolve = 0, guest_then = 0, guest_promise_prototype = 0;
    jsbay_value_t guest_stack_getter = 0, completion_failure = 0;
};
struct Binding {
    Engine *engine;
    napi_ref callback;
    bool asynchronous;
};
struct Completion {
#ifdef JSBAY_NODE_TESTING
    Completion() {
        ++live_completions;
    }
    ~Completion() {
        --live_completions;
    }
#endif
    unsigned refs = 1;
    bool completed = false;
    Engine *engine = nullptr;
    uint64_t request = 0;
};
struct Value {
    jsbay_value_t id = 0;
    Value() = default;
    Value(const Value &) = delete;
    Value &operator=(const Value &) = delete;
    ~Value() {
        if (id)
            jsbay_value_release(id);
    }
};
struct ConversionBudget {
    static constexpr size_t max_nodes = 10000;
    static constexpr size_t max_bytes = 16 * 1024 * 1024;
    size_t nodes = 0;
    size_t bytes = 0;
    bool node() {
        return ++nodes <= max_nodes;
    }
    bool addBytes(size_t count) {
        return count <= max_bytes - bytes && ((bytes += count), true);
    }
};
static void releaseCompletion(Completion *completion) {
    if (--completion->refs == 0)
        delete completion;
}
static void completionFinalizer(napi_env, void *data, void *) {
    releaseCompletion(static_cast<Completion *>(data));
}
static std::atomic_int32_t next_instance_id{1};

static void finishClose(Engine *engine);
static void maybeDeleteEngine(Engine *engine);
static void requestClose(Engine *engine);
static void resolveCloseWaiters(Engine *engine);
static void releaseEngineAsyncResources(Engine *engine);
static void completeCloseWaiters(Engine *engine);

struct Operation {
    Engine *engine;
    explicit Operation(Engine *value) : engine(value) {
        ++engine->active_operations;
    }
    ~Operation() {
        if (--engine->active_operations == 0 && engine->destroy_pending)
            finishClose(engine);
    }
};

struct NodeTurn {
    napi_env env;
    napi_handle_scope handles = nullptr;
    napi_callback_scope callback = nullptr;
    bool ready = false;
    explicit NodeTurn(Engine *engine) : env(engine->env) {
        napi_value resource;
        ready =
            !engine->environment_cleaning_up && napi_open_handle_scope(env, &handles) == napi_ok &&
            napi_get_reference_value(env, engine->async_resource, &resource) == napi_ok &&
            napi_open_callback_scope(env, resource, engine->async_context, &callback) == napi_ok;
    }
    ~NodeTurn() {
        if (callback)
            napi_close_callback_scope(env, callback);
        if (handles)
            napi_close_handle_scope(env, handles);
    }
};

struct PendingDeferred {
    napi_env env;
    napi_deferred value = nullptr;
    explicit PendingDeferred(napi_env input) : env(input) {}
    napi_status settle(napi_value result, bool rejected = false) {
        bool pending = false;
        if (napi_is_exception_pending(env, &pending) != napi_ok || pending)
            return napi_pending_exception;
        auto owned = value;
        value = nullptr;
        return rejected ? napi_reject_deferred(env, owned, result)
                        : napi_resolve_deferred(env, owned, result);
    }
    ~PendingDeferred() {
        if (!value)
            return;
        bool pending = false;
        napi_value exception = nullptr;
        if (napi_is_exception_pending(env, &pending) == napi_ok && pending)
            napi_get_and_clear_last_exception(env, &exception);
        napi_value result;
        if (napi_get_undefined(env, &result) == napi_ok)
            settle(result);
        if (exception)
            napi_throw(env, exception);
    }
};

static void retainObservers(Engine *engine) {
    bool retain = !engine->closed && !engine->observers.empty();
    if (!engine->wrapper || retain == engine->observer_retained)
        return;
    uint32_t count;
    if (retain)
        napi_reference_ref(engine->env, engine->wrapper, &count);
    else
        napi_reference_unref(engine->env, engine->wrapper, &count);
    engine->observer_retained = retain;
}

static napi_value undefined(napi_env env) {
    napi_value out;
    napi_get_undefined(env, &out);
    return out;
}
static napi_value throwText(napi_env env, const char *text) {
    napi_throw_error(env, nullptr, text);
    return nullptr;
}
static napi_value throwStatusWithMessage(napi_env env, jsbay_status_t status,
                                         const char *message_text) {
    napi_value message, error, code;
    napi_create_string_utf8(env, message_text, NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, nullptr, message, &error);
    napi_create_int32(env, status, &code);
    napi_set_named_property(env, error, "status", code);
    const char *status_code = "JSBAY_UNKNOWN";
    switch (status) {
    case JSBAY_OK:
        status_code = "JSBAY_OK";
        break;
    case JSBAY_EXCEPTION:
        status_code = "JSBAY_EXCEPTION";
        break;
    case JSBAY_INVALID_ARGUMENT:
        status_code = "JSBAY_INVALID_ARGUMENT";
        break;
    case JSBAY_WRONG_THREAD:
        status_code = "JSBAY_WRONG_THREAD";
        break;
    case JSBAY_INSTANCE_NOT_FOUND:
        status_code = "JSBAY_INSTANCE_NOT_FOUND";
        break;
    case JSBAY_STALE_VALUE:
        status_code = "JSBAY_STALE_VALUE";
        break;
    case JSBAY_OUT_OF_MEMORY:
        status_code = "JSBAY_OUT_OF_MEMORY";
        break;
    case JSBAY_UNSUPPORTED:
        status_code = "JSBAY_UNSUPPORTED";
        break;
    case JSBAY_LOOP_FAILED:
        status_code = "JSBAY_LOOP_FAILED";
        break;
    }
    napi_value code_text;
    napi_create_string_utf8(env, status_code, NAPI_AUTO_LENGTH, &code_text);
    napi_set_named_property(env, error, "code", code_text);
    napi_throw(env, error);
    return nullptr;
}
static napi_value throwStatus(napi_env env, jsbay_status_t status) {
    std::string message = "js-bay status " + std::to_string(static_cast<int>(status));
    return throwStatusWithMessage(env, status, message.c_str());
}
static bool string(napi_env env, napi_value input, std::string *out) {
    size_t size = 0, copied = 0;
    if (napi_get_value_string_utf8(env, input, nullptr, 0, &size) != napi_ok)
        return false;
    out->resize(size);
    return napi_get_value_string_utf8(env, input, out->data(), size + 1, &copied) == napi_ok;
}
static bool boundedString(napi_env env, napi_value input, ConversionBudget *budget,
                          std::string *out) {
    size_t size = 0, copied = 0;
    if (napi_get_value_string_utf8(env, input, nullptr, 0, &size) != napi_ok ||
        !budget->addBytes(size))
        return false;
    out->resize(size);
    return napi_get_value_string_utf8(env, input, out->data(), size + 1, &copied) == napi_ok;
}
static jsbay_utf8_t text(const std::string &value) {
    return {reinterpret_cast<const uint8_t *>(value.data()), value.size()};
}
static Engine *unwrap(napi_env env, napi_value value) {
    bool tagged = false;
    if (napi_check_object_type_tag(env, value, &engineTypeTag, &tagged) != napi_ok || !tagged)
        return nullptr;
    Engine *out = nullptr;
    return napi_unwrap(env, value, reinterpret_cast<void **>(&out)) == napi_ok ? out : nullptr;
}
static bool requireEngine(napi_env env, Engine *engine) {
    if (!engine) {
        throwStatus(env, JSBAY_INSTANCE_NOT_FOUND);
        return false;
    }
    if (engine->closed) {
        throwStatusWithMessage(env, JSBAY_INSTANCE_NOT_FOUND, "JsBay engine closed");
        return false;
    }
    if (engine->owner != std::this_thread::get_id()) {
        throwStatus(env, JSBAY_WRONG_THREAD);
        return false;
    }
    return true;
}

struct LoopTaskInvocation {
    Engine *engine;
    jsbay_loop_task_t task;
    void *data;
};

static void invokeLoopTaskInGeneration(void *opaque) noexcept {
    auto *invocation = static_cast<LoopTaskInvocation *>(opaque);
    Engine *engine = invocation->engine;
    auto observer = engine->embed_task_observer;
    auto *observer_data = engine->embed_task_observer_data;
    try {
        if (observer)
            observer(observer_data, true);
        invocation->task(invocation->data);
    } catch (...) {
    }
    try {
        if (observer)
            observer(observer_data, false);
    } catch (...) {
    }
}

static void fireTimer(uv_timer_t *timer) {
    auto *loop = static_cast<Loop *>(timer->data);
    jsbay_loop_task_t task = nullptr;
    void *data = nullptr;
    {
        std::lock_guard<std::mutex> lock(loop->mutex);
        if (!loop->closing) {
            task = loop->task;
            data = loop->task_data;
            loop->task = nullptr;
            loop->task_data = nullptr;
        }
    }
    if (task) {
        Operation operation(loop->owner);
        NodeTurn turn(loop->owner);
        if (turn.ready && !loop->owner->closed) {
            LoopTaskInvocation invocation{loop->owner, task, data};
            const jsbay_status_t status =
                jsbay_engine_with_generation_scope(loop->owner->id, loop->owner->core_generation,
                                                   invokeLoopTaskInGeneration, &invocation);
            if (status != JSBAY_OK)
                requestClose(loop->owner);
        } else
            requestClose(loop->owner);
    }
}
static void wakeLoop(uv_async_t *async) {
    auto *loop = static_cast<Loop *>(async->data);
    if (loop->owner->destroy_pending && loop->owner->active_operations == 0) {
        if (loop->owner->environment_cleaning_up)
            finishClose(loop->owner);
        else {
            Operation operation(loop->owner);
            NodeTurn turn(loop->owner);
        }
        return;
    }
    std::lock_guard<std::mutex> lock(loop->mutex);
    if (!loop->closing) {
        uv_timer_stop(&loop->timer);
        if (loop->task)
            uv_timer_start(&loop->timer, fireTimer, loop->delay, 0);
    }
}
static bool scheduleLoop(void *opaque, uint64_t delay, jsbay_loop_task_t task, void *data) {
    auto *loop = static_cast<Loop *>(opaque);
    std::lock_guard<std::mutex> lock(loop->mutex);
    if (loop->closing)
        return false;
    loop->task = task;
    loop->task_data = data;
    loop->delay = delay;
    if (std::this_thread::get_id() == loop->owner->owner) {
        uv_timer_stop(&loop->timer);
        return uv_timer_start(&loop->timer, fireTimer, delay, 0) == 0;
    }
    return uv_async_send(&loop->async) == 0;
}
static void cancelLoop(void *opaque) {
    auto *loop = static_cast<Loop *>(opaque);
    std::lock_guard<std::mutex> lock(loop->mutex);
    if (loop->closing)
        return;
    loop->task = nullptr;
    loop->task_data = nullptr;
    if (std::this_thread::get_id() == loop->owner->owner)
        uv_timer_stop(&loop->timer);
    else
        (void)uv_async_send(&loop->async);
}
static void closeHandle(uv_handle_t *handle) {
    auto *loop = static_cast<Loop *>(handle->data);
    if (--loop->open_handles == 0) {
        Engine *engine = loop->owner;
        delete loop;
        engine->loop = nullptr;
        if (engine->destroyed) {
            if (engine->environment_cleaning_up)
                releaseEngineAsyncResources(engine);
            else
                completeCloseWaiters(engine);
        }
        maybeDeleteEngine(engine);
    }
}
static void closeLoop(Engine *engine, bool detach_core) {
    auto *loop = engine->loop;
    if (!loop)
        return;
    if (detach_core)
        (void)jsbay_engine_detach_loop(engine->id);
    {
        std::lock_guard<std::mutex> lock(loop->mutex);
        loop->closing = true;
        loop->task = nullptr;
        loop->task_data = nullptr;
    }
    if (loop->timer_ready) {
        uv_timer_stop(&loop->timer);
        if (!uv_is_closing(reinterpret_cast<uv_handle_t *>(&loop->timer)))
            uv_close(reinterpret_cast<uv_handle_t *>(&loop->timer), closeHandle);
    }
    if (loop->async_ready && !uv_is_closing(reinterpret_cast<uv_handle_t *>(&loop->async)))
        uv_close(reinterpret_cast<uv_handle_t *>(&loop->async), closeHandle);
    if (loop->open_handles == 0) {
        engine->loop = nullptr;
        delete loop;
    }
}

static bool snapshotCurrentGeneration(Engine *engine) {
    jsbay_instance_snapshot_t snapshot{};
    snapshot.struct_size = sizeof(snapshot);
    return jsbay_engine_snapshot(engine->id, &snapshot) &&
           snapshot.generation == engine->core_generation;
}

static void scheduleCloseWake(Engine *engine) {
    auto *loop = engine->loop;
    if (!loop || !loop->async_ready || uv_is_closing(reinterpret_cast<uv_handle_t *>(&loop->async)))
        return;
    (void)uv_async_send(&loop->async);
}

static void releaseCoreValuesImpl(Engine *engine) {
    for (auto value :
         {engine->dispatch_ok, engine->dispatch_error, engine->bind_function, engine->get_prototype,
          engine->object_is, engine->object_prototype, engine->get_descriptor, engine->has_own,
          engine->error_constructor, engine->create_object, engine->define_property,
          engine->guest_stack_getter, engine->completion_failure, engine->guest_promise,
          engine->guest_resolve, engine->guest_then, engine->guest_promise_prototype})
        if (value)
            jsbay_value_release(value);
    engine->dispatch_ok = engine->dispatch_error = engine->bind_function = 0;
    engine->get_prototype = engine->object_is = engine->object_prototype = 0;
    engine->get_descriptor = engine->has_own = engine->error_constructor = 0;
    engine->create_object = engine->define_property = engine->guest_stack_getter = 0;
    engine->completion_failure = engine->guest_promise = engine->guest_resolve = 0;
    engine->guest_then = engine->guest_promise_prototype = 0;
}

static void releaseEngineGenerationInScope(void *user_data) noexcept {
    auto *engine = static_cast<Engine *>(user_data);
    releaseCoreValuesImpl(engine);
    invalidateNodeValues(engine, true);
    jsbay_engine_destroy_generation(engine->id, engine->core_generation);
}

static void finishCoreGenerationClose(Engine *engine) {
    const jsbay_status_t status = jsbay_engine_with_generation_scope(
        engine->id, engine->core_generation, releaseEngineGenerationInScope, engine);
    if (status != JSBAY_OK) {
        invalidateNodeValues(engine, false);
        jsbay_engine_destroy_generation(engine->id, engine->core_generation);
    }
}

static void rejectObservers(Engine *engine) {
    auto pending = std::move(engine->observers);
    engine->observers.clear();
    if (engine->environment_cleaning_up)
        return;
    bool has_exception = false;
    napi_value exception = nullptr;
    if (napi_is_exception_pending(engine->env, &has_exception) == napi_ok && has_exception)
        napi_get_and_clear_last_exception(engine->env, &exception);
    retainObservers(engine);
    for (auto &entry : pending) {
        napi_value message, error;
        napi_create_string_utf8(engine->env, "JsBay engine closed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(engine->env, nullptr, message, &error);
        napi_reject_deferred(engine->env, entry.second, error);
    }
    if (exception)
        napi_throw(engine->env, exception);
}
static void releaseEngineAsyncResources(Engine *engine) {
    const bool was_active = engine->close_completion_active;
    engine->close_completion_active = true;
    if (engine->async_context) {
        napi_async_destroy(engine->env, engine->async_context);
        engine->async_context = nullptr;
    }
    for (auto reference : {engine->async_resource, engine->wrapper})
        if (reference)
            napi_delete_reference(engine->env, reference);
    engine->async_resource = nullptr;
    engine->wrapper = nullptr;
    engine->close_completion_active = was_active;
}
static void resolveCloseWaiters(Engine *engine) {
    if (engine->environment_cleaning_up) {
        engine->close_waiters.clear();
        return;
    }
    napi_handle_scope scope = nullptr;
    napi_callback_scope callback_scope = nullptr;
    napi_value resource = nullptr;
    if (!engine->async_context || !engine->async_resource ||
        napi_open_handle_scope(engine->env, &scope) != napi_ok) {
        engine->close_waiters.clear();
        return;
    }
    if (napi_get_reference_value(engine->env, engine->async_resource, &resource) != napi_ok ||
        napi_open_callback_scope(engine->env, resource, engine->async_context, &callback_scope) !=
            napi_ok) {
        napi_close_handle_scope(engine->env, scope);
        engine->close_waiters.clear();
        return;
    }
    if (engine->close_loop_referenced && engine->loop && engine->loop->async_ready &&
        !uv_is_closing(reinterpret_cast<uv_handle_t *>(&engine->loop->async)))
        uv_unref(reinterpret_cast<uv_handle_t *>(&engine->loop->async));
    engine->close_loop_referenced = false;
    for (auto deferred : engine->close_waiters)
        napi_resolve_deferred(engine->env, deferred, undefined(engine->env));
    engine->close_waiters.clear();
    napi_close_callback_scope(engine->env, callback_scope);
    napi_close_handle_scope(engine->env, scope);
}
static void completeCloseWaiters(Engine *engine) {
    engine->close_completion_active = true;
    resolveCloseWaiters(engine);
    releaseEngineAsyncResources(engine);
    engine->close_completion_active = false;
}
static void finishClose(Engine *engine) {
    if (engine->destroyed || engine->active_operations != 0)
        return;
    if (!engine->embed_destroy_callback) {
        if (!engine->core_destroy_requested) {
            engine->core_destroy_requested = true;
            finishCoreGenerationClose(engine);
        }
        if (!jsbay_engine_is_destroyed(engine->id, engine->core_generation)) {
            scheduleCloseWake(engine);
            return;
        }
        engine->destroyed = true;
        releaseBridge(engine->callbacks);
        if (engine->callbacks)
            eraseCallbackBridge(engine->callbacks->token);
        rejectObservers(engine);
        for (auto *completion : engine->completions) {
            completion->engine = nullptr;
            completion->completed = true;
            releaseCompletion(completion);
        }
        engine->completions.clear();
        if (engine->promise_then) {
            napi_delete_reference(engine->env, engine->promise_then);
            engine->promise_then = nullptr;
        }
        if (engine->host_stack_getter) {
            napi_delete_reference(engine->env, engine->host_stack_getter);
            engine->host_stack_getter = nullptr;
        }
        closeLoop(engine, false);
        if (engine->environment_cleaning_up) {
            releaseEngineAsyncResources(engine);
        } else if (!engine->loop) {
            completeCloseWaiters(engine);
        }
        engine->embed_task_observer = nullptr;
        engine->embed_task_observer_data = nullptr;
        maybeDeleteEngine(engine);
        return;
    }
    if (!engine->core_destroy_requested) {
        engine->core_destroy_requested = true;
        finishCoreGenerationClose(engine);
    }
    if (!jsbay_engine_is_destroyed(engine->id, engine->core_generation)) {
        scheduleCloseWake(engine);
        return;
    }
    engine->destroyed = true;
    releaseBridge(engine->callbacks);
    if (engine->callbacks)
        eraseCallbackBridge(engine->callbacks->token);
    rejectObservers(engine);
    for (auto *completion : engine->completions) {
        completion->engine = nullptr;
        completion->completed = true;
        releaseCompletion(completion);
    }
    engine->completions.clear();
    if (engine->promise_then) {
        napi_delete_reference(engine->env, engine->promise_then);
        engine->promise_then = nullptr;
    }
    if (engine->host_stack_getter) {
        napi_delete_reference(engine->env, engine->host_stack_getter);
        engine->host_stack_getter = nullptr;
    }
    closeLoop(engine, false);
    engine->embed_task_observer = nullptr;
    engine->embed_task_observer_data = nullptr;
    if (engine->embed_destroy_callback) {
        auto callback = engine->embed_destroy_callback;
        auto *user_data = engine->embed_user_data;
        engine->embed_destroy_callback = nullptr;
        engine->embed_user_data = nullptr;
        callback(user_data);
    }
    if (engine->environment_cleaning_up) {
        releaseEngineAsyncResources(engine);
    } else if (!engine->loop) {
        completeCloseWaiters(engine);
    }
    maybeDeleteEngine(engine);
}
static void environmentCleanup(void *opaque) {
    auto *engine = static_cast<Engine *>(opaque);
    engine->environment_cleaning_up = true;
    engine->cleanup_hook_registered = false;
    engine->closed = true;
    engine->destroy_pending = true;
    engine->close_waiters.clear();
    rejectObservers(engine);
    if (engine->active_operations == 0)
        finishClose(engine);
}
static void maybeDeleteEngine(Engine *engine) {
    if (!engine->wrapper_finalized || !engine->destroyed || engine->loop ||
        engine->close_completion_active)
        return;
    if (engine->cleanup_hook_registered)
        napi_remove_env_cleanup_hook(engine->env, environmentCleanup, engine);
    delete engine;
}
static void requestClose(Engine *engine) {
    if (!engine || engine->destroy_pending)
        return;
    engine->closed = true;
    engine->destroy_pending = true;
    releaseBridge(engine->callbacks);
    rejectObservers(engine);
    if (engine->active_operations == 0)
        finishClose(engine);
}
static bool bytes(napi_env env, napi_value input, const uint8_t **data, size_t *size) {
    bool array_buffer = false, typed = false, buffer = false, data_view = false;
    if (napi_is_dataview(env, input, &data_view) == napi_ok && data_view) {
        void *raw = nullptr;
        napi_value backing;
        size_t offset = 0;
        if (napi_get_dataview_info(env, input, size, &raw, &backing, &offset) != napi_ok)
            return false;
        *data = static_cast<const uint8_t *>(raw);
        return true;
    }
    if (napi_is_buffer(env, input, &buffer) == napi_ok && buffer) {
        void *raw = nullptr;
        return napi_get_buffer_info(env, input, &raw, size) == napi_ok &&
               ((*data = static_cast<const uint8_t *>(raw)), true);
    }
    if (napi_is_arraybuffer(env, input, &array_buffer) == napi_ok && array_buffer) {
        void *raw = nullptr;
        return napi_get_arraybuffer_info(env, input, &raw, size) == napi_ok &&
               ((*data = static_cast<const uint8_t *>(raw)), true);
    }
    if (napi_is_typedarray(env, input, &typed) == napi_ok && typed) {
        napi_typedarray_type type;
        size_t count = 0, offset = 0;
        void *raw = nullptr;
        napi_value backing;
        if (napi_get_typedarray_info(env, input, &type, &count, &raw, &backing, &offset) != napi_ok)
            return false;
        const size_t width =
            type == napi_int8_array || type == napi_uint8_array || type == napi_uint8_clamped_array
                ? 1
            : type == napi_int16_array || type == napi_uint16_array ? 2
            : type == napi_int32_array || type == napi_uint32_array || type == napi_float32_array
                ? 4
                : 8;
        *data = static_cast<const uint8_t *>(raw);
        *size = count * width;
        return true;
    }
    return false;
}

static bool sameValue(napi_env env, napi_value left, napi_value right) {
    bool equal = false;
    return napi_strict_equals(env, left, right, &equal) == napi_ok && equal;
}

static bool guestCall(Engine *engine, jsbay_value_t fn, const jsbay_value_t *args, size_t count,
                      Value &out) {
    Value receiver, exception;
    return jsbay_value_undefined(engine->id, &receiver.id) == JSBAY_OK &&
           jsbay_value_call(fn, receiver.id, args, count, &out.id, &exception.id) == JSBAY_OK;
}
static bool guestSame(Engine *engine, jsbay_value_t left, jsbay_value_t right) {
    Value result;
    jsbay_value_t args[] = {left, right};
    bool equal = false;
    return guestCall(engine, engine->object_is, args, 2, result) &&
           jsbay_value_to_bool(result.id, &equal) == JSBAY_OK && equal;
}
static bool ownData(Engine *engine, jsbay_value_t object, jsbay_value_t key, Value &out) {
    Value descriptor, value_key, owns, exception;
    jsbay_value_t args[] = {object, key};
    if (!guestCall(engine, engine->get_descriptor, args, 2, descriptor) ||
        jsbay_value_new_string(engine->id, text("value"), &value_key.id) != JSBAY_OK)
        return false;
    jsbay_value_t own_args[] = {value_key.id};
    bool has_value = false;
    if (jsbay_value_call(engine->has_own, descriptor.id, own_args, 1, &owns.id, &exception.id) !=
            JSBAY_OK ||
        jsbay_value_to_bool(owns.id, &has_value) != JSBAY_OK || !has_value)
        return false;
    return jsbay_value_get(descriptor.id, text("value"), &out.id, &exception.id) == JSBAY_OK;
}
static bool nodeField(Engine *engine, napi_value object, const char *name, napi_value *out) {
    napi_env env = engine->env;
    napi_value global, constructor, descriptor_fn, key, value_key;
    if (napi_get_global(env, &global) != napi_ok ||
        napi_get_named_property(env, global, "Object", &constructor) != napi_ok ||
        napi_get_named_property(env, constructor, "getOwnPropertyDescriptor", &descriptor_fn) !=
            napi_ok ||
        napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &key) != napi_ok ||
        napi_create_string_utf8(env, "value", NAPI_AUTO_LENGTH, &value_key) != napi_ok)
        return false;
    napi_value cursor = object;
    for (unsigned depth = 0; depth < 64; ++depth) {
        napi_value descriptor;
        napi_value args[] = {cursor, key};
        napi_valuetype type;
        if (napi_call_function(env, constructor, descriptor_fn, 2, args, &descriptor) != napi_ok ||
            napi_typeof(env, descriptor, &type) != napi_ok)
            return false;
        if (type != napi_undefined) {
            bool data = false;
            if (napi_has_own_property(env, descriptor, value_key, &data) != napi_ok)
                return false;
            if (data)
                return napi_get_property(env, descriptor, value_key, out) == napi_ok;
            napi_value getter, native;
            bool equal = false;
            if (std::strcmp(name, "stack") == 0 && engine->host_stack_getter &&
                napi_get_named_property(env, descriptor, "get", &getter) == napi_ok &&
                napi_get_reference_value(env, engine->host_stack_getter, &native) == napi_ok &&
                napi_strict_equals(env, getter, native, &equal) == napi_ok && equal)
                return napi_get_property(env, object, key, out) == napi_ok;
            return false;
        }
        if (napi_get_prototype(env, cursor, &cursor) != napi_ok ||
            napi_typeof(env, cursor, &type) != napi_ok)
            return false;
        if (type == napi_null) {
            *out = undefined(env);
            return true;
        }
    }
    return false;
}
static bool guestField(Engine *engine, jsbay_value_t object, const char *name, Value &out) {
    Value key, cursor, exception;
    if (jsbay_value_new_string(engine->id, text(name), &key.id) != JSBAY_OK ||
        jsbay_value_retain(object, &cursor.id) != JSBAY_OK)
        return false;
    for (unsigned depth = 0; depth < 64; ++depth) {
        Value descriptor;
        jsbay_value_t args[] = {cursor.id, key.id};
        jsbay_value_kind_t type;
        if (!guestCall(engine, engine->get_descriptor, args, 2, descriptor) ||
            jsbay_value_type(descriptor.id, &type) != JSBAY_OK)
            return false;
        if (type != JSBAY_VALUE_UNDEFINED) {
            if (ownData(engine, cursor.id, key.id, out))
                return true;
            Value getter;
            if (std::strcmp(name, "stack") == 0 && engine->guest_stack_getter &&
                jsbay_value_get(descriptor.id, text("get"), &getter.id, &exception.id) ==
                    JSBAY_OK &&
                guestSame(engine, getter.id, engine->guest_stack_getter))
                return jsbay_value_get(object, text(name), &out.id, &exception.id) == JSBAY_OK;
            return false;
        }
        Value prototype;
        jsbay_value_t prototype_args[] = {cursor.id};
        if (!guestCall(engine, engine->get_prototype, prototype_args, 1, prototype) ||
            jsbay_value_type(prototype.id, &type) != JSBAY_OK)
            return false;
        if (type == JSBAY_VALUE_NULL)
            return jsbay_value_undefined(engine->id, &out.id) == JSBAY_OK;
        jsbay_value_release(cursor.id);
        cursor.id = prototype.id;
        prototype.id = 0;
    }
    return false;
}
static jsbay_status_t defineData(Engine *engine, jsbay_value_t target, const std::string &key,
                                 jsbay_value_t value, jsbay_value_t *exception,
                                 bool enumerable = true) {
    Value null, descriptor, name, yes, no, result;
    if (jsbay_value_null(engine->id, &null.id) != JSBAY_OK)
        return JSBAY_OUT_OF_MEMORY;
    jsbay_value_t create_args[] = {null.id};
    if (!guestCall(engine, engine->create_object, create_args, 1, descriptor) ||
        jsbay_value_new_string(engine->id, text(key), &name.id) != JSBAY_OK ||
        jsbay_value_new_bool(engine->id, true, &yes.id) != JSBAY_OK)
        return JSBAY_OUT_OF_MEMORY;
    auto status = jsbay_value_set(descriptor.id, text("value"), value, exception);
    for (const char *field : {"writable", "configurable"})
        if (status == JSBAY_OK)
            status = jsbay_value_set(descriptor.id, text(field), yes.id, exception);
    if (status == JSBAY_OK && !enumerable)
        status = jsbay_value_new_bool(engine->id, false, &no.id);
    if (status == JSBAY_OK)
        status = jsbay_value_set(descriptor.id, text("enumerable"), enumerable ? yes.id : no.id,
                                 exception);
    if (status != JSBAY_OK)
        return status;
    jsbay_value_t args[] = {target, name.id, descriptor.id};
    return jsbay_value_call(engine->define_property, null.id, args, 3, &result.id, exception);
}
static jsbay_status_t nodeToValue(napi_env env, Engine *engine, napi_value input,
                                  jsbay_value_t *out, jsbay_value_t *exception,
                                  std::vector<napi_value> *ancestors, unsigned depth = 0,
                                  ConversionBudget *budget = nullptr) {
    ConversionBudget local_budget;
    if (!budget)
        budget = &local_budget;
    if (depth > 64 || !budget->node())
        return JSBAY_UNSUPPORTED;
    napi_valuetype type;
    if (napi_typeof(env, input, &type) != napi_ok)
        return JSBAY_INVALID_ARGUMENT;
    if (type == napi_undefined)
        return jsbay_value_undefined(engine->id, out);
    if (type == napi_null)
        return jsbay_value_null(engine->id, out);
    if (type == napi_boolean) {
        bool value;
        if (napi_get_value_bool(env, input, &value) != napi_ok)
            return JSBAY_INVALID_ARGUMENT;
        return jsbay_value_new_bool(engine->id, value, out);
    }
    if (type == napi_number) {
        double value;
        if (napi_get_value_double(env, input, &value) != napi_ok)
            return JSBAY_INVALID_ARGUMENT;
        return jsbay_value_new_number(engine->id, value, out);
    }
    if (type == napi_string) {
        std::string value;
        return boundedString(env, input, budget, &value)
                   ? jsbay_value_new_string(engine->id, text(value), out)
                   : JSBAY_INVALID_ARGUMENT;
    }
    const uint8_t *raw = nullptr;
    size_t size = 0;
    if (bytes(env, input, &raw, &size))
        return budget->addBytes(size) ? jsbay_value_new_array_buffer(engine->id, raw, size, out)
                                      : JSBAY_UNSUPPORTED;
    if (type != napi_object)
        return JSBAY_UNSUPPORTED;
    bool is_error = false;
    if (napi_is_error(env, input, &is_error) == napi_ok && is_error) {
        napi_value message;
        std::string message_text;
        if (!nodeField(engine, input, "message", &message))
            return JSBAY_UNSUPPORTED;
        napi_valuetype message_type;
        napi_typeof(env, message, &message_type);
        if (message_type != napi_undefined && !boundedString(env, message, budget, &message_text))
            return JSBAY_UNSUPPORTED;
        auto status = jsbay_value_new_error(engine->id, text(message_text), out);
        for (const char *field : {"name", "stack"}) {
            napi_value property;
            std::string copied;
            Value value;
            if (!nodeField(engine, input, field, &property))
                return JSBAY_UNSUPPORTED;
            napi_valuetype property_type;
            napi_typeof(env, property, &property_type);
            if (property_type == napi_undefined)
                continue;
            if (!boundedString(env, property, budget, &copied))
                return JSBAY_UNSUPPORTED;
            if (status == JSBAY_OK)
                status = jsbay_value_new_string(engine->id, text(copied), &value.id);
            if (status == JSBAY_OK)
                status = defineData(engine, *out, field, value.id, exception, false);
        }
        return status;
    }
    for (auto parent : *ancestors)
        if (sameValue(env, parent, input))
            return JSBAY_UNSUPPORTED;
    ancestors->push_back(input);
    struct Pop {
        std::vector<napi_value> *values;
        ~Pop() {
            values->pop_back();
        }
    } pop{ancestors};
    bool array = false;
    if (napi_is_array(env, input, &array) != napi_ok)
        return JSBAY_INVALID_ARGUMENT;
    if (!array) {
        napi_value prototype, global, object, object_prototype, null;
        napi_get_null(env, &null);
        if (napi_get_prototype(env, input, &prototype) != napi_ok ||
            napi_get_global(env, &global) != napi_ok ||
            napi_get_named_property(env, global, "Object", &object) != napi_ok ||
            napi_get_named_property(env, object, "prototype", &object_prototype) != napi_ok ||
            (!sameValue(env, prototype, object_prototype) && !sameValue(env, prototype, null)))
            return JSBAY_UNSUPPORTED;
    }
    auto status =
        array ? jsbay_value_new_array(engine->id, out) : jsbay_value_new_object(engine->id, out);
    if (status != JSBAY_OK)
        return status;
    napi_value keys, global, object, descriptor_fn;
    if (napi_get_all_property_names(
            env, input, napi_key_own_only,
            static_cast<napi_key_filter>(napi_key_enumerable | napi_key_skip_symbols),
            napi_key_numbers_to_strings, &keys) != napi_ok ||
        napi_get_global(env, &global) != napi_ok ||
        napi_get_named_property(env, global, "Object", &object) != napi_ok ||
        napi_get_named_property(env, object, "getOwnPropertyDescriptor", &descriptor_fn) != napi_ok)
        return JSBAY_INVALID_ARGUMENT;
    uint32_t length = 0;
    if (napi_get_array_length(env, keys, &length) != napi_ok)
        return JSBAY_INVALID_ARGUMENT;
    if (length > ConversionBudget::max_nodes - budget->nodes)
        return JSBAY_UNSUPPORTED;
    for (uint32_t index = 0; index < length; ++index) {
        napi_value key, descriptor, child, value_key;
        std::string name;
        bool has_value = false;
        if (napi_get_element(env, keys, index, &key) != napi_ok ||
            !boundedString(env, key, budget, &name))
            return JSBAY_INVALID_ARGUMENT;
        napi_value args[] = {input, key};
        if (napi_create_string_utf8(env, "value", NAPI_AUTO_LENGTH, &value_key) != napi_ok ||
            napi_call_function(env, object, descriptor_fn, 2, args, &descriptor) != napi_ok ||
            napi_has_own_property(env, descriptor, value_key, &has_value) != napi_ok ||
            !has_value || napi_get_property(env, descriptor, value_key, &child) != napi_ok)
            return JSBAY_UNSUPPORTED;
        Value copied;
        status =
            nodeToValue(env, engine, child, &copied.id, exception, ancestors, depth + 1, budget);
        if (status == JSBAY_OK)
            status = defineData(engine, *out, name, copied.id, exception);
        if (status != JSBAY_OK)
            return status;
    }
    if (array) {
        uint32_t array_length = 0;
        Value copied;
        if (napi_get_array_length(env, input, &array_length) != napi_ok)
            return JSBAY_INVALID_ARGUMENT;
        status = jsbay_value_new_number(engine->id, array_length, &copied.id);
        if (status == JSBAY_OK)
            status = jsbay_value_set(*out, text("length"), copied.id, exception);
    }
    return status;
}
static napi_value nodeValue(napi_env env, Engine *engine, jsbay_value_t value,
                            jsbay_value_t *exception, unsigned depth = 0,
                            ConversionBudget *budget = nullptr) {
    ConversionBudget local_budget;
    if (!budget)
        budget = &local_budget;
    if (depth > 64 || !budget->node())
        return throwText(env, "JsBay value nesting is too deep or circular");
    jsbay_value_kind_t type;
    if (jsbay_value_type(value, &type) != JSBAY_OK)
        return throwText(env, "could not inspect JsBay value");
    napi_value out;
    if (type == JSBAY_VALUE_UNDEFINED)
        return undefined(env);
    if (type == JSBAY_VALUE_NULL) {
        napi_get_null(env, &out);
        return out;
    }
    if (type == JSBAY_VALUE_BOOL) {
        bool raw;
        if (jsbay_value_to_bool(value, &raw) != JSBAY_OK)
            return nullptr;
        napi_get_boolean(env, raw, &out);
        return out;
    }
    if (type == JSBAY_VALUE_NUMBER) {
        double raw;
        if (jsbay_value_to_number(value, &raw) != JSBAY_OK)
            return nullptr;
        napi_create_double(env, raw, &out);
        return out;
    }
    if (type == JSBAY_VALUE_STRING) {
        jsbay_bytes_t raw{};
        if (jsbay_value_to_utf8(value, &raw, exception) != JSBAY_OK)
            return nullptr;
        if (injectedFailure("node_string") || !budget->addBytes(raw.len) ||
            napi_create_string_utf8(env, reinterpret_cast<const char *>(raw.data), raw.len, &out) !=
                napi_ok) {
            jsbay_free_bytes(raw);
            return nullptr;
        }
        jsbay_free_bytes(raw);
        return out;
    }
    if (type != JSBAY_VALUE_ARRAY && type != JSBAY_VALUE_OBJECT)
        return throwText(env, "unsupported JsBay value");
    jsbay_bytes_t raw{};
    if (jsbay_value_copy_buffer(value, &raw, exception) == JSBAY_OK) {
        void *copy = nullptr;
        if (!budget->addBytes(raw.len) ||
            napi_create_arraybuffer(env, raw.len, &copy, &out) != napi_ok) {
            jsbay_free_bytes(raw);
            return nullptr;
        }
        if (raw.len)
            std::memcpy(copy, raw.data, raw.len);
        jsbay_free_bytes(raw);
        return out;
    }
    if (*exception) {
        jsbay_value_release(*exception);
        *exception = 0;
    }
    bool is_error = false;
    if (jsbay_value_instance_of(value, engine->error_constructor, &is_error, exception) != JSBAY_OK)
        return nullptr;
    if (is_error) {
        Value message;
        if (!guestField(engine, value, "message", message))
            return throwText(env, "Error accessors cannot be copied");
        napi_value copied = nodeValue(env, engine, message.id, exception, depth + 1, budget);
        if (!copied || napi_create_error(env, nullptr, copied, &out) != napi_ok)
            return nullptr;
        for (const char *field : {"name", "stack"}) {
            Value property;
            if (!guestField(engine, value, field, property))
                return throwText(env, "Error accessors cannot be copied");
            napi_value item = nodeValue(env, engine, property.id, exception, depth + 1, budget);
            napi_property_descriptor defined{};
            defined.utf8name = field;
            defined.value = item;
            defined.attributes =
                static_cast<napi_property_attributes>(napi_writable | napi_configurable);
            if (!item || napi_define_properties(env, out, 1, &defined) != napi_ok)
                return nullptr;
        }
        return out;
    }
    if (type == JSBAY_VALUE_OBJECT) {
        Value prototype;
        jsbay_value_t args[] = {value};
        jsbay_value_kind_t prototype_type;
        if (!guestCall(engine, engine->get_prototype, args, 1, prototype) ||
            jsbay_value_type(prototype.id, &prototype_type) != JSBAY_OK ||
            (prototype_type != JSBAY_VALUE_NULL &&
             !guestSame(engine, prototype.id, engine->object_prototype)))
            return throwText(env, "unsupported JsBay object prototype");
        if (napi_create_object(env, &out) != napi_ok)
            return nullptr;
    } else {
        Value length;
        double count;
        if (jsbay_value_get(value, text("length"), &length.id, exception) != JSBAY_OK ||
            jsbay_value_to_number(length.id, &count) != JSBAY_OK || !std::isfinite(count) ||
            count < 0 || count > 4294967295.0 || std::floor(count) != count ||
            napi_create_array(env, &out) != napi_ok)
            return nullptr;
        napi_value node_length;
        if (napi_create_double(env, count, &node_length) != napi_ok ||
            napi_set_named_property(env, out, "length", node_length) != napi_ok)
            return nullptr;
    }
    Value keys, length;
    double count = 0;
    if (jsbay_value_keys(value, &keys.id, exception) != JSBAY_OK ||
        jsbay_value_get(keys.id, text("length"), &length.id, exception) != JSBAY_OK ||
        jsbay_value_to_number(length.id, &count) != JSBAY_OK)
        return nullptr;
    if (!std::isfinite(count) || count < 0 || count > ConversionBudget::max_nodes - budget->nodes)
        return throwText(env, "JsBay value has too many properties to copy");
    for (uint32_t index = 0; index < count; ++index) {
        Value key, child;
        jsbay_bytes_t key_bytes{};
        if (jsbay_value_get(keys.id, text(std::to_string(index)), &key.id, exception) != JSBAY_OK ||
            jsbay_value_to_utf8(key.id, &key_bytes, exception) != JSBAY_OK)
            return nullptr;
        napi_value node_key;
        if (injectedFailure("node_key") || !budget->addBytes(key_bytes.len) ||
            napi_create_string_utf8(env, reinterpret_cast<const char *>(key_bytes.data),
                                    key_bytes.len, &node_key) != napi_ok) {
            jsbay_free_bytes(key_bytes);
            return nullptr;
        }
        jsbay_free_bytes(key_bytes);
        if (!ownData(engine, value, key.id, child))
            return throwText(env, "accessor properties cannot be copied");
        napi_value copied = nodeValue(env, engine, child.id, exception, depth + 1, budget);
        napi_property_descriptor property{};
        property.name = node_key;
        property.value = copied;
        property.attributes = static_cast<napi_property_attributes>(
            napi_writable | napi_enumerable | napi_configurable);
        if (!copied || napi_define_properties(env, out, 1, &property) != napi_ok)
            return nullptr;
    }
    return out;
}
static jsbay_status_t completionConversionFailure(Engine *engine, jsbay_value_t *out,
                                                  jsbay_value_t guest_exception = 0) {
    *out = 0;
    bool pending = false;
    if (napi_is_exception_pending(engine->env, &pending) == napi_ok && pending) {
        napi_value error;
        if (napi_get_and_clear_last_exception(engine->env, &error) == napi_ok) {
            Value secondary;
            std::vector<napi_value> ancestors;
            if (nodeToValue(engine->env, engine, error, out, &secondary.id, &ancestors) == JSBAY_OK)
                return JSBAY_OK;
            if (*out) {
                jsbay_value_release(*out);
                *out = 0;
            }
        }
        napi_value ignored;
        (void)napi_get_and_clear_last_exception(engine->env, &ignored);
    }
    if (guest_exception && jsbay_value_retain(guest_exception, out) == JSBAY_OK)
        return JSBAY_OK;
    if (jsbay_value_new_error(engine->id, text("could not convert host completion"), out) ==
        JSBAY_OK)
        return JSBAY_OK;
    return jsbay_value_retain(engine->completion_failure, out);
}
static napi_value conversionFailure(Engine *engine, jsbay_status_t status,
                                    jsbay_value_t exception) {
    bool pending = false;
    if (napi_is_exception_pending(engine->env, &pending) == napi_ok && pending) {
        napi_value error;
        if (napi_get_and_clear_last_exception(engine->env, &error) == napi_ok)
            return error;
    }
    if (status == JSBAY_EXCEPTION && exception) {
        jsbay_value_t secondary = 0;
        napi_value reason = nodeValue(engine->env, engine, exception, &secondary);
        if (secondary)
            jsbay_value_release(secondary);
        if (reason)
            return reason;
        bool pending = false;
        if (napi_is_exception_pending(engine->env, &pending) == napi_ok && pending) {
            napi_value error;
            if (napi_get_and_clear_last_exception(engine->env, &error) == napi_ok)
                return error;
        }
    }
    napi_value message, error, number, code_text;
    std::string text_value = "js-bay status " + std::to_string(static_cast<int>(status));
    const char *status_code = "JSBAY_UNKNOWN";
    switch (status) {
    case JSBAY_OK:
        status_code = "JSBAY_OK";
        break;
    case JSBAY_EXCEPTION:
        status_code = "JSBAY_EXCEPTION";
        break;
    case JSBAY_INVALID_ARGUMENT:
        status_code = "JSBAY_INVALID_ARGUMENT";
        break;
    case JSBAY_WRONG_THREAD:
        status_code = "JSBAY_WRONG_THREAD";
        break;
    case JSBAY_INSTANCE_NOT_FOUND:
        status_code = "JSBAY_INSTANCE_NOT_FOUND";
        break;
    case JSBAY_STALE_VALUE:
        status_code = "JSBAY_STALE_VALUE";
        break;
    case JSBAY_OUT_OF_MEMORY:
        status_code = "JSBAY_OUT_OF_MEMORY";
        break;
    case JSBAY_UNSUPPORTED:
        status_code = "JSBAY_UNSUPPORTED";
        break;
    case JSBAY_LOOP_FAILED:
        status_code = "JSBAY_LOOP_FAILED";
        break;
    }
    if (napi_create_string_utf8(engine->env, text_value.c_str(), text_value.size(), &message) ==
            napi_ok &&
        napi_create_error(engine->env, nullptr, message, &error) == napi_ok &&
        napi_create_int32(engine->env, status, &number) == napi_ok &&
        napi_create_string_utf8(engine->env, status_code, NAPI_AUTO_LENGTH, &code_text) ==
            napi_ok &&
        napi_set_named_property(engine->env, error, "status", number) == napi_ok &&
        napi_set_named_property(engine->env, error, "code", code_text) == napi_ok)
        return error;
    pending = false;
    if (napi_is_exception_pending(engine->env, &pending) == napi_ok && pending) {
        napi_value fallback;
        if (napi_get_and_clear_last_exception(engine->env, &fallback) == napi_ok)
            return fallback;
    }
    return undefined(engine->env);
}
static napi_value guestFailure(Engine *engine, jsbay_status_t status, jsbay_value_t exception) {
    return conversionFailure(engine, status, exception);
}
#include "jsbay_node_values.inc"
static napi_value evaluateValue(napi_env env, napi_callback_info info) {
    size_t count = 3;
    napi_value args[3], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    Engine *engine = unwrap(env, self);
    if (engine)
        engine->last_cache_hit = false;
    std::string source, filename = "<node>", cache_dir, cache_version;
    napi_valuetype filename_type = napi_undefined;
    if (count > 1)
        napi_typeof(env, args[1], &filename_type);
    if (!requireEngine(env, engine) || count < 1 || !string(env, args[0], &source) ||
        (filename_type != napi_undefined && !string(env, args[1], &filename)))
        return throwText(env, "evaluateValue requires source and optional filename");
    Operation operation(engine);
    jsbay_engine_evaluate_options_t options{};
    options.struct_size = sizeof(options);
    options.out_cache_hit = &engine->last_cache_hit;
    if (count > 2) {
        napi_valuetype type;
        bool has_dir = false, has_version = false;
        napi_value dir, version;
        if (napi_typeof(env, args[2], &type) != napi_ok || type != napi_object ||
            napi_has_named_property(env, args[2], "cacheDir", &has_dir) != napi_ok ||
            napi_has_named_property(env, args[2], "cacheVersion", &has_version) != napi_ok ||
            has_dir != has_version)
            return throwText(env, "cacheDir and cacheVersion must be provided together");
        if (has_dir &&
            (napi_get_named_property(env, args[2], "cacheDir", &dir) != napi_ok ||
             napi_get_named_property(env, args[2], "cacheVersion", &version) != napi_ok ||
             !string(env, dir, &cache_dir) || !string(env, version, &cache_version) ||
             cache_dir.empty() || cache_version.empty()))
            return throwText(env, "cacheDir and cacheVersion must be non-empty strings");
        if (has_dir) {
            options.cache_dir = text(cache_dir);
            options.cache_version = text(cache_version);
        }
    }
    if (engine->closed)
        return throwText(env, "JsBay engine closed");
    Value result, exception;
    const auto status = jsbay_engine_evaluate(engine->id, text(source), text(filename),
                                              options.cache_dir.len ? &options : nullptr,
                                              &result.id, &exception.id);
    if (status != JSBAY_OK) {
        napi_value reason = guestFailure(engine, status, exception.id);
        if (exception.id) {
            jsbay_value_release(exception.id);
            exception.id = 0;
        }
        return napi_throw(env, reason) == napi_ok ? nullptr : nullptr;
    }
    if (engine->closed)
        return throwStatus(env, JSBAY_INSTANCE_NOT_FOUND);
    if (!initNodeValueClass(engine))
        return throwText(env, "could not initialize NodeValue");
    return transferNodeValue(engine, result);
}
struct CompletionInvocation {
    napi_env env;
    Completion *completion;
    jsbay_status_t outcome;
    napi_value value;
};

static void finishCompletionInGeneration(void *opaque) noexcept {
    auto *invocation = static_cast<CompletionInvocation *>(opaque);
    napi_env env = invocation->env;
    Completion *completion = invocation->completion;
    jsbay_status_t outcome = invocation->outcome;
    napi_value value = invocation->value;
    if (!completion || completion->completed)
        return;
    completion->completed = true;
    Engine *engine = completion->engine;
    if (!engine)
        return;
    Operation operation(engine);
    Value copied, exception, conversion_error;
    std::vector<napi_value> ancestors;
    auto status = nodeToValue(env, engine, value, &copied.id, &exception.id, &ancestors);
    jsbay_value_t settlement_value = copied.id;
    if (status != JSBAY_OK) {
        if (completionConversionFailure(engine, &conversion_error.id, exception.id) != JSBAY_OK) {
            requestClose(engine);
            return;
        }
        settlement_value = conversion_error.id;
        outcome = JSBAY_EXCEPTION;
    }
    if (!engine->closed &&
        jsbay_promise_settle(completion->request, outcome, settlement_value) != JSBAY_OK)
        requestClose(engine);
    completion->engine = nullptr;
    engine->completions.erase(completion);
    releaseCompletion(completion);
}

static void finish(napi_env env, Completion *completion, jsbay_status_t outcome, napi_value value) {
    if (!completion || completion->completed)
        return;
    Engine *engine = completion->engine;
    if (!engine)
        return;
    CompletionInvocation invocation{env, completion, outcome, value};
    const jsbay_status_t status = jsbay_engine_with_generation_scope(
        engine->id, engine->core_generation, finishCompletionInGeneration, &invocation);
    if (status != JSBAY_OK)
        requestClose(engine);
}
static jsbay_status_t failCompletion(Engine *engine, Completion *completion) {
    bool pending = false;
    if (napi_is_exception_pending(engine->env, &pending) == napi_ok && pending) {
        napi_value ignored;
        napi_get_and_clear_last_exception(engine->env, &ignored);
    }
    completion->completed = true;
    Value reason;
    auto status =
        injectedFailure("completion_error")
            ? JSBAY_OUT_OF_MEMORY
            : jsbay_value_new_error(engine->id, text("could not create host completion handler"),
                                    &reason.id);
    if (status != JSBAY_OK)
        status = jsbay_value_retain(engine->completion_failure, &reason.id);
    if (status == JSBAY_OK)
        status = jsbay_promise_settle(completion->request, JSBAY_EXCEPTION, reason.id);
    completion->engine = nullptr;
    engine->completions.erase(completion);
    releaseCompletion(completion);
    if (status != JSBAY_OK)
        requestClose(engine);
    return status;
}
static napi_value fulfilled(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    void *data;
    napi_get_cb_info(env, info, &count, args, nullptr, &data);
    finish(env, static_cast<Completion *>(data), JSBAY_OK, count ? args[0] : undefined(env));
    return undefined(env);
}
static napi_value rejected(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    void *data;
    napi_get_cb_info(env, info, &count, args, nullptr, &data);
    finish(env, static_cast<Completion *>(data), JSBAY_EXCEPTION, count ? args[0] : undefined(env));
    return undefined(env);
}
static jsbay_status_t hostCallImpl(int, void *opaque, jsbay_value_t, size_t argc,
                                   const jsbay_value_t *argv, jsbay_value_t *out_value,
                                   jsbay_value_t *out_exception) {
    auto *binding = static_cast<Binding *>(opaque);
    Engine *engine = binding->engine;
    if (engine->closed)
        return JSBAY_INSTANCE_NOT_FOUND;
    Operation operation(engine);
    napi_value callback;
    if (napi_get_reference_value(engine->env, binding->callback, &callback) != napi_ok)
        return JSBAY_INSTANCE_NOT_FOUND;
    std::vector<napi_value> args;
    ConversionBudget arguments_budget;
    for (size_t index = 0; index < argc; ++index) {
        napi_value item =
            nodeValue(engine->env, engine, argv[index], out_exception, 0, &arguments_budget);
        if (!item)
            return JSBAY_INVALID_ARGUMENT;
        args.push_back(item);
    }
    if (!binding->asynchronous) {
        napi_value result;
        auto called = injectedFailure("call_host")
                          ? napi_generic_failure
                          : napi_call_function(engine->env, undefined(engine->env), callback,
                                               args.size(), args.data(), &result);
        if (called != napi_ok) {
            bool pending = false;
            if (napi_is_exception_pending(engine->env, &pending) != napi_ok || !pending ||
                napi_get_and_clear_last_exception(engine->env, &result) != napi_ok)
                return JSBAY_INVALID_ARGUMENT;
        }
        std::vector<napi_value> ancestors;
        Value converted, secondary;
        auto status =
            nodeToValue(engine->env, engine, result, &converted.id, &secondary.id, &ancestors);
        if (status == JSBAY_OK) {
            *(called == napi_ok ? out_value : out_exception) = converted.id;
            converted.id = 0;
            return called == napi_ok ? JSBAY_OK : JSBAY_EXCEPTION;
        }
        if (secondary.id) {
            *out_exception = secondary.id;
            secondary.id = 0;
            return JSBAY_EXCEPTION;
        }
        return status;
    }
    uint64_t request = 0;
    auto status = jsbay_promise_create(engine->id, &request, out_value, out_exception);
    if (status != JSBAY_OK)
        return status;
    auto *completion = new Completion{};
    completion->engine = engine;
    completion->request = request;
    engine->completions.insert(completion);
    // Subscribe before invoking application code so setup failure cannot strand a rejected host promise.
    napi_value normalized, on_ok, on_error, ignored, then;
    PendingDeferred deferred(engine->env);
    if (napi_create_promise(engine->env, &deferred.value, &normalized) != napi_ok ||
        napi_get_reference_value(engine->env, engine->promise_then, &then) != napi_ok)
        return failCompletion(engine, completion);
    for (auto descriptor : {std::pair<napi_callback, const char *>{fulfilled, "jsbayFulfilled"},
                            {rejected, "jsbayRejected"}}) {
        napi_value function;
        if (injectedFailure(descriptor.first == fulfilled ? "create_first" : "create_second") ||
            napi_create_function(engine->env, descriptor.second, NAPI_AUTO_LENGTH, descriptor.first,
                                 completion, &function) != napi_ok) {
            return failCompletion(engine, completion);
        }
        ++completion->refs;
        if (injectedFailure(descriptor.first == fulfilled ? "finalize_first" : "finalize_second") ||
            napi_add_finalizer(engine->env, function, completion, completionFinalizer, nullptr,
                               nullptr) != napi_ok) {
            releaseCompletion(completion);
            return failCompletion(engine, completion);
        }
        if (descriptor.first == fulfilled)
            on_ok = function;
        else
            on_error = function;
    }
    napi_value handlers[] = {on_ok, on_error};
    if (napi_call_function(engine->env, normalized, then, 2, handlers, &ignored) != napi_ok)
        return failCompletion(engine, completion);
    napi_value result;
    auto called = injectedFailure("call_host")
                      ? napi_generic_failure
                      : napi_call_function(engine->env, undefined(engine->env), callback,
                                           args.size(), args.data(), &result);
    if (called != napi_ok) {
        bool pending = false;
        if (napi_is_exception_pending(engine->env, &pending) != napi_ok || !pending ||
            napi_get_and_clear_last_exception(engine->env, &result) != napi_ok)
            return failCompletion(engine, completion);
        if (deferred.settle(result, true) != napi_ok)
            return failCompletion(engine, completion);
    } else if (deferred.settle(result) != napi_ok) {
        return failCompletion(engine, completion);
    }
    return JSBAY_OK;
}

static jsbay_status_t hostCall(int instance_id, void *opaque, jsbay_value_t receiver, size_t argc,
                               const jsbay_value_t *argv, jsbay_value_t *out,
                               jsbay_value_t *exception) {
    auto *binding = static_cast<Binding *>(opaque);
    Engine *engine = binding->engine;
    if (engine->closed)
        return JSBAY_INSTANCE_NOT_FOUND;
    Operation operation(engine);
    auto status = hostCallImpl(instance_id, opaque, receiver, argc, argv, out, exception);
    bool pending = false;
    if (napi_is_exception_pending(engine->env, &pending) != napi_ok)
        pending = false;
    if (pending) {
        napi_value error;
        if (napi_get_and_clear_last_exception(engine->env, &error) != napi_ok)
            return JSBAY_INVALID_ARGUMENT;
        if (*out) {
            jsbay_value_release(*out);
            *out = 0;
        }
        if (*exception)
            return JSBAY_EXCEPTION;
        Value converted, secondary;
        std::vector<napi_value> ancestors;
        status = nodeToValue(engine->env, engine, error, &converted.id, &secondary.id, &ancestors);
        if (status == JSBAY_OK) {
            *exception = converted.id;
            converted.id = 0;
            return JSBAY_EXCEPTION;
        }
        if (secondary.id) {
            *exception = secondary.id;
            secondary.id = 0;
        }
        napi_value ignored;
        (void)napi_get_and_clear_last_exception(engine->env, &ignored);
    }
    if (status == JSBAY_OK)
        return status;
    if (*out) {
        jsbay_value_release(*out);
        *out = 0;
    }
    if (*exception)
        return JSBAY_EXCEPTION;
    std::string message =
        "native callback failed with status " + std::to_string(static_cast<int>(status));
    status = jsbay_value_new_error(engine->id, text(message), exception);
    if (status == JSBAY_OK)
        return JSBAY_EXCEPTION;
    status = jsbay_value_retain(engine->completion_failure, exception);
    return status == JSBAY_OK ? JSBAY_EXCEPTION : status;
}
static void finalizeBinding(void *opaque) {
    auto *binding = static_cast<Binding *>(opaque);
    if (binding) {
        if (binding->callback)
            napi_delete_reference(binding->engine->env, binding->callback);
        delete binding;
    }
}

static napi_value evaluate(napi_env env, napi_callback_info info) {
    size_t count = 3;
    napi_value args[3], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    Engine *engine = unwrap(env, self);
    if (engine)
        engine->last_cache_hit = false;
    std::string source, filename = "<node>";
    napi_valuetype filename_type = napi_undefined;
    if (count > 1)
        napi_typeof(env, args[1], &filename_type);
    if (!requireEngine(env, engine) || count < 1 || !string(env, args[0], &source) ||
        (filename_type != napi_undefined && !string(env, args[1], &filename)))
        return throwText(env, "evaluate requires source and optional filename");
    Operation operation(engine);
    jsbay_engine_evaluate_options_t options{};
    options.struct_size = sizeof(options);
    options.out_cache_hit = &engine->last_cache_hit;
    std::string cache_dir, cache_version;
    if (count > 2) {
        napi_valuetype options_type;
        if (napi_typeof(env, args[2], &options_type) != napi_ok || options_type != napi_object)
            return throwText(env, "evaluate options must be an object");
        napi_value cache_dir_value, cache_version_value;
        bool has_cache_dir = false, has_cache_version = false;
        if (napi_has_named_property(env, args[2], "cacheDir", &has_cache_dir) != napi_ok ||
            napi_has_named_property(env, args[2], "cacheVersion", &has_cache_version) != napi_ok ||
            has_cache_dir != has_cache_version)
            return throwText(env, "cacheDir and cacheVersion must be provided together");
        if (has_cache_dir) {
            if (napi_get_named_property(env, args[2], "cacheDir", &cache_dir_value) != napi_ok ||
                napi_get_named_property(env, args[2], "cacheVersion", &cache_version_value) !=
                    napi_ok ||
                !string(env, cache_dir_value, &cache_dir) ||
                !string(env, cache_version_value, &cache_version) || cache_dir.empty() ||
                cache_version.empty())
                return throwText(env, "cacheDir and cacheVersion must be non-empty strings");
            options.cache_dir = text(cache_dir);
            options.cache_version = text(cache_version);
        }
    }
    if (engine->closed)
        return throwText(env, "JsBay engine closed");
    jsbay_value_t value = 0, exception = 0;
    const jsbay_status_t status =
        jsbay_engine_evaluate(engine->id, text(source), text(filename),
                              options.cache_dir.len ? &options : nullptr, &value, &exception);
    if (status != JSBAY_OK) {
        napi_value reason = guestFailure(engine, status, exception);
        if (exception)
            jsbay_value_release(exception);
        napi_throw(env, reason);
        return nullptr;
    }
    jsbay_value_kind_t kind;
    if (jsbay_value_type(value, &kind) == JSBAY_OK && kind == JSBAY_VALUE_OBJECT) {
        Value prototype;
        jsbay_value_t args[] = {value};
        if (guestCall(engine, engine->get_prototype, args, 1, prototype) &&
            guestSame(engine, prototype.id, engine->guest_promise_prototype)) {
            jsbay_value_release(value);
            return throwText(env, "evaluate returned a Promise; use evaluateAsync");
        }
    }
    napi_value result = nodeValue(env, engine, value, &exception);
    jsbay_value_release(value);
    if (!result) {
        if (exception)
            jsbay_value_release(exception);
        return throwText(env, "could not convert JsBay result");
    }
    return result;
}
static napi_value bind(napi_env env, napi_callback_info info, bool asynchronous) {
    size_t count = 2;
    napi_value args[2], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    Engine *engine = unwrap(env, self);
    std::string name;
    napi_valuetype type;
    if (!requireEngine(env, engine) || count != 2 || !string(env, args[0], &name) ||
        napi_typeof(env, args[1], &type) != napi_ok || type != napi_function)
        return throwText(env, asynchronous ? "bindAsync requires name and callback"
                                           : "bind requires name and callback");
    Operation operation(engine);
    auto *binding = new Binding{engine, nullptr, asynchronous};
    if (napi_create_reference(env, args[1], 1, &binding->callback) != napi_ok) {
        delete binding;
        return throwText(env, "could not retain callback");
    }
    jsbay_value_t function = 0, exception = 0;
    const jsbay_status_t status = jsbay_engine_bind(engine->id, text(name), hostCall, binding,
                                                    finalizeBinding, &function, &exception);
    if (function)
        jsbay_value_release(function);
    if (status != JSBAY_OK) {
        finalizeBinding(binding);
        if (exception)
            jsbay_value_release(exception);
        return throwStatus(env, status);
    }
    return undefined(env);
}
static napi_value bindSync(napi_env env, napi_callback_info info) {
    return bind(env, info, false);
}
static napi_value bindAsync(napi_env env, napi_callback_info info) {
    return bind(env, info, true);
}
static jsbay_status_t observe(Engine *engine, bool rejected, size_t argc, const jsbay_value_t *argv,
                              jsbay_value_t *out, jsbay_value_t *exception) {
    if (argc < 1)
        return JSBAY_INVALID_ARGUMENT;
    double number = 0;
    if (jsbay_value_to_number(argv[0], &number) != JSBAY_OK)
        return JSBAY_INVALID_ARGUMENT;
    auto found = engine->observers.find(static_cast<uint64_t>(number));
    if (found == engine->observers.end())
        return jsbay_value_undefined(engine->id, out);
    auto deferred = found->second;
    engine->observers.erase(found);
    Operation operation(engine);
    napi_value value =
        argc > 1 ? nodeValue(engine->env, engine, argv[1], exception) : undefined(engine->env);
    if (!value) {
        value = conversionFailure(engine, *exception ? JSBAY_EXCEPTION : JSBAY_INVALID_ARGUMENT,
                                  *exception);
        rejected = true;
    }
    if (engine->closed) {
        napi_value message = nullptr, error = nullptr;
        if (napi_create_string_utf8(engine->env, "JsBay engine closed", NAPI_AUTO_LENGTH,
                                    &message) == napi_ok &&
            napi_create_error(engine->env, nullptr, message, &error) == napi_ok)
            value = error;
        else
            value = conversionFailure(engine, JSBAY_INVALID_ARGUMENT, 0);
        rejected = true;
    }
    if (rejected)
        napi_reject_deferred(engine->env, deferred, value);
    else
        napi_resolve_deferred(engine->env, deferred, value);
    if (*exception) {
        jsbay_value_release(*exception);
        *exception = 0;
    }
    retainObservers(engine);
    return jsbay_value_undefined(engine->id, out);
}
static jsbay_status_t settleObserver(int, void *data, jsbay_value_t, size_t argc,
                                     const jsbay_value_t *argv, jsbay_value_t *out,
                                     jsbay_value_t *exception) {
    return observe(static_cast<Engine *>(data), false, argc, argv, out, exception);
}
static jsbay_status_t rejectObserver(int, void *data, jsbay_value_t, size_t argc,
                                     const jsbay_value_t *argv, jsbay_value_t *out,
                                     jsbay_value_t *exception) {
    return observe(static_cast<Engine *>(data), true, argc, argv, out, exception);
}
static napi_value evaluateAsync(napi_env env, napi_callback_info info) {
    size_t count = 3;
    napi_value args[3], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    Engine *engine = unwrap(env, self);
    if (engine)
        engine->last_cache_hit = false;
    std::string source, filename = "<node>";
    napi_valuetype filename_type = napi_undefined;
    if (count > 1)
        napi_typeof(env, args[1], &filename_type);
    if (!requireEngine(env, engine) || count < 1 || !string(env, args[0], &source) ||
        (filename_type != napi_undefined && !string(env, args[1], &filename)))
        return throwText(env, "evaluateAsync requires source and optional filename");
    Operation operation(engine);
    jsbay_engine_evaluate_options_t options{};
    options.struct_size = sizeof(options);
    options.out_cache_hit = &engine->last_cache_hit;
    std::string cache_dir, cache_version;
    if (count > 2) {
        napi_valuetype options_type;
        bool has_dir = false, has_version = false;
        napi_value dir_value, version_value;
        if (napi_typeof(env, args[2], &options_type) != napi_ok || options_type != napi_object ||
            napi_has_named_property(env, args[2], "cacheDir", &has_dir) != napi_ok ||
            napi_has_named_property(env, args[2], "cacheVersion", &has_version) != napi_ok ||
            has_dir != has_version)
            return throwText(env,
                             "evaluateAsync options require cacheDir and cacheVersion together");
        if (has_dir &&
            (napi_get_named_property(env, args[2], "cacheDir", &dir_value) != napi_ok ||
             napi_get_named_property(env, args[2], "cacheVersion", &version_value) != napi_ok ||
             !string(env, dir_value, &cache_dir) || !string(env, version_value, &cache_version) ||
             cache_dir.empty() || cache_version.empty()))
            return throwText(env, "cacheDir and cacheVersion must be non-empty strings");
        if (has_dir) {
            options.cache_dir = text(cache_dir);
            options.cache_version = text(cache_version);
        }
    }
    if (engine->closed)
        return throwText(env, "JsBay engine closed");
    napi_deferred deferred;
    napi_value promise;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok)
        return nullptr;
    Value result, exception, normalized;
    auto status = jsbay_engine_evaluate(engine->id, text(source), text(filename),
                                        options.cache_dir.len ? &options : nullptr, &result.id,
                                        &exception.id);
    if (status == JSBAY_OK && !engine->closed)
        status = jsbay_value_call(engine->guest_resolve, engine->guest_promise, &result.id, 1,
                                  &normalized.id, &exception.id);
    if (engine->closed) {
        napi_value message, error;
        napi_create_string_utf8(env, "JsBay engine closed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, deferred, error);
        return promise;
    }
    if (status != JSBAY_OK) {
        napi_reject_deferred(env, deferred, guestFailure(engine, status, exception.id));
        return promise;
    }
    if (engine->observer_id >= 9007199254740991ULL) {
        napi_reject_deferred(env, deferred, guestFailure(engine, JSBAY_OUT_OF_MEMORY, 0));
        return promise;
    }
    auto id = ++engine->observer_id;
    engine->observers.emplace(id, deferred);
    retainObservers(engine);
    Value key, receiver, on_ok, on_error, ignored;
    status = jsbay_value_new_number(engine->id, static_cast<double>(id), &key.id);
    if (status == JSBAY_OK)
        status = jsbay_value_undefined(engine->id, &receiver.id);
    jsbay_value_t bind_args[] = {receiver.id, key.id};
    if (status == JSBAY_OK)
        status = jsbay_value_call(engine->bind_function, engine->dispatch_ok, bind_args, 2,
                                  &on_ok.id, &exception.id);
    if (status == JSBAY_OK)
        status = jsbay_value_call(engine->bind_function, engine->dispatch_error, bind_args, 2,
                                  &on_error.id, &exception.id);
    jsbay_value_t handlers[] = {on_ok.id, on_error.id};
    if (status == JSBAY_OK)
        status = jsbay_value_call(engine->guest_then, normalized.id, handlers, 2, &ignored.id,
                                  &exception.id);
    if (status != JSBAY_OK && engine->observers.erase(id))
        napi_reject_deferred(env, deferred, guestFailure(engine, status, exception.id));
    retainObservers(engine);
    return promise;
}

static bool initializeIntrinsicsImpl(Engine *engine) {
    if (jsbay_value_new_error(engine->id, text("could not create host completion handler"),
                              &engine->completion_failure) != JSBAY_OK)
        return false;

    Value global, object, function, prototype, exception;
    if (jsbay_engine_global(engine->id, &global.id) != JSBAY_OK ||
        jsbay_value_get(global.id, text("Object"), &object.id, &exception.id) != JSBAY_OK ||
        jsbay_value_get(object.id, text("prototype"), &engine->object_prototype, &exception.id) !=
            JSBAY_OK ||
        jsbay_value_get(object.id, text("is"), &engine->object_is, &exception.id) != JSBAY_OK ||
        jsbay_value_get(object.id, text("getPrototypeOf"), &engine->get_prototype, &exception.id) !=
            JSBAY_OK ||
        jsbay_value_get(object.id, text("create"), &engine->create_object, &exception.id) !=
            JSBAY_OK ||
        jsbay_value_get(object.id, text("defineProperty"), &engine->define_property,
                        &exception.id) != JSBAY_OK ||
        jsbay_value_get(object.id, text("getOwnPropertyDescriptor"), &engine->get_descriptor,
                        &exception.id) != JSBAY_OK ||
        jsbay_value_get(engine->object_prototype, text("hasOwnProperty"), &engine->has_own,
                        &exception.id) != JSBAY_OK ||
        jsbay_value_get(global.id, text("Error"), &engine->error_constructor, &exception.id) !=
            JSBAY_OK ||
        jsbay_value_get(global.id, text("Function"), &function.id, &exception.id) != JSBAY_OK ||
        jsbay_value_get(function.id, text("prototype"), &prototype.id, &exception.id) != JSBAY_OK ||
        jsbay_value_get(prototype.id, text("bind"), &engine->bind_function, &exception.id) !=
            JSBAY_OK ||
        jsbay_value_get(global.id, text("Promise"), &engine->guest_promise, &exception.id) !=
            JSBAY_OK ||
        jsbay_value_get(engine->guest_promise, text("resolve"), &engine->guest_resolve,
                        &exception.id) != JSBAY_OK ||
        jsbay_value_get(engine->guest_promise, text("prototype"), &engine->guest_promise_prototype,
                        &exception.id) != JSBAY_OK ||
        jsbay_value_get(engine->guest_promise_prototype, text("then"), &engine->guest_then,
                        &exception.id) != JSBAY_OK)
        return false;
    for (auto entry :
         {std::pair<const char *, jsbay_host_callback_t>{"__jsbay_node_resolve", settleObserver},
          {"__jsbay_node_reject", rejectObserver}}) {
        auto *out = entry.second == settleObserver ? &engine->dispatch_ok : &engine->dispatch_error;
        bool deleted = false;
        if (jsbay_engine_bind(engine->id, text(entry.first), entry.second, engine, nullptr, out,
                              &exception.id) != JSBAY_OK ||
            jsbay_value_delete(global.id, text(entry.first), &deleted, &exception.id) != JSBAY_OK ||
            !deleted)
            return false;
    }
    Value error_prototype, stack_name, descriptor;
    if (jsbay_value_get(engine->error_constructor, text("prototype"), &error_prototype.id,
                        &exception.id) != JSBAY_OK ||
        jsbay_value_new_string(engine->id, text("stack"), &stack_name.id) != JSBAY_OK)
        return false;
    jsbay_value_t descriptor_args[] = {error_prototype.id, stack_name.id};
    if (!guestCall(engine, engine->get_descriptor, descriptor_args, 2, descriptor))
        return false;
    jsbay_value_kind_t descriptor_type;
    if (jsbay_value_type(descriptor.id, &descriptor_type) == JSBAY_OK &&
        descriptor_type == JSBAY_VALUE_OBJECT) {
        Value getter;
        if (jsbay_value_get(descriptor.id, text("get"), &getter.id, &exception.id) != JSBAY_OK)
            return false;
        jsbay_value_kind_t type;
        jsbay_value_type(getter.id, &type);
        if (type == JSBAY_VALUE_FUNCTION) {
            engine->guest_stack_getter = getter.id;
            getter.id = 0;
        }
    }
    napi_value host_global, promise, host_prototype, then, error, message, object_constructor,
        describe, stack_key, stack_descriptor, getter;
    if (napi_get_global(engine->env, &host_global) != napi_ok ||
        napi_get_named_property(engine->env, host_global, "Promise", &promise) != napi_ok ||
        napi_get_named_property(engine->env, promise, "prototype", &host_prototype) != napi_ok ||
        napi_get_named_property(engine->env, host_prototype, "then", &then) != napi_ok ||
        napi_create_reference(engine->env, then, 1, &engine->promise_then) != napi_ok ||
        napi_create_string_utf8(engine->env, "", 0, &message) != napi_ok ||
        napi_create_error(engine->env, nullptr, message, &error) != napi_ok ||
        napi_get_named_property(engine->env, host_global, "Object", &object_constructor) !=
            napi_ok ||
        napi_get_named_property(engine->env, object_constructor, "getOwnPropertyDescriptor",
                                &describe) != napi_ok ||
        napi_create_string_utf8(engine->env, "stack", NAPI_AUTO_LENGTH, &stack_key) != napi_ok)
        return false;
    napi_value args[] = {error, stack_key};
    if (napi_call_function(engine->env, object_constructor, describe, 2, args, &stack_descriptor) !=
            napi_ok ||
        napi_get_named_property(engine->env, stack_descriptor, "get", &getter) != napi_ok)
        return false;
    napi_valuetype getter_type;
    napi_typeof(engine->env, getter, &getter_type);
    return getter_type != napi_function ||
           napi_create_reference(engine->env, getter, 1, &engine->host_stack_getter) == napi_ok;
}

struct EngineSetup {
    Engine *engine;
    const jsbay_resource_limits_t *limits;
    bool initialized = false;
};

static void initializeEngineInGeneration(void *user_data) noexcept {
    auto *setup = static_cast<EngineSetup *>(user_data);
    Engine *engine = setup->engine;
    if (setup->limits && !jsbay_engine_set_resource_limits(engine->id, setup->limits))
        return;
    if (!initializeIntrinsicsImpl(engine) ||
        jsbay_engine_attach_loop(engine->id, scheduleLoop, cancelLoop, engine->loop) != JSBAY_OK)
        return;
    if (engine->callbacks &&
        !jsbay_engine_set_event_handler(engine->id, nodeEventHandler,
                                        reinterpret_cast<void *>(engine->callbacks->token)))
        return;
    setup->initialized = true;
}

static bool initializeEngine(Engine *engine, const jsbay_resource_limits_t *limits) {
    EngineSetup setup{engine, limits, false};
    const auto status = jsbay_engine_with_generation_scope(engine->id, engine->core_generation,
                                                           initializeEngineInGeneration, &setup);
    return status == JSBAY_OK && setup.initialized;
}
static napi_value closeEngine(napi_env env, napi_callback_info info) {
    napi_value self;
    napi_get_cb_info(env, info, nullptr, nullptr, &self, nullptr);
    Engine *engine = unwrap(env, self);
    if (!engine || engine->closed)
        return undefined(env);
    if (!requireEngine(env, engine))
        return nullptr;
    if (injectedFailure("close_pending"))
        napi_throw_error(env, nullptr, "pending error during close");
    if (injectedFailure("cleanup_pending")) {
        engine->destroy_pending = true;
        if (engine->cleanup_hook_registered)
            napi_remove_env_cleanup_hook(env, environmentCleanup, engine);
        environmentCleanup(engine);
        return undefined(env);
    }
    requestClose(engine);
    return undefined(env);
}
static Engine *engineWithArgs(napi_env env, napi_callback_info info, size_t *count,
                              napi_value *args, size_t capacity) {
    napi_value self;
    *count = capacity;
    napi_get_cb_info(env, info, count, args, &self, nullptr);
    Engine *engine = unwrap(env, self);
    return requireEngine(env, engine) ? engine : nullptr;
}
static bool unsignedArgument(napi_env env, napi_value value, uint64_t *out) {
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok)
        return false;
    if (type == napi_bigint) {
        bool lossless = false;
        return napi_get_value_bigint_uint64(env, value, out, &lossless) == napi_ok && lossless;
    }
    double number = 0;
    if (napi_get_value_double(env, value, &number) != napi_ok || !std::isfinite(number) ||
        number < 0 || number > 9007199254740991.0 || std::floor(number) != number)
        return false;
    *out = static_cast<uint64_t>(number);
    return true;
}
static napi_value bigint(napi_env env, uint64_t value) {
    napi_value out = nullptr;
    napi_create_bigint_uint64(env, value, &out);
    return out;
}
struct ParsedLimits {
    jsbay_resource_limits_t value{};
    bool present = false;
};
static bool parseLimits(napi_env env, napi_value object, ParsedLimits *out) {
    napi_valuetype type;
    if (napi_typeof(env, object, &type) != napi_ok || type != napi_object)
        return false;
    static constexpr std::pair<const char *, size_t> fields[] = {
        {"maxTimers", offsetof(jsbay_resource_limits_t, max_timers)},
        {"maxTsfnHandles", offsetof(jsbay_resource_limits_t, max_tsfn_handles)},
        {"maxPendingCalls", offsetof(jsbay_resource_limits_t, max_pending_calls)},
        {"maxPendingBytes", offsetof(jsbay_resource_limits_t, max_pending_bytes)},
        {"maxPendingTasks", offsetof(jsbay_resource_limits_t, max_pending_tasks)}};
    out->value.struct_size = sizeof(out->value);
    for (const auto &field : fields) {
        bool has = false;
        if (napi_has_named_property(env, object, field.first, &has) != napi_ok || !has)
            return false;
        napi_value item;
        uint64_t number = 0;
        if (napi_get_named_property(env, object, field.first, &item) != napi_ok ||
            !unsignedArgument(env, item, &number) || number > std::numeric_limits<size_t>::max())
            return false;
        *reinterpret_cast<size_t *>(reinterpret_cast<uint8_t *>(&out->value) + field.second) =
            static_cast<size_t>(number);
    }
    out->present = true;
    return true;
}
static napi_value boolean(napi_env env, bool value) {
    napi_value out = nullptr;
    napi_get_boolean(env, value, &out);
    return out;
}
static napi_value cancelEngine(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "cancel takes no arguments");
    return boolean(env, jsbay_engine_cancel(engine->id, engine->core_generation));
}
static napi_value interruptEngine(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "requestInterrupt takes no arguments");
    return boolean(
        env, jsbay_engine_request_interrupt_for_generation(engine->id, engine->core_generation));
}
static napi_value beginShutdown(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 1);
    uint64_t millis = 0;
    if (!engine || count != 1 || !unsignedArgument(env, args[0], &millis) || millis == 0)
        return throwText(env, "beginShutdown requires a positive grace period in milliseconds");
    return boolean(env, jsbay_engine_begin_shutdown(engine->id, engine->core_generation, millis));
}
static napi_value shutdownStatus(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "shutdownStatus takes no arguments");
    jsbay_shutdown_status_t status{};
    if (!jsbay_engine_shutdown_status(engine->id, engine->core_generation, &status))
        return undefined(env);
    napi_value out, phase;
    napi_create_object(env, &out);
    napi_create_uint32(env, static_cast<uint32_t>(status.phase), &phase);
    napi_set_named_property(env, out, "phase", phase);
    napi_set_named_property(env, out, "remainingMs", bigint(env, status.remaining_ms));
    return out;
}
static napi_value suspendEngine(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "suspend takes no arguments");
    return boolean(env, jsbay_engine_suspend(engine->id));
}
static napi_value resumeEngine(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "resume takes no arguments");
    return boolean(env, jsbay_engine_resume(engine->id));
}
static napi_value isSuspended(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "isSuspended takes no arguments");
    return boolean(env, jsbay_engine_is_suspended(engine->id));
}
static napi_value runGc(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "runGc takes no arguments");
    if (!jsbay_engine_run_gc(engine->id))
        return throwStatus(env, JSBAY_UNSUPPORTED);
    return undefined(env);
}
static napi_value lastCacheHit(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "lastCacheHit takes no arguments");
    return boolean(env, engine->last_cache_hit);
}
static napi_value createSubmissionPromise(napi_env env, SubmissionState **out_state) {
    napi_value promise, callback, resource_name;
    napi_deferred deferred = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok ||
        napi_create_function(
            env, "jsbaySubmission", NAPI_AUTO_LENGTH,
            [](napi_env e, napi_callback_info) { return undefined(e); }, nullptr,
            &callback) != napi_ok ||
        napi_create_string_utf8(env, "JsBaySubmission", NAPI_AUTO_LENGTH, &resource_name) !=
            napi_ok)
        return nullptr;
    auto *state = new (std::nothrow) SubmissionState{};
    if (!state)
        return throwStatus(env, JSBAY_OUT_OF_MEMORY);
    state->env = env;
    state->deferred = deferred;
    if (napi_create_threadsafe_function(env, callback, nullptr, resource_name, 1, 1, state,
                                        submissionFinalize, state, submissionCallJs,
                                        &state->function) != napi_ok) {
        state->refs.store(1, std::memory_order_relaxed);
        releaseSubmissionState(state);
        return throwText(env, "could not create submission callback bridge");
    }
    *out_state = state;
    return promise;
}
static napi_value postScript(napi_env env, napi_callback_info info) {
    size_t count = 2;
    napi_value args[2], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    Engine *engine = unwrap(env, self);
    std::string source, filename = "<node>";
    if (!requireEngine(env, engine) || count < 1 || count > 2 || !string(env, args[0], &source) ||
        (count == 2 && !string(env, args[1], &filename)))
        return throwText(env, "postScript requires source and optional filename");
    SubmissionState *state = nullptr;
    napi_value promise = createSubmissionPromise(env, &state);
    if (!promise)
        return nullptr;
    if (!jsbay_engine_post_script(engine->id, engine->core_generation, text(source), text(filename),
                                  submissionCallback, state)) {
        napi_value error = nullptr, message = nullptr;
        if (napi_create_string_utf8(env, "JsBay rejected the script submission", NAPI_AUTO_LENGTH,
                                    &message) == napi_ok &&
            napi_create_error(env, nullptr, message, &error) == napi_ok)
            (void)napi_reject_deferred(env, state->deferred, error);
        else if (napi_get_undefined(env, &error) == napi_ok)
            (void)napi_reject_deferred(env, state->deferred, error);
        napi_release_threadsafe_function(state->function, napi_tsfn_abort);
        releaseSubmissionState(state);
    }
    return promise;
}
static napi_value postFence(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    Engine *engine = unwrap(env, self);
    if (!requireEngine(env, engine) || count > 1)
        return throwText(env, "postFence accepts optional {sealShutdown}");
    Operation operation(engine);
    bool seal = false;
    if (count == 1) {
        napi_valuetype type;
        bool has = false;
        if (napi_typeof(env, args[0], &type) != napi_ok || type != napi_object ||
            napi_has_named_property(env, args[0], "sealShutdown", &has) != napi_ok)
            return throwText(env, "postFence options must be an object");
        if (has) {
            napi_value value;
            napi_valuetype value_type;
            if (napi_get_named_property(env, args[0], "sealShutdown", &value) != napi_ok ||
                napi_typeof(env, value, &value_type) != napi_ok || value_type != napi_boolean ||
                napi_get_value_bool(env, value, &seal) != napi_ok)
                return throwText(env, "sealShutdown must be a boolean");
        }
    }
    if (engine->closed)
        return throwText(env, "JsBay engine closed");
    SubmissionState *state = nullptr;
    napi_value promise = createSubmissionPromise(env, &state);
    if (!promise)
        return nullptr;
    if (!jsbay_engine_post_fence(engine->id, engine->core_generation, seal, submissionCallback,
                                 state)) {
        napi_value error = nullptr, message = nullptr;
        if (napi_create_string_utf8(env, "JsBay rejected the submission fence", NAPI_AUTO_LENGTH,
                                    &message) == napi_ok &&
            napi_create_error(env, nullptr, message, &error) == napi_ok)
            (void)napi_reject_deferred(env, state->deferred, error);
        else if (napi_get_undefined(env, &error) == napi_ok)
            (void)napi_reject_deferred(env, state->deferred, error);
        napi_release_threadsafe_function(state->function, napi_tsfn_abort);
        releaseSubmissionState(state);
    }
    return promise;
}
static napi_value setResourceLimits(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 1);
    if (!engine)
        return nullptr;
    Operation operation(engine);
    ParsedLimits limits;
    if (count != 1 || !parseLimits(env, args[0], &limits))
        return throwText(env, "resource limits require all five non-negative integer fields");
    if (engine->closed)
        return throwText(env, "JsBay engine closed");
    return boolean(env, jsbay_engine_set_resource_limits(engine->id, &limits.value));
}
static napi_value setAdmissionClass(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 1);
    std::string name;
    if (!engine || count != 1 || !string(env, args[0], &name) ||
        (name != "foreground" && name != "background"))
        return throwText(env, "admission class must be foreground or background");
    return boolean(env, jsbay_engine_set_admission_class(
                            engine->id, name == "background" ? JSBAY_ADMISSION_BACKGROUND
                                                             : JSBAY_ADMISSION_FOREGROUND));
}
static napi_value admissionClass(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "admissionClass takes no arguments");
    jsbay_admission_class_t value;
    if (!jsbay_engine_get_admission_class(engine->id, &value))
        return throwStatus(env, JSBAY_UNSUPPORTED);
    napi_value out;
    napi_create_string_utf8(env, value == JSBAY_ADMISSION_BACKGROUND ? "background" : "foreground",
                            NAPI_AUTO_LENGTH, &out);
    return out;
}
static napi_value engineSnapshot(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "snapshot takes no arguments");
    jsbay_instance_snapshot_t snapshot{};
    snapshot.struct_size = sizeof(snapshot);
    if (!jsbay_engine_snapshot(engine->id, &snapshot))
        return undefined(env);
    napi_value out;
    napi_create_object(env, &out);
    auto number = [&](const char *name, uint32_t value) {
        napi_value v;
        napi_create_uint32(env, value, &v);
        napi_set_named_property(env, out, name, v);
    };
    auto wide = [&](const char *name, uint64_t value) {
        napi_set_named_property(env, out, name, bigint(env, value));
    };
    number("instanceId", static_cast<uint32_t>(snapshot.instance_id));
    wide("generation", snapshot.generation);
    wide("ownerThreadId", snapshot.owner_thread_id);
    number("loopMode", snapshot.loop_mode);
    number("flags", snapshot.flags);
    napi_value cls;
    napi_create_string_utf8(
        env, snapshot.admission_class == JSBAY_ADMISSION_BACKGROUND ? "background" : "foreground",
        NAPI_AUTO_LENGTH, &cls);
    napi_set_named_property(env, out, "admissionClass", cls);
    wide("timersReserved", snapshot.timers_reserved);
    wide("timersRegistered", snapshot.timers_registered);
    wide("scriptTasksQueued", snapshot.script_tasks_queued);
    wide("nativeTasksQueued", snapshot.native_tasks_queued);
    wide("pendingBytes", snapshot.pending_bytes);
    napi_value limits;
    napi_create_object(env, &limits);
    napi_set_named_property(env, limits, "maxTimers", bigint(env, snapshot.max_timers));
    napi_set_named_property(env, limits, "maxPendingTasks",
                            bigint(env, snapshot.max_pending_tasks));
    napi_set_named_property(env, limits, "maxPendingBytes",
                            bigint(env, snapshot.max_pending_bytes));
    napi_set_named_property(env, out, "limits", limits);
    return out;
}
static napi_value listEngines(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_get_cb_info(env, info, &count, nullptr, nullptr, nullptr);
    if (count)
        return throwText(env, "listEngines takes no arguments");
    const size_t total = jsbay_engine_list(nullptr, 0);
    std::vector<int> ids;
    try {
        ids.resize(total);
    } catch (...) {
        return throwStatus(env, JSBAY_OUT_OF_MEMORY);
    }
    const size_t written = jsbay_engine_list(ids.data(), ids.size());
    napi_value out;
    napi_create_array_with_length(env, written, &out);
    for (size_t i = 0; i < written; ++i) {
        napi_value id;
        napi_create_int32(env, ids[i], &id);
        napi_set_element(env, out, i, id);
    }
    return out;
}
static napi_value globalResourceUsage(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_get_cb_info(env, info, &count, nullptr, nullptr, nullptr);
    if (count)
        return throwText(env, "globalResourceUsage takes no arguments");
    jsbay_resource_global_usage_t usage{};
    usage.struct_size = sizeof(usage);
    if (!jsbay_resource_global_usage(&usage))
        return throwStatus(env, JSBAY_UNSUPPORTED);
    napi_value out;
    napi_create_object(env, &out);
#define SET_GLOBAL(field)                                                                          \
    do {                                                                                           \
        napi_set_named_property(env, out, #field,                                                  \
                                bigint(env, static_cast<uint64_t>(usage.field)));                  \
    } while (0)
    SET_GLOBAL(timers);
    SET_GLOBAL(tsfn_handles);
    SET_GLOBAL(pending_calls);
    SET_GLOBAL(native_tasks);
    SET_GLOBAL(script_tasks);
    SET_GLOBAL(pending_bytes);
    SET_GLOBAL(max_timers);
    SET_GLOBAL(max_tsfn_handles);
    SET_GLOBAL(max_pending_calls);
    SET_GLOBAL(max_native_tasks);
    SET_GLOBAL(max_script_tasks);
    SET_GLOBAL(max_pending_bytes);
    SET_GLOBAL(fg_headroom_timers);
    SET_GLOBAL(fg_headroom_tsfn_handles);
    SET_GLOBAL(fg_headroom_pending_calls);
    SET_GLOBAL(fg_headroom_native_tasks);
    SET_GLOBAL(fg_headroom_script_tasks);
    SET_GLOBAL(fg_headroom_pending_bytes);
    SET_GLOBAL(bg_effective_max_timers);
    SET_GLOBAL(bg_effective_max_tsfn_handles);
    SET_GLOBAL(bg_effective_max_pending_calls);
    SET_GLOBAL(bg_effective_max_native_tasks);
    SET_GLOBAL(bg_effective_max_script_tasks);
    SET_GLOBAL(bg_effective_max_pending_bytes);
#undef SET_GLOBAL
    return out;
}
static napi_value replaceBridgeCallback(napi_env env, napi_callback_info info, bool event) {
    size_t count = 1;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 1);
    if (!engine || count != 1)
        return throwText(env, "callback setter requires a function or null");
    if (!engine->callbacks)
        return throwStatus(env, JSBAY_UNSUPPORTED);
    napi_valuetype type;
    if (napi_typeof(env, args[0], &type) != napi_ok || (type != napi_function && type != napi_null))
        return throwText(env, "callback setter requires a function or null");
    napi_value callback = type == napi_function ? args[0] : nullptr;
    return boolean(env, replaceCallbackFunction(env, engine->callbacks, callback, event));
}
static napi_value setLogHandler(napi_env env, napi_callback_info info) {
    return replaceBridgeCallback(env, info, false);
}
static napi_value setEventHandler(napi_env env, napi_callback_info info) {
    return replaceBridgeCallback(env, info, true);
}
struct ControlToken {
    int32_t instance_id = 0;
    uint64_t generation = 0;
};
static bool readControlToken(napi_env env, napi_value value, ControlToken *token) {
    bool has_id = false, has_generation = false;
    napi_value id_value, generation_value;
    double id = 0;
    bool lossless = false;
    return napi_has_named_property(env, value, "instanceId", &has_id) == napi_ok && has_id &&
           napi_has_named_property(env, value, "generation", &has_generation) == napi_ok &&
           has_generation &&
           napi_get_named_property(env, value, "instanceId", &id_value) == napi_ok &&
           napi_get_named_property(env, value, "generation", &generation_value) == napi_ok &&
           napi_get_value_double(env, id_value, &id) == napi_ok && std::isfinite(id) && id >= 1 &&
           id <= 2147483647 && std::floor(id) == id &&
           napi_get_value_bigint_uint64(env, generation_value, &token->generation, &lossless) ==
               napi_ok &&
           lossless && token->generation != 0 &&
           ((token->instance_id = static_cast<int32_t>(id)), true);
}
static napi_value staticControl(napi_env env, napi_callback_info info, int operation) {
    size_t count = operation == 2 ? 2 : 1;
    napi_value args[2];
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    ControlToken token;
    if (count != (operation == 2 ? 2U : 1U) || !readControlToken(env, args[0], &token))
        return throwText(env, "control requires {instanceId, generation: bigint}");
    bool accepted = false;
    if (operation == 0)
        accepted =
            jsbay_engine_request_interrupt_for_generation(token.instance_id, token.generation);
    else if (operation == 1)
        accepted = jsbay_engine_cancel(token.instance_id, token.generation);
    else if (operation == 2) {
        uint64_t millis = 0;
        if (!unsignedArgument(env, args[1], &millis) || !millis)
            return throwText(env, "graceMs must be a positive integer");
        accepted = jsbay_engine_begin_shutdown(token.instance_id, token.generation, millis);
    } else {
        jsbay_shutdown_status_t status{};
        if (!jsbay_engine_shutdown_status(token.instance_id, token.generation, &status))
            return undefined(env);
        napi_value out, phase;
        napi_create_object(env, &out);
        napi_create_uint32(env, static_cast<uint32_t>(status.phase), &phase);
        napi_set_named_property(env, out, "phase", phase);
        napi_set_named_property(env, out, "remainingMs", bigint(env, status.remaining_ms));
        return out;
    }
    return boolean(env, accepted);
}
static napi_value staticInterrupt(napi_env env, napi_callback_info info) {
    return staticControl(env, info, 0);
}
static napi_value staticCancel(napi_env env, napi_callback_info info) {
    return staticControl(env, info, 1);
}
static napi_value staticBeginShutdown(napi_env env, napi_callback_info info) {
    return staticControl(env, info, 2);
}
static napi_value staticShutdownStatus(napi_env env, napi_callback_info info) {
    return staticControl(env, info, 3);
}
static napi_value setExecutionLimit(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 1);
    uint64_t value;
    if (!engine || count != 1 || !unsignedArgument(env, args[0], &value))
        return throwText(env, "limit must be a non-negative safe integer in milliseconds");
    const bool ok = jsbay_engine_set_execution_time_limit(engine->id, value);
    return ok ? undefined(env) : throwStatus(env, JSBAY_UNSUPPORTED);
}
static napi_value setExecutionBudget(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 1);
    uint64_t value;
    if (!engine || count != 1 || !unsignedArgument(env, args[0], &value))
        return throwText(env, "budget must be a non-negative safe integer in milliseconds");
    const bool ok = jsbay_engine_set_execution_budget(engine->id, value);
    return ok ? undefined(env) : throwStatus(env, JSBAY_UNSUPPORTED);
}
static napi_value setMemoryLimit(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 1);
    uint64_t value;
    if (!engine || count != 1 || !unsignedArgument(env, args[0], &value))
        return throwText(env, "memory limit must be a non-negative safe integer in bytes");
    const bool ok = jsbay_engine_set_memory_limit(engine->id, value);
    return ok ? undefined(env) : throwStatus(env, JSBAY_UNSUPPORTED);
}
static napi_value inspectorStart(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 1);
    uint64_t port;
    if (!engine || count != 1 || !unsignedArgument(env, args[0], &port) || port > 65535)
        return throwText(env, "inspector port must be an integer from 0 to 65535");
    uint16_t selected = 0;
    if (!jsbay_engine_inspector_start(engine->id, static_cast<uint16_t>(port), &selected))
        return throwText(env, "inspector listener could not start; the transport may be disabled "
                              "or the port unavailable");
    napi_value result;
    napi_create_uint32(env, selected, &result);
    return result;
}
static napi_value inspectorStop(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "inspectorStop takes no arguments");
    jsbay_engine_inspector_stop(engine->id);
    return undefined(env);
}
static napi_value resourceUsage(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "resourceUsage takes no arguments");
    jsbay_resource_usage_t usage{};
    usage.struct_size = sizeof(usage);
    if (!jsbay_engine_get_resource_usage(engine->id, &usage))
        return throwStatus(env, JSBAY_UNSUPPORTED);
    napi_value out;
    napi_create_object(env, &out);
#define SET_SIZE(field)                                                                            \
    do {                                                                                           \
        napi_value v = bigint(env, static_cast<uint64_t>(usage.field));                            \
        napi_set_named_property(env, out, #field, v);                                              \
    } while (0)
    SET_SIZE(timers);
    SET_SIZE(tsfn_handles);
    SET_SIZE(pending_calls);
    SET_SIZE(native_tasks);
    SET_SIZE(script_tasks);
    SET_SIZE(pending_bytes);
    SET_SIZE(max_timers);
    SET_SIZE(max_tsfn_handles);
    SET_SIZE(max_pending_calls);
    SET_SIZE(max_pending_bytes);
    SET_SIZE(max_pending_tasks);
#undef SET_SIZE
    return out;
}
static napi_value memoryUsage(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1];
    Engine *engine = engineWithArgs(env, info, &count, args, 0);
    if (!engine || count)
        return throwText(env, "memoryUsage takes no arguments");
    jsbay_memory_usage_t usage{};
    usage.struct_size = sizeof(usage);
    if (!jsbay_engine_get_memory_usage(engine->id, &usage))
        return throwStatus(env, JSBAY_UNSUPPORTED);
    napi_value out;
    napi_create_object(env, &out);
#define SET_MEMORY(field)                                                                          \
    do {                                                                                           \
        napi_value v = bigint(env, usage.field);                                                   \
        napi_set_named_property(env, out, #field, v);                                              \
    } while (0)
    SET_MEMORY(malloc_count);
    SET_MEMORY(malloc_size);
    SET_MEMORY(malloc_limit);
    SET_MEMORY(memory_used_count);
    SET_MEMORY(memory_used_size);
    SET_MEMORY(atom_count);
    SET_MEMORY(atom_size);
    SET_MEMORY(obj_count);
    SET_MEMORY(obj_size);
    SET_MEMORY(shape_count);
#undef SET_MEMORY
    return out;
}
static napi_value closeAsync(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value args[1], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    Engine *engine = unwrap(env, self);
    if (!engine || count || engine->owner != std::this_thread::get_id())
        return throwText(env, "closeAsync requires an Engine on its owner thread and no arguments");
    napi_value promise;
    napi_deferred deferred;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok)
        return throwText(env, "could not create close promise");
    if (engine->destroyed && !engine->loop) {
        napi_resolve_deferred(env, deferred, undefined(env));
        return promise;
    }
    try {
        engine->close_waiters.push_back(deferred);
    } catch (...) {
        return throwText(env, "could not retain close completion");
    }
    if (engine->loop && engine->loop->async_ready && !engine->close_loop_referenced) {
        uv_ref(reinterpret_cast<uv_handle_t *>(&engine->loop->async));
        engine->close_loop_referenced = true;
    }
    if (!engine->destroyed)
        requestClose(engine);
    return promise;
}

struct GenerationInvocation {
    napi_env env;
    napi_callback_info info;
    napi_callback callback;
    napi_value result = nullptr;
};

static void invokeGenerationCallback(void *opaque) noexcept {
    auto *invocation = static_cast<GenerationInvocation *>(opaque);
    try {
        invocation->result = invocation->callback(invocation->env, invocation->info);
    } catch (...) {
        invocation->result = throwStatus(invocation->env, JSBAY_OUT_OF_MEMORY);
    }
}

template <napi_value (*Callback)(napi_env, napi_callback_info)>
static napi_value engineMethodBoundary(napi_env env, napi_callback_info info) noexcept {
    size_t count = 0;
    napi_value self = nullptr;
    if (napi_get_cb_info(env, info, &count, nullptr, &self, nullptr) != napi_ok)
        return throwText(env, "could not read Engine receiver");
    Engine *engine = unwrap(env, self);
    if (!engine)
        return throwStatus(env, JSBAY_INSTANCE_NOT_FOUND);
    if ((Callback == closeEngine || Callback == closeAsync) && engine->closed)
        return Callback(env, info);
    if (!requireEngine(env, engine))
        return nullptr;
    GenerationInvocation invocation{env, info, Callback};
    const jsbay_status_t status = jsbay_engine_with_generation_scope(
        engine->id, engine->core_generation, invokeGenerationCallback, &invocation);
    if (status != JSBAY_OK) {
        if (status == JSBAY_INSTANCE_NOT_FOUND) {
            requestClose(engine);
            if (Callback == closeEngine || Callback == closeAsync)
                return Callback(env, info);
        }
        return throwStatus(env, status);
    }
    return invocation.result;
}

static napi_value capabilities(napi_env env, napi_callback_info) {
    jsbay_engine_capabilities_t value{};
    value.struct_size = sizeof(value);
    jsbay_engine_version_info_t version{};
    version.struct_size = sizeof(version);
    if (!jsbay_library_capabilities(&value) || !jsbay_engine_version(&version))
        return throwText(env, "could not read engine capabilities");
    napi_value out, backend, flags;
    napi_create_object(env, &out);
    napi_create_string_utf8(env, version.backend, NAPI_AUTO_LENGTH, &backend);
    napi_create_uint32(env, value.flags, &flags);
    napi_set_named_property(env, out, "backend", backend);
    napi_set_named_property(env, out, "flags", flags);
    napi_value debugger, memory, bytecode, cache, deadline;
    napi_get_boolean(
        env, (value.flags & (JSBAY_CAP_CDP_SOURCE_DEBUGGER | JSBAY_CAP_SAFARI_WEB_INSPECTOR)) != 0,
        &debugger);
    napi_get_boolean(env, (value.flags & JSBAY_CAP_HEAP_STACK_LIMIT) != 0, &memory);
    napi_get_boolean(env, (value.flags & JSBAY_CAP_EXPLICIT_BYTECODE) != 0, &bytecode);
    napi_get_boolean(env, (value.flags & JSBAY_CAP_PERSISTENT_BYTECODE_CACHE) != 0, &cache);
    napi_get_boolean(env, (value.flags & JSBAY_CAP_INTERRUPT_DEADLINE) != 0, &deadline);
    napi_set_named_property(env, out, "sourceDebugger", debugger);
    napi_set_named_property(env, out, "memoryLimit", memory);
    napi_set_named_property(env, out, "bytecode", bytecode);
    napi_set_named_property(env, out, "bytecodeCache", cache);
    napi_set_named_property(env, out, "executionLimit", deadline);
    return out;
}

static napi_value createEngine(napi_env env, int32_t id, jsbay_log_handler_t log_handler,
                               void *user_data, void (*destroy_callback)(void *),
                               std::shared_ptr<CallbackBridge> bridge = nullptr,
                               const jsbay_resource_limits_t *limits = nullptr) {
    if (id < 1)
        return throwText(env, "instanceId must be a positive int32");
    if (log_handler || bridge) {
        jsbay_engine_create_options_t options{};
        options.struct_size = sizeof(options);
        options.backend = JSBAY_BACKEND_PRIMARY;
        options.log_handler = log_handler ? log_handler : nodeLogHandler;
        options.log_user_data = log_handler ? user_data : reinterpret_cast<void *>(bridge->token);
        if (!jsbay_engine_create_with_options(id, &options)) {
            if (bridge) {
                releaseBridge(bridge);
                eraseCallbackBridge(bridge->token);
            }
            return throwText(env, "could not create JsBay engine");
        }
    } else if (!jsbay_engine_create(id, nullptr, nullptr)) {
        if (bridge) {
            releaseBridge(bridge);
            eraseCallbackBridge(bridge->token);
        }
        return throwText(env, "could not create JsBay engine");
    }
    jsbay_instance_snapshot_t snapshot{};
    snapshot.struct_size = sizeof(snapshot);
    if (!jsbay_engine_snapshot(id, &snapshot)) {
        if (bridge) {
            releaseBridge(bridge);
            eraseCallbackBridge(bridge->token);
        }
        return throwText(env, "could not initialize JsBay engine");
    }
    napi_value out = nullptr;
    if (napi_create_object(env, &out) != napi_ok) {
        jsbay_engine_destroy_generation(id, snapshot.generation);
        if (bridge) {
            releaseBridge(bridge);
            eraseCallbackBridge(bridge->token);
        }
        return nullptr;
    }
    auto *engine = new (std::nothrow) Engine{};
    if (!engine) {
        jsbay_engine_destroy_generation(id, snapshot.generation);
        if (bridge) {
            releaseBridge(bridge);
            eraseCallbackBridge(bridge->token);
        }
        return throwStatus(env, JSBAY_OUT_OF_MEMORY);
    }
    engine->callbacks = bridge;
    engine->env = env;
    engine->id = id;
    engine->core_generation = snapshot.generation;
    engine->owner = std::this_thread::get_id();
    engine->loop = new (std::nothrow) Loop{};
    if (!engine->loop) {
        engine->wrapper_finalized = true;
        engine->destroyed = true;
        jsbay_engine_destroy_generation(id, snapshot.generation);
        if (bridge) {
            releaseBridge(bridge);
            eraseCallbackBridge(bridge->token);
        }
        delete engine;
        return throwStatus(env, JSBAY_OUT_OF_MEMORY);
    }
    engine->loop->owner = engine;
    uv_loop_t *loop = nullptr;
    bool initialized = napi_get_uv_event_loop(env, &loop) == napi_ok;
    if (initialized) {
        initialized = uv_async_init(loop, &engine->loop->async, wakeLoop) == 0;
        if (initialized) {
            engine->loop->async_ready = true;
            ++engine->loop->open_handles;
            engine->loop->async.data = engine->loop;
            uv_unref(reinterpret_cast<uv_handle_t *>(&engine->loop->async));
        }
    }
    if (initialized) {
        initialized = uv_timer_init(loop, &engine->loop->timer) == 0;
        if (initialized) {
            engine->loop->timer_ready = true;
            ++engine->loop->open_handles;
            engine->loop->timer.data = engine->loop;
        }
    }
    napi_value resource, resource_name;
    initialized =
        initialized && napi_create_object(env, &resource) == napi_ok &&
        napi_create_reference(env, resource, 1, &engine->async_resource) == napi_ok &&
        napi_create_string_utf8(env, "JsBay", NAPI_AUTO_LENGTH, &resource_name) == napi_ok &&
        napi_async_init(env, resource, resource_name, &engine->async_context) == napi_ok;
    if (!initialized || !initializeEngine(engine, limits)) {
        engine->wrapper_finalized = true;
        requestClose(engine);
        return throwText(env, "could not initialize JsBay engine");
    }
    if (napi_type_tag_object(env, out, &engineTypeTag) != napi_ok) {
        engine->wrapper_finalized = true;
        requestClose(engine);
        return throwText(env, "could not tag JsBay engine wrapper");
    }
    if (injectedFailure("wrap") ||
        napi_wrap(
            env, out, engine,
            [](napi_env, void *data, void *) {
                auto *engine = static_cast<Engine *>(data);
                engine->wrapper_finalized = true;
                if (!engine->destroy_pending) {
                    engine->closed = true;
                    engine->destroy_pending = true;
                }
                if (engine->loop &&
                    !uv_is_closing(reinterpret_cast<uv_handle_t *>(&engine->loop->async)))
                    (void)uv_async_send(&engine->loop->async);
                else
                    maybeDeleteEngine(engine);
            },
            nullptr, nullptr) != napi_ok) {
        engine->wrapper_finalized = true;
        engine->closed = true;
        engine->destroy_pending = true;
        finishClose(engine);
        return throwText(env, "could not wrap JsBay engine");
    }
    napi_add_env_cleanup_hook(env, environmentCleanup, engine);
    engine->cleanup_hook_registered = true;
    if (napi_create_reference(env, out, 0, &engine->wrapper) != napi_ok) {
        requestClose(engine);
        return throwText(env, "could not retain JsBay engine wrapper");
    }
    if (!initNodeValueClass(engine)) {
        requestClose(engine);
        return throwText(env, "could not initialize NodeValue class");
    }
    const napi_property_descriptor methods[] = {
        {"evaluate", nullptr, engineMethodBoundary<evaluate>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"evaluateAsync", nullptr, engineMethodBoundary<evaluateAsync>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"evaluateValue", nullptr, engineMethodBoundary<evaluateValue>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"bind", nullptr, engineMethodBoundary<bindSync>, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"bindAsync", nullptr, engineMethodBoundary<bindAsync>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"close", nullptr, engineMethodBoundary<closeEngine>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"closeAsync", nullptr, engineMethodBoundary<closeAsync>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"requestInterrupt", nullptr, engineMethodBoundary<interruptEngine>, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"cancel", nullptr, engineMethodBoundary<cancelEngine>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"beginShutdown", nullptr, engineMethodBoundary<beginShutdown>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"shutdownStatus", nullptr, engineMethodBoundary<shutdownStatus>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"suspend", nullptr, engineMethodBoundary<suspendEngine>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"resume", nullptr, engineMethodBoundary<resumeEngine>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"isSuspended", nullptr, engineMethodBoundary<isSuspended>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"runGc", nullptr, engineMethodBoundary<runGc>, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"lastCacheHit", nullptr, engineMethodBoundary<lastCacheHit>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"setResourceLimits", nullptr, engineMethodBoundary<setResourceLimits>, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"setAdmissionClass", nullptr, engineMethodBoundary<setAdmissionClass>, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"admissionClass", nullptr, engineMethodBoundary<admissionClass>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"snapshot", nullptr, engineMethodBoundary<engineSnapshot>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"setLogHandler", nullptr, engineMethodBoundary<setLogHandler>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"setEventHandler", nullptr, engineMethodBoundary<setEventHandler>, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"postScript", nullptr, engineMethodBoundary<postScript>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"postFence", nullptr, engineMethodBoundary<postFence>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"value", nullptr, engineMethodBoundary<engineConvertNodeValue>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"global", nullptr, engineMethodBoundary<engineGlobalValue>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"object", nullptr, engineMethodBoundary<engineObjectValue>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"array", nullptr, engineMethodBoundary<engineArrayValue>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"setExecutionTimeLimit", nullptr, engineMethodBoundary<setExecutionLimit>, nullptr,
         nullptr, nullptr, napi_default, nullptr},
        {"setExecutionBudget", nullptr, engineMethodBoundary<setExecutionBudget>, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"setMemoryLimit", nullptr, engineMethodBoundary<setMemoryLimit>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"inspectorStart", nullptr, engineMethodBoundary<inspectorStart>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"inspectorStop", nullptr, engineMethodBoundary<inspectorStop>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"resourceUsage", nullptr, engineMethodBoundary<resourceUsage>, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"memoryUsage", nullptr, engineMethodBoundary<memoryUsage>, nullptr, nullptr, nullptr,
         napi_default, nullptr}};
    if (napi_define_properties(env, out, sizeof(methods) / sizeof(methods[0]), methods) !=
        napi_ok) {
        requestClose(engine);
        return throwText(env, "could not define JsBay engine methods");
    }
    napi_value id_value, generation_value, token;
    napi_create_int32(env, id, &id_value);
    napi_set_named_property(env, out, "id", id_value);
    napi_create_bigint_uint64(env, snapshot.generation, &generation_value);
    napi_set_named_property(env, out, "generation", generation_value);
    napi_create_object(env, &token);
    napi_set_named_property(env, token, "instanceId", id_value);
    napi_set_named_property(env, token, "generation", generation_value);
    napi_set_named_property(env, out, "controlToken", token);
    engine->embed_user_data = user_data;
    engine->embed_destroy_callback = destroy_callback;
    return out;
}
static napi_value create(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    int32_t id = 0;
    napi_value log_callback = nullptr, event_callback = nullptr;
    ParsedLimits limits;
    if (count == 1) {
        napi_value value;
        bool has_id = false;
        if (napi_has_named_property(env, args[0], "instanceId", &has_id) != napi_ok)
            return nullptr;
        if (has_id) {
            if (napi_get_named_property(env, args[0], "instanceId", &value) != napi_ok)
                return nullptr;
            napi_valuetype value_type;
            double numeric_id = 0;
            if (napi_typeof(env, value, &value_type) != napi_ok)
                return nullptr;
            if (value_type != napi_undefined) {
                if (napi_get_value_double(env, value, &numeric_id) != napi_ok ||
                    !std::isfinite(numeric_id) || numeric_id < 1 || numeric_id > 2147483647 ||
                    std::floor(numeric_id) != numeric_id)
                    return throwText(env, "instanceId must be a positive int32");
                id = static_cast<int32_t>(numeric_id);
            }
        }
        bool has_log = false, has_event = false;
        if (napi_has_named_property(env, args[0], "onLog", &has_log) != napi_ok ||
            napi_has_named_property(env, args[0], "onEvent", &has_event) != napi_ok)
            return nullptr;
        napi_valuetype callback_type;
        if (has_log) {
            if (napi_get_named_property(env, args[0], "onLog", &log_callback) != napi_ok ||
                napi_typeof(env, log_callback, &callback_type) != napi_ok ||
                callback_type != napi_function)
                return throwText(env, "onLog must be a function");
        }
        if (has_event) {
            if (napi_get_named_property(env, args[0], "onEvent", &event_callback) != napi_ok ||
                napi_typeof(env, event_callback, &callback_type) != napi_ok ||
                callback_type != napi_function)
                return throwText(env, "onEvent must be a function");
        }
        bool has_limits = false;
        if (napi_has_named_property(env, args[0], "limits", &has_limits) != napi_ok)
            return nullptr;
        if (has_limits) {
            napi_value limits_value;
            if (napi_get_named_property(env, args[0], "limits", &limits_value) != napi_ok ||
                !parseLimits(env, limits_value, &limits))
                return throwText(env, "limits must define all five non-negative integer fields");
        }
    }
    if (id == 0) {
        do {
            id = next_instance_id.fetch_add(1);
            if (id <= 0)
                return throwText(env, "could not allocate a JsBay instance id");
            jsbay_instance_snapshot_t snapshot{};
            snapshot.struct_size = sizeof(snapshot);
            if (!jsbay_engine_snapshot(id, &snapshot))
                break;
        } while (true);
    }
    std::shared_ptr<CallbackBridge> bridge;
    try {
        bridge = std::make_shared<CallbackBridge>();
    } catch (...) {
        return throwStatus(env, JSBAY_OUT_OF_MEMORY);
    }
    bridge->instance_id = id;
    bridge->token = allocateCallbackToken();
    if (!bridge->token)
        return throwText(env, "could not allocate callback token");
    if ((log_callback && !createCallbackFunction(env, log_callback, "JsBayLog", bridge->token,
                                                 bridge->log_epoch, false, &bridge->log)) ||
        (event_callback && !createCallbackFunction(env, event_callback, "JsBayEvent", bridge->token,
                                                   bridge->event_epoch, true, &bridge->event))) {
        releaseBridge(bridge);
        return throwText(env, "could not create JsBay callback bridge");
    }
    try {
        std::lock_guard<std::mutex> lock(callback_bridges_mutex);
        callback_bridges.emplace(bridge->token, bridge);
    } catch (...) {
        releaseBridge(bridge);
        return throwText(env, "could not register JsBay callback bridge");
    }
    return createEngine(env, id, nullptr, nullptr, nullptr, std::move(bridge),
                        limits.present ? &limits.value : nullptr);
}
} // namespace
#ifdef JSBAY_NODE_EMBEDDED
extern "C" napi_value jsbay_node_create(napi_env env, int instance_id,
                                        jsbay_log_handler_t log_handler, void *user_data,
                                        jsbay_node_destroy_callback_t destroy_callback) {
    return createEngine(env, instance_id, log_handler, user_data, destroy_callback);
}
extern "C" void jsbay_node_close(napi_env env, napi_value value) {
    Engine *engine = unwrap(env, value);
    if (!engine || engine->closed || !requireEngine(env, engine))
        return;
    requestClose(engine);
}
extern "C" bool jsbay_node_set_task_observer(napi_env env, napi_value value,
                                             jsbay_node_task_observer_t observer, void *user_data) {
    Engine *engine = unwrap(env, value);
    if (!engine || engine->closed || !requireEngine(env, engine))
        return false;
    engine->embed_task_observer = observer;
    engine->embed_task_observer_data = user_data;
    return true;
}
#else
#ifdef JSBAY_NODE_TESTING
static napi_value testFail(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    if (count != 1 || !string(env, args[0], &failure_point))
        return throwText(env, "failure point must be a string");
    return undefined(env);
}
static napi_value testState(napi_env env, napi_callback_info) {
    napi_value out, value;
    napi_create_object(env, &out);
    jsbay_resource_global_usage_t resources{};
    resources.struct_size = sizeof(resources);
    jsbay_resource_global_usage(&resources);
    for (auto entry : {std::pair<const char *, size_t>{"engines", live_engines.load()},
                       {"completions", live_completions.load()},
                       {"pendingCalls", resources.pending_calls}}) {
        napi_create_double(env, static_cast<double>(entry.second), &value);
        napi_set_named_property(env, out, entry.first, value);
    }
    return out;
}
#endif
static napi_value init(napi_env env, napi_value exports) {
    napi_value engine, factory;
    napi_create_object(env, &engine);
    napi_create_function(env, "create", NAPI_AUTO_LENGTH, nodeValueBoundary<create>, nullptr,
                         &factory);
    napi_set_named_property(env, engine, "create", factory);
    napi_value capability_function;
    napi_create_function(env, "capabilities", NAPI_AUTO_LENGTH, capabilities, nullptr,
                         &capability_function);
    napi_set_named_property(env, engine, "capabilities", capability_function);
    for (auto method : {std::pair<const char *, napi_callback>{"requestInterrupt",
                                                               nodeValueBoundary<staticInterrupt>},
                        {"cancel", nodeValueBoundary<staticCancel>},
                        {"beginShutdown", nodeValueBoundary<staticBeginShutdown>},
                        {"shutdownStatus", nodeValueBoundary<staticShutdownStatus>},
                        {"listEngines", nodeValueBoundary<listEngines>},
                        {"globalResourceUsage", nodeValueBoundary<globalResourceUsage>}}) {
        napi_value function;
        if (napi_create_function(env, method.first, NAPI_AUTO_LENGTH, method.second, nullptr,
                                 &function) != napi_ok ||
            napi_set_named_property(env, engine, method.first, function) != napi_ok)
            return throwText(env, "could not define JsBay engine control API");
    }
    napi_set_named_property(env, exports, "Engine", engine);
#ifdef JSBAY_NODE_TESTING
    napi_value fail, state;
    napi_create_function(env, "testFail", NAPI_AUTO_LENGTH, testFail, nullptr, &fail);
    napi_create_function(env, "testState", NAPI_AUTO_LENGTH, testState, nullptr, &state);
    napi_set_named_property(env, exports, "_testFail", fail);
    napi_set_named_property(env, exports, "_testState", state);
#endif
    return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
#endif
