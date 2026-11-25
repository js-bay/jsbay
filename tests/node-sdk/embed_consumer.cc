#include <atomic>
#include <cstdio>
#include <node_api.h>
#include <thread>
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
jsbay_value_t replacement_value = 0;
int replacement_id = 0;
uint64_t replacement_generation = 0;

void cleanupReplacement(bool release_value_on_owner) {
    const jsbay_value_t value = replacement_value;
    const int id = replacement_id;
    replacement_value = 0;
    replacement_id = 0;
    replacement_generation = 0;
    if (release_value_on_owner && value)
        (void)jsbay_value_release(value);
    if (id)
        jsbay_engine_destroy(id);
}

struct GenerationDestroyRace {
    int id;
    uint64_t generation;
    std::atomic<bool> callback_entered{false};
    std::atomic<bool> destroy_started{false};
    std::atomic<int> stale_scope_status{-1};
    std::atomic<bool> replacement_created{false};
};

void noopGenerationScope(void *) {}

void generationDestroyCallback(void *opaque) {
    auto *race = static_cast<GenerationDestroyRace *>(opaque);
    race->callback_entered.store(true);
    while (!race->destroy_started.load())
        std::this_thread::yield();
    jsbay_status_t status = JSBAY_OK;
    while (status == JSBAY_OK) {
        status = jsbay_engine_with_generation_scope(race->id, race->generation, noopGenerationScope,
                                                    nullptr);
        if (status == JSBAY_OK)
            std::this_thread::yield();
    }
    race->stale_scope_status.store(status);
    jsbay_engine_destroy_generation(race->id, race->generation);
}

void destroyAndReplaceGeneration(GenerationDestroyRace *race) {
    while (!race->callback_entered.load())
        std::this_thread::yield();
    race->destroy_started.store(true);
    jsbay_engine_destroy_generation(race->id, race->generation);
    if (!jsbay_engine_create(race->id, nullptr, nullptr))
        return;
    replacement_id = race->id;
    jsbay_instance_snapshot_t snapshot{};
    snapshot.struct_size = sizeof(snapshot);
    if (!jsbay_engine_snapshot(race->id, &snapshot)) {
        jsbay_engine_destroy(race->id);
        replacement_id = 0;
        replacement_generation = 0;
        return;
    }
    replacement_generation = snapshot.generation;
    if (jsbay_value_new_number(race->id, 42, &replacement_value) == JSBAY_OK)
        race->replacement_created.store(true);
    else {
        jsbay_engine_destroy(race->id);
        replacement_id = 0;
        replacement_generation = 0;
    }
}

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
napi_value createCoreEngineBeforeEmbedded(napi_env env, napi_callback_info) {
    constexpr int32_t id = 700;
    if (!jsbay_engine_create(id, nullptr, nullptr)) {
        napi_throw_error(env, nullptr, "could not create the core engine before embedded setup");
        return nullptr;
    }
    jsbay_engine_destroy(id);
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
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
napi_value destroyAndReplace(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    int32_t id = 0;
    if (count != 1 || napi_get_value_int32(env, args[0], &id) != napi_ok) {
        napi_throw_type_error(env, nullptr, "instance id is required");
        return nullptr;
    }
    jsbay_engine_destroy(id);
    if (!jsbay_engine_create(id, nullptr, nullptr)) {
        napi_throw_error(env, nullptr, "could not recreate the C ABI engine");
        return nullptr;
    }
    replacement_id = id;
    if (jsbay_value_new_number(id, 42, &replacement_value) != JSBAY_OK) {
        jsbay_engine_destroy(id);
        replacement_id = 0;
        napi_throw_error(env, nullptr, "could not create a replacement-generation value");
        return nullptr;
    }
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}
napi_value raceDestroyAndReplace(napi_env env, napi_callback_info info) {
    size_t count = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    int32_t id = 0;
    uint64_t generation = 0;
    bool lossless = false;
    if (count != 2 || napi_get_value_int32(env, args[0], &id) != napi_ok ||
        napi_get_value_bigint_uint64(env, args[1], &generation, &lossless) != napi_ok ||
        !lossless) {
        napi_throw_type_error(env, nullptr, "instance id and generation are required");
        return nullptr;
    }
    cleanupReplacement(false);
    GenerationDestroyRace race{id, generation};
    std::thread worker;
    try {
        worker = std::thread(destroyAndReplaceGeneration, &race);
    } catch (...) {
        napi_throw_error(env, nullptr, "could not start generation replacement thread");
        return nullptr;
    }
    const jsbay_status_t scope_status =
        jsbay_engine_with_generation_scope(id, generation, generationDestroyCallback, &race);
    if (scope_status != JSBAY_OK && !race.callback_entered.load())
        race.callback_entered.store(true);
    worker.join();
    const int stale_scope_status = race.stale_scope_status.load();
    const bool replacement_created = race.replacement_created.load();
    if (scope_status != JSBAY_OK || stale_scope_status != JSBAY_INSTANCE_NOT_FOUND ||
        !replacement_created) {
        std::fprintf(stderr,
                     "generation replacement race: scope=%d stale_scope=%d replacement=%d\n",
                     scope_status, stale_scope_status, replacement_created ? 1 : 0);
    }
    napi_value result;
    napi_get_boolean(env,
                     scope_status == JSBAY_OK && stale_scope_status == JSBAY_INSTANCE_NOT_FOUND &&
                         replacement_created,
                     &result);
    return result;
}
napi_value replacementValueIsAlive(napi_env env, napi_callback_info) {
    double number = 0;
    const jsbay_status_t status =
        replacement_value ? jsbay_value_to_number(replacement_value, &number) : JSBAY_STALE_VALUE;
    const char source[] = "typeof globalThis.replacementProbe === 'undefined'";
    const char filename[] = "replacement-check.js";
    jsbay_value_t probe = 0, exception = 0;
    const jsbay_status_t probe_status = jsbay_engine_evaluate(
        replacement_id, {reinterpret_cast<const uint8_t *>(source), sizeof(source) - 1},
        {reinterpret_cast<const uint8_t *>(filename), sizeof(filename) - 1}, nullptr, &probe,
        &exception);
    bool probe_is_untouched = false;
    if (probe_status == JSBAY_OK)
        (void)jsbay_value_to_bool(probe, &probe_is_untouched);
    if (probe)
        (void)jsbay_value_release(probe);
    if (exception)
        (void)jsbay_value_release(exception);
    cleanupReplacement(true);
    napi_value result;
    napi_get_boolean(env, status == JSBAY_OK && number == 42 && probe_is_untouched, &result);
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
    napi_create_function(env, "createCoreEngineBeforeEmbedded", NAPI_AUTO_LENGTH,
                         createCoreEngineBeforeEmbedded, nullptr, &value);
    napi_set_named_property(env, exports, "createCoreEngineBeforeEmbedded", value);
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
    napi_create_function(env, "destroyAndReplace", NAPI_AUTO_LENGTH, destroyAndReplace, nullptr,
                         &value);
    napi_set_named_property(env, exports, "destroyAndReplace", value);
    napi_create_function(env, "raceDestroyAndReplace", NAPI_AUTO_LENGTH, raceDestroyAndReplace,
                         nullptr, &value);
    napi_set_named_property(env, exports, "raceDestroyAndReplace", value);
    napi_create_function(env, "replacementValueIsAlive", NAPI_AUTO_LENGTH, replacementValueIsAlive,
                         nullptr, &value);
    napi_set_named_property(env, exports, "replacementValueIsAlive", value);
    napi_create_function(
        env, "replacementGenerationIsAlive", NAPI_AUTO_LENGTH,
        [](napi_env env, napi_callback_info) -> napi_value {
            jsbay_instance_snapshot_t snapshot{};
            snapshot.struct_size = sizeof(snapshot);
            const bool alive = replacement_id && replacement_generation &&
                               jsbay_engine_snapshot(replacement_id, &snapshot) &&
                               snapshot.generation == replacement_generation;
            cleanupReplacement(false);
            napi_value result;
            napi_get_boolean(env, alive, &result);
            return result;
        },
        nullptr, &value);
    napi_set_named_property(env, exports, "replacementGenerationIsAlive", value);
    napi_create_function(
        env, "cleanupReplacement", NAPI_AUTO_LENGTH,
        [](napi_env env, napi_callback_info) -> napi_value {
            cleanupReplacement(false);
            napi_value result;
            napi_get_undefined(env, &result);
            return result;
        },
        nullptr, &value);
    napi_set_named_property(env, exports, "cleanupReplacement", value);
    napi_create_function(env, "stats", NAPI_AUTO_LENGTH, stats, nullptr, &value);
    napi_set_named_property(env, exports, "stats", value);
    return exports;
}
} // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
