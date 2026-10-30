#include "jsbay.h"
#include "jsbay_sync.h"
#include <napi/native_api.h>
#include <node_api.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <stdint.h>
#include <string>
#include <thread>
#include <vector>

namespace {
struct Engine;
struct LoopBinding;
struct Value {
    Engine *engine;
    jsbay_value_t handle;
    bool borrowed;
    bool live;
};
struct Binding {
    Engine *engine;
    napi_ref callback;
};
struct SyncBinding {
    Engine *engine;
    napi_ref callback;
};
struct Engine {
    napi_env env;
    int32_t id;
    std::thread::id owner;
    bool closed = false;
    std::atomic_uint32_t refs{1};
    LoopBinding *loop = nullptr;
    std::atomic_uint64_t loop_generation{0};
    bool cleanup_registered = false;
};
struct LoopBinding {
    Engine *engine;
    napi_threadsafe_function tsfn = nullptr;
    std::atomic_bool active{true};
    std::atomic_bool pending{false};
    std::mutex mutex;
    uint64_t generation = 0;
    uint64_t delay_ms = 0;
    jsbay_loop_task_t task = nullptr;
    void *task_data = nullptr;
    /// Soft-cancel asks ArkTS to clearTimeout without deactivating the binding.
    bool clear_timer = false;
};
struct ScopedValue {
    Value *value;
    napi_ref keepalive;
};
struct CallbackScope {
    Engine *engine;
    CallbackScope *parent;
    std::vector<ScopedValue> owned;
};
thread_local CallbackScope *callback_scope = nullptr;

static void retainEngine(Engine *e) {
    if (e)
        e->refs.fetch_add(1, std::memory_order_relaxed);
}
static void releaseEngine(Engine *e) {
    if (e && e->refs.fetch_sub(1, std::memory_order_acq_rel) == 1)
        delete e;
}

static napi_value undefined(napi_env env) {
    napi_value v;
    napi_get_undefined(env, &v);
    return v;
}
static const char *statusCode(jsbay_status_t status) {
    switch (status) {
    case JSBAY_OK:
        return "JSBAY_OK";
    case JSBAY_EXCEPTION:
        return "JSBAY_EXCEPTION";
    case JSBAY_INVALID_ARGUMENT:
        return "JSBAY_INVALID_ARGUMENT";
    case JSBAY_WRONG_THREAD:
        return "JSBAY_WRONG_THREAD";
    case JSBAY_INSTANCE_NOT_FOUND:
        return "JSBAY_INSTANCE_NOT_FOUND";
    case JSBAY_STALE_VALUE:
        return "JSBAY_STALE_VALUE";
    case JSBAY_OUT_OF_MEMORY:
        return "JSBAY_OUT_OF_MEMORY";
    case JSBAY_UNSUPPORTED:
        return "JSBAY_UNSUPPORTED";
    case JSBAY_LOOP_FAILED:
        return "JSBAY_LOOP_FAILED";
    }
    return "JSBAY_UNKNOWN";
}
static napi_value statusError(napi_env env, jsbay_status_t status) {
    napi_value message = nullptr, error = nullptr, numeric = nullptr, code = nullptr;
    const std::string text =
        std::string("js-bay status ") + std::to_string(static_cast<int>(status));
    napi_create_string_utf8(env, text.c_str(), NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, nullptr, message, &error);
    napi_create_int32(env, static_cast<int32_t>(status), &numeric);
    napi_create_string_utf8(env, statusCode(status), NAPI_AUTO_LENGTH, &code);
    napi_set_named_property(env, error, "status", numeric);
    napi_set_named_property(env, error, "code", code);
    napi_throw(env, error);
    return nullptr;
}
static napi_value makeError(napi_env env, const char *,
                            jsbay_status_t status = JSBAY_INVALID_ARGUMENT) {
    return statusError(env, status);
}
static bool owner(Engine *e) {
    return e && !e->closed && e->owner == std::this_thread::get_id();
}
static bool readUtf8(napi_env env, napi_value value, std::string *out) {
    size_t n = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &n) != napi_ok)
        return false;
    out->resize(n);
    return napi_get_value_string_utf8(env, value, out->data(), n + 1, &n) == napi_ok;
}
static jsbay_utf8_t bytes(const std::string &s) {
    return {reinterpret_cast<const uint8_t *>(s.data()), s.size()};
}
static Value *unwrapValue(napi_env env, napi_value v) {
    Value *out = nullptr;
    return napi_unwrap(env, v, reinterpret_cast<void **>(&out)) == napi_ok ? out : nullptr;
}
static Engine *unwrapEngine(napi_env env, napi_value v) {
    Engine *out = nullptr;
    return napi_unwrap(env, v, reinterpret_cast<void **>(&out)) == napi_ok ? out : nullptr;
}
static void invalidate(Value *v);
static void clearLoop(Engine *engine);
static void envCleanup(void *data);
static void detachEnvCleanup(Engine *engine);
static bool requireEngine(napi_env env, Engine *e) {
    if (!e) {
        statusError(env, JSBAY_INVALID_ARGUMENT);
        return false;
    }
    if (e->closed) {
        statusError(env, JSBAY_INSTANCE_NOT_FOUND);
        return false;
    }
    if (e->owner != std::this_thread::get_id()) {
        statusError(env, JSBAY_WRONG_THREAD);
        return false;
    }
    return true;
}
static napi_value wrapValue(napi_env env, Engine *e, jsbay_value_t h, bool borrowed,
                            bool track_scope = true) {
    if (!h)
        return nullptr;
    napi_value o;
    if (napi_create_object(env, &o) != napi_ok)
        return makeError(env, "cannot allocate JsBay Value wrapper");
    retainEngine(e);
    auto *v = new Value{e, h, borrowed, true};
    if (napi_wrap(
            env, o, v,
            [](napi_env, void *data, void *) {
                auto *value = static_cast<Value *>(data);
                releaseEngine(value->engine);
                delete value;
            },
            nullptr, nullptr) != napi_ok) {
        if (!e->closed)
            (void)jsbay_value_release(h);
        delete v;
        releaseEngine(e);
        return makeError(env, "cannot wrap JsBay Value");
    }
    CallbackScope *value_scope = callback_scope;
    while (value_scope && value_scope->engine != e)
        value_scope = value_scope->parent;
    if (track_scope && !borrowed && value_scope) {
        napi_ref keepalive = nullptr;
        if (napi_create_reference(env, o, 1, &keepalive) != napi_ok) {
            if (!e->closed)
                (void)jsbay_value_release(h);
            invalidate(v);
            napi_throw_error(env, nullptr, "cannot retain temporary JsBay Value");
            return nullptr;
        }
        value_scope->owned.push_back({v, keepalive});
    }
    return o;
}
static bool checkedValue(napi_env env, napi_value input, Engine *expected, Value **out) {
    Value *v = unwrapValue(env, input);
    if (!v) {
        statusError(env, JSBAY_INVALID_ARGUMENT);
        return false;
    }
    if (!v->live || v->engine != expected || !expected || expected->closed) {
        statusError(env, JSBAY_STALE_VALUE);
        return false;
    }
    if (expected->owner != std::this_thread::get_id()) {
        statusError(env, JSBAY_WRONG_THREAD);
        return false;
    }
    *out = v;
    return true;
}
static bool requireValue(napi_env env, napi_value input, Value **out) {
    Value *value = unwrapValue(env, input);
    if (!value) {
        statusError(env, JSBAY_INVALID_ARGUMENT);
        return false;
    }
    if (!value->live || !value->engine || value->engine->closed) {
        statusError(env, JSBAY_STALE_VALUE);
        return false;
    }
    if (value->engine->owner != std::this_thread::get_id()) {
        statusError(env, JSBAY_WRONG_THREAD);
        return false;
    }
    *out = value;
    return true;
}
static napi_value takeResult(napi_env env, Engine *e, jsbay_status_t status, jsbay_value_t value,
                             jsbay_value_t exception) {
    if (status == JSBAY_OK)
        return wrapValue(env, e, value, false);
    if (status == JSBAY_EXCEPTION && exception) {
        napi_value ex_value = wrapValue(env, e, exception, false), message, error;
        napi_create_string_utf8(env, "JavaScript exception", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_set_named_property(env, error, "value", ex_value);
        napi_throw(env, error);
        return nullptr;
    }
    return statusError(env, status);
}
/* The boolean results of has/delete/instanceOf are meaningful only on JSBAY_OK; an exception is rethrown through takeResult. */
static napi_value takeBoolResult(napi_env env, Engine *e, jsbay_status_t status, bool flag,
                                 jsbay_value_t exception) {
    if (status != JSBAY_OK)
        return takeResult(env, e, status, 0, exception);
    napi_value out;
    napi_get_boolean(env, flag, &out);
    return out;
}
static void invalidate(Value *v) {
    if (v) {
        v->live = false;
        v->handle = 0;
    }
}
static void closeCallbackScope(CallbackScope *scope) {
    for (const auto &entry : scope->owned) {
        Value *value = entry.value;
        if (value && value->live && !value->borrowed) {
            /* A close request made in the callback defers runtime teardown. Releasing a temporary then could race that teardown, so only invalidate it. */
            if (!scope->engine->closed)
                (void)jsbay_value_release(value->handle);
            invalidate(value);
        }
        if (entry.keepalive)
            napi_delete_reference(scope->engine->env, entry.keepalive);
    }
}

/* The core calls this only after the last callback has unwound.  Do not invoke ArkTS from here: deleting a N-API reference and releasing our state are the complete teardown operation. */
static void finalizeBinding(void *opaque) {
    auto *binding = static_cast<Binding *>(opaque);
    if (!binding)
        return;
    if (binding->callback)
        napi_delete_reference(binding->engine->env, binding->callback);
    releaseEngine(binding->engine);
    delete binding;
}

static jsbay_status_t bridge(int id, void *opaque, jsbay_value_t this_value, size_t argc,
                             const jsbay_value_t *args, jsbay_value_t *out,
                             jsbay_value_t *out_exception) {
    auto *b = static_cast<Binding *>(opaque);
    Engine *e = b ? b->engine : nullptr;
    if (!owner(e))
        return JSBAY_WRONG_THREAD;
    napi_handle_scope scope;
    if (napi_open_handle_scope(e->env, &scope) != napi_ok)
        return JSBAY_OUT_OF_MEMORY;
    CallbackScope owned_scope{e, callback_scope, {}};
    callback_scope = &owned_scope;
    napi_value fn = nullptr, recv = undefined(e->env);
    if (napi_get_reference_value(e->env, b->callback, &fn) != napi_ok || !fn) {
        callback_scope = owned_scope.parent;
        napi_close_handle_scope(e->env, scope);
        return jsbay_value_new_error(id, bytes("Harmony host callback is unavailable"),
                                     out_exception) == JSBAY_OK
                   ? JSBAY_EXCEPTION
                   : JSBAY_UNSUPPORTED;
    }
    napi_value this_box = wrapValue(e->env, e, this_value, true);
    std::vector<napi_value> argv;
    argv.reserve(argc + 1);
    argv.push_back(this_box);
    std::vector<Value *> borrowed;
    borrowed.push_back(unwrapValue(e->env, this_box));
    for (size_t i = 0; i < argc; ++i) {
        napi_value box = wrapValue(e->env, e, args[i], true);
        argv.push_back(box);
        borrowed.push_back(unwrapValue(e->env, box));
    }
    napi_value result = nullptr;
    napi_status ns = napi_call_function(e->env, recv, fn, argv.size(), argv.data(), &result);
    if (ns == napi_pending_exception) {
        napi_value pending = nullptr;
        napi_get_and_clear_last_exception(e->env, &pending);
        napi_value propagated = nullptr;
        Value *propagated_value = nullptr;
        if (pending && napi_get_named_property(e->env, pending, "value", &propagated) == napi_ok)
            propagated_value = unwrapValue(e->env, propagated);
        if (propagated_value && propagated_value->live && propagated_value->engine == e) {
            jsbay_status_t s = jsbay_value_retain(propagated_value->handle, out_exception);
            for (auto *v : borrowed)
                invalidate(v);
            closeCallbackScope(&owned_scope);
            callback_scope = owned_scope.parent;
            napi_close_handle_scope(e->env, scope);
            return s == JSBAY_OK ? JSBAY_EXCEPTION : s;
        }
        std::string message = "Harmony host callback threw";
        napi_value msg = nullptr;
        if (pending && napi_get_named_property(e->env, pending, "message", &msg) == napi_ok) {
            std::string text;
            if (readUtf8(e->env, msg, &text))
                message = text;
        }
        jsbay_status_t s = jsbay_value_new_error(id, bytes(message), out_exception);
        for (auto *v : borrowed)
            invalidate(v);
        closeCallbackScope(&owned_scope);
        callback_scope = owned_scope.parent;
        napi_close_handle_scope(e->env, scope);
        return s == JSBAY_OK ? JSBAY_EXCEPTION : s;
    }
    Value *returned = unwrapValue(e->env, result);
    if (!returned || !returned->live || returned->engine != e) {
        jsbay_status_t s = jsbay_value_new_error(
            id, bytes("host callback must return a live Value from this Engine"), out_exception);
        for (auto *v : borrowed)
            invalidate(v);
        closeCallbackScope(&owned_scope);
        callback_scope = owned_scope.parent;
        napi_close_handle_scope(e->env, scope);
        return s == JSBAY_OK ? JSBAY_EXCEPTION : s;
    }
    jsbay_status_t s = jsbay_value_retain(returned->handle, out);
    for (auto *v : borrowed)
        invalidate(v);
    closeCallbackScope(&owned_scope);
    callback_scope = owned_scope.parent;
    napi_close_handle_scope(e->env, scope);
    return s;
}

static void finalizeSyncBinding(void *opaque) {
    auto *binding = static_cast<SyncBinding *>(opaque);
    if (!binding)
        return;
    if (binding->callback)
        napi_delete_reference(binding->engine->env, binding->callback);
    releaseEngine(binding->engine);
    delete binding;
}

/* Runs only on the engine owner Worker. request_id is intentionally converted to a bigint instead of a Number: starters may forward it to independent native code, which must call jsbay_sync_complete directly without N-API. */
static void syncBridge(int id, void *opaque, uint64_t request_id, jsbay_value_t this_value,
                       size_t argc, const jsbay_value_t *args) {
    (void)id;
    auto *binding = static_cast<SyncBinding *>(opaque);
    Engine *e = binding ? binding->engine : nullptr;
    if (!owner(e))
        return;
    napi_handle_scope scope;
    if (napi_open_handle_scope(e->env, &scope) != napi_ok) {
        (void)jsbay_sync_complete(request_id, JSBAY_EXCEPTION, JSBAY_SYNC_PAYLOAD_UTF8_STRING,
                                  bytes("Harmony sync starter is unavailable"));
        return;
    }
    CallbackScope owned_scope{e, callback_scope, {}};
    callback_scope = &owned_scope;
    std::vector<Value *> borrowed;
    const auto finish = [&]() {
        for (auto *value : borrowed)
            invalidate(value);
        closeCallbackScope(&owned_scope);
        callback_scope = owned_scope.parent;
        napi_close_handle_scope(e->env, scope);
    };
    napi_value fn = nullptr;
    if (napi_get_reference_value(e->env, binding->callback, &fn) != napi_ok || !fn) {
        (void)jsbay_sync_complete(request_id, JSBAY_EXCEPTION, JSBAY_SYNC_PAYLOAD_UTF8_STRING,
                                  bytes("Harmony sync starter is unavailable"));
        finish();
        return;
    }
    napi_value request = nullptr, this_box = nullptr, array = nullptr;
    if (napi_create_bigint_uint64(e->env, request_id, &request) != napi_ok ||
        !(this_box = wrapValue(e->env, e, this_value, true)) ||
        napi_create_array_with_length(e->env, argc, &array) != napi_ok) {
        (void)jsbay_sync_complete(request_id, JSBAY_EXCEPTION, JSBAY_SYNC_PAYLOAD_UTF8_STRING,
                                  bytes("Harmony sync starter allocation failed"));
        finish();
        return;
    }
    borrowed.push_back(unwrapValue(e->env, this_box));
    for (size_t index = 0; index < argc; ++index) {
        napi_value item = wrapValue(e->env, e, args[index], true);
        if (!item ||
            napi_set_element(e->env, array, static_cast<uint32_t>(index), item) != napi_ok) {
            (void)jsbay_sync_complete(request_id, JSBAY_EXCEPTION, JSBAY_SYNC_PAYLOAD_UTF8_STRING,
                                      bytes("Harmony sync starter allocation failed"));
            finish();
            return;
        }
        borrowed.push_back(unwrapValue(e->env, item));
    }
    napi_value argv[3] = {request, this_box, array};
    napi_value ignored = nullptr;
    const napi_status call_status =
        napi_call_function(e->env, undefined(e->env), fn, 3, argv, &ignored);
    if (call_status == napi_pending_exception) {
        napi_value pending = nullptr;
        napi_get_and_clear_last_exception(e->env, &pending);
        (void)jsbay_sync_complete(request_id, JSBAY_EXCEPTION, JSBAY_SYNC_PAYLOAD_UTF8_STRING,
                                  bytes("Harmony sync starter threw"));
    } else if (call_status != napi_ok) {
        (void)jsbay_sync_complete(request_id, JSBAY_EXCEPTION, JSBAY_SYNC_PAYLOAD_UTF8_STRING,
                                  bytes("Harmony sync starter failed"));
    }
    finish();
}

static napi_value bindSync(napi_env env, napi_callback_info info) {
    size_t n = 4;
    napi_value a[4];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    std::string name;
    uint64_t timeout = 0;
    bool lossless = false;
    napi_valuetype type;
    if (n != 4 || !requireEngine(env, e) || !readUtf8(env, a[1], &name) ||
        napi_get_value_bigint_uint64(env, a[2], &timeout, &lossless) != napi_ok || !lossless ||
        timeout == 0 || napi_typeof(env, a[3], &type) != napi_ok || type != napi_function)
        return makeError(
            env,
            "bindSync requires owner Engine, name, positive lossless bigint timeout and function");
    auto *binding = new SyncBinding{e, nullptr};
    if (napi_create_reference(env, a[3], 1, &binding->callback) != napi_ok) {
        delete binding;
        return makeError(env, "cannot retain sync starter");
    }
    retainEngine(e);
    jsbay_value_t fn = 0, exception = 0;
    const jsbay_status_t status = jsbay_engine_bind_sync(
        e->id, bytes(name), syncBridge, binding, finalizeSyncBinding, timeout, &fn, &exception);
    if (status != JSBAY_OK) {
        napi_delete_reference(env, binding->callback);
        releaseEngine(e);
        delete binding;
    }
    return takeResult(env, e, status, fn, exception);
}

static bool readBufferWindow(napi_env env, napi_value input, const uint8_t **data, size_t *len);

/* This intentionally has no Engine argument and touches no Engine or N-API wrapper state. It is safe to invoke from another ArkTS Worker's own env; native background threads should call jsbay_sync_complete directly.
 * BYTES+OK accepts ArrayBuffer/TypedArray/DataView (opaque octets). STRING/JSON/EXCEPTION require a UTF-8 string. */
static napi_value completeSync(napi_env env, napi_callback_info info) {
    size_t n = 4;
    napi_value a[4];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    uint64_t request_id = 0;
    bool lossless = false;
    uint32_t outcome = 0;
    uint32_t kind = 0;
    jsbay_status_t status = JSBAY_INVALID_ARGUMENT;
    if (n == 4 && napi_get_value_bigint_uint64(env, a[0], &request_id, &lossless) == napi_ok &&
        lossless && napi_get_value_uint32(env, a[1], &outcome) == napi_ok &&
        (outcome == JSBAY_OK || outcome == JSBAY_EXCEPTION) &&
        napi_get_value_uint32(env, a[2], &kind) == napi_ok &&
        (kind == JSBAY_SYNC_PAYLOAD_UTF8_STRING || kind == JSBAY_SYNC_PAYLOAD_BYTES ||
         kind == JSBAY_SYNC_PAYLOAD_JSON)) {
        const bool bytes_ok = (kind == JSBAY_SYNC_PAYLOAD_BYTES && outcome == JSBAY_OK);
        if (bytes_ok) {
            const uint8_t *raw = nullptr;
            size_t len = 0;
            if (readBufferWindow(env, a[3], &raw, &len)) {
                jsbay_utf8_t payload = {raw, len};
                status = jsbay_sync_complete(request_id, static_cast<jsbay_status_t>(outcome),
                                             static_cast<jsbay_sync_payload_kind_t>(kind), payload);
            }
        } else {
            std::string data;
            if (readUtf8(env, a[3], &data))
                status =
                    jsbay_sync_complete(request_id, static_cast<jsbay_status_t>(outcome),
                                        static_cast<jsbay_sync_payload_kind_t>(kind), bytes(data));
        }
    }
    napi_value result = nullptr;
    napi_create_int32(env, static_cast<int32_t>(status), &result);
    return result;
}

static void loopFinalize(napi_env, void *data, void *) {
    auto *binding = static_cast<LoopBinding *>(data);
    releaseEngine(binding->engine);
    delete binding;
}

static bool scheduleLoopTask(void *data, uint64_t delay_ms, jsbay_loop_task_t task,
                             void *task_data) {
    auto *binding = static_cast<LoopBinding *>(data);
    std::lock_guard<std::mutex> lock(binding->mutex);
    if (!binding->active.load(std::memory_order_acquire))
        return false;
    binding->generation =
        binding->engine->loop_generation.fetch_add(1, std::memory_order_relaxed) + 1;
    binding->delay_ms = delay_ms;
    binding->task = task;
    binding->task_data = task_data;
    if (binding->pending.exchange(true, std::memory_order_acq_rel))
        return true;
    if (napi_call_threadsafe_function(binding->tsfn, nullptr, napi_tsfn_nonblocking) == napi_ok)
        return true;
    binding->pending.store(false, std::memory_order_release);
    return false;
}

/* Soft cancel: drop pending work only. Binding stays active for suspend/resume.
 * Also wakes ArkTS so it can clearTimeout the pending platform timer (R2). */
static void cancelLoopTask(void *data) {
    auto *binding = static_cast<LoopBinding *>(data);
    bool need_wake = false;
    {
        std::lock_guard<std::mutex> lock(binding->mutex);
        if (!binding->active.load(std::memory_order_acquire))
            return;
        binding->task = nullptr;
        binding->task_data = nullptr;
        binding->clear_timer = true;
        binding->generation =
            binding->engine->loop_generation.fetch_add(1, std::memory_order_relaxed) + 1;
        if (!binding->pending.exchange(true, std::memory_order_acq_rel))
            need_wake = true;
    }
    if (need_wake && binding->tsfn) {
        if (napi_call_threadsafe_function(binding->tsfn, nullptr, napi_tsfn_nonblocking) != napi_ok)
            binding->pending.store(false, std::memory_order_release);
    }
}

static void shutdownLoopTask(LoopBinding *binding) {
    if (!binding)
        return;
    std::lock_guard<std::mutex> lock(binding->mutex);
    binding->active.store(false, std::memory_order_release);
    binding->task = nullptr;
    binding->task_data = nullptr;
    binding->engine->loop_generation.fetch_add(1, std::memory_order_relaxed);
}

static void loopDispatch(napi_env env, napi_value callback, void *context, void *) {
    auto *binding = static_cast<LoopBinding *>(context);
    binding->pending.store(false, std::memory_order_release);
    if (!env || !callback || !binding->active.load(std::memory_order_acquire) ||
        binding->engine->closed)
        return;
    uint64_t generation, delay;
    bool clear_only = false;
    {
        std::lock_guard<std::mutex> lock(binding->mutex);
        if (!binding->active.load(std::memory_order_acquire))
            return;
        generation = binding->generation;
        delay = binding->delay_ms;
        if (binding->clear_timer) {
            binding->clear_timer = false;
            clear_only = binding->task == nullptr;
        }
    }
    (void)napi_ref_threadsafe_function(env, binding->tsfn);
    napi_value args[2], ignored;
    // Negative delay is the soft-cancel sentinel: ArkTS clears setTimeout and returns.
    const double delay_arg = clear_only ? -1.0 : static_cast<double>(delay);
    napi_create_double(env, delay_arg, &args[0]);
    napi_create_bigint_uint64(env, generation, &args[1]);
    (void)napi_call_function(env, undefined(env), callback, 2, args, &ignored);
    napi_value exception = nullptr;
    (void)napi_get_and_clear_last_exception(env, &exception);
}

static void clearLoop(Engine *engine) {
    LoopBinding *old = engine->loop;
    if (!old)
        return;
    (void)jsbay_engine_detach_loop(engine->id);
    engine->loop = nullptr;
    shutdownLoopTask(old);
    (void)napi_release_threadsafe_function(old->tsfn, napi_tsfn_abort);
}

static void detachEnvCleanup(Engine *engine) {
    if (!engine->cleanup_registered)
        return;
    engine->cleanup_registered = false;
    (void)napi_remove_env_cleanup_hook(engine->env, envCleanup, engine);
    releaseEngine(engine);
}

/* N-API invokes cleanup on this environment's owner thread. It closes the core before the environment can invalidate the TSFN, so no later native wake can retain freed user_data. This path deliberately does not call ArkTS. */
static void envCleanup(void *data) {
    auto *engine = static_cast<Engine *>(data);
    if (!engine)
        return;
    if (engine->cleanup_registered) {
        engine->cleanup_registered = false;
        clearLoop(engine);
        if (!engine->closed) {
            engine->closed = true;
            jsbay_engine_destroy(engine->id);
        }
        releaseEngine(engine);
    }
}

static napi_value attachLoop(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *engine = n ? unwrapEngine(env, a[0]) : nullptr;
    if (n != 2 || !requireEngine(env, engine))
        return nullptr;
    napi_valuetype type;
    if (napi_typeof(env, a[1], &type) != napi_ok || type != napi_function)
        return makeError(env, "attachLoop requires a platform scheduler");
    clearLoop(engine);
    napi_value resource_name;
    napi_create_string_utf8(env, "js-bay loop", NAPI_AUTO_LENGTH, &resource_name);
    auto *binding = new LoopBinding{};
    binding->engine = engine;
    retainEngine(engine);
    if (napi_create_threadsafe_function(env, a[1], nullptr, resource_name, 0, 1, binding,
                                        loopFinalize, binding, loopDispatch,
                                        &binding->tsfn) != napi_ok) {
        releaseEngine(engine);
        delete binding;
        return makeError(env, "cannot create loop dispatcher");
    }
    const auto status =
        jsbay_engine_attach_loop(engine->id, scheduleLoopTask, cancelLoopTask, binding);
    if (status != JSBAY_OK) {
        shutdownLoopTask(binding);
        (void)napi_release_threadsafe_function(binding->tsfn, napi_tsfn_abort);
        return statusError(env, status);
    }
    engine->loop = binding;
    return undefined(env);
}

static napi_value runLoopTask(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *engine = n ? unwrapEngine(env, a[0]) : nullptr;
    if (n != 2 || !requireEngine(env, engine))
        return nullptr;
    uint64_t generation;
    bool lossless = false;
    if (napi_get_value_bigint_uint64(env, a[1], &generation, &lossless) != napi_ok || !lossless)
        return makeError(env, "invalid loop generation");
    LoopBinding *binding = engine->loop;
    if (!binding)
        return undefined(env);
    jsbay_loop_task_t task;
    void *task_data;
    {
        std::lock_guard<std::mutex> lock(binding->mutex);
        if (!binding->active.load(std::memory_order_acquire) || generation != binding->generation)
            return undefined(env);
        task = binding->task;
        task_data = binding->task_data;
        binding->task = nullptr;
    }
    if (task)
        task(task_data);
    if (!engine->closed && jsbay_engine_loop_status(engine->id) == JSBAY_LOOP_FAILED)
        return statusError(env, JSBAY_LOOP_FAILED);
    if (!engine->closed && engine->loop == binding &&
        binding->active.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lock(binding->mutex);
        if (binding->task == nullptr && !binding->pending.load(std::memory_order_acquire))
            (void)napi_unref_threadsafe_function(env, binding->tsfn);
    }
    return undefined(env);
}

static napi_value runLoop(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *engine = n ? unwrapEngine(env, a[0]) : nullptr;
    if (!requireEngine(env, engine))
        return nullptr;
    for (auto *scope = callback_scope; scope; scope = scope->parent) {
        if (scope->engine == engine)
            return statusError(env, JSBAY_INVALID_ARGUMENT);
    }
    const auto loop_status = jsbay_engine_loop_status(engine->id);
    if (loop_status != JSBAY_OK)
        return statusError(env, loop_status);
    clearLoop(engine);
    const auto status = jsbay_engine_run_loop(engine->id);
    return status == JSBAY_OK ? undefined(env) : statusError(env, status);
}

static napi_value stopLoop(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *engine = n ? unwrapEngine(env, a[0]) : nullptr;
    if (!requireEngine(env, engine))
        return nullptr;
    napi_value result;
    napi_get_boolean(env, jsbay_engine_stop_loop(engine->id), &result);
    return result;
}

static napi_value suspendLoop(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *engine = n ? unwrapEngine(env, a[0]) : nullptr;
    if (!requireEngine(env, engine))
        return nullptr;
    napi_value result;
    napi_get_boolean(env, jsbay_engine_suspend(engine->id), &result);
    return result;
}

static napi_value resumeLoop(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *engine = n ? unwrapEngine(env, a[0]) : nullptr;
    if (!requireEngine(env, engine))
        return nullptr;
    napi_value result;
    napi_get_boolean(env, jsbay_engine_resume(engine->id), &result);
    return result;
}

static napi_value isSuspended(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *engine = n ? unwrapEngine(env, a[0]) : nullptr;
    if (!requireEngine(env, engine))
        return nullptr;
    napi_value result;
    napi_get_boolean(env, jsbay_engine_is_suspended(engine->id), &result);
    return result;
}

static napi_value wrapCreatedEngine(napi_env env, int32_t id) {
    napi_value o;
    if (napi_create_object(env, &o) != napi_ok) {
        jsbay_engine_destroy(id);
        return makeError(env, "cannot allocate JsBay Engine wrapper");
    }
    auto *e = new Engine;
    e->env = env;
    e->id = id;
    /* Owner is the creating Worker thread for the life of this Engine. Engine and Value N-API entry points reject other threads with JSBAY_WRONG_THREAD; do not move wrappers across Workers. */
    e->owner = std::this_thread::get_id();
    if (napi_wrap(
            env, o, e,
            [](napi_env, void *data, void *) { releaseEngine(static_cast<Engine *>(data)); },
            nullptr, nullptr) != napi_ok) {
        jsbay_engine_destroy(id);
        delete e;
        return makeError(env, "cannot wrap JsBay Engine");
    }
    retainEngine(e);
    if (napi_add_env_cleanup_hook(env, envCleanup, e) != napi_ok) {
        releaseEngine(e);
        jsbay_engine_destroy(id);
        return makeError(env, "cannot register JsBay environment cleanup");
    }
    e->cleanup_registered = true;
    return o;
}
static bool readU64AsSize(napi_env env, napi_value v, size_t *out) {
    uint64_t raw = 0;
    bool lossless = false;
    if (napi_get_value_bigint_uint64(env, v, &raw, &lossless) == napi_ok && lossless) {
        *out = (size_t)raw;
        return true;
    }
    int64_t signed_v = 0;
    if (napi_get_value_int64(env, v, &signed_v) == napi_ok && signed_v >= 0) {
        *out = (size_t)signed_v;
        return true;
    }
    double d = 0;
    if (napi_get_value_double(env, v, &d) == napi_ok && d >= 0 && d == (double)(uint64_t)d) {
        *out = (size_t)d;
        return true;
    }
    return false;
}
static bool readLimitsArgs(napi_env env, napi_value *a, size_t start,
                           jsbay_resource_limits_t *out) {
    size_t max_timers, max_tsfn, max_calls, max_bytes, max_tasks;
    if (!readU64AsSize(env, a[start], &max_timers) ||
        !readU64AsSize(env, a[start + 1], &max_tsfn) ||
        !readU64AsSize(env, a[start + 2], &max_calls) ||
        !readU64AsSize(env, a[start + 3], &max_bytes) ||
        !readU64AsSize(env, a[start + 4], &max_tasks))
        return false;
    *out = (jsbay_resource_limits_t){
        .struct_size = sizeof(*out),
        .max_timers = max_timers,
        .max_tsfn_handles = max_tsfn,
        .max_pending_calls = max_calls,
        .max_pending_bytes = max_bytes,
        .max_pending_tasks = max_tasks,
    };
    return true;
}
static bool setU64Prop(napi_env env, napi_value obj, const char *name, uint64_t value) {
    napi_value v;
    if (napi_create_bigint_uint64(env, value, &v) != napi_ok)
        return false;
    return napi_set_named_property(env, obj, name, v) == napi_ok;
}

static bool setI32Prop(napi_env env, napi_value obj, const char *name, int32_t value) {
    napi_value v;
    if (napi_create_int32(env, value, &v) != napi_ok)
        return false;
    return napi_set_named_property(env, obj, name, v) == napi_ok;
}
static bool setU8Prop(napi_env env, napi_value obj, const char *name, uint8_t value) {
    return setI32Prop(env, obj, name, static_cast<int32_t>(value));
}

static napi_value create(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    int32_t id;
    if (n != 1 || napi_get_value_int32(env, a[0], &id) != napi_ok ||
        !jsbay_engine_create(id, nullptr, nullptr))
        return makeError(env, "cannot create JsBay Engine");
    return wrapCreatedEngine(env, id);
}
static napi_value createWithLimits(napi_env env, napi_callback_info info) {
    size_t n = 6;
    napi_value a[6];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    int32_t id;
    jsbay_resource_limits_t limits;
    if (n != 6 || napi_get_value_int32(env, a[0], &id) != napi_ok ||
        !readLimitsArgs(env, a, 1, &limits) ||
        !jsbay_engine_create_with_limits(id, nullptr, nullptr, &limits))
        return makeError(env, "cannot create JsBay Engine with limits");
    return wrapCreatedEngine(env, id);
}
static napi_value setResourceLimits(napi_env env, napi_callback_info info) {
    size_t n = 6;
    napi_value a[6];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    jsbay_resource_limits_t limits;
    if (n != 6 || !requireEngine(env, e) || !readLimitsArgs(env, a, 1, &limits))
        return nullptr;
    napi_value out;
    napi_get_boolean(env, jsbay_engine_set_resource_limits(e->id, &limits), &out);
    return out;
}
static napi_value resourceUsage(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    if (n != 1 || !requireEngine(env, e))
        return nullptr;
    jsbay_resource_usage_t usage = {.struct_size = sizeof(usage)};
    if (!jsbay_engine_get_resource_usage(e->id, &usage))
        return makeError(env, "cannot read resource usage");
    napi_value out;
    if (napi_create_object(env, &out) != napi_ok)
        return makeError(env, "cannot allocate resource usage");
    if (!setU64Prop(env, out, "timers", usage.timers) ||
        !setU64Prop(env, out, "tsfnHandles", usage.tsfn_handles) ||
        !setU64Prop(env, out, "pendingCalls", usage.pending_calls) ||
        !setU64Prop(env, out, "nativeTasks", usage.native_tasks) ||
        !setU64Prop(env, out, "scriptTasks", usage.script_tasks) ||
        !setU64Prop(env, out, "pendingBytes", usage.pending_bytes) ||
        !setU64Prop(env, out, "maxTimers", usage.max_timers) ||
        !setU64Prop(env, out, "maxTsfnHandles", usage.max_tsfn_handles) ||
        !setU64Prop(env, out, "maxPendingCalls", usage.max_pending_calls) ||
        !setU64Prop(env, out, "maxPendingBytes", usage.max_pending_bytes) ||
        !setU64Prop(env, out, "maxPendingTasks", usage.max_pending_tasks))
        return makeError(env, "cannot populate resource usage");
    return out;
}

static napi_value listEngines(napi_env env, napi_callback_info info) {
    (void)info;
    size_t need = jsbay_engine_list(nullptr, 0);
    std::vector<int32_t> ids(need);
    size_t n = jsbay_engine_list(ids.data(), need);
    if (n > need) {
        ids.resize(n);
        n = jsbay_engine_list(ids.data(), n);
    }
    if (n < ids.size())
        ids.resize(n);
    napi_value out;
    if (napi_create_array_with_length(env, ids.size(), &out) != napi_ok)
        return makeError(env, "cannot allocate engine list");
    for (size_t i = 0; i < ids.size(); ++i) {
        napi_value item;
        napi_create_int32(env, ids[i], &item);
        napi_set_element(env, out, i, item);
    }
    return out;
}
static napi_value snapshotEngine(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    int32_t id = 0;
    if (n != 1 || napi_get_value_int32(env, a[0], &id) != napi_ok) {
        napi_value out;
        napi_get_null(env, &out);
        return out;
    }
    jsbay_instance_snapshot_t snap = {.struct_size = sizeof(snap)};
    if (!jsbay_engine_snapshot(id, &snap)) {
        napi_value out;
        napi_get_null(env, &out);
        return out;
    }
    napi_value out;
    if (napi_create_object(env, &out) != napi_ok)
        return makeError(env, "cannot allocate instance snapshot");
    if (!setI32Prop(env, out, "instanceId", snap.instance_id) ||
        !setU64Prop(env, out, "generation", snap.generation) ||
        !setU64Prop(env, out, "ownerThreadId", snap.owner_thread_id) ||
        !setU8Prop(env, out, "loopMode", snap.loop_mode) ||
        !setU8Prop(env, out, "flags", snap.flags) ||
        !setI32Prop(env, out, "admissionClass", static_cast<int32_t>(snap.admission_class)) ||
        !setU64Prop(env, out, "timersReserved", snap.timers_reserved) ||
        !setU64Prop(env, out, "timersRegistered", snap.timers_registered) ||
        !setU64Prop(env, out, "scriptTasksQueued", snap.script_tasks_queued) ||
        !setU64Prop(env, out, "nativeTasksQueued", snap.native_tasks_queued) ||
        !setU64Prop(env, out, "pendingBytes", snap.pending_bytes) ||
        !setU64Prop(env, out, "maxTimers", snap.max_timers) ||
        !setU64Prop(env, out, "maxPendingTasks", snap.max_pending_tasks) ||
        !setU64Prop(env, out, "maxPendingBytes", snap.max_pending_bytes))
        return makeError(env, "cannot populate instance snapshot");
    return out;
}
static napi_value globalResourceUsage(napi_env env, napi_callback_info info) {
    (void)info;
    jsbay_resource_global_usage_t usage = {.struct_size = sizeof(usage)};
    if (!jsbay_resource_global_usage(&usage))
        return makeError(env, "cannot read global resource usage");
    napi_value out;
    if (napi_create_object(env, &out) != napi_ok)
        return makeError(env, "cannot allocate global resource usage");
    if (!setU64Prop(env, out, "timers", usage.timers) ||
        !setU64Prop(env, out, "tsfnHandles", usage.tsfn_handles) ||
        !setU64Prop(env, out, "pendingCalls", usage.pending_calls) ||
        !setU64Prop(env, out, "nativeTasks", usage.native_tasks) ||
        !setU64Prop(env, out, "scriptTasks", usage.script_tasks) ||
        !setU64Prop(env, out, "pendingBytes", usage.pending_bytes) ||
        !setU64Prop(env, out, "maxTimers", usage.max_timers) ||
        !setU64Prop(env, out, "maxTsfnHandles", usage.max_tsfn_handles) ||
        !setU64Prop(env, out, "maxPendingCalls", usage.max_pending_calls) ||
        !setU64Prop(env, out, "maxNativeTasks", usage.max_native_tasks) ||
        !setU64Prop(env, out, "maxScriptTasks", usage.max_script_tasks) ||
        !setU64Prop(env, out, "maxPendingBytes", usage.max_pending_bytes) ||
        !setU64Prop(env, out, "fgHeadroomTimers", usage.fg_headroom_timers) ||
        !setU64Prop(env, out, "fgHeadroomTsfnHandles", usage.fg_headroom_tsfn_handles) ||
        !setU64Prop(env, out, "fgHeadroomPendingCalls", usage.fg_headroom_pending_calls) ||
        !setU64Prop(env, out, "fgHeadroomNativeTasks", usage.fg_headroom_native_tasks) ||
        !setU64Prop(env, out, "fgHeadroomScriptTasks", usage.fg_headroom_script_tasks) ||
        !setU64Prop(env, out, "fgHeadroomPendingBytes", usage.fg_headroom_pending_bytes) ||
        !setU64Prop(env, out, "bgEffectiveMaxTimers", usage.bg_effective_max_timers) ||
        !setU64Prop(env, out, "bgEffectiveMaxTsfnHandles", usage.bg_effective_max_tsfn_handles) ||
        !setU64Prop(env, out, "bgEffectiveMaxPendingCalls", usage.bg_effective_max_pending_calls) ||
        !setU64Prop(env, out, "bgEffectiveMaxNativeTasks", usage.bg_effective_max_native_tasks) ||
        !setU64Prop(env, out, "bgEffectiveMaxScriptTasks", usage.bg_effective_max_script_tasks) ||
        !setU64Prop(env, out, "bgEffectiveMaxPendingBytes", usage.bg_effective_max_pending_bytes))
        return makeError(env, "cannot populate global resource usage");
    return out;
}
static napi_value closeEngine(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    if (!e)
        return makeError(env, "Engine.close requires Engine");
    if (e->closed)
        return undefined(env);
    if (e->owner != std::this_thread::get_id())
        return makeError(env, "Engine.close must run on its owner thread");
    clearLoop(e);
    detachEnvCleanup(e);
    e->closed = true;
    jsbay_engine_destroy(e->id);
    return undefined(env);
}
static napi_value evaluate(napi_env env, napi_callback_info info) {
    size_t n = 5;
    napi_value a[5];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    std::string src, file, dir, version;
    if (n != 3 && n != 5)
        return makeError(env, "evaluate requires owner Engine, UTF-8 source and filename, plus "
                              "optional cache directory and version");
    if (!requireEngine(env, e))
        return nullptr;
    if (!readUtf8(env, a[1], &src) || !readUtf8(env, a[2], &file))
        return makeError(env, "evaluate requires owner Engine, UTF-8 source and filename, plus "
                              "optional cache directory and version");
    bool hit = false;
    jsbay_engine_evaluate_options_t options = {sizeof(options), {nullptr, 0}, {nullptr, 0}, &hit};
    if (n > 3 && (!readUtf8(env, a[3], &dir) || !readUtf8(env, a[4], &version) ||
                  (dir.empty() != version.empty())))
        return makeError(env, "cache directory and version must both be empty or non-empty");
    if (n > 3) {
        options.cache_dir = bytes(dir);
        options.cache_version = bytes(version);
    }
    jsbay_value_t v = 0, x = 0;
    auto s =
        jsbay_engine_evaluate(e->id, bytes(src), bytes(file), n > 3 ? &options : nullptr, &v, &x);
    napi_value result = takeResult(env, e, s, v, x);
    if (result) {
        napi_value did_hit;
        napi_get_boolean(env, hit, &did_hit);
        napi_set_named_property(env, result, "cacheHit", did_hit);
    }
    return result;
}
static napi_value releaseValue(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *v = nullptr;
    if (n != 1 || !requireValue(env, a[0], &v))
        return nullptr;
    if (v->borrowed)
        return statusError(env, JSBAY_INVALID_ARGUMENT);
    auto s = jsbay_value_release(v->handle);
    if (s != JSBAY_OK)
        return statusError(env, s);
    invalidate(v);
    return undefined(env);
}
static napi_value retainValue(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *v = nullptr;
    if (n != 1 ||
        !checkedValue(env, a[0], unwrapValue(env, a[0]) ? unwrapValue(env, a[0])->engine : nullptr,
                      &v))
        return nullptr;
    jsbay_value_t h = 0;
    auto s = jsbay_value_retain(v->handle, &h); /* retain explicitly escapes a callback scope. */
    return s == JSBAY_OK ? wrapValue(env, v->engine, h, false, false) : statusError(env, s);
}
static napi_value globalValue(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    if (n != 1)
        return makeError(env, "global requires owner Engine");
    if (!requireEngine(env, e))
        return nullptr;
    jsbay_value_t h = 0;
    auto s = jsbay_engine_global(e->id, &h);
    return s == JSBAY_OK ? wrapValue(env, e, h, false) : statusError(env, s);
}
static napi_value getValue(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *v = nullptr;
    std::string key;
    if (n != 2 || !readUtf8(env, a[1], &key) ||
        !checkedValue(env, a[0], unwrapValue(env, a[0]) ? unwrapValue(env, a[0])->engine : nullptr,
                      &v))
        return nullptr;
    jsbay_value_t h = 0, x = 0;
    auto s = jsbay_value_get(v->handle, bytes(key), &h, &x);
    return takeResult(env, v->engine, s, h, x);
}
static napi_value setValue(napi_env env, napi_callback_info info) {
    size_t n = 3;
    napi_value a[3];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *o = nullptr, *v = nullptr;
    std::string key;
    if (n != 3 || !readUtf8(env, a[1], &key) ||
        !checkedValue(env, a[0], unwrapValue(env, a[0]) ? unwrapValue(env, a[0])->engine : nullptr,
                      &o) ||
        !checkedValue(env, a[2], o->engine, &v))
        return nullptr;
    jsbay_value_t x = 0;
    auto s = jsbay_value_set(o->handle, bytes(key), v->handle, &x);
    if (s == JSBAY_OK)
        return undefined(env);
    return takeResult(env, o->engine, s, 0, x);
}
static napi_value callValue(napi_env env, napi_callback_info info) {
    size_t n = 3;
    napi_value a[3];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *fn = nullptr, *self = nullptr;
    if (n != 3 ||
        !checkedValue(env, a[0], unwrapValue(env, a[0]) ? unwrapValue(env, a[0])->engine : nullptr,
                      &fn) ||
        !checkedValue(env, a[1], fn->engine, &self))
        return nullptr;
    bool is_array = false;
    if (napi_is_array(env, a[2], &is_array) != napi_ok || !is_array)
        return makeError(env, "call args must be an array of Value");
    uint32_t count = 0;
    napi_get_array_length(env, a[2], &count);
    std::vector<jsbay_value_t> args;
    args.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
        napi_value item;
        Value *v = nullptr;
        napi_get_element(env, a[2], i, &item);
        if (!checkedValue(env, item, fn->engine, &v))
            return nullptr;
        args.push_back(v->handle);
    }
    jsbay_value_t h = 0, x = 0;
    auto s = jsbay_value_call(fn->handle, self->handle, args.data(), args.size(), &h, &x);
    return takeResult(env, fn->engine, s, h, x);
}
static napi_value constructValue(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *fn = nullptr;
    if (n != 2 ||
        !checkedValue(env, a[0], unwrapValue(env, a[0]) ? unwrapValue(env, a[0])->engine : nullptr,
                      &fn))
        return nullptr;
    bool is_array = false;
    if (napi_is_array(env, a[1], &is_array) != napi_ok || !is_array)
        return makeError(env, "construct args must be an array of Value");
    uint32_t count = 0;
    napi_get_array_length(env, a[1], &count);
    std::vector<jsbay_value_t> args;
    args.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
        napi_value item;
        Value *v = nullptr;
        napi_get_element(env, a[1], i, &item);
        if (!checkedValue(env, item, fn->engine, &v))
            return nullptr;
        args.push_back(v->handle);
    }
    jsbay_value_t h = 0, x = 0;
    auto s = jsbay_value_construct(fn->handle, args.data(), args.size(), &h, &x);
    return takeResult(env, fn->engine, s, h, x);
}
static napi_value hasValue(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *v = nullptr;
    std::string key;
    if (n != 2 || !readUtf8(env, a[1], &key) ||
        !checkedValue(env, a[0], unwrapValue(env, a[0]) ? unwrapValue(env, a[0])->engine : nullptr,
                      &v))
        return nullptr;
    bool found = false;
    jsbay_value_t x = 0;
    auto s = jsbay_value_has(v->handle, bytes(key), &found, &x);
    return takeBoolResult(env, v->engine, s, found, x);
}
static napi_value deleteValue(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *v = nullptr;
    std::string key;
    if (n != 2 || !readUtf8(env, a[1], &key) ||
        !checkedValue(env, a[0], unwrapValue(env, a[0]) ? unwrapValue(env, a[0])->engine : nullptr,
                      &v))
        return nullptr;
    bool deleted = false;
    jsbay_value_t x = 0;
    auto s = jsbay_value_delete(v->handle, bytes(key), &deleted, &x);
    return takeBoolResult(env, v->engine, s, deleted, x);
}
static napi_value keysValue(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *v = nullptr;
    if (n != 1 ||
        !checkedValue(env, a[0], unwrapValue(env, a[0]) ? unwrapValue(env, a[0])->engine : nullptr,
                      &v))
        return nullptr;
    jsbay_value_t h = 0, x = 0;
    auto s = jsbay_value_keys(v->handle, &h, &x);
    return takeResult(env, v->engine, s, h, x);
}
static napi_value instanceOfValue(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *v = nullptr, *ctor = nullptr;
    if (n != 2 ||
        !checkedValue(env, a[0], unwrapValue(env, a[0]) ? unwrapValue(env, a[0])->engine : nullptr,
                      &v) ||
        !checkedValue(env, a[1], v->engine, &ctor))
        return nullptr;
    bool result = false;
    jsbay_value_t x = 0;
    auto s = jsbay_value_instance_of(v->handle, ctor->handle, &result, &x);
    return takeBoolResult(env, v->engine, s, result, x);
}
static napi_value newString(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    std::string text;
    if (n != 2 || !owner(e) || !readUtf8(env, a[1], &text))
        return makeError(env, "newString requires owner Engine and string");
    jsbay_value_t h = 0;
    auto s = jsbay_value_new_string(e->id, bytes(text), &h);
    return s == JSBAY_OK ? wrapValue(env, e, h, false) : statusError(env, s);
}
static napi_value newNumber(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    double value;
    if (n != 2 || !owner(e) || napi_get_value_double(env, a[1], &value) != napi_ok)
        return makeError(env, "newNumber requires owner Engine and number");
    jsbay_value_t h = 0;
    auto s = jsbay_value_new_number(e->id, value, &h);
    return s == JSBAY_OK ? wrapValue(env, e, h, false) : statusError(env, s);
}
static napi_value newBool(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    bool value;
    if (n != 2 || !owner(e) || napi_get_value_bool(env, a[1], &value) != napi_ok)
        return makeError(env, "newBool requires owner Engine and boolean");
    jsbay_value_t h = 0;
    auto s = jsbay_value_new_bool(e->id, value, &h);
    return s == JSBAY_OK ? wrapValue(env, e, h, false) : statusError(env, s);
}
static napi_value newSimple(napi_env env, napi_callback_info info, int kind) {
    size_t n = 1;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    if (!owner(e))
        return makeError(env, "constructor requires owner Engine");
    jsbay_value_t h = 0;
    jsbay_status_t s = kind == 0   ? jsbay_value_undefined(e->id, &h)
                       : kind == 1 ? jsbay_value_null(e->id, &h)
                       : kind == 2 ? jsbay_value_new_object(e->id, &h)
                                   : jsbay_value_new_array(e->id, &h);
    return s == JSBAY_OK ? wrapValue(env, e, h, false) : statusError(env, s);
}
static napi_value newUndefined(napi_env e, napi_callback_info i) {
    return newSimple(e, i, 0);
}
static napi_value newNull(napi_env e, napi_callback_info i) {
    return newSimple(e, i, 1);
}
static napi_value newObject(napi_env e, napi_callback_info i) {
    return newSimple(e, i, 2);
}
static napi_value newArray(napi_env e, napi_callback_info i) {
    return newSimple(e, i, 3);
}
static napi_value newTextValue(napi_env env, napi_callback_info info, bool json, bool error) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    std::string text;
    if (n != 2 || !owner(e) || !readUtf8(env, a[1], &text))
        return makeError(env, "constructor requires owner Engine and string");
    jsbay_value_t h = 0, x = 0;
    jsbay_status_t s = error  ? jsbay_value_new_error(e->id, bytes(text), &h)
                       : json ? jsbay_value_new_json(e->id, bytes(text), &h, &x)
                              : JSBAY_INVALID_ARGUMENT;
    return error ? (s == JSBAY_OK ? wrapValue(env, e, h, false) : statusError(env, s))
                 : takeResult(env, e, s, h, x);
}
static napi_value newJson(napi_env e, napi_callback_info i) {
    return newTextValue(e, i, true, false);
}
static napi_value newErrorValue(napi_env e, napi_callback_info i) {
    return newTextValue(e, i, false, true);
}
static size_t typedArrayBytes(napi_typedarray_type type) {
    switch (type) {
    case napi_int8_array:
    case napi_uint8_array:
    case napi_uint8_clamped_array:
        return 1;
    case napi_int16_array:
    case napi_uint16_array:
        return 2;
    case napi_int32_array:
    case napi_uint32_array:
    case napi_float32_array:
        return 4;
    case napi_float64_array:
    case napi_bigint64_array:
    case napi_biguint64_array:
        return 8;
    default:
        return 0;
    }
}
static bool readBufferWindow(napi_env env, napi_value input, const uint8_t **data, size_t *len) {
    bool matches = false;
    if (napi_is_arraybuffer(env, input, &matches) == napi_ok && matches) {
        void *raw = nullptr;
        return napi_get_arraybuffer_info(env, input, &raw, len) == napi_ok &&
               ((*data = static_cast<const uint8_t *>(raw)), true);
    }
    if (napi_is_typedarray(env, input, &matches) == napi_ok && matches) {
        napi_typedarray_type type;
        size_t length = 0, offset = 0;
        void *raw = nullptr;
        napi_value backing;
        if (napi_get_typedarray_info(env, input, &type, &length, &raw, &backing, &offset) !=
            napi_ok)
            return false;
        size_t width = typedArrayBytes(type);
        if (!width || length > SIZE_MAX / width)
            return false;
        *data = static_cast<const uint8_t *>(raw);
        *len = length * width;
        return true;
    }
    if (napi_is_dataview(env, input, &matches) == napi_ok && matches) {
        void *raw = nullptr;
        size_t offset = 0;
        napi_value backing;
        return napi_get_dataview_info(env, input, len, &raw, &backing, &offset) == napi_ok &&
               ((*data = static_cast<const uint8_t *>(raw)), true);
    }
    return false;
}
static napi_value newArrayBufferValue(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    const uint8_t *data = nullptr;
    size_t len = 0;
    if (n != 2 || !owner(e) || !readBufferWindow(env, a[1], &data, &len))
        return makeError(
            env, "newArrayBuffer requires owner Engine and ArrayBuffer, TypedArray, or DataView");
    jsbay_value_t h = 0;
    auto s = jsbay_value_new_array_buffer(e->id, data, len, &h);
    return s == JSBAY_OK ? wrapValue(env, e, h, false) : statusError(env, s);
}
static napi_value copyBufferValue(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *v = nullptr;
    if (n != 1 || !requireValue(env, a[0], &v))
        return nullptr;
    jsbay_bytes_t b = {nullptr, 0};
    jsbay_value_t x = 0;
    auto s = jsbay_value_copy_buffer(v->handle, &b, &x);
    if (s == JSBAY_EXCEPTION)
        return takeResult(env, v->engine, s, 0, x);
    if (s != JSBAY_OK)
        return statusError(env, s);
    napi_value out;
    void *data = nullptr;
    if (napi_create_arraybuffer(env, b.len, &data, &out) != napi_ok) {
        jsbay_free_bytes(b);
        return makeError(env, "cannot allocate ArrayBuffer", JSBAY_OUT_OF_MEMORY);
    }
    if (b.len)
        memcpy(data, b.data, b.len);
    jsbay_free_bytes(b);
    return out;
}
static napi_value typeValue(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *v = nullptr;
    if (n != 1 || !requireValue(env, a[0], &v))
        return nullptr;
    jsbay_value_kind_t kind;
    auto s = jsbay_value_type(v->handle, &kind);
    if (s != JSBAY_OK)
        return statusError(env, s);
    napi_value out;
    napi_create_int32(env, static_cast<int32_t>(kind), &out);
    return out;
}
static napi_value scalarValue(napi_env env, napi_callback_info info, bool boolean) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *v = nullptr;
    if (n != 1 || !requireValue(env, a[0], &v))
        return nullptr;
    if (boolean) {
        bool b = false;
        auto s = jsbay_value_to_bool(v->handle, &b);
        if (s != JSBAY_OK)
            return statusError(env, s);
        napi_value out;
        napi_get_boolean(env, b, &out);
        return out;
    }
    double d = 0;
    auto s = jsbay_value_to_number(v->handle, &d);
    if (s != JSBAY_OK)
        return statusError(env, s);
    napi_value out;
    napi_create_double(env, d, &out);
    return out;
}
static napi_value toBool(napi_env e, napi_callback_info i) {
    return scalarValue(e, i, true);
}
static napi_value toNumber(napi_env e, napi_callback_info i) {
    return scalarValue(e, i, false);
}
static napi_value textValue(napi_env env, napi_callback_info info, bool json) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Value *v = nullptr;
    if (n != 1 || !requireValue(env, a[0], &v))
        return nullptr;
    jsbay_bytes_t b = {nullptr, 0};
    jsbay_value_t x = 0;
    auto s = json ? jsbay_value_to_json(v->handle, &b, &x) : jsbay_value_to_utf8(v->handle, &b, &x);
    if (s == JSBAY_EXCEPTION)
        return takeResult(env, v->engine, s, 0, x);
    if (s != JSBAY_OK)
        return statusError(env, s);
    napi_value ab;
    void *out = nullptr;
    if (napi_create_arraybuffer(env, b.len, &out, &ab) != napi_ok) {
        jsbay_free_bytes(b);
        return makeError(env, "cannot allocate ArrayBuffer", JSBAY_OUT_OF_MEMORY);
    }
    if (b.len)
        memcpy(out, b.data, b.len);
    jsbay_free_bytes(b);
    return ab;
}
static napi_value toUtf8(napi_env e, napi_callback_info i) {
    return textValue(e, i, false);
}
static napi_value toJson(napi_env e, napi_callback_info i) {
    return textValue(e, i, true);
}
static napi_value cacheHit(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    bool hit = false;
    if (n == 1) {
        napi_value marker;
        if (napi_get_named_property(env, a[0], "cacheHit", &marker) == napi_ok)
            napi_get_value_bool(env, marker, &hit);
    }
    napi_value out;
    napi_get_boolean(env, hit, &out);
    return out;
}
static napi_value engineBool(napi_env env, napi_callback_info info, int op) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    if (n != (op == 0 ? 1u : 2u))
        return makeError(env, "Engine operation requires owner thread");
    if (!requireEngine(env, e))
        return nullptr;
    bool ok = false;
    if (op == 0)
        ok = jsbay_engine_clear_interrupt(e->id);
    else {
        uint64_t raw = 0;
        bool lossless = false;
        if (napi_get_value_bigint_uint64(env, a[1], &raw, &lossless) != napi_ok || !lossless)
            return makeError(env, "limit must be a non-negative uint64 bigint");
        ok = op == 1 ? jsbay_engine_set_execution_time_limit(e->id, raw)
                     : jsbay_engine_set_memory_limit(e->id, raw);
    }
    napi_value out;
    napi_get_boolean(env, ok, &out);
    return out;
}
static napi_value clearInterrupt(napi_env e, napi_callback_info i) {
    return engineBool(e, i, 0);
}
static napi_value setTimeLimit(napi_env e, napi_callback_info i) {
    return engineBool(e, i, 1);
}
static napi_value setMemoryLimit(napi_env e, napi_callback_info i) {
    return engineBool(e, i, 2);
}
static napi_value getMemoryUsage(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    if (n != 1 || !requireEngine(env, e))
        return nullptr;
    jsbay_memory_usage_t u;
    memset(&u, 0, sizeof(u));
    u.struct_size = (uint32_t)sizeof(u);
    if (!jsbay_engine_get_memory_usage(e->id, &u))
        return makeError(env, "getMemoryUsage failed");
    napi_value o;
    if (napi_create_object(env, &o) != napi_ok)
        return makeError(env, "cannot allocate MemoryUsage");
    auto put = [&](const char *key, uint64_t v) {
        napi_value b;
        napi_create_bigint_uint64(env, v, &b);
        napi_set_named_property(env, o, key, b);
    };
    put("mallocCount", u.malloc_count);
    put("mallocSize", u.malloc_size);
    put("mallocLimit", u.malloc_limit);
    put("memoryUsedCount", u.memory_used_count);
    put("memoryUsedSize", u.memory_used_size);
    put("atomCount", u.atom_count);
    put("atomSize", u.atom_size);
    put("objCount", u.obj_count);
    put("objSize", u.obj_size);
    put("shapeCount", u.shape_count);
    return o;
}
static napi_value runGc(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    if (n != 1 || !requireEngine(env, e))
        return nullptr;
    napi_value out;
    napi_get_boolean(env, jsbay_engine_run_gc(e->id), &out);
    return out;
}
static napi_value inspectorStart(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    uint32_t port = 0;
    if (n != 2 || !owner(e) || napi_get_value_uint32(env, a[1], &port) != napi_ok || port > 65535)
        return makeError(env, "inspectorStart requires owner Engine and port");
    uint16_t actual = 0;
    bool ok = jsbay_engine_inspector_start(e->id, (uint16_t)port, &actual);
    napi_value out;
    napi_create_uint32(env, ok ? actual : 0, &out);
    return out;
}
static napi_value inspectorStop(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    if (!owner(e))
        return makeError(env, "inspectorStop requires owner Engine");
    jsbay_engine_inspector_stop(e->id);
    return undefined(env);
}
static napi_value bind(napi_env env, napi_callback_info info) {
    size_t n = 3;
    napi_value a[3];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    std::string name;
    if (n != 3 || !owner(e) || !readUtf8(env, a[1], &name))
        return makeError(env, "bind requires owner Engine, name and function");
    napi_valuetype type;
    if (napi_typeof(env, a[2], &type) != napi_ok || type != napi_function)
        return makeError(env, "bind callback must be a function");
    auto *b = new Binding{e, nullptr};
    if (napi_create_reference(env, a[2], 1, &b->callback) != napi_ok) {
        delete b;
        return makeError(env, "cannot retain callback");
    }
    retainEngine(e);
    jsbay_value_t fn = 0, x = 0;
    jsbay_status_t s = jsbay_engine_bind(e->id, bytes(name), bridge, b, finalizeBinding, &fn, &x);
    if (s != JSBAY_OK) {
        napi_delete_reference(env, b->callback);
        releaseEngine(e);
        delete b;
    }
    return takeResult(env, e, s, fn, x);
}

static napi_value setAdmissionClass(napi_env env, napi_callback_info info) {
    size_t n = 2;
    napi_value a[2];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n >= 1 ? unwrapEngine(env, a[0]) : nullptr;
    uint32_t cls = 0;
    bool ok = false;
    if (e && !e->closed && n == 2 && napi_get_value_uint32(env, a[1], &cls) == napi_ok &&
        (cls == JSBAY_ADMISSION_FOREGROUND || cls == JSBAY_ADMISSION_BACKGROUND))
        ok = jsbay_engine_set_admission_class(e->id, static_cast<jsbay_admission_class_t>(cls));
    napi_value out;
    napi_get_boolean(env, ok, &out);
    return out;
}
static napi_value getAdmissionClass(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    jsbay_admission_class_t cls = JSBAY_ADMISSION_FOREGROUND;
    int32_t out_cls = -1;
    if (e && !e->closed && jsbay_engine_get_admission_class(e->id, &cls))
        out_cls = static_cast<int32_t>(cls);
    napi_value out;
    napi_create_int32(env, out_cls, &out);
    return out;
}
static napi_value requestInterrupt(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    Engine *e = n ? unwrapEngine(env, a[0]) : nullptr;
    bool ok = e && !e->closed && jsbay_engine_request_interrupt(e->id);
    napi_value out;
    napi_get_boolean(env, ok, &out);
    return out;
}
static napi_value requestInterruptById(napi_env env, napi_callback_info info) {
    size_t n = 1;
    napi_value a[1];
    napi_get_cb_info(env, info, &n, a, nullptr, nullptr);
    int32_t id;
    if (n != 1 || napi_get_value_int32(env, a[0], &id) != napi_ok)
        return makeError(env, "requestInterrupt requires int32 instance id");
    napi_value out;
    napi_get_boolean(env, jsbay_engine_request_interrupt(id), &out);
    return out;
}
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor p[] = {
        {"create", 0, create, 0, 0, 0, napi_default, 0},
        {"createWithLimits", 0, createWithLimits, 0, 0, 0, napi_default, 0},
        {"setResourceLimits", 0, setResourceLimits, 0, 0, 0, napi_default, 0},
        {"resourceUsage", 0, resourceUsage, 0, 0, 0, napi_default, 0},
        {"globalResourceUsage", 0, globalResourceUsage, 0, 0, 0, napi_default, 0},
        {"listEngines", 0, listEngines, 0, 0, 0, napi_default, 0},
        {"snapshotEngine", 0, snapshotEngine, 0, 0, 0, napi_default, 0},
        {"close", 0, closeEngine, 0, 0, 0, napi_default, 0},
        {"evaluate", 0, evaluate, 0, 0, 0, napi_default, 0},
        {"bind", 0, bind, 0, 0, 0, napi_default, 0},
        {"bindSync", 0, bindSync, 0, 0, 0, napi_default, 0},
        {"completeSync", 0, completeSync, 0, 0, 0, napi_default, 0},
        {"attachLoop", 0, attachLoop, 0, 0, 0, napi_default, 0},
        {"runLoopTask", 0, runLoopTask, 0, 0, 0, napi_default, 0},
        {"runLoop", 0, runLoop, 0, 0, 0, napi_default, 0},
        {"stopLoop", 0, stopLoop, 0, 0, 0, napi_default, 0},
        {"suspendLoop", 0, suspendLoop, 0, 0, 0, napi_default, 0},
        {"resumeLoop", 0, resumeLoop, 0, 0, 0, napi_default, 0},
        {"isSuspended", 0, isSuspended, 0, 0, 0, napi_default, 0},
        {"setAdmissionClass", 0, setAdmissionClass, 0, 0, 0, napi_default, 0},
        {"getAdmissionClass", 0, getAdmissionClass, 0, 0, 0, napi_default, 0},
        {"release", 0, releaseValue, 0, 0, 0, napi_default, 0},
        {"retain", 0, retainValue, 0, 0, 0, napi_default, 0},
        {"global", 0, globalValue, 0, 0, 0, napi_default, 0},
        {"get", 0, getValue, 0, 0, 0, napi_default, 0},
        {"set", 0, setValue, 0, 0, 0, napi_default, 0},
        {"call", 0, callValue, 0, 0, 0, napi_default, 0},
        {"construct", 0, constructValue, 0, 0, 0, napi_default, 0},
        {"has", 0, hasValue, 0, 0, 0, napi_default, 0},
        {"deleteKey", 0, deleteValue, 0, 0, 0, napi_default, 0},
        {"keys", 0, keysValue, 0, 0, 0, napi_default, 0},
        {"instanceOf", 0, instanceOfValue, 0, 0, 0, napi_default, 0},
        {"newString", 0, newString, 0, 0, 0, napi_default, 0},
        {"newNumber", 0, newNumber, 0, 0, 0, napi_default, 0},
        {"newBool", 0, newBool, 0, 0, 0, napi_default, 0},
        {"undefined", 0, newUndefined, 0, 0, 0, napi_default, 0},
        {"null", 0, newNull, 0, 0, 0, napi_default, 0},
        {"newJson", 0, newJson, 0, 0, 0, napi_default, 0},
        {"newError", 0, newErrorValue, 0, 0, 0, napi_default, 0},
        {"newObject", 0, newObject, 0, 0, 0, napi_default, 0},
        {"newArray", 0, newArray, 0, 0, 0, napi_default, 0},
        {"newArrayBuffer", 0, newArrayBufferValue, 0, 0, 0, napi_default, 0},
        {"copyBuffer", 0, copyBufferValue, 0, 0, 0, napi_default, 0},
        {"type", 0, typeValue, 0, 0, 0, napi_default, 0},
        {"toBool", 0, toBool, 0, 0, 0, napi_default, 0},
        {"toNumber", 0, toNumber, 0, 0, 0, napi_default, 0},
        {"toUtf8", 0, toUtf8, 0, 0, 0, napi_default, 0},
        {"toJson", 0, toJson, 0, 0, 0, napi_default, 0},
        {"cacheHit", 0, cacheHit, 0, 0, 0, napi_default, 0},
        {"requestInterrupt", 0, requestInterrupt, 0, 0, 0, napi_default, 0},
        {"requestInterruptById", 0, requestInterruptById, 0, 0, 0, napi_default, 0},
        {"clearInterrupt", 0, clearInterrupt, 0, 0, 0, napi_default, 0},
        {"setExecutionTimeLimit", 0, setTimeLimit, 0, 0, 0, napi_default, 0},
        {"setMemoryLimit", 0, setMemoryLimit, 0, 0, 0, napi_default, 0},
        {"getMemoryUsage", 0, getMemoryUsage, 0, 0, 0, napi_default, 0},
        {"runGc", 0, runGc, 0, 0, 0, napi_default, 0},
        {"inspectorStart", 0, inspectorStart, 0, 0, 0, napi_default, 0},
        {"inspectorStop", 0, inspectorStop, 0, 0, 0, napi_default, 0}};
    napi_define_properties(env, exports, sizeof(p) / sizeof(p[0]), p);
    return exports;
}
} // namespace
NAPI_MODULE(jsbay_harmony, Init)
