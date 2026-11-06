#include "jsbay.h"
#include "jsbay_async.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
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
    bool wrapper_finalized = false, cleanup_hook_registered = false,
         environment_cleaning_up = false;
    unsigned active_operations = 0;
    Loop *loop = nullptr;
    std::unordered_map<uint64_t, napi_deferred> observers;
    std::unordered_set<Completion *> completions;
    uint64_t observer_id = 0;
    jsbay_value_t dispatch_ok = 0, dispatch_error = 0, bind_function = 0;
    jsbay_value_t get_prototype = 0, object_is = 0, object_prototype = 0;
    jsbay_value_t get_descriptor = 0, has_own = 0, error_constructor = 0;
    jsbay_value_t create_object = 0, define_property = 0;
    napi_ref promise_then = nullptr, host_stack_getter = nullptr;
    napi_ref async_resource = nullptr, wrapper = nullptr;
    napi_async_context async_context = nullptr;
    bool observer_retained = false;
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
static napi_value throwStatus(napi_env env, jsbay_status_t status) {
    napi_value message, error, code;
    std::string text = "js-bay status " + std::to_string(static_cast<int>(status));
    napi_create_string_utf8(env, text.c_str(), NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, nullptr, message, &error);
    napi_create_int32(env, status, &code);
    napi_set_named_property(env, error, "status", code);
    napi_throw(env, error);
    return nullptr;
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
    Engine *out = nullptr;
    return napi_unwrap(env, value, reinterpret_cast<void **>(&out)) == napi_ok ? out : nullptr;
}
static bool requireEngine(napi_env env, Engine *engine) {
    if (!engine || engine->closed) {
        throwStatus(env, JSBAY_INSTANCE_NOT_FOUND);
        return false;
    }
    if (engine->owner != std::this_thread::get_id()) {
        throwStatus(env, JSBAY_WRONG_THREAD);
        return false;
    }
    return true;
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
        if (turn.ready && !loop->owner->closed)
            task(data);
        else
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
        maybeDeleteEngine(engine);
    }
}
static void closeLoop(Engine *engine) {
    auto *loop = engine->loop;
    if (!loop)
        return;
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
static void finishClose(Engine *engine) {
    if (engine->destroyed || engine->active_operations != 0)
        return;
    engine->destroyed = true;
    rejectObservers(engine);
    for (auto *completion : engine->completions) {
        completion->engine = nullptr;
        completion->completed = true;
        releaseCompletion(completion);
    }
    engine->completions.clear();
    for (auto value :
         {engine->dispatch_ok, engine->dispatch_error, engine->bind_function, engine->get_prototype,
          engine->object_is, engine->object_prototype, engine->get_descriptor, engine->has_own,
          engine->error_constructor, engine->create_object, engine->define_property,
          engine->guest_stack_getter, engine->completion_failure, engine->guest_promise,
          engine->guest_resolve, engine->guest_then, engine->guest_promise_prototype})
        if (value)
            jsbay_value_release(value);
    if (engine->promise_then) {
        napi_delete_reference(engine->env, engine->promise_then);
        engine->promise_then = nullptr;
    }
    if (engine->host_stack_getter) {
        napi_delete_reference(engine->env, engine->host_stack_getter);
        engine->host_stack_getter = nullptr;
    }
    if (engine->async_context) {
        napi_async_destroy(engine->env, engine->async_context);
        engine->async_context = nullptr;
    }
    for (auto reference : {engine->async_resource, engine->wrapper})
        if (reference)
            napi_delete_reference(engine->env, reference);
    engine->async_resource = nullptr;
    engine->wrapper = nullptr;
    closeLoop(engine);
    jsbay_engine_destroy(engine->id);
    maybeDeleteEngine(engine);
}
static void environmentCleanup(void *opaque) {
    auto *engine = static_cast<Engine *>(opaque);
    engine->environment_cleaning_up = true;
    engine->cleanup_hook_registered = false;
    engine->closed = true;
    engine->destroy_pending = true;
    rejectObservers(engine);
    if (engine->active_operations == 0)
        finishClose(engine);
}
static void maybeDeleteEngine(Engine *engine) {
    if (!engine->wrapper_finalized || !engine->destroyed || engine->loop)
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
    napi_value message, error, number;
    std::string text_value = "js-bay status " + std::to_string(static_cast<int>(status));
    if (napi_create_string_utf8(engine->env, text_value.c_str(), text_value.size(), &message) ==
            napi_ok &&
        napi_create_error(engine->env, nullptr, message, &error) == napi_ok &&
        napi_create_int32(engine->env, status, &number) == napi_ok &&
        napi_set_named_property(engine->env, error, "status", number) == napi_ok)
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
static void finish(napi_env env, Completion *completion, jsbay_status_t outcome, napi_value value) {
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
    size_t count = 2;
    napi_value args[2], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    Engine *engine = unwrap(env, self);
    std::string source, filename = "<node>";
    napi_valuetype filename_type = napi_undefined;
    if (count > 1)
        napi_typeof(env, args[1], &filename_type);
    if (!requireEngine(env, engine) || count < 1 || !string(env, args[0], &source) ||
        (filename_type != napi_undefined && !string(env, args[1], &filename)))
        return throwText(env, "evaluate requires source and optional filename");
    Operation operation(engine);
    jsbay_value_t value = 0, exception = 0;
    const jsbay_status_t status = jsbay_engine_evaluate(engine->id, text(source), text(filename),
                                                        nullptr, &value, &exception);
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
    size_t count = 2;
    napi_value args[2], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    Engine *engine = unwrap(env, self);
    std::string source, filename = "<node>";
    napi_valuetype filename_type = napi_undefined;
    if (count > 1)
        napi_typeof(env, args[1], &filename_type);
    if (!requireEngine(env, engine) || count < 1 || !string(env, args[0], &source) ||
        (filename_type != napi_undefined && !string(env, args[1], &filename)))
        return throwText(env, "evaluateAsync requires source and optional filename");
    Operation operation(engine);
    napi_deferred deferred;
    napi_value promise;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok)
        return nullptr;
    Value result, exception, normalized;
    auto status = jsbay_engine_evaluate(engine->id, text(source), text(filename), nullptr,
                                        &result.id, &exception.id);
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

static bool initializeIntrinsics(Engine *engine) {
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

static napi_value create(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    int32_t id = 0;
    bool supplied_id = false;
    if (count == 1) {
        napi_value value;
        bool has_id = false;
        if (napi_has_named_property(env, args[0], "instanceId", &has_id) == napi_ok && has_id) {
            double numeric_id = 0;
            if (napi_get_named_property(env, args[0], "instanceId", &value) != napi_ok)
                return nullptr;
            napi_valuetype value_type;
            if (napi_typeof(env, value, &value_type) != napi_ok)
                return nullptr;
            if (value_type != napi_undefined) {
                if (napi_get_value_double(env, value, &numeric_id) != napi_ok ||
                    !std::isfinite(numeric_id) || numeric_id < 1 || numeric_id > 2147483647 ||
                    std::floor(numeric_id) != numeric_id)
                    return throwText(env, "instanceId must be a positive int32");
                id = static_cast<int32_t>(numeric_id);
                supplied_id = true;
            }
        }
    }
    if (supplied_id) {
        if (!jsbay_engine_create(id, nullptr, nullptr))
            return throwText(env, "could not create JsBay engine");
    } else {
        do {
            id = next_instance_id.fetch_add(1);
            if (id <= 0)
                return throwText(env, "could not allocate a JsBay instance id");
            jsbay_instance_snapshot_t snapshot{};
            snapshot.struct_size = sizeof(snapshot);
            if (jsbay_engine_snapshot(id, &snapshot))
                continue;
            if (!jsbay_engine_create(id, nullptr, nullptr))
                return throwText(env, "could not create JsBay engine");
            break;
        } while (true);
    }
    napi_value out;
    napi_create_object(env, &out);
    auto *engine = new Engine{};
    engine->env = env;
    engine->id = id;
    engine->owner = std::this_thread::get_id();
    engine->loop = new Loop{};
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
    if (!initialized || !initializeIntrinsics(engine) ||
        jsbay_engine_attach_loop(id, scheduleLoop, cancelLoop, engine->loop) != JSBAY_OK) {
        engine->wrapper_finalized = true;
        requestClose(engine);
        return throwText(env, "could not initialize JsBay engine");
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
    const napi_property_descriptor methods[] = {
        {"evaluate", nullptr, evaluate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"evaluateAsync", nullptr, evaluateAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"bind", nullptr, bindSync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"bindAsync", nullptr, bindAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, closeEngine, nullptr, nullptr, nullptr, napi_default, nullptr}};
    napi_define_properties(env, out, sizeof(methods) / sizeof(methods[0]), methods);
    return out;
}
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
    napi_create_function(env, "create", NAPI_AUTO_LENGTH, create, nullptr, &factory);
    napi_set_named_property(env, engine, "create", factory);
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
} // namespace
NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
