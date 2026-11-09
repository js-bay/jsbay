#include <atomic>
#include <cstdio>
#include <node_api.h>
#include <utility>

#include "jsbay_node_embed.h"

namespace {
struct State {
    napi_env env = nullptr;
    napi_ref engine = nullptr;
    bool close_on_log = false;
    bool report_destroy = false;
};
std::atomic<unsigned> logs{0};
std::atomic<unsigned> destroys{0};
std::atomic<unsigned> task_enters{0};
std::atomic<unsigned> task_leaves{0};
std::atomic<unsigned> close_attempts{0};
std::atomic<unsigned> destroy_during_log{0};
std::atomic<bool> log_active{false};

void log(int, jsbay_log_level_t, const char *, void *data) {
    ++logs;
    auto *state = static_cast<State *>(data);
    if (state->close_on_log && state->engine) {
        ++close_attempts;
        state->close_on_log = false;
        napi_value engine = nullptr;
        log_active.store(true);
        if (napi_get_reference_value(state->env, state->engine, &engine) == napi_ok)
            jsbay_node_close(state->env, engine);
        log_active.store(false);
    }
}
void destroyed(void *data) {
    if (log_active.load())
        ++destroy_during_log;
    ++destroys;
    auto *state = static_cast<State *>(data);
    if (state->engine)
        napi_delete_reference(state->env, state->engine);
    if (state->report_destroy)
        std::fputs("JSBAY_NODE_EMBED_ENV_DESTROY\n", stdout);
    delete state;
}
void task(void *, bool entering) {
    if (entering)
        ++task_enters;
    else
        ++task_leaves;
}
napi_value createEngine(napi_env env, napi_callback_info info, bool close_on_log,
                        bool report_destroy = false) {
    size_t count = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    int32_t id = 0;
    if (count != 1 || napi_get_value_int32(env, args[0], &id) != napi_ok) {
        napi_throw_type_error(env, nullptr, "instance id is required");
        return nullptr;
    }
    auto *state = new State{env, nullptr, close_on_log, report_destroy};
    napi_value engine = jsbay_node_create(env, id, log, state, destroyed);
    if (!engine) {
        delete state;
        return nullptr;
    }
    if (!jsbay_node_set_task_observer(env, engine, task, state)) {
        jsbay_node_close(env, engine);
        return nullptr;
    }
    if (napi_create_reference(env, engine, 1, &state->engine) != napi_ok) {
        jsbay_node_close(env, engine);
        napi_throw_error(env, nullptr, "could not retain embedded engine");
        return nullptr;
    }
    return engine;
}
napi_value create(napi_env env, napi_callback_info info) {
    return createEngine(env, info, false, false);
}
napi_value createCloseOnLog(napi_env env, napi_callback_info info) {
    return createEngine(env, info, true, false);
}
napi_value createUnclosed(napi_env env, napi_callback_info info) {
    return createEngine(env, info, false, true);
}
napi_value rawCloseOnLog(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    int32_t id = 0;
    if (count != 1 || napi_get_value_int32(env, args[0], &id) != napi_ok) {
        napi_throw_type_error(env, nullptr, "instance id is required");
        return nullptr;
    }
    auto *state = new State{env, nullptr, true, false};
    napi_value engine = jsbay_node_create(env, id, log, state, destroyed);
    if (!engine) {
        delete state;
        return nullptr;
    }
    if (napi_create_reference(env, engine, 1, &state->engine) != napi_ok) {
        jsbay_node_close(env, engine);
        napi_throw_error(env, nullptr, "could not retain embedded engine");
        return nullptr;
    }
    const char source[] = "console.info('raw close'); 13";
    const char filename[] = "raw-close.js";
    jsbay_value_t value = 0, exception = 0;
    jsbay_engine_evaluate(id, {reinterpret_cast<const uint8_t *>(source), sizeof(source) - 1},
                          {reinterpret_cast<const uint8_t *>(filename), sizeof(filename) - 1},
                          nullptr, &value, &exception);
    if (value)
        jsbay_value_release(value);
    if (exception)
        jsbay_value_release(exception);
    napi_value output;
    napi_get_boolean(env, true, &output);
    return output;
}
napi_value tryDuplicate(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    int32_t id = 0;
    if (count != 1 || napi_get_value_int32(env, args[0], &id) != napi_ok) {
        napi_throw_type_error(env, nullptr, "instance id is required");
        return nullptr;
    }
    auto *state = new State{env, nullptr, false, false};
    napi_value engine = jsbay_node_create(env, id, log, state, destroyed);
    if (engine) {
        jsbay_node_close(env, engine);
        napi_throw_error(env, nullptr, "duplicate instance unexpectedly created");
        return nullptr;
    }
    napi_value ignored = nullptr;
    napi_get_and_clear_last_exception(env, &ignored);
    delete state;
    napi_value result;
    napi_get_boolean(env, false, &result);
    return result;
}
napi_value stats(napi_env env, napi_callback_info) {
    napi_value out, value;
    napi_create_object(env, &out);
    for (const auto &[name, counter] :
         {std::pair{"logs", &logs}, std::pair{"destroys", &destroys},
          std::pair{"taskEnters", &task_enters}, std::pair{"taskLeaves", &task_leaves},
          std::pair{"closeAttempts", &close_attempts},
          std::pair{"destroyDuringLog", &destroy_during_log}}) {
        napi_create_uint32(env, counter->load(), &value);
        napi_set_named_property(env, out, name, value);
    }
    return out;
}
napi_value init(napi_env env, napi_value exports) {
    napi_value value;
    napi_create_function(env, "create", NAPI_AUTO_LENGTH, create, nullptr, &value);
    napi_set_named_property(env, exports, "create", value);
    napi_create_function(env, "createCloseOnLog", NAPI_AUTO_LENGTH, createCloseOnLog, nullptr,
                         &value);
    napi_set_named_property(env, exports, "createCloseOnLog", value);
    napi_create_function(env, "createUnclosed", NAPI_AUTO_LENGTH, createUnclosed, nullptr, &value);
    napi_set_named_property(env, exports, "createUnclosed", value);
    napi_create_function(env, "rawCloseOnLog", NAPI_AUTO_LENGTH, rawCloseOnLog, nullptr, &value);
    napi_set_named_property(env, exports, "rawCloseOnLog", value);
    napi_create_function(env, "tryDuplicate", NAPI_AUTO_LENGTH, tryDuplicate, nullptr, &value);
    napi_set_named_property(env, exports, "tryDuplicate", value);
    napi_create_function(env, "stats", NAPI_AUTO_LENGTH, stats, nullptr, &value);
    napi_set_named_property(env, exports, "stats", value);
    return exports;
}
} // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
