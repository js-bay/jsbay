struct NodeValueState {
    Engine *engine = nullptr;
    jsbay_value_t value = 0;
    napi_ref engine_wrapper = nullptr;
    bool wrapped = false;
};

static constexpr napi_type_tag nodeValueTypeTag = {0x24af60d391fe4981ULL, 0xb51a780ce225463fULL};
static void nodeValueFinalizer(napi_env env, void *data, void *hint);
static bool initNodeValueClass(Engine *engine);
static napi_value makeNodeValue(Engine *engine, jsbay_value_t value);
static void releaseNodeValueFinalizerInScope(void *opaque) noexcept;

static napi_value transferNodeValue(Engine *engine, Value &value) {
    const jsbay_value_t owned = value.id;
    value.id = 0;
    return makeNodeValue(engine, owned);
}

static Engine *nodeValueEngineFromInfo(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value self;
    if (napi_get_cb_info(env, info, &count, nullptr, &self, nullptr) != napi_ok)
        return nullptr;
    Engine *engine = unwrap(env, self);
    return requireEngine(env, engine) ? engine : nullptr;
}

static napi_value nodeValueConstructor(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1], self;
    if (napi_get_cb_info(env, info, &count, args, &self, nullptr) != napi_ok || count != 1)
        return throwText(env, "NodeValue instances are created by Engine methods");
    napi_valuetype type;
    if (napi_typeof(env, args[0], &type) != napi_ok || type != napi_external)
        return throwText(env, "NodeValue instances are created by Engine methods");
    NodeValueState *state = nullptr;
    if (napi_get_value_external(env, args[0], reinterpret_cast<void **>(&state)) != napi_ok ||
        !state || !state->engine)
        return throwText(env, "invalid NodeValue state");
    if (napi_type_tag_object(env, self, &nodeValueTypeTag) != napi_ok ||
        napi_wrap(env, self, state, nodeValueFinalizer, nullptr, nullptr) != napi_ok)
        return throwText(env, "could not wrap NodeValue");
    state->wrapped = true;
    return self;
}

static void releaseNodeValueState(NodeValueState *state, bool release_core, bool release_refs) {
    if (!state)
        return;
    Engine *engine = state->engine;
    const jsbay_value_t value = state->value;
    state->engine = nullptr;
    state->value = 0;
    if (engine)
        engine->node_values.erase(state);
    if (release_core && engine && value)
        (void)jsbay_value_release(value);
    napi_ref engine_wrapper = state->engine_wrapper;
    state->engine_wrapper = nullptr;
    if (release_refs && engine_wrapper && engine && !engine->environment_cleaning_up)
        (void)napi_delete_reference(engine->env, engine_wrapper);
}

static void nodeValueFinalizer(napi_env, void *data, void *) {
    auto *state = static_cast<NodeValueState *>(data);
    if (!state)
        return;
    Engine *engine = state->engine;
    const bool release_core = engine && !engine->closed &&
                              engine->owner == std::this_thread::get_id() &&
                              !engine->environment_cleaning_up;
    if (release_core &&
        jsbay_engine_with_generation_scope(engine->id, engine->core_generation,
                                           releaseNodeValueFinalizerInScope, state) == JSBAY_OK) {
        delete state;
        return;
    }
    if (engine && release_core)
        requestClose(engine);
    releaseNodeValueState(state, false, true);
    delete state;
}

static void releaseNodeValueFinalizerInScope(void *opaque) noexcept {
    auto *state = static_cast<NodeValueState *>(opaque);
    Engine *engine = state->engine;
    Operation operation(engine);
    releaseNodeValueState(state, true, true);
}

static void invalidateNodeValues(Engine *engine, bool release_core) {
    if (!engine)
        return;
    const bool can_call_napi = !engine->environment_cleaning_up;
    const bool can_release_core = can_call_napi && release_core;
    while (!engine->node_values.empty()) {
        NodeValueState *state = *engine->node_values.begin();
        releaseNodeValueState(state, can_release_core, can_call_napi);
    }
    if (engine->node_value_constructor && can_call_napi)
        napi_delete_reference(engine->env, engine->node_value_constructor);
    engine->node_value_constructor = nullptr;
}

static napi_value makeNodeValue(Engine *engine, jsbay_value_t value) {
    if (!value)
        return throwStatus(engine->env, JSBAY_STALE_VALUE);
    napi_value constructor, external, instance;
    auto *state = new (std::nothrow) NodeValueState{};
    if (!state) {
        jsbay_value_release(value);
        return throwStatus(engine->env, JSBAY_OUT_OF_MEMORY);
    }
    state->engine = engine;
    state->value = value;
    napi_value engine_wrapper;
    if (!engine->wrapper || !engine->node_value_constructor ||
        napi_get_reference_value(engine->env, engine->wrapper, &engine_wrapper) != napi_ok ||
        napi_create_reference(engine->env, engine_wrapper, 1, &state->engine_wrapper) != napi_ok ||
        napi_get_reference_value(engine->env, engine->node_value_constructor, &constructor) !=
            napi_ok ||
        napi_create_external(engine->env, state, nullptr, nullptr, &external) != napi_ok) {
        releaseNodeValueState(state, true, true);
        delete state;
        return throwText(engine->env, "could not create NodeValue");
    }
    try {
        engine->node_values.insert(state);
    } catch (...) {
        releaseNodeValueState(state, true, true);
        delete state;
        return throwStatus(engine->env, JSBAY_OUT_OF_MEMORY);
    }
    if (napi_new_instance(engine->env, constructor, 1, &external, &instance) != napi_ok) {
        if (!state->wrapped) {
            releaseNodeValueState(state, true, true);
            delete state;
        }
        return nullptr;
    }
    return instance;
}

static NodeValueState *unwrapNodeValue(napi_env env, napi_value value) {
    bool tagged = false;
    if (napi_check_object_type_tag(env, value, &nodeValueTypeTag, &tagged) != napi_ok || !tagged)
        return nullptr;
    NodeValueState *state = nullptr;
    return napi_unwrap(env, value, reinterpret_cast<void **>(&state)) == napi_ok ? state : nullptr;
}

static NodeValueState *requireNodeValue(napi_env env, napi_value value) {
    NodeValueState *state = unwrapNodeValue(env, value);
    if (!state || !state->engine || !state->value) {
        throwStatus(env, JSBAY_STALE_VALUE);
        return nullptr;
    }
    Engine *engine = state->engine;
    if (!requireEngine(env, engine))
        return nullptr;
    if (!snapshotCurrentGeneration(engine)) {
        throwStatus(env, JSBAY_INSTANCE_NOT_FOUND);
        return nullptr;
    }
    return state;
}

struct NodeValueLease {
    NodeValueState *state;
    Engine *engine;
    Operation operation;
    Value retained;
    jsbay_status_t status;

    explicit NodeValueLease(NodeValueState *value)
        : state(value), engine(value->engine), operation(engine), status(JSBAY_OK) {
        status = jsbay_value_retain(value->value, &retained.id);
    }

    bool ready(napi_env env) const {
        if (status != JSBAY_OK) {
            throwStatus(env, status);
            return false;
        }
        if (engine->closed) {
            throwStatus(env, JSBAY_INSTANCE_NOT_FOUND);
            return false;
        }
        if (state->engine != engine || !state->value) {
            throwStatus(env, JSBAY_STALE_VALUE);
            return false;
        }
        if (!snapshotCurrentGeneration(engine)) {
            throwStatus(env, JSBAY_INSTANCE_NOT_FOUND);
            return false;
        }
        return true;
    }
};

static bool getNodeArgument(napi_env env, Engine *engine, napi_value input, jsbay_value_t *out,
                            Value *temporary, std::vector<napi_value> *ancestors) {
    if (NodeValueState *state = unwrapNodeValue(env, input)) {
        if (state->engine != engine || !state->value) {
            throwText(env, state->engine ? "NodeValue belongs to a different Engine"
                                         : "NodeValue is closed");
            return false;
        }
        auto status = jsbay_value_retain(state->value, &temporary->id);
        if (status != JSBAY_OK) {
            throwStatus(env, status);
            return false;
        }
        *out = temporary->id;
        return true;
    }
    jsbay_value_t exception = 0;
    auto status = nodeToValue(env, engine, input, &temporary->id, &exception, ancestors);
    if (status != JSBAY_OK) {
        napi_value error = conversionFailure(engine, status, exception);
        if (exception)
            jsbay_value_release(exception);
        if (error)
            napi_throw(env, error);
        return false;
    }
    *out = temporary->id;
    return true;
}

static napi_value engineGlobalValue(napi_env env, napi_callback_info info) {
    Engine *engine = nodeValueEngineFromInfo(env, info);
    if (!engine)
        return nullptr;
    if (!initNodeValueClass(engine))
        return throwText(env, "could not initialize NodeValue");
    Operation operation(engine);
    jsbay_value_t value = 0;
    auto status = jsbay_engine_global(engine->id, &value);
    return status == JSBAY_OK ? makeNodeValue(engine, value) : throwStatus(env, status);
}

static napi_value engineCreateNodeValue(napi_env env, napi_callback_info info, bool array) {
    Engine *engine = nodeValueEngineFromInfo(env, info);
    if (!engine)
        return nullptr;
    if (!initNodeValueClass(engine))
        return throwText(env, "could not initialize NodeValue");
    Operation operation(engine);
    jsbay_value_t value = 0;
    auto status = array ? jsbay_value_new_array(engine->id, &value)
                        : jsbay_value_new_object(engine->id, &value);
    return status == JSBAY_OK ? makeNodeValue(engine, value) : throwStatus(env, status);
}

static napi_value engineObjectValue(napi_env env, napi_callback_info info) {
    return engineCreateNodeValue(env, info, false);
}

static napi_value engineArrayValue(napi_env env, napi_callback_info info) {
    return engineCreateNodeValue(env, info, true);
}

static napi_value engineConvertNodeValue(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1];
    napi_value self;
    if (napi_get_cb_info(env, info, &count, args, &self, nullptr) != napi_ok)
        return throwText(env, "could not read Engine.value arguments");
    Engine *engine = unwrap(env, self);
    if (!requireEngine(env, engine))
        return nullptr;
    if (count != 1)
        return throwText(env, "value requires one host value");
    if (!initNodeValueClass(engine))
        return throwText(env, "could not initialize NodeValue");
    Operation operation(engine);
    if (NodeValueState *state = unwrapNodeValue(env, args[0])) {
        if (state->engine != engine || !state->value)
            return throwText(env, state->engine ? "NodeValue belongs to a different Engine"
                                                : "NodeValue is closed");
        jsbay_value_t retained = 0;
        auto status = jsbay_value_retain(state->value, &retained);
        return status == JSBAY_OK ? makeNodeValue(engine, retained) : throwStatus(env, status);
    }
    Value value;
    jsbay_value_t exception = 0;
    std::vector<napi_value> ancestors;
    auto status = nodeToValue(env, engine, args[0], &value.id, &exception, &ancestors);
    if (status != JSBAY_OK) {
        napi_value error = conversionFailure(engine, status, exception);
        if (exception)
            jsbay_value_release(exception);
        return napi_throw(env, error) == napi_ok ? nullptr : nullptr;
    }
    if (engine->closed || !snapshotCurrentGeneration(engine))
        return throwStatus(env, JSBAY_INSTANCE_NOT_FOUND);
    return transferNodeValue(engine, value);
}

static napi_value nodeValueRetain(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value self;
    napi_get_cb_info(env, info, &count, nullptr, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    jsbay_value_t value = 0;
    auto status = jsbay_value_retain(state->value, &value);
    if (status != JSBAY_OK)
        return throwStatus(env, status);
    return makeNodeValue(state->engine, value);
}

static napi_value nodeValueClose(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value self;
    napi_get_cb_info(env, info, &count, nullptr, &self, nullptr);
    NodeValueState *state = unwrapNodeValue(env, self);
    if (!state || !state->engine || !state->value)
        return undefined(env);
    Engine *engine = state->engine;
    if (!requireEngine(env, engine))
        return nullptr;
    Operation operation(engine);
    releaseNodeValueState(state, true, true);
    return undefined(env);
}

static napi_value nodeValueType(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value self;
    napi_get_cb_info(env, info, &count, nullptr, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    Operation operation(state->engine);
    jsbay_value_kind_t kind;
    auto status = jsbay_value_type(state->value, &kind);
    if (status != JSBAY_OK)
        return throwStatus(env, status);
    const char *name = nullptr;
    switch (kind) {
    case JSBAY_VALUE_UNDEFINED:
        name = "undefined";
        break;
    case JSBAY_VALUE_NULL:
        name = "null";
        break;
    case JSBAY_VALUE_BOOL:
        name = "boolean";
        break;
    case JSBAY_VALUE_NUMBER:
        name = "number";
        break;
    case JSBAY_VALUE_STRING:
        name = "string";
        break;
    case JSBAY_VALUE_OBJECT:
        name = "object";
        break;
    case JSBAY_VALUE_ARRAY:
        name = "array";
        break;
    case JSBAY_VALUE_FUNCTION:
        name = "function";
        break;
    case JSBAY_VALUE_SYMBOL:
        name = "symbol";
        break;
    case JSBAY_VALUE_BIGINT:
        name = "bigint";
        break;
    }
    napi_value result;
    return name && napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &result) == napi_ok
               ? result
               : throwText(env, "could not create NodeValue type");
}

static napi_value nodeValueToHost(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value self;
    napi_get_cb_info(env, info, &count, nullptr, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    jsbay_value_t exception = 0;
    napi_value result = nodeValue(env, state->engine, lease.retained.id, &exception);
    if (!lease.ready(env)) {
        if (exception)
            jsbay_value_release(exception);
        return nullptr;
    }
    if (!result) {
        bool pending = false;
        if (!exception && (napi_is_exception_pending(env, &pending) != napi_ok || !pending))
            return throwText(env, "could not convert JsBay value");
        napi_value error = conversionFailure(
            state->engine, exception ? JSBAY_EXCEPTION : JSBAY_INVALID_ARGUMENT, exception);
        if (exception)
            jsbay_value_release(exception);
        if (error)
            napi_throw(env, error);
        return nullptr;
    }
    if (exception)
        jsbay_value_release(exception);
    return result;
}

static napi_value nodeValueToBool(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value self;
    napi_get_cb_info(env, info, &count, nullptr, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    bool result = false;
    auto status = jsbay_value_to_bool(lease.retained.id, &result);
    if (status != JSBAY_OK)
        return throwStatus(env, status);
    napi_value out;
    return napi_get_boolean(env, result, &out) == napi_ok ? out : nullptr;
}

static napi_value nodeValueToNumber(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value self;
    napi_get_cb_info(env, info, &count, nullptr, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    double result = 0;
    auto status = jsbay_value_to_number(lease.retained.id, &result);
    if (status != JSBAY_OK)
        return throwStatus(env, status);
    napi_value out;
    return napi_create_double(env, result, &out) == napi_ok ? out : nullptr;
}

static napi_value nodeValueToString(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value self;
    napi_get_cb_info(env, info, &count, nullptr, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    jsbay_bytes_t bytes{};
    Value exception;
    auto status = jsbay_value_to_utf8(lease.retained.id, &bytes, &exception.id);
    if (status != JSBAY_OK) {
        napi_value error = conversionFailure(state->engine, status, exception.id);
        jsbay_free_bytes(bytes);
        return napi_throw(env, error) == napi_ok ? nullptr : nullptr;
    }
    if (!lease.ready(env)) {
        jsbay_free_bytes(bytes);
        return nullptr;
    }
    napi_value out = nullptr;
    if (napi_create_string_utf8(env, reinterpret_cast<const char *>(bytes.data), bytes.len, &out) !=
        napi_ok)
        out = nullptr;
    jsbay_free_bytes(bytes);
    return out;
}

static napi_value nodeValueToJson(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value self;
    napi_get_cb_info(env, info, &count, nullptr, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    jsbay_bytes_t bytes{};
    Value exception;
    auto status = jsbay_value_to_json(lease.retained.id, &bytes, &exception.id);
    if (status != JSBAY_OK) {
        napi_value error = conversionFailure(state->engine, status, exception.id);
        jsbay_free_bytes(bytes);
        return napi_throw(env, error) == napi_ok ? nullptr : nullptr;
    }
    if (!lease.ready(env)) {
        jsbay_free_bytes(bytes);
        return nullptr;
    }
    napi_value out = nullptr;
    if (napi_create_string_utf8(env, reinterpret_cast<const char *>(bytes.data), bytes.len, &out) !=
        napi_ok)
        out = nullptr;
    jsbay_free_bytes(bytes);
    return out;
}

static napi_value nodeValueCopyBuffer(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value self;
    napi_get_cb_info(env, info, &count, nullptr, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    jsbay_bytes_t bytes{};
    Value exception;
    auto status = jsbay_value_copy_buffer(lease.retained.id, &bytes, &exception.id);
    if (status != JSBAY_OK) {
        napi_value error = conversionFailure(state->engine, status, exception.id);
        jsbay_free_bytes(bytes);
        return napi_throw(env, error) == napi_ok ? nullptr : nullptr;
    }
    napi_value out = nullptr;
    void *copied = nullptr;
    if (napi_create_arraybuffer(env, bytes.len, &copied, &out) != napi_ok)
        out = nullptr;
    else if (bytes.len)
        std::memcpy(copied, bytes.data, bytes.len);
    jsbay_free_bytes(bytes);
    return out;
}

static napi_value nodeValueGet(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    std::string key;
    if (count != 1 || !string(env, args[0], &key))
        return throwText(env, "get requires a string key");
    if (!initNodeValueClass(state->engine))
        return throwText(env, "could not initialize NodeValue");
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    Value value, exception;
    auto status = jsbay_value_get(lease.retained.id, text(key), &value.id, &exception.id);
    if (status != JSBAY_OK)
        return napi_throw(env, conversionFailure(state->engine, status, exception.id)) == napi_ok
                   ? nullptr
                   : nullptr;
    if (!lease.ready(env))
        return nullptr;
    return transferNodeValue(state->engine, value);
}

static napi_value nodeValueSet(napi_env env, napi_callback_info info) {
    size_t count = 2;
    napi_value args[2], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    std::string key;
    if (count != 2 || !string(env, args[0], &key))
        return throwText(env, "set requires a string key and a value");
    Engine *engine = state->engine;
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    Value temporary, exception;
    jsbay_value_t value = 0;
    std::vector<napi_value> ancestors;
    if (!getNodeArgument(env, engine, args[1], &value, &temporary, &ancestors))
        return nullptr;
    if (!lease.ready(env))
        return nullptr;
    auto status = jsbay_value_set(lease.retained.id, text(key), value, &exception.id);
    if (status != JSBAY_OK)
        return napi_throw(env, conversionFailure(engine, status, exception.id)) == napi_ok
                   ? nullptr
                   : nullptr;
    if (!lease.ready(env))
        return nullptr;
    return self;
}

static napi_value nodeValueHas(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    std::string key;
    if (count != 1 || !string(env, args[0], &key))
        return throwText(env, "has requires a string key");
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    bool result = false;
    Value exception;
    auto status = jsbay_value_has(lease.retained.id, text(key), &result, &exception.id);
    if (status != JSBAY_OK)
        return napi_throw(env, conversionFailure(state->engine, status, exception.id)) == napi_ok
                   ? nullptr
                   : nullptr;
    if (!lease.ready(env))
        return nullptr;
    napi_value out;
    return napi_get_boolean(env, result, &out) == napi_ok ? out : nullptr;
}

static napi_value nodeValueDelete(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    std::string key;
    if (count != 1 || !string(env, args[0], &key))
        return throwText(env, "delete requires a string key");
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    bool result = false;
    Value exception;
    auto status = jsbay_value_delete(lease.retained.id, text(key), &result, &exception.id);
    if (status != JSBAY_OK)
        return napi_throw(env, conversionFailure(state->engine, status, exception.id)) == napi_ok
                   ? nullptr
                   : nullptr;
    if (!lease.ready(env))
        return nullptr;
    napi_value out;
    return napi_get_boolean(env, result, &out) == napi_ok ? out : nullptr;
}

static napi_value nodeValueKeys(napi_env env, napi_callback_info info) {
    size_t count = 0;
    napi_value self;
    napi_get_cb_info(env, info, &count, nullptr, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    if (!initNodeValueClass(state->engine))
        return throwText(env, "could not initialize NodeValue");
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    Value result, exception;
    auto status = jsbay_value_keys(lease.retained.id, &result.id, &exception.id);
    if (status != JSBAY_OK)
        return napi_throw(env, conversionFailure(state->engine, status, exception.id)) == napi_ok
                   ? nullptr
                   : nullptr;
    if (!lease.ready(env))
        return nullptr;
    return transferNodeValue(state->engine, result);
}

static napi_value nodeValueInstanceOf(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value args[1], self;
    napi_get_cb_info(env, info, &count, args, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    if (count != 1)
        return throwText(env, "instanceOf requires a constructor NodeValue");
    NodeValueState *constructor = unwrapNodeValue(env, args[0]);
    if (!constructor || constructor->engine != state->engine || !constructor->value)
        return throwText(env, "instanceOf requires a NodeValue from the same Engine");
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    Value retained_constructor;
    auto retain_status = jsbay_value_retain(constructor->value, &retained_constructor.id);
    if (retain_status != JSBAY_OK)
        return throwStatus(env, retain_status);
    bool result = false;
    Value exception;
    auto status =
        jsbay_value_instance_of(lease.retained.id, retained_constructor.id, &result, &exception.id);
    if (status != JSBAY_OK)
        return napi_throw(env, conversionFailure(state->engine, status, exception.id)) == napi_ok
                   ? nullptr
                   : nullptr;
    if (!lease.ready(env))
        return nullptr;
    napi_value out;
    return napi_get_boolean(env, result, &out) == napi_ok ? out : nullptr;
}

struct NodeValueTemporaries {
    std::vector<jsbay_value_t> values;
    ~NodeValueTemporaries() {
        for (jsbay_value_t value : values)
            jsbay_value_release(value);
    }
    bool adopt(Value &value) {
        if (!value.id)
            return true;
        try {
            values.push_back(value.id);
        } catch (...) {
            jsbay_value_release(value.id);
            value.id = 0;
            return false;
        }
        value.id = 0;
        return true;
    }
};

static napi_value nodeValueInvoke(napi_env env, napi_callback_info info, bool construct) {
    size_t count = 0;
    napi_value self;
    napi_get_cb_info(env, info, &count, nullptr, &self, nullptr);
    NodeValueState *state = requireNodeValue(env, self);
    if (!state)
        return nullptr;
    std::vector<napi_value> args;
    try {
        args.resize(count);
    } catch (...) {
        return throwStatus(env, JSBAY_OUT_OF_MEMORY);
    }
    if (count && napi_get_cb_info(env, info, &count, args.data(), &self, nullptr) != napi_ok)
        return throwText(env, "could not read NodeValue arguments");
    Engine *engine = state->engine;
    if (!initNodeValueClass(engine))
        return throwText(env, "could not initialize NodeValue");
    NodeValueLease lease(state);
    if (!lease.ready(env))
        return nullptr;
    Value result, exception;
    std::vector<jsbay_value_t> values;
    try {
        values.reserve(construct || count == 0 ? count : count - 1);
    } catch (...) {
        return throwStatus(env, JSBAY_OUT_OF_MEMORY);
    }
    NodeValueTemporaries owned;
    std::vector<napi_value> ancestors;
    jsbay_value_t receiver = 0;
    size_t first_argument = 0;
    if (!construct) {
        if (count == 0)
            return throwText(env, "call requires an explicit thisValue");
        Value *temporary = new (std::nothrow) Value{};
        if (!temporary)
            return throwStatus(env, JSBAY_OUT_OF_MEMORY);
        if (!getNodeArgument(env, engine, args[0], &receiver, temporary, &ancestors)) {
            delete temporary;
            return nullptr;
        }
        if (temporary->id) {
            if (!owned.adopt(*temporary)) {
                delete temporary;
                return throwStatus(env, JSBAY_OUT_OF_MEMORY);
            }
            delete temporary;
        } else {
            delete temporary;
        }
        if (!lease.ready(env))
            return nullptr;
        first_argument = 1;
    }
    for (size_t index = first_argument; index < count; ++index) {
        Value temporary;
        jsbay_value_t value = 0;
        if (!getNodeArgument(env, engine, args[index], &value, &temporary, &ancestors))
            return nullptr;
        if (temporary.id && !owned.adopt(temporary))
            return throwStatus(env, JSBAY_OUT_OF_MEMORY);
        if (!lease.ready(env))
            return nullptr;
        try {
            values.push_back(value);
        } catch (...) {
            return throwStatus(env, JSBAY_OUT_OF_MEMORY);
        }
    }
    if (!lease.ready(env))
        return nullptr;
    auto status = construct ? jsbay_value_construct(lease.retained.id,
                                                    values.empty() ? nullptr : values.data(),
                                                    values.size(), &result.id, &exception.id)
                            : jsbay_value_call(lease.retained.id, receiver,
                                               values.empty() ? nullptr : values.data(),
                                               values.size(), &result.id, &exception.id);
    if (status != JSBAY_OK)
        return napi_throw(env, conversionFailure(engine, status, exception.id)) == napi_ok
                   ? nullptr
                   : nullptr;
    if (!lease.ready(env))
        return nullptr;
    return transferNodeValue(engine, result);
}

static napi_value nodeValueCall(napi_env env, napi_callback_info info) {
    return nodeValueInvoke(env, info, false);
}

static napi_value nodeValueConstruct(napi_env env, napi_callback_info info) {
    return nodeValueInvoke(env, info, true);
}

struct NodeValueInvocation {
    napi_env env;
    napi_callback_info info;
    napi_value (*callback)(napi_env, napi_callback_info);
    napi_value result = nullptr;
};

static void invokeNodeValueCallback(void *opaque) noexcept {
    auto *invocation = static_cast<NodeValueInvocation *>(opaque);
    try {
        invocation->result = invocation->callback(invocation->env, invocation->info);
    } catch (...) {
        invocation->result = throwStatus(invocation->env, JSBAY_OUT_OF_MEMORY);
    }
}

template <napi_value (*Callback)(napi_env, napi_callback_info)>
static napi_value nodeValueBoundary(napi_env env, napi_callback_info info) noexcept {
    try {
        size_t count = 0;
        napi_value self = nullptr;
        if (napi_get_cb_info(env, info, &count, nullptr, &self, nullptr) != napi_ok)
            return throwText(env, "could not read NodeValue receiver");
        NodeValueState *state = unwrapNodeValue(env, self);
        if (!state || !state->engine || !state->value)
            return Callback(env, info);
        Engine *engine = state->engine;
        if (!requireEngine(env, engine))
            return nullptr;
        NodeValueInvocation invocation{env, info, Callback};
        const auto status = jsbay_engine_with_generation_scope(
            engine->id, engine->core_generation, invokeNodeValueCallback, &invocation);
        if (status == JSBAY_OK)
            return invocation.result;
        if (status == JSBAY_INSTANCE_NOT_FOUND) {
            requestClose(engine);
            if (Callback == nodeValueClose)
                return undefined(env);
        }
        return throwStatus(env, status);
    } catch (...) {
        return throwStatus(env, JSBAY_OUT_OF_MEMORY);
    }
}

static const napi_property_descriptor nodeValueMethods[] = {
    {"retain", nullptr, nodeValueBoundary<nodeValueRetain>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"close", nullptr, nodeValueBoundary<nodeValueClose>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"type", nullptr, nodeValueBoundary<nodeValueType>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"toHost", nullptr, nodeValueBoundary<nodeValueToHost>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"toBool", nullptr, nodeValueBoundary<nodeValueToBool>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"toNumber", nullptr, nodeValueBoundary<nodeValueToNumber>, nullptr, nullptr, nullptr,
     napi_default, nullptr},
    {"toString", nullptr, nodeValueBoundary<nodeValueToString>, nullptr, nullptr, nullptr,
     napi_default, nullptr},
    {"toJson", nullptr, nodeValueBoundary<nodeValueToJson>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"copyBuffer", nullptr, nodeValueBoundary<nodeValueCopyBuffer>, nullptr, nullptr, nullptr,
     napi_default, nullptr},
    {"get", nullptr, nodeValueBoundary<nodeValueGet>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"set", nullptr, nodeValueBoundary<nodeValueSet>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"call", nullptr, nodeValueBoundary<nodeValueCall>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"construct", nullptr, nodeValueBoundary<nodeValueConstruct>, nullptr, nullptr, nullptr,
     napi_default, nullptr},
    {"has", nullptr, nodeValueBoundary<nodeValueHas>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"delete", nullptr, nodeValueBoundary<nodeValueDelete>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"keys", nullptr, nodeValueBoundary<nodeValueKeys>, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"instanceOf", nullptr, nodeValueBoundary<nodeValueInstanceOf>, nullptr, nullptr, nullptr,
     napi_default, nullptr},
};

static bool initNodeValueClass(Engine *engine) {
    if (engine->node_value_constructor)
        return true;
    napi_value constructor;
    return napi_define_class(engine->env, "NodeValue", NAPI_AUTO_LENGTH, nodeValueConstructor,
                             nullptr, sizeof(nodeValueMethods) / sizeof(nodeValueMethods[0]),
                             nodeValueMethods, &constructor) == napi_ok &&
           napi_create_reference(engine->env, constructor, 1, &engine->node_value_constructor) ==
               napi_ok;
}
