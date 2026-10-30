#include "escargot_bridge.h"
#include "EscargotPublic.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

using namespace Escargot;

// Forward decls used by BridgePlatform::onLoadModule
struct EscargotContextOpaque;
static EscargotContextOpaque *lookupCtx(ContextRef *cref);

class BridgePlatform : public PlatformRef {
public:
    void markJSJobEnqueued(ContextRef *) override {}
    void markJSJobFromAnotherThreadExists(ContextRef *) override {}
    LoadModuleResult onLoadModule(ContextRef *relatedContext, ScriptRef *whereRequestFrom,
                                  StringRef *moduleSrc, ModuleType type) override;
    void didLoadModule(ContextRef *relatedContext, OptionalRef<ScriptRef> whereRequestFrom,
                       ScriptRef *loadedModule) override;
};

static BridgePlatform g_platform;
static std::once_flag g_globals_once;

static void ensureGlobals() {
    std::call_once(g_globals_once, [] {
        if (!Globals::isInitialized()) {
            Globals::initialize(&g_platform);
        }
    });
}

struct EscargotRuntimeOpaque {
    PersistentRefHolder<VMInstanceRef> vm;
};

struct EscargotContextOpaque;

struct NoCopyPack {
    EscargotBufferDeleter deleter = nullptr;
    void *user_data = nullptr;
    EscargotContextOpaque *owner = nullptr;
    bool fired = false;
    // Set when context_free finalizes the pack but BackingStore may still invoke
    // the C++ deleter later (Memory::gc is process-global). Late calls free the shell.
    bool retired = false;
};

struct EscargotContextOpaque {
    EscargotRuntimeOpaque *rt = nullptr;
    PersistentRefHolder<ContextRef> ctx;
    void *opaque = nullptr;
    std::mutex protect_mu;
    std::unordered_map<ValueRef *, std::pair<int, PersistentRefHolder<ValueRef>>> protect;
    std::string pending_throw;
    std::mutex buffers_mu;
    std::vector<NoCopyPack *> pending_buffers;
    struct PendingFinal {
        void (*fire)(void *);
        void *data;
        bool fired;
    };
    std::mutex finals_mu;
    std::vector<PendingFinal *> pending_finals;
    // ES module loader (set via escargot_install_module_loader)
    void *mod_ud = nullptr;
    EscargotModResolveFn mod_resolve = nullptr;
    EscargotModLoadFn mod_load = nullptr;
    EscargotModFreeResolvedFn mod_free_resolved = nullptr;
    // path -> cached ScriptRef (client must cache per Escargot Platform contract)
    std::vector<std::pair<std::string, PersistentRefHolder<ScriptRef>>> module_cache;

    // Host promise-rejection tracker (VMInstanceRef::registerPromiseRejectCallback).
    // Queue unhandled rejects; flush after microtask drain (process_pending_jobs).
    struct PendingRejection {
        ValueRef *promise = nullptr; // retained via protect map
        ValueRef *reason = nullptr;
    };
    std::mutex rejection_mu;
    std::vector<PendingRejection> pending_rejections;
    using RejectionTrackerFn = void (*)(int32_t, bool, const char *, size_t, void *);
    RejectionTrackerFn rejection_fn = nullptr;
    void *rejection_userdata = nullptr;
    int32_t rejection_instance_id = 0;
    bool rejection_hook_on_vm = false;
    bool flushing_rejections = false;
};


static std::mutex g_ctx_map_mu;
static std::unordered_map<ContextRef *, EscargotContextOpaque *> g_ctx_map;

static EscargotContextOpaque *lookupCtx(ContextRef *cref) {
    if (!cref) return nullptr;
    std::lock_guard<std::mutex> lock(g_ctx_map_mu);
    auto it = g_ctx_map.find(cref);
    return it == g_ctx_map.end() ? nullptr : it->second;
}

static ValueRef *asVal(EscargotValue v) { return static_cast<ValueRef *>(v); }

static EscargotValue retain(EscargotContextOpaque *c, ValueRef *v) {
    if (!v) return nullptr;
    if (!v->isStoredInHeap()) return v;
    std::lock_guard<std::mutex> lock(c->protect_mu);
    auto it = c->protect.find(v);
    if (it != c->protect.end()) {
        it->second.first += 1;
        return v;
    }
    c->protect.emplace(v, std::make_pair(1, PersistentRefHolder<ValueRef>(v)));
    return v;
}

static void release(EscargotContextOpaque *c, ValueRef *v) {
    if (!c || !v || !v->isStoredInHeap()) return;
    std::lock_guard<std::mutex> lock(c->protect_mu);
    auto it = c->protect.find(v);
    if (it == c->protect.end()) return;
    if (--it->second.first <= 0) c->protect.erase(it);
}

static char *dupCString(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, s.data(), s.size());
    out[s.size()] = 0;
    return out;
}

static char *stringRefToUtf8(StringRef *s) {
    if (!s) return dupCString("");
    return dupCString(s->toStdUTF8String());
}

static void clearPendingRejectionsLocked(EscargotContextOpaque *c) {
    for (auto &p : c->pending_rejections) {
        release(c, p.promise);
        release(c, p.reason);
    }
    c->pending_rejections.clear();
}

static void dispatchRejection(EscargotContextOpaque *c, bool handled, ValueRef *reason) {
    if (!c || !c->rejection_fn) return;
    std::string text;
    if (reason) {
        StringRef *s = reason->toStringWithoutException(c->ctx.get());
        if (s) text = s->toStdUTF8String();
    }
    c->rejection_fn(c->rejection_instance_id, handled, text.data(), text.size(), c->rejection_userdata);
}

static void onPromiseRejectCallback(ExecutionStateRef *state, PromiseObjectRef *promise, ValueRef *value,
                                    VMInstanceRef::PromiseRejectEvent event) {
    if (!state || !promise) return;
    EscargotContextOpaque *c = lookupCtx(state->context());
    if (!c) return;
    std::unique_lock<std::mutex> lock(c->rejection_mu);
    if (event == VMInstanceRef::PromiseRejectWithNoHandler) {
        ValueRef *p = static_cast<ValueRef *>(promise);
        ValueRef *r = value ? value : ValueRef::createUndefined();
        retain(c, p);
        retain(c, r);
        c->pending_rejections.push_back({p, r});
        return;
    }
    if (event == VMInstanceRef::PromiseHandlerAddedAfterReject) {
        ValueRef *p = static_cast<ValueRef *>(promise);
        for (size_t i = 0; i < c->pending_rejections.size(); ++i) {
            if (c->pending_rejections[i].promise == p) {
                release(c, c->pending_rejections[i].promise);
                release(c, c->pending_rejections[i].reason);
                c->pending_rejections.erase(c->pending_rejections.begin() + static_cast<std::ptrdiff_t>(i));
                return; // caught before flush — stay quiet
            }
        }
        EscargotContextOpaque::RejectionTrackerFn fn = c->rejection_fn;
        int32_t id = c->rejection_instance_id;
        void *ud = c->rejection_userdata;
        ValueRef *r = value ? value : ValueRef::createUndefined();
        std::string reason_text;
        if (fn) {
            StringRef *s = r->toStringWithoutException(c->ctx.get());
            if (s) reason_text = s->toStdUTF8String();
            lock.unlock();
            fn(id, true, reason_text.data(), reason_text.size(), ud);
        }
        return;
    }
}

static void flushPendingRejections(EscargotContextOpaque *c) {
    if (!c || c->flushing_rejections) return;
    c->flushing_rejections = true;
    std::vector<EscargotContextOpaque::PendingRejection> queued;
    {
        std::lock_guard<std::mutex> lock(c->rejection_mu);
        queued.swap(c->pending_rejections);
    }
    for (auto &item : queued) {
        dispatchRejection(c, false, item.reason);
        release(c, item.promise);
        release(c, item.reason);
    }
    // Drop anything queued re-entrantly during dispatch without another convert loop.
    {
        std::lock_guard<std::mutex> lock(c->rejection_mu);
        clearPendingRejectionsLocked(c);
    }
    c->flushing_rejections = false;
}

extern "C" void escargot_globals_ensure(void) { ensureGlobals(); }

extern "C" void escargot_thread_enter(void) {
    // ENABLE_THREADING: g_globalsInited is thread_local; each OS thread that touches
    // Escargot must initializeThread (Shell/cctest pattern). No-op when vendor is
    // non-threaded (supportsThreading()==false).
    if (!Globals::supportsThreading()) return;
    if (!Globals::isInitialized()) {
        Globals::initializeThread();
    }
}

extern "C" void escargot_thread_leave(void) {
    if (!Globals::supportsThreading()) return;
    if (Globals::isInitialized()) {
        Globals::finalizeThread();
    }
}

extern "C" bool escargot_supports_threading(void) {
    return Globals::supportsThreading();
}

extern "C" EscargotRuntime *escargot_runtime_new(void) {
    ensureGlobals();
    auto *rt = new EscargotRuntimeOpaque();
    rt->vm = VMInstanceRef::create();
    return rt;
}

extern "C" void escargot_runtime_free(EscargotRuntime *rt) { delete rt; }
extern "C" void escargot_runtime_gc(EscargotRuntime *rt) {
    (void)rt;
    Memory::gc();
}

extern "C" size_t escargot_runtime_heap_size(EscargotRuntime *) {
    return Memory::heapSize();
}
extern "C" size_t escargot_runtime_total_size(EscargotRuntime *) {
    return Memory::totalSize();
}

extern "C" EscargotContext *escargot_context_new(EscargotRuntime *rt) {
    if (!rt) return nullptr;
    auto *c = new EscargotContextOpaque();
    c->rt = rt;
    c->ctx = ContextRef::create(rt->vm.get());
    {
        std::lock_guard<std::mutex> lock(g_ctx_map_mu);
        g_ctx_map[c->ctx.get()] = c;
    }
    return c;
}

extern "C" void escargot_context_free(EscargotContext *ctx) {
    if (!ctx) return;
    ctx->pending_throw.clear();
    if (ctx->pending_throw_value) {
        escargot_free_value(ctx, ctx->pending_throw_value);
        ctx->pending_throw_value = nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(g_ctx_map_mu);
        g_ctx_map.erase(ctx->ctx.get());
    }
    {
        std::lock_guard<std::mutex> lock(ctx->rejection_mu);
        ctx->rejection_fn = nullptr;
        ctx->rejection_userdata = nullptr;
        clearPendingRejectionsLocked(ctx);
        if (ctx->rejection_hook_on_vm && ctx->rt && ctx->rt->vm.get()) {
            ctx->rt->vm.get()->unregisterPromiseRejectCallback();
            ctx->rejection_hook_on_vm = false;
        }
    }
    {
        std::lock_guard<std::mutex> lock(ctx->protect_mu);
        ctx->protect.clear();
    }
    // Drop PersistentRefs then GC so BackingStore deleters can run.
    Memory::gc();
    Memory::gc();
    // Force any remaining no-copy buffer finalizers (engine teardown contract).
    std::vector<NoCopyPack *> leftover;
    {
        std::lock_guard<std::mutex> lock(ctx->buffers_mu);
        leftover.swap(ctx->pending_buffers);
    }
    for (auto *pk : leftover) {
        if (!pk) continue;
        pk->owner = nullptr; // already removed from list
        if (!pk->fired) {
            pk->fired = true;
            if (pk->deleter) {
                auto d = pk->deleter;
                auto *u = pk->user_data;
                pk->deleter = nullptr;
                d(u);
            }
            // Do not delete: a later process-global GC may still invoke the
            // BackingStore deleter; fireNoCopyPack will free the retired shell.
            pk->retired = true;
        }
    }

    // Force any remaining External/weak finalizers (engine teardown contract).
    std::vector<EscargotContextOpaque::PendingFinal *> leftover_finals;
    {
        std::lock_guard<std::mutex> lock(ctx->finals_mu);
        leftover_finals.swap(ctx->pending_finals);
    }
    for (auto *pf : leftover_finals) {
        if (!pf) continue;
        if (!pf->fired) {
            pf->fired = true;
            if (pf->fire) pf->fire(pf->data);
        }
        delete pf;
    }

    delete ctx;
}

extern "C" void escargot_context_set_opaque(EscargotContext *ctx, void *opaque) {
    if (ctx) ctx->opaque = opaque;
}
extern "C" void *escargot_context_get_opaque(EscargotContext *ctx) {
    return ctx ? ctx->opaque : nullptr;
}

extern "C" EscargotEvalResult escargot_eval(EscargotContext *c, const char *src, size_t src_len,
                                            const char *filename, size_t filename_len) {
    EscargotEvalResult out{nullptr, nullptr};
    if (!c || !c->ctx.get() || !src) {
        out.err = dupCString("invalid context");
        return out;
    }
    auto source = StringRef::createFromUTF8(src, src_len);
    auto fname = StringRef::createFromUTF8(filename ? filename : "", filename_len);
    auto parsed = c->ctx.get()->scriptParser()->initializeScript(source, fname, false);
    if (!parsed.isSuccessful()) {
        out.err = stringRefToUtf8(parsed.parseErrorMessage);
        if (!out.err) out.err = dupCString("parse error");
        return out;
    }
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ScriptRef *script) -> ValueRef * {
            return script->execute(state);
        },
        parsed.script.get());
    if (!er.isSuccessful()) {
        out.err = stringRefToUtf8(er.resultOrErrorToString(c->ctx.get()));
        if (!out.err) out.err = dupCString("JavaScript error");
        // resultOrErrorToString often omits sourceURL; append for host/tests.
        if (out.err && filename && filename_len) {
            std::string msg(out.err);
            std::string url(filename, filename_len);
            if (!url.empty() && msg.find(url) == std::string::npos) {
                msg.append("\n    at ");
                msg.append(url);
                std::free(out.err);
                out.err = dupCString(msg.c_str());
            }
        }
        return out;
    }
    ValueRef *result = er.result;
    if (!result || result->isUndefined() || result->isNull()) return out;
    if (result->isObject()) {
        out.result = escargot_json_stringify(c, result);
    } else {
        out.result = escargot_value_to_utf8(c, result);
    }
    return out;
}

extern "C" void escargot_eval_result_free(EscargotEvalResult r) {
    std::free(r.result);
    std::free(r.err);
}

extern "C" EscargotValue escargot_undefined(void) { return ValueRef::createUndefined(); }
extern "C" EscargotValue escargot_null(void) { return ValueRef::createNull(); }
extern "C" EscargotValue escargot_new_bool(bool v) { return ValueRef::create(v); }
extern "C" EscargotValue escargot_new_int32(int32_t v) { return ValueRef::create((int)v); }
extern "C" EscargotValue escargot_new_float64(double v) { return ValueRef::create(v); }

extern "C" EscargotValue escargot_new_string(EscargotContext *c, const char *utf8, size_t len) {
    if (!c) return nullptr;
    return retain(c, StringRef::createFromUTF8(utf8 ? utf8 : "", len));
}

extern "C" EscargotValue escargot_new_object(EscargotContext *c) {
    if (!c) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state) -> ValueRef * { return ObjectRef::create(state); });
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}

extern "C" EscargotValue escargot_new_array(EscargotContext *c, uint32_t len) {
    if (!c) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, uint32_t n) -> ValueRef * {
            return ArrayObjectRef::create(state, (uint64_t)n);
        },
        len);
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}

extern "C" EscargotValue escargot_dup(EscargotContext *c, EscargotValue v) {
    if (!c || !v) return v;
    return retain(c, asVal(v));
}

extern "C" void escargot_free_value(EscargotContext *c, EscargotValue v) { release(c, asVal(v)); }

extern "C" bool escargot_is_undefined(EscargotValue v) { return !v || asVal(v)->isUndefined(); }
extern "C" bool escargot_is_null(EscargotValue v) { return v && asVal(v)->isNull(); }
extern "C" bool escargot_is_bool(EscargotValue v) { return v && asVal(v)->isBoolean(); }
extern "C" bool escargot_is_number(EscargotValue v) { return v && asVal(v)->isNumber(); }
extern "C" bool escargot_is_string(EscargotValue v) { return v && asVal(v)->isString(); }
extern "C" bool escargot_is_object(EscargotValue v) { return v && asVal(v)->isObject(); }
extern "C" bool escargot_is_array(EscargotContext *, EscargotValue v) {
    return v && asVal(v)->isArrayObject();
}
extern "C" bool escargot_is_function(EscargotContext *, EscargotValue v) {
    return v && (asVal(v)->isFunctionObject() || asVal(v)->isCallable());
}

extern "C" bool escargot_is_constructor(EscargotContext *, EscargotValue v) {
    if (!v || !asVal(v)->isFunctionObject()) return false;
    return asVal(v)->asFunctionObject()->isConstructor();
}

extern "C" bool escargot_to_bool(EscargotValue v) {
    return v && asVal(v)->isBoolean() && asVal(v)->asBoolean();
}
extern "C" int32_t escargot_to_int32(EscargotValue v) {
    if (!v || !asVal(v)->isNumber()) return 0;
    // ToInt32-style truncation toward zero (asInt32 may reject non-integers).
    double d = asVal(v)->asNumber();
    if (std::isnan(d) || std::isinf(d)) return 0;
    return (int32_t)d;
}
extern "C" double escargot_to_float64(EscargotValue v) {
    if (!v || !asVal(v)->isNumber()) return 0;
    return asVal(v)->asNumber();
}

extern "C" char *escargot_value_to_utf8(EscargotContext *c, EscargotValue v) {
    if (!c || !v) return nullptr;
    return stringRefToUtf8(asVal(v)->toStringWithoutException(c->ctx.get()));
}
/* Length-aware UTF-8 (preserves embedded NUL). Caller frees; *out_len is byte length excluding terminator. */
extern "C" char *escargot_value_to_utf8_n(EscargotContext *c, EscargotValue v, size_t *out_len) {
    if (out_len) *out_len = 0;
    if (!c || !v) return nullptr;
    StringRef *s = asVal(v)->toStringWithoutException(c->ctx.get());
    if (!s) return nullptr;
    std::string utf8 = s->toStdUTF8String();
    if (out_len) *out_len = utf8.size();
    return dupCString(utf8);
}

extern "C" char *escargot_json_stringify(EscargotContext *c, EscargotValue v) {
    if (!c || !v) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *val) -> ValueRef * {
            auto *JSON = state->context()->globalObject()->get(
                state, StringRef::createFromASCII("JSON"));
            auto *stringify = JSON->asObject()->get(
                state, StringRef::createFromASCII("stringify"));
            ValueRef *args[] = {val};
            return stringify->call(state, JSON, 1, args);
        },
        asVal(v));
    if (!er.isSuccessful() || !er.result || !er.result->isString()) return nullptr;
    return stringRefToUtf8(er.result->asString());
}

extern "C" EscargotValue escargot_json_parse(EscargotContext *c, const char *utf8, size_t len) {
    if (!c) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, const char *u, size_t n) -> ValueRef * {
            auto *JSON = state->context()->globalObject()->get(
                state, StringRef::createFromASCII("JSON"));
            auto *parse = JSON->asObject()->get(
                state, StringRef::createFromASCII("parse"));
            ValueRef *args[] = {StringRef::createFromUTF8(u ? u : "", n)};
            return parse->call(state, JSON, 1, args);
        },
        utf8, len);
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}

extern "C" EscargotValue escargot_get_global(EscargotContext *c) {
    if (!c) return nullptr;
    return retain(c, c->ctx.get()->globalObject());
}

extern "C" EscargotValue escargot_get_property(EscargotContext *c, EscargotValue obj, const char *key) {
    if (!c || !obj || !key) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, const char *k) -> ValueRef * {
            if (!o->isObject()) return ValueRef::createUndefined();
            return o->asObject()->get(state, StringRef::createFromUTF8(k, std::strlen(k)));
        },
        asVal(obj), key);
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}

extern "C" bool escargot_set_property(EscargotContext *c, EscargotValue obj, const char *key, EscargotValue val) {
    if (!c || !obj || !key) return false;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, const char *k, ValueRef *v) -> ValueRef * {
            if (!o->isObject()) return ValueRef::create(false);
            bool ok = o->asObject()->set(state, StringRef::createFromUTF8(k, std::strlen(k)),
                v ? v : ValueRef::createUndefined());
            return ValueRef::create(ok);
        },
        asVal(obj), key, asVal(val));
    return er.isSuccessful() && er.result && er.result->isBoolean() && er.result->asBoolean();
}

extern "C" bool escargot_has_property(EscargotContext *c, EscargotValue obj, const char *key) {
    if (!c || !obj || !key) return false;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, const char *k) -> ValueRef * {
            if (!o->isObject()) return ValueRef::create(false);
            return ValueRef::create(o->asObject()->has(state,
                StringRef::createFromUTF8(k, std::strlen(k))));
        },
        asVal(obj), key);
    return er.isSuccessful() && er.result && er.result->isBoolean() && er.result->asBoolean();
}

struct CallPack {
    ValueRef *fn;
    ValueRef *this_val;
    ValueRef **argv;
    size_t argc;
};

extern "C" EscargotValue escargot_call(EscargotContext *c, EscargotValue fn, EscargotValue this_val,
                                       const EscargotValue *args, size_t argc, char **out_err) {
    if (out_err) *out_err = nullptr;
    if (!c || !fn) {
        if (out_err) *out_err = dupCString("invalid call");
        return nullptr;
    }
    std::vector<ValueRef *> argv(argc);
    for (size_t i = 0; i < argc; i++) argv[i] = asVal(args[i]);
    CallPack pack{asVal(fn), this_val ? asVal(this_val) : nullptr, argv.data(), argc};
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, CallPack *p) -> ValueRef * {
            ValueRef *recv = p->this_val ? p->this_val : ValueRef::createUndefined();
            return p->fn->call(state, recv, p->argc, p->argv);
        },
        &pack);
    if (!er.isSuccessful()) {
        if (out_err) *out_err = stringRefToUtf8(er.resultOrErrorToString(c->ctx.get()));
        return nullptr;
    }
    return retain(c, er.result);
}

extern "C" void escargot_process_pending_jobs(EscargotContext *c) {
    if (!c || !c->rt || !c->rt->vm.get()) return;
    auto *vm = c->rt->vm.get();
    while (vm->hasPendingJob()) {
        (void)vm->executePendingJob();
    }
    flushPendingRejections(c);
}

extern "C" void escargot_set_rejection_tracker(EscargotContext *c, int32_t instance_id,
                                              void (*fn)(int32_t, bool, const char *, size_t, void *),
                                              void *userdata) {
    if (!c) return;
    std::lock_guard<std::mutex> lock(c->rejection_mu);
    if (!fn) {
        c->rejection_fn = nullptr;
        c->rejection_userdata = nullptr;
        c->rejection_instance_id = 0;
        clearPendingRejectionsLocked(c);
        return;
    }
    c->rejection_fn = fn;
    c->rejection_userdata = userdata;
    c->rejection_instance_id = instance_id;
    if (!c->rejection_hook_on_vm && c->rt && c->rt->vm.get()) {
        c->rt->vm.get()->registerPromiseRejectCallback(&onPromiseRejectCallback);
        c->rejection_hook_on_vm = true;
    }
}


static EscargotContextOpaque *contextFromRef(ContextRef *cref) {
    if (!cref) return nullptr;
    std::lock_guard<std::mutex> lock(g_ctx_map_mu);
    auto it = g_ctx_map.find(cref);
    return it == g_ctx_map.end() ? nullptr : it->second;
}

extern "C" EscargotValueResult escargot_eval_value(EscargotContext *c, const char *src, size_t src_len,
                                                   const char *filename, size_t filename_len) {
    EscargotValueResult out{nullptr, nullptr};
    if (!c || !c->ctx.get() || !src) {
        out.err = dupCString("invalid context");
        return out;
    }
    auto source = StringRef::createFromUTF8(src, src_len);
    auto fname = StringRef::createFromUTF8(filename ? filename : "", filename_len);
    auto parsed = c->ctx.get()->scriptParser()->initializeScript(source, fname, false);
    if (!parsed.isSuccessful()) {
        out.err = stringRefToUtf8(parsed.parseErrorMessage);
        if (!out.err) out.err = dupCString("parse error");
        return out;
    }
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ScriptRef *script) -> ValueRef * {
            return script->execute(state);
        },
        parsed.script.get());
    if (!er.isSuccessful()) {
        // Retain the thrown value when possible; also surface string form.
        if (er.error) {
            out.value = retain(c, er.error.value());
        }
        out.err = stringRefToUtf8(er.resultOrErrorToString(c->ctx.get()));
        if (!out.err) out.err = dupCString("JavaScript error");
        return out;
    }
    out.value = retain(c, er.result);
    return out;
}

extern "C" void escargot_value_result_free_err(EscargotValueResult r) {
    if (r.err) std::free(r.err);
}

extern "C" EscargotValue escargot_get_index(EscargotContext *c, EscargotValue obj, uint32_t index) {
    if (!c || !obj) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, uint32_t i) -> ValueRef * {
            if (!o->isObject()) return ValueRef::createUndefined();
            return o->asObject()->getIndexedProperty(state, ValueRef::create(i));
        },
        asVal(obj), index);
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}

extern "C" bool escargot_set_index(EscargotContext *c, EscargotValue obj, uint32_t index, EscargotValue val) {
    if (!c || !obj) return false;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, uint32_t i, ValueRef *v) -> ValueRef * {
            if (!o->isObject()) return ValueRef::create(false);
            bool ok = o->asObject()->setIndexedProperty(state, ValueRef::create(i), v ? v : ValueRef::createUndefined());
            return ValueRef::create(ok);
        },
        asVal(obj), index, asVal(val));
    return er.isSuccessful() && er.result && er.result->isBoolean() && er.result->asBoolean();
}

extern "C" bool escargot_set_length(EscargotContext *c, EscargotValue obj, uint32_t length) {
    if (!c || !obj) return false;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, uint32_t len) -> ValueRef * {
            if (!o->isObject()) return ValueRef::create(false);
            bool ok = o->asObject()->set(state, StringRef::createFromASCII("length"), ValueRef::create((double)len));
            return ValueRef::create(ok);
        },
        asVal(obj), length);
    return er.isSuccessful() && er.result && er.result->isBoolean() && er.result->asBoolean();
}

extern "C" bool escargot_define_data_property(EscargotContext *c, EscargotValue obj, const char *key,
                                             EscargotValue val, bool writable) {
    if (!c || !obj || !key) return false;
    // Reject embedded NUL in key (C strlen contract).
    size_t key_len = strlen(key);
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, const char *k, size_t klen, ValueRef *v, bool w) -> ValueRef * {
            if (!o->isObject()) return ValueRef::create(false);
            auto name = StringRef::createFromUTF8(k, klen);
            bool ok = o->asObject()->defineDataProperty(state, name, v ? v : ValueRef::createUndefined(), w, true, true);
            return ValueRef::create(ok);
        },
        asVal(obj), key, key_len, asVal(val), writable);
    return er.isSuccessful() && er.result && er.result->isBoolean() && er.result->asBoolean();
}

extern "C" EscargotValue escargot_new_symbol(EscargotContext *c, const char *desc, size_t desc_len) {
    if (!c) return nullptr;
    OptionalRef<StringRef> d;
    if (desc && desc_len > 0) d = StringRef::createFromUTF8(desc, desc_len);
    else if (desc) d = StringRef::createFromUTF8(desc, strlen(desc));
    SymbolRef *sym = SymbolRef::create(d);
    return retain(c, sym);
}

extern "C" EscargotValue escargot_symbol_for(EscargotContext *c, const char *key, size_t key_len) {
    if (!c || !c->rt || !c->rt->vm.get()) return nullptr;
    StringRef *k = StringRef::createFromUTF8(key ? key : "", key ? (key_len ? key_len : strlen(key)) : 0);
    SymbolRef *sym = SymbolRef::fromGlobalSymbolRegistry(c->rt->vm.get(), k);
    return retain(c, sym);
}

extern "C" bool escargot_strict_equal(EscargotContext *c, EscargotValue a, EscargotValue b) {
    if (!c) return a == b;
    // undefined/null/immediates: equalsTo still needs an ExecutionState
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *lhs, ValueRef *rhs) -> ValueRef * {
            ValueRef *l = lhs ? lhs : ValueRef::createUndefined();
            ValueRef *r = rhs ? rhs : ValueRef::createUndefined();
            return ValueRef::create(l->equalsTo(state, r));
        },
        asVal(a), asVal(b));
    return er.isSuccessful() && er.result && er.result->isBoolean() && er.result->asBoolean();
}

extern "C" uint32_t escargot_get_length(EscargotContext *c, EscargotValue obj) {
    if (!c || !obj) return 0;
    // Primitives: String has a length (UTF-16 code units), matching QuickJS/JSC getLength.
    if (asVal(obj)->isString()) {
        return (uint32_t)asVal(obj)->asString()->length();
    }
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o) -> ValueRef * {
            if (!o->isObject()) return ValueRef::create(0u);
            ValueRef *len = o->asObject()->get(state, StringRef::createFromASCII("length"));
            if (!len || !len->isNumber()) return ValueRef::create(0u);
            double d = len->asNumber();
            if (d < 0) d = 0;
            if (d > 0xffffffffu) d = 0xffffffffu;
            return ValueRef::create((uint32_t)d);
        },
        asVal(obj));
    if (!er.isSuccessful() || !er.result || !er.result->isNumber()) return 0;
    return er.result->asUInt32();
}

extern "C" bool escargot_is_date(EscargotContext *c, EscargotValue v) {
    (void)c;
    return v && asVal(v)->isDateObject();
}
extern "C" int64_t escargot_date_to_ms(EscargotContext *c, EscargotValue v) {
    if (!c || !v || !asVal(v)->isDateObject()) return 0;
    return (int64_t)asVal(v)->asDateObject()->primitiveValue();
}
extern "C" EscargotValue escargot_new_date(EscargotContext *c, int64_t ms) {
    if (!c) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, int64_t t) -> ValueRef * {
            auto *d = DateObjectRef::create(state);
            d->setTimeValue(t);
            return d;
        },
        ms);
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}

extern "C" bool escargot_is_bigint(EscargotValue v) {
    return v && asVal(v)->isBigInt();
}
extern "C" EscargotValue escargot_new_bigint_i64(int64_t v) {
    return BigIntRef::create(v);
}
extern "C" EscargotValue escargot_new_bigint_u64(uint64_t v) {
    return BigIntRef::create(v);
}
extern "C" bool escargot_bigint_to_i64(EscargotValue v, int64_t *out) {
    if (!v || !asVal(v)->isBigInt() || !out) return false;
    *out = asVal(v)->asBigInt()->toInt64();
    return true;
}
extern "C" bool escargot_bigint_to_u64(EscargotValue v, uint64_t *out) {
    if (!v || !asVal(v)->isBigInt() || !out) return false;
    *out = asVal(v)->asBigInt()->toUint64();
    return true;
}

extern "C" bool escargot_is_map(EscargotValue v) { return v && asVal(v)->isMapObject(); }
extern "C" bool escargot_is_set(EscargotValue v) { return v && asVal(v)->isSetObject(); }

extern "C" EscargotValue escargot_new_map(EscargotContext *c) {
    if (!c) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state) -> ValueRef * { return MapObjectRef::create(state); });
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}
extern "C" EscargotValue escargot_new_set(EscargotContext *c) {
    if (!c) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state) -> ValueRef * { return SetObjectRef::create(state); });
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}
extern "C" bool escargot_map_set(EscargotContext *c, EscargotValue map, EscargotValue key, EscargotValue val) {
    if (!c || !map || !asVal(map)->isMapObject()) return false;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *m, ValueRef *k, ValueRef *v) -> ValueRef * {
            m->asMapObject()->set(state, k, v ? v : ValueRef::createUndefined());
            return ValueRef::create(true);
        },
        asVal(map), asVal(key), asVal(val));
    return er.isSuccessful();
}
extern "C" bool escargot_set_add(EscargotContext *c, EscargotValue set, EscargotValue val) {
    if (!c || !set || !asVal(set)->isSetObject()) return false;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *s, ValueRef *v) -> ValueRef * {
            s->asSetObject()->add(state, v ? v : ValueRef::createUndefined());
            return ValueRef::create(true);
        },
        asVal(set), asVal(val));
    return er.isSuccessful();
}
extern "C" size_t escargot_map_size(EscargotContext *c, EscargotValue map) {
    if (!c || !map || !asVal(map)->isMapObject()) return 0;
    size_t out = 0;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *m, size_t *o) -> ValueRef * {
            *o = m->asMapObject()->size(state);
            return ValueRef::createUndefined();
        },
        asVal(map), &out);
    return er.isSuccessful() ? out : 0;
}
extern "C" size_t escargot_set_size(EscargotContext *c, EscargotValue set) {
    if (!c || !set || !asVal(set)->isSetObject()) return 0;
    size_t out = 0;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *s, size_t *o) -> ValueRef * {
            *o = s->asSetObject()->size(state);
            return ValueRef::createUndefined();
        },
        asVal(set), &out);
    return er.isSuccessful() ? out : 0;
}

// Map/Set JSON via JS helpers (keys that are not JSON-friendly).
static char *evalToUtf8(EscargotContext *c, const char *src) {
    auto r = escargot_eval(c, src, std::strlen(src), "<bridge>", 7);
    char *out = r.result;
    if (r.err) std::free(r.err);
    return out;
}

extern "C" char *escargot_map_to_json(EscargotContext *c, EscargotValue map) {
    if (!c || !map) return nullptr;
    // Stash map on a temp global slot, stringify, clear.
    ValueRef *g = c->ctx.get()->globalObject();
    Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *glob, ValueRef *m) -> ValueRef * {
            glob->asObject()->set(state, StringRef::createFromASCII("__jsbay_tmp_map"), m);
            return ValueRef::createUndefined();
        },
        g, asVal(map));
    char *json = evalToUtf8(c,
        "JSON.stringify(Array.from(__jsbay_tmp_map.entries()))");
    Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *glob) -> ValueRef * {
            glob->asObject()->set(state, StringRef::createFromASCII("__jsbay_tmp_map"),
                                  ValueRef::createUndefined());
            return ValueRef::createUndefined();
        },
        g);
    return json;
}
extern "C" char *escargot_set_to_json(EscargotContext *c, EscargotValue set) {
    if (!c || !set) return nullptr;
    ValueRef *g = c->ctx.get()->globalObject();
    Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *glob, ValueRef *s) -> ValueRef * {
            glob->asObject()->set(state, StringRef::createFromASCII("__jsbay_tmp_set"), s);
            return ValueRef::createUndefined();
        },
        g, asVal(set));
    char *json = evalToUtf8(c, "JSON.stringify(Array.from(__jsbay_tmp_set.values()))");
    Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *glob) -> ValueRef * {
            glob->asObject()->set(state, StringRef::createFromASCII("__jsbay_tmp_set"),
                                  ValueRef::createUndefined());
            return ValueRef::createUndefined();
        },
        g);
    return json;
}
extern "C" EscargotValue escargot_new_map_from_json(EscargotContext *c, const char *json, size_t len) {
    if (!c || !json) return nullptr;
    // Assign JSON text then build Map
    auto parsed = escargot_json_parse(c, json, len);
    if (!parsed) return nullptr;
    ValueRef *g = c->ctx.get()->globalObject();
    Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *glob, ValueRef *arr) -> ValueRef * {
            glob->asObject()->set(state, StringRef::createFromASCII("__jsbay_tmp_arr"), arr);
            return ValueRef::createUndefined();
        },
        g, asVal(parsed));
    release(c, asVal(parsed));
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state) -> ValueRef * {
            // new Map(__jsbay_tmp_arr)
            auto *MapCtor = state->context()->globalObject()->get(
                state, StringRef::createFromASCII("Map"));
            ValueRef *arr = state->context()->globalObject()->get(
                state, StringRef::createFromASCII("__jsbay_tmp_arr"));
            ValueRef *args[] = {arr};
            return MapCtor->construct(state, 1, args);
        });
    Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *glob) -> ValueRef * {
            glob->asObject()->set(state, StringRef::createFromASCII("__jsbay_tmp_arr"),
                                  ValueRef::createUndefined());
            return ValueRef::createUndefined();
        },
        g);
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}
extern "C" EscargotValue escargot_new_set_from_json(EscargotContext *c, const char *json, size_t len) {
    if (!c || !json) return nullptr;
    auto parsed = escargot_json_parse(c, json, len);
    if (!parsed) return nullptr;
    ValueRef *g = c->ctx.get()->globalObject();
    Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *glob, ValueRef *arr) -> ValueRef * {
            glob->asObject()->set(state, StringRef::createFromASCII("__jsbay_tmp_arr"), arr);
            return ValueRef::createUndefined();
        },
        g, asVal(parsed));
    release(c, asVal(parsed));
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state) -> ValueRef * {
            auto *SetCtor = state->context()->globalObject()->get(
                state, StringRef::createFromASCII("Set"));
            ValueRef *arr = state->context()->globalObject()->get(
                state, StringRef::createFromASCII("__jsbay_tmp_arr"));
            ValueRef *args[] = {arr};
            return SetCtor->construct(state, 1, args);
        });
    Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *glob) -> ValueRef * {
            glob->asObject()->set(state, StringRef::createFromASCII("__jsbay_tmp_arr"),
                                  ValueRef::createUndefined());
            return ValueRef::createUndefined();
        },
        g);
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}

extern "C" bool escargot_map_foreach(EscargotContext *c, EscargotValue map, void *cb_ctx, EscargotMapForEachFn cb) {
    if (!c || !map || !cb || !asVal(map)->isMapObject()) return false;
    // Use JS forEach to drive iteration; install a native callback via make_function would recurse.
    // Instead: dump entries array and iterate in C++.
    char *json = escargot_map_to_json(c, map);
    if (!json) return false;
    auto arr = escargot_json_parse(c, json, std::strlen(json));
    std::free(json);
    if (!arr) return false;
    uint32_t n = escargot_get_length(c, arr);
    bool ok = true;
    for (uint32_t i = 0; i < n; i++) {
        auto pair = escargot_get_index(c, arr, i);
        if (!pair) { ok = false; break; }
        auto key = escargot_get_index(c, pair, 0);
        auto val = escargot_get_index(c, pair, 1);
        escargot_free_value(c, pair);
        if (!cb(c, cb_ctx, key, val)) {
            if (key) escargot_free_value(c, key);
            if (val) escargot_free_value(c, val);
            ok = false;
            break;
        }
        if (key) escargot_free_value(c, key);
        if (val) escargot_free_value(c, val);
    }
    escargot_free_value(c, arr);
    return ok;
}
extern "C" bool escargot_set_foreach(EscargotContext *c, EscargotValue set, void *cb_ctx, EscargotSetForEachFn cb) {
    if (!c || !set || !cb || !asVal(set)->isSetObject()) return false;
    char *json = escargot_set_to_json(c, set);
    if (!json) return false;
    auto arr = escargot_json_parse(c, json, std::strlen(json));
    std::free(json);
    if (!arr) return false;
    uint32_t n = escargot_get_length(c, arr);
    bool ok = true;
    for (uint32_t i = 0; i < n; i++) {
        auto val = escargot_get_index(c, arr, i);
        if (!cb(c, cb_ctx, val)) {
            if (val) escargot_free_value(c, val);
            ok = false;
            break;
        }
        if (val) escargot_free_value(c, val);
    }
    escargot_free_value(c, arr);
    return ok;
}

extern "C" bool escargot_is_array_buffer(EscargotValue v) {
    return v && asVal(v)->isArrayBufferObject();
}
extern "C" bool escargot_is_typed_array(EscargotValue v) {
    return v && asVal(v)->isTypedArrayObject();
}
extern "C" bool escargot_is_data_view(EscargotValue v) {
    return v && asVal(v)->isDataViewObject();
}

extern "C" EscargotValue escargot_new_array_buffer_copy(EscargotContext *c, const uint8_t *bytes, size_t len) {
    if (!c) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, const uint8_t *b, size_t n) -> ValueRef * {
            auto *ab = ArrayBufferObjectRef::create(state);
            ab->allocateBuffer(state, n);
            if (b && n) std::memcpy(ab->rawBuffer(), b, n);
            return ab;
        },
        bytes, len);
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}

static void fireNoCopyPack(NoCopyPack *pk) {
    if (!pk) return;
    if (pk->fired) {
        // Context teardown already ran the user deleter; BackingStore is late.
        if (pk->retired) delete pk;
        return;
    }
    pk->fired = true;
    EscargotContextOpaque *owner = pk->owner;
    pk->owner = nullptr;
    if (owner) {
        std::lock_guard<std::mutex> lock(owner->buffers_mu);
        auto &vec = owner->pending_buffers;
        vec.erase(std::remove(vec.begin(), vec.end(), pk), vec.end());
    }
    if (pk->deleter) {
        auto d = pk->deleter;
        auto *u = pk->user_data;
        pk->deleter = nullptr;
        d(u);
    }
    delete pk;
}

extern "C" EscargotValue escargot_new_array_buffer_no_copy(EscargotContext *c, uint8_t *bytes, size_t len,
                                                           EscargotBufferDeleter deleter, void *user_data) {
    if (!c || !bytes) return nullptr;
    auto *pack = new NoCopyPack{deleter, user_data, c, false};
    {
        std::lock_guard<std::mutex> lock(c->buffers_mu);
        c->pending_buffers.push_back(pack);
    }
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, uint8_t *b, size_t n, NoCopyPack *p) -> ValueRef * {
            auto *store = BackingStoreRef::createNonSharedBackingStore(
                b, n,
                [](void *data, size_t length, void *deleterData) {
                    (void)data; (void)length;
                    fireNoCopyPack(static_cast<NoCopyPack *>(deleterData));
                },
                p);
            auto *ab = ArrayBufferObjectRef::create(state);
            ab->attachBuffer(store);
            return ab;
        },
        bytes, len, pack);
    if (!er.isSuccessful()) {
        fireNoCopyPack(pack);
        return nullptr;
    }
    return retain(c, er.result);
}

extern "C" uint8_t *escargot_array_buffer_data(EscargotContext *c, EscargotValue ab, size_t *out_len) {
    (void)c;
    if (!ab || !asVal(ab)->isArrayBufferObject()) return nullptr;
    auto *buf = asVal(ab)->asArrayBufferObject();
    if (out_len) *out_len = buf->byteLength();
    return buf->rawBuffer();
}

static EscargotValue makeTypedArray(EscargotContext *c, EscargotValue ab, int kind, size_t byte_offset, size_t length) {
    if (!c || !ab || !asVal(ab)->isArrayBufferObject()) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *buffer, int k, size_t off, size_t len) -> ValueRef * {
            ArrayBufferViewRef *view = nullptr;
            switch (k) {
            case 0: view = Int8ArrayObjectRef::create(state); break;
            case 1: view = Uint8ArrayObjectRef::create(state); break;
            case 2: view = Uint8ClampedArrayObjectRef::create(state); break;
            case 3: view = Int16ArrayObjectRef::create(state); break;
            case 4: view = Uint16ArrayObjectRef::create(state); break;
            case 5: view = Int32ArrayObjectRef::create(state); break;
            case 6: view = Uint32ArrayObjectRef::create(state); break;
            case 7: view = Float32ArrayObjectRef::create(state); break;
            case 8: view = Float64ArrayObjectRef::create(state); break;
            case 9: view = BigInt64ArrayObjectRef::create(state); break;
            case 10: view = BigUint64ArrayObjectRef::create(state); break;
            default: return ValueRef::createUndefined();
            }
            size_t elem = 1;
            switch (k) {
            case 3: case 4: elem = 2; break;
            case 5: case 6: case 7: elem = 4; break;
            case 8: case 9: case 10: elem = 8; break;
            default: elem = 1; break;
            }
            size_t byteLen = len * elem;
            view->setBuffer(buffer->asArrayBufferObject(), off, byteLen, len);
            return view;
        },
        asVal(ab), kind, byte_offset, length);
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}

extern "C" EscargotValue escargot_new_typed_array(EscargotContext *c, EscargotValue ab, int kind,
                                                   size_t byte_offset, size_t length) {
    return makeTypedArray(c, ab, kind, byte_offset, length);
}

static int typedArrayKind(ValueRef *v) {
    if (v->isInt8ArrayObject()) return 0;
    if (v->isUint8ArrayObject()) return 1;
    if (v->isUint8ClampedArrayObject()) return 2;
    if (v->isInt16ArrayObject()) return 3;
    if (v->isUint16ArrayObject()) return 4;
    if (v->isInt32ArrayObject()) return 5;
    if (v->isUint32ArrayObject()) return 6;
    if (v->isFloat32ArrayObject()) return 7;
    if (v->isFloat64ArrayObject()) return 8;
    if (v->isBigInt64ArrayObject()) return 9;
    if (v->isBigUint64ArrayObject()) return 10;
    return -1;
}

extern "C" uint8_t *escargot_typed_array_data(EscargotContext *c, EscargotValue ta, size_t *byte_offset,
                                               size_t *byte_length, int *kind) {
    (void)c;
    if (!ta || !asVal(ta)->isTypedArrayObject()) return nullptr;
    auto *view = asVal(ta)->asArrayBufferView();
    if (byte_offset) *byte_offset = view->byteOffset();
    if (byte_length) *byte_length = view->byteLength();
    if (kind) *kind = typedArrayKind(asVal(ta));
    return view->rawBuffer();
}

extern "C" EscargotValue escargot_new_data_view(EscargotContext *c, EscargotValue ab, size_t byte_offset, size_t byte_length) {
    if (!c || !ab || !asVal(ab)->isArrayBufferObject()) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *buffer, size_t off, size_t len) -> ValueRef * {
            auto *dv = DataViewObjectRef::create(state);
            dv->setBuffer(buffer->asArrayBufferObject(), off, len);
            return dv;
        },
        asVal(ab), byte_offset, byte_length);
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}
extern "C" uint8_t *escargot_data_view_data(EscargotContext *c, EscargotValue dv, size_t *byte_offset, size_t *byte_length) {
    (void)c;
    if (!dv || !asVal(dv)->isDataViewObject()) return nullptr;
    auto *view = asVal(dv)->asArrayBufferView();
    auto *buf = view->buffer();
    if (!buf) return nullptr;
    // Detached: ArrayBufferObjectRef only. Match QuickJS dataViewInfo→null.
    if (asVal((EscargotValue)buf)->isArrayBufferObject() &&
        asVal((EscargotValue)buf)->asArrayBufferObject()->isDetachedBuffer()) {
        return nullptr;
    }
    uint8_t *base = buf->rawBuffer();
    size_t ab_len = buf->byteLength();
    size_t off = view->byteOffset();
    size_t len = view->byteLength();
    uint8_t *p = view->rawBuffer(); // view-relative
    // Escargot OOB-after-resize zeros view offset/length and clears view rawBuffer while
    // the backing store may still be live (m_wasResetByInvalidByteLength). That must not
    // look like a legitimate empty DataView (which keeps a non-null view pointer into the
    // buffer, or is the empty-on-empty-AB case). Match QuickJS → null / INVALID copy.
    if (!p) {
        if (len == 0 && off == 0 && ab_len == 0 && !base) {
            if (byte_offset) *byte_offset = 0;
            if (byte_length) *byte_length = 0;
            static uint8_t empty_dv_sentinel;
            return &empty_dv_sentinel;
        }
        return nullptr;
    }
    if (off > ab_len || len > ab_len - off) return nullptr;
    if (byte_offset) *byte_offset = off;
    if (byte_length) *byte_length = len;
    return p;
}

struct NativeFnData {
    EscargotNativeFn fn;
    void *user_data;
    EscargotContextOpaque *ctx;
};

static ValueRef *nativeTrampoline(ExecutionStateRef *state, ValueRef *thisValue,
                                  size_t argc, ValueRef **argv, bool isConstructorCall) {
    (void)isConstructorCall;
    auto callee = state->resolveCallee();
    if (!callee) return ValueRef::createUndefined();
    auto *data = static_cast<NativeFnData *>(callee->extraData());
    if (!data || !data->fn || !data->ctx) return ValueRef::createUndefined();
    std::vector<EscargotValue> args(argc);
    for (size_t i = 0; i < argc; i++) args[i] = argv[i];
    data->ctx->pending_throw.clear();
    if (data->ctx->pending_throw_value) {
        // Drop any stale retained exception before the callback.
        escargot_free_value(data->ctx, data->ctx->pending_throw_value);
        data->ctx->pending_throw_value = nullptr;
    }
    EscargotValue result = data->fn(data->ctx, thisValue, args.data(), argc, data->user_data);
    if (data->ctx->pending_throw_value) {
        ValueRef *exc = asVal(data->ctx->pending_throw_value);
        data->ctx->pending_throw_value = nullptr;
        data->ctx->pending_throw.clear();
        if (result) escargot_free_value(data->ctx, result);
        state->throwException(exc);
        return ValueRef::createUndefined();
    }
    if (!data->ctx->pending_throw.empty()) {
        std::string msg = data->ctx->pending_throw;
        data->ctx->pending_throw.clear();
        if (result) escargot_free_value(data->ctx, result);
        state->throwException(ErrorObjectRef::create(state, ErrorObjectRef::Code::TypeError,
            StringRef::createFromUTF8(msg.data(), msg.size())));
        return ValueRef::createUndefined();
    }
    return result ? asVal(result) : ValueRef::createUndefined();
}

extern "C" EscargotValue escargot_make_function(EscargotContext *c, const char *name, EscargotNativeFn fn, void *user_data) {
    if (!c || !fn) return nullptr;
    auto *ndata = new NativeFnData{fn, user_data, c};
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, const char *n, NativeFnData *d) -> ValueRef * {
            AtomicStringRef *an = AtomicStringRef::create(state->context(), n ? n : "", n ? std::strlen(n) : 0);
            FunctionObjectRef::NativeFunctionInfo info(an, nativeTrampoline, 0, true, false);
            auto *f = FunctionObjectRef::create(state, info);
            f->setExtraData(d);
            return f;
        },
        name, ndata);
    if (!er.isSuccessful()) {
        delete ndata;
        return nullptr;
    }
    return retain(c, er.result);
}

extern "C" void escargot_throw_value(EscargotContext *c, EscargotValue exception) {
    if (!c) return;
    c->pending_throw.clear();
    if (c->pending_throw_value) {
        escargot_free_value(c, c->pending_throw_value);
        c->pending_throw_value = nullptr;
    }
    // Caller transferred ownership of the handle.
    c->pending_throw_value = exception;
    if (!exception) c->pending_throw = "Error";
}

extern "C" void escargot_throw(EscargotContext *c, const char *message) {
    // Do not throw across Evaluator here — that would be caught. Record pending for trampoline.
    if (!c) return;
    if (c->pending_throw_value) {
        escargot_free_value(c, c->pending_throw_value);
        c->pending_throw_value = nullptr;
    }
    c->pending_throw = message ? message : "Error";
}

extern "C" EscargotAtom escargot_atom_new(EscargotContext *c, const char *utf8, size_t len) {
    if (!c || !utf8) return nullptr;
    return AtomicStringRef::create(c->ctx.get(), utf8, len);
}
extern "C" void escargot_atom_free(EscargotAtom) {}
extern "C" char *escargot_atom_to_utf8(EscargotContext *c, EscargotAtom atom) {
    (void)c;
    if (!atom) return nullptr;
    return stringRefToUtf8(static_cast<AtomicStringRef *>(atom)->string());
}
extern "C" EscargotValue escargot_get_property_atom(EscargotContext *c, EscargotValue obj, EscargotAtom atom) {
    if (!c || !obj || !atom) return nullptr;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, AtomicStringRef *a) -> ValueRef * {
            if (!o->isObject()) return ValueRef::createUndefined();
            return o->asObject()->get(state, a->string());
        },
        asVal(obj), static_cast<AtomicStringRef *>(atom));
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}
extern "C" bool escargot_set_property_atom(EscargotContext *c, EscargotValue obj, EscargotAtom atom, EscargotValue val) {
    if (!c || !obj || !atom) return false;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, AtomicStringRef *a, ValueRef *v) -> ValueRef * {
            if (!o->isObject()) return ValueRef::create(false);
            bool ok = o->asObject()->set(state, a->string(), v ? v : ValueRef::createUndefined());
            return ValueRef::create(ok);
        },
        asVal(obj), static_cast<AtomicStringRef *>(atom), asVal(val));
    return er.isSuccessful() && er.result && er.result->isBoolean() && er.result->asBoolean();
}
extern "C" bool escargot_has_property_atom(EscargotContext *c, EscargotValue obj, EscargotAtom atom) {
    if (!c || !obj || !atom) return false;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, AtomicStringRef *a) -> ValueRef * {
            if (!o->isObject()) return ValueRef::create(false);
            return ValueRef::create(o->asObject()->has(state, a->string()));
        },
        asVal(obj), static_cast<AtomicStringRef *>(atom));
    return er.isSuccessful() && er.result && er.result->isBoolean() && er.result->asBoolean();
}

extern "C" bool escargot_is_error(EscargotValue v) {
    return v && asVal(v)->isErrorObject();
}

extern "C" EscargotValue escargot_new_error(EscargotContext *c, int kind, const char *message) {
    if (!c) return nullptr;
    const char *msg = message ? message : "";
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, int k, const char *m) -> ValueRef * {
            auto *s = StringRef::createFromUTF8(m, std::strlen(m));
            // Zig JsErrorKind: 0=generic 1=type 2=range 3=reference 4=syntax 5=uri 6=eval 7=internal 8=aggregate
            ErrorObjectRef::Code code = ErrorObjectRef::Code::None;
            switch (k) {
            case 1: code = ErrorObjectRef::Code::TypeError; break;
            case 2: code = ErrorObjectRef::Code::RangeError; break;
            case 3: code = ErrorObjectRef::Code::ReferenceError; break;
            case 4: code = ErrorObjectRef::Code::SyntaxError; break;
            case 5: code = ErrorObjectRef::Code::URIError; break;
            case 6: code = ErrorObjectRef::Code::EvalError; break;
            case 8: code = ErrorObjectRef::Code::AggregateError; break;
            default: code = ErrorObjectRef::Code::None; break;
            }
            auto *err = ErrorObjectRef::create(state, code, s);
            err->updateStackTraceData(state);
            return err;
        },
        kind, msg);
    if (!er.isSuccessful()) return nullptr;
    return retain(c, er.result);
}

// ---- Round 3: construct / has / delete / keys / instanceof / promise / external / weak ----

static EscargotOpResult opFail(EscargotContextOpaque *c, ValueRef *exc) {
    EscargotOpResult out{nullptr, nullptr};
    if (exc) out.exception = retain(c, exc);
    return out;
}
static EscargotOpResult opOk(EscargotContextOpaque *c, ValueRef *v) {
    EscargotOpResult out{nullptr, nullptr};
    out.value = retain(c, v);
    return out;
}
static EscargotBoolOpResult boolFail(EscargotContextOpaque *c, ValueRef *exc) {
    EscargotBoolOpResult out{false, nullptr};
    if (exc) out.exception = retain(c, exc);
    return out;
}
static EscargotBoolOpResult boolOk(bool v) {
    return EscargotBoolOpResult{v, nullptr};
}

static ValueRef *retainedErrorOrNull(EscargotContextOpaque *c, const Evaluator::EvaluatorResult &er) {
    if (er.error) return const_cast<ValueRef *>(er.error.value());
    return nullptr;
}

extern "C" EscargotOpResult escargot_call_result(EscargotContext *c, EscargotValue fn, EscargotValue this_val,
                                                 const EscargotValue *args, size_t argc) {
    EscargotOpResult out{nullptr, nullptr};
    if (!c || !fn) return out;
    std::vector<ValueRef *> argv(argc);
    for (size_t i = 0; i < argc; i++) argv[i] = asVal(args[i]);
    CallPack pack{asVal(fn), this_val ? asVal(this_val) : nullptr, argv.data(), argc};
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, CallPack *p) -> ValueRef * {
            ValueRef *recv = p->this_val ? p->this_val : ValueRef::createUndefined();
            return p->fn->call(state, recv, p->argc, p->argv);
        },
        &pack);
    if (!er.isSuccessful()) return opFail(c, retainedErrorOrNull(c, er));
    return opOk(c, er.result);
}


extern "C" EscargotOpResult escargot_set_property_result(EscargotContext *c, EscargotValue obj, const char *key, EscargotValue val) {
    EscargotOpResult out{nullptr, nullptr};
    if (!c || !obj || !key) return out;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, const char *k, ValueRef *v) -> ValueRef * {
            if (!o->isObject()) {
                state->throwException(ErrorObjectRef::create(state, ErrorObjectRef::Code::TypeError,
                    StringRef::createFromUTF8("cannot set property of non-object", 33)));
                return ValueRef::createUndefined();
            }
            o->asObject()->set(state, StringRef::createFromUTF8(k, std::strlen(k)),
                v ? v : ValueRef::createUndefined());
            return ValueRef::createUndefined();
        },
        asVal(obj), key, asVal(val));
    if (!er.isSuccessful()) return opFail(c, retainedErrorOrNull(c, er));
    return opOk(c, ValueRef::createUndefined());
}

extern "C" EscargotOpResult escargot_construct(EscargotContext *c, EscargotValue ctor,
                                               const EscargotValue *args, size_t argc) {
    EscargotOpResult out{nullptr, nullptr};
    if (!c || !ctor) return out;
    std::vector<ValueRef *> argv(argc);
    for (size_t i = 0; i < argc; i++) argv[i] = asVal(args[i]);
    struct Pack { ValueRef *fn; ValueRef **argv; size_t argc; } pack{asVal(ctor), argv.data(), argc};
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, Pack *p) -> ValueRef * {
            if (!p->fn->isConstructible()) {
                state->throwException(ErrorObjectRef::create(state, ErrorObjectRef::Code::TypeError,
                    StringRef::createFromUTF8("value is not a constructor", 25)));
                return ValueRef::createUndefined();
            }
            return p->fn->construct(state, p->argc, p->argv);
        },
        &pack);
    if (!er.isSuccessful()) return opFail(c, retainedErrorOrNull(c, er));
    return opOk(c, er.result);
}

extern "C" EscargotBoolOpResult escargot_has_in(EscargotContext *c, EscargotValue obj, const char *key) {
    if (!c || !obj || !key) return boolOk(false);
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, const char *k) -> ValueRef * {
            if (!o->isObject()) {
                state->throwException(ErrorObjectRef::create(state, ErrorObjectRef::Code::TypeError,
                    StringRef::createFromUTF8("cannot use 'in' operator to search for a key in a non-object", 58)));
                return ValueRef::createUndefined();
            }
            bool found = o->asObject()->has(state, StringRef::createFromUTF8(k, std::strlen(k)));
            return ValueRef::create(found);
        },
        asVal(obj), key);
    if (!er.isSuccessful()) return boolFail(c, retainedErrorOrNull(c, er));
    bool v = er.result && er.result->isBoolean() && er.result->asBoolean();
    return boolOk(v);
}

extern "C" EscargotBoolOpResult escargot_delete_property(EscargotContext *c, EscargotValue obj, const char *key) {
    if (!c || !obj || !key) return boolOk(false);
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o, const char *k) -> ValueRef * {
            ObjectRef *target = o->toObject(state);
            bool ok = target->deleteOwnProperty(state, StringRef::createFromUTF8(k, std::strlen(k)));
            return ValueRef::create(ok);
        },
        asVal(obj), key);
    if (!er.isSuccessful()) return boolFail(c, retainedErrorOrNull(c, er));
    bool v = er.result && er.result->isBoolean() && er.result->asBoolean();
    return boolOk(v);
}

extern "C" EscargotOpResult escargot_own_keys(EscargotContext *c, EscargotValue obj) {
    EscargotOpResult out{nullptr, nullptr};
    if (!c || !obj) return out;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *o) -> ValueRef * {
            ObjectRef *target = o->toObject(state);
            ValueVectorRef *raw = target->ownPropertyKeys(state);
            auto *arr = ArrayObjectRef::create(state);
            uint32_t idx = 0;
            for (size_t i = 0; i < raw->size(); i++) {
                ValueRef *name = raw->at(i);
                if (!name->isString()) continue;
                ValueRef *desc = target->getOwnPropertyDescriptor(state, name);
                if (!desc || !desc->isObject()) continue;
                ValueRef *enumerable = desc->asObject()->get(state, StringRef::createFromUTF8("enumerable", 10));
                if (!enumerable || !enumerable->isBoolean() || !enumerable->asBoolean()) continue;
                // DefineDataProperty = CreateDataProperty (no Array.prototype setters).
                arr->defineDataProperty(state, ValueRef::create((double)idx), name, true, true, true);
                idx++;
            }
            return arr;
        },
        asVal(obj));
    if (!er.isSuccessful()) return opFail(c, retainedErrorOrNull(c, er));
    return opOk(c, er.result);
}

extern "C" EscargotBoolOpResult escargot_instance_of(EscargotContext *c, EscargotValue value, EscargotValue ctor) {
    if (!c || !value || !ctor) return boolOk(false);
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *v, ValueRef *ctorV) -> ValueRef * {
            return ValueRef::create(v->instanceOf(state, ctorV));
        },
        asVal(value), asVal(ctor));
    if (!er.isSuccessful()) return boolFail(c, retainedErrorOrNull(c, er));
    bool v = er.result && er.result->isBoolean() && er.result->asBoolean();
    return boolOk(v);
}

struct PromiseSettleData {
    PromiseObjectRef *promise;
    bool fulfill;
};

static ValueRef *promiseSettleTrampoline(ExecutionStateRef *state, ValueRef *thisValue,
                                         size_t argc, ValueRef **argv, bool isConstructorCall) {
    (void)thisValue;
    (void)isConstructorCall;
    auto callee = state->resolveCallee();
    if (!callee) return ValueRef::createUndefined();
    auto *data = static_cast<PromiseSettleData *>(callee->extraData());
    if (!data || !data->promise) return ValueRef::createUndefined();
    ValueRef *arg = (argc > 0 && argv[0]) ? argv[0] : ValueRef::createUndefined();
    if (data->fulfill) data->promise->fulfill(state, arg);
    else data->promise->reject(state, arg);
    return ValueRef::createUndefined();
}

extern "C" bool escargot_promise_create(EscargotContext *c, EscargotValue *out_promise,
                                        EscargotValue *out_resolve, EscargotValue *out_reject) {
    if (!c || !out_promise || !out_resolve || !out_reject) return false;
    *out_promise = nullptr;
    *out_resolve = nullptr;
    *out_reject = nullptr;
    struct Out {
        EscargotValue p, r, j;
    } out{nullptr, nullptr, nullptr};
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, Out *o, EscargotContextOpaque *ctx) -> ValueRef * {
            auto *promise = PromiseObjectRef::create(state);
            auto *resData = new PromiseSettleData{promise, true};
            auto *rejData = new PromiseSettleData{promise, false};
            AtomicStringRef *resName = AtomicStringRef::create(state->context(), "resolve", 7);
            AtomicStringRef *rejName = AtomicStringRef::create(state->context(), "reject", 6);
            FunctionObjectRef::NativeFunctionInfo resInfo(resName, promiseSettleTrampoline, 1, true, false);
            FunctionObjectRef::NativeFunctionInfo rejInfo(rejName, promiseSettleTrampoline, 1, true, false);
            auto *resFn = FunctionObjectRef::create(state, resInfo);
            auto *rejFn = FunctionObjectRef::create(state, rejInfo);
            resFn->setExtraData(resData);
            rejFn->setExtraData(rejData);
            // Free settle data when the function is collected.
            Memory::gcRegisterFinalizer(resFn,
                [](void *, void *data) { delete static_cast<PromiseSettleData *>(data); }, resData);
            Memory::gcRegisterFinalizer(rejFn,
                [](void *, void *data) { delete static_cast<PromiseSettleData *>(data); }, rejData);
            o->p = retain(ctx, promise);
            o->r = retain(ctx, resFn);
            o->j = retain(ctx, rejFn);
            return promise;
        },
        &out, c);
    if (!er.isSuccessful() || !out.p || !out.r || !out.j) {
        if (out.p) escargot_free_value(c, out.p);
        if (out.r) escargot_free_value(c, out.r);
        if (out.j) escargot_free_value(c, out.j);
        return false;
    }
    *out_promise = out.p;
    *out_resolve = out.r;
    *out_reject = out.j;
    return true;
}

extern "C" bool escargot_is_promise(EscargotContext *c, EscargotValue v) {
    (void)c;
    return v && asVal(v)->isPromiseObject();
}

extern "C" int escargot_promise_state(EscargotContext *c, EscargotValue v) {
    (void)c;
    if (!v || !asVal(v)->isPromiseObject()) return -1;
    switch (asVal(v)->asPromiseObject()->state()) {
    case PromiseObjectRef::Pending: return 0;
    case PromiseObjectRef::FulFilled: return 1;
    case PromiseObjectRef::Rejected: return 2;
    }
    return -1;
}

extern "C" EscargotValue escargot_promise_result(EscargotContext *c, EscargotValue v) {
    if (!c || !v || !asVal(v)->isPromiseObject()) return nullptr;
    auto *p = asVal(v)->asPromiseObject();
    if (p->state() == PromiseObjectRef::Pending) return nullptr;
    return retain(c, p->promiseResult());
}

static const uint32_t kExternalMagic = 0x4A534258u; // 'JSBX'

struct ExternalBox {
    uint32_t magic;
    void *ptr;
    EscargotExternalFinalizer fin;
};

static void fireExternalPending(void *data) {
    auto *bx = static_cast<ExternalBox *>(data);
    if (bx->fin) bx->fin(bx->ptr);
    bx->fin = nullptr;
    delete bx;
}

extern "C" EscargotValue escargot_new_external(EscargotContext *c, void *ptr, EscargotExternalFinalizer fin) {
    if (!c) return nullptr;
    auto *box = new ExternalBox{kExternalMagic, ptr, fin};
    auto *pf = new EscargotContextOpaque::PendingFinal{&fireExternalPending, box, false};
    {
        std::lock_guard<std::mutex> lock(c->finals_mu);
        c->pending_finals.push_back(pf);
    }
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ExternalBox *b) -> ValueRef * {
            auto *o = ObjectRef::create(state);
            o->setExtraData(b);
            return o;
        },
        box);
    if (!er.isSuccessful()) {
        std::lock_guard<std::mutex> lock(c->finals_mu);
        auto &vec = c->pending_finals;
        vec.erase(std::remove(vec.begin(), vec.end(), pf), vec.end());
        delete pf;
        delete box;
        return nullptr;
    }
    return retain(c, er.result);
}

extern "C" void *escargot_get_external(EscargotContext *c, EscargotValue v) {
    (void)c;
    if (!v || !asVal(v)->isObject()) return nullptr;
    auto *data = asVal(v)->asObject()->extraData();
    if (!data) return nullptr;
    auto *box = static_cast<ExternalBox *>(data);
    if (box->magic != kExternalMagic) return nullptr;
    return box->ptr;
}

extern "C" bool escargot_is_external(EscargotContext *c, EscargotValue v) {
    (void)c;
    if (!v || !asVal(v)->isObject()) return false;
    auto *data = asVal(v)->asObject()->extraData();
    if (!data) return false;
    return static_cast<ExternalBox *>(data)->magic == kExternalMagic;
}

struct WeakBox {
    void *user_data;
    EscargotWeakFinalizer cb;
};

static void fireWeakPending(void *data) {
    auto *bx = static_cast<WeakBox *>(data);
    if (bx->cb) bx->cb(bx->user_data);
    bx->cb = nullptr;
    delete bx;
}

extern "C" bool escargot_weak_attach_finalizer(EscargotContext *c, EscargotValue target,
                                               void *user_data, EscargotWeakFinalizer cb) {
    if (!c || !target || !cb) return false;
    if (!asVal(target)->isObject()) return false;
    auto *box = new WeakBox{user_data, cb};
    auto *pf = new EscargotContextOpaque::PendingFinal{&fireWeakPending, box, false};
    {
        std::lock_guard<std::mutex> lock(c->finals_mu);
        c->pending_finals.push_back(pf);
    }
    static std::atomic<uint64_t> seq{0};
    uint64_t n = seq.fetch_add(1);
    char keybuf[64];
    std::snprintf(keybuf, sizeof(keybuf), "__$jsbay_escargot_Finalizer%llu$__", (unsigned long long)n);
    const char *key_ptr = keybuf;
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ValueRef *t, WeakBox *b, const char *key) -> ValueRef * {
            auto *holder = ObjectRef::create(state);
            holder->setExtraData(b);
            bool ok = t->asObject()->defineDataProperty(state,
                StringRef::createFromUTF8(key, std::strlen(key)),
                holder, true, false, true);
            return ValueRef::create(ok);
        },
        asVal(target), box, key_ptr);
    if (!er.isSuccessful() || !(er.result && er.result->isBoolean() && er.result->asBoolean())) {
        std::lock_guard<std::mutex> lock(c->finals_mu);
        auto &vec = c->pending_finals;
        vec.erase(std::remove(vec.begin(), vec.end(), pf), vec.end());
        delete pf;
        delete box;
        return false;
    }
    return true;
}


// ---- Host object via Proxy (get/set traps separated) ----

struct HostObjectBox {
    int32_t instance_id = 0;
    void *user_data = nullptr;
    EscargotHostGetFn get_fn = nullptr;
    EscargotHostSetFn set_fn = nullptr;
    EscargotHostNamesFn names_fn = nullptr;
    EscargotHostFinalizeFn finalize_fn = nullptr;
    bool finalized = false;
    EscargotContextOpaque *ctx = nullptr;
    EscargotContextOpaque::PendingFinal *pending = nullptr;
};

static void fireHostPending(void *data) {
    auto *box = static_cast<HostObjectBox *>(data);
    if (!box) return;
    if (!box->finalized) {
        box->finalized = true;
        auto fin = box->finalize_fn;
        box->finalize_fn = nullptr;
        if (fin) fin(box->user_data);
    }
    delete box;
}

static HostObjectBox *hostBoxFromCallee(ExecutionStateRef *state) {
    auto callee = state->resolveCallee();
    if (!callee) return nullptr;
    return static_cast<HostObjectBox *>(callee->extraData());
}

static std::string propKeyToUtf8(ExecutionStateRef *state, ValueRef *key) {
    if (!key) return {};
    if (key->isSymbol()) return {}; // ignore symbols for host traps
    StringRef *s = key->toString(state);
    if (!s) return {};
    return s->toStdUTF8String();
}

static ValueRef *hostValueToJs(ExecutionStateRef *state, const EscargotHostValue &hv) {
    (void)state;
    if (hv.tag == 1) return ValueRef::create(hv.number);
    if (hv.tag == 2) {
        const char *p = hv.ptr ? hv.ptr : "";
        return StringRef::createFromUTF8(p, hv.len);
    }
    return ValueRef::createUndefined();
}

static void jsToHostValue(ValueRef *value, EscargotHostValue *hv, std::string *str_storage) {
    hv->tag = 0;
    hv->reserved = 0;
    hv->number = 0;
    hv->ptr = nullptr;
    hv->len = 0;
    if (!value || value->isUndefined() || value->isNull()) return;
    if (value->isNumber()) {
        hv->tag = 1;
        hv->number = value->asNumber();
        return;
    }
    if (value->isString()) {
        *str_storage = value->asString()->toStdUTF8String();
        hv->tag = 2;
        hv->ptr = str_storage->data();
        hv->len = str_storage->size();
    }
}

static void hostObjectFinalizer(void *self_ptr, void *) {
    auto *self = static_cast<ObjectRef *>(self_ptr);
    auto *box = static_cast<HostObjectBox *>(self->extraData());
    if (!box) return;
    self->setExtraData(nullptr);
    // Prefer destroy-time pending list; mark it fired if GC wins the race.
    if (box->pending) box->pending->fired = true;
    if (!box->finalized) {
        box->finalized = true;
        auto fin = box->finalize_fn;
        box->finalize_fn = nullptr;
        if (fin) fin(box->user_data);
    }
    // pending->data still points here; clear so destroy does not double-delete.
    if (box->pending) box->pending->data = nullptr;
    delete box;
}

static bool isCanonicalArrayIndex(const std::string &name, uint32_t *out) {
    if (name.empty() || name.size() > 10) return false;
    if (name[0] == '0') {
        if (name.size() != 1) return false;
        *out = 0;
        return true;
    }
    uint64_t n = 0;
    for (char ch : name) {
        if (ch < '0' || ch > '9') return false;
        n = n * 10 + (uint64_t)(ch - '0');
    }
    if (n >= 0xFFFFFFFFull) return false;
    *out = (uint32_t)n;
    return true;
}

static ValueRef *hostProxyGet(ExecutionStateRef *state, ValueRef *thisValue, size_t argc, ValueRef **argv, bool) {
    (void)thisValue;
    auto *box = hostBoxFromCallee(state);
    if (!box) return ValueRef::createUndefined();
    // argv: target, prop, receiver
    ValueRef *prop = argc >= 2 ? argv[1] : ValueRef::createUndefined();
    std::string name = propKeyToUtf8(state, prop);
    if (name.empty() && prop && prop->isSymbol()) return ValueRef::createUndefined();
    EscargotHostValue hv{};
    hv.tag = 0;
    if (box->get_fn) {
        if (const char *err = box->get_fn(box->instance_id, box->user_data, name.data(), name.size(), &hv)) {
            state->throwException(ErrorObjectRef::create(state, ErrorObjectRef::Code::TypeError,
                StringRef::createFromUTF8(err, std::strlen(err))));
            return ValueRef::createUndefined();
        }
    }
    return hostValueToJs(state, hv);
}

static ValueRef *hostProxySet(ExecutionStateRef *state, ValueRef *thisValue, size_t argc, ValueRef **argv, bool) {
    (void)thisValue;
    auto *box = hostBoxFromCallee(state);
    if (!box) return ValueRef::create(false);
    // argv: target, prop, value, receiver
    ValueRef *prop = argc >= 2 ? argv[1] : ValueRef::createUndefined();
    ValueRef *value = argc >= 3 ? argv[2] : ValueRef::createUndefined();
    std::string name = propKeyToUtf8(state, prop);
    if (!box->set_fn) {
        auto *err = ErrorObjectRef::create(state, ErrorObjectRef::Code::None,
            StringRef::createFromASCII("TypeError: cannot set property"));
        state->throwException(err);
        return ValueRef::create(false);
    }
    EscargotHostValue hv{};
    std::string str_storage;
    jsToHostValue(value, &hv, &str_storage);
    if (const char *err = box->set_fn(box->instance_id, box->user_data, name.data(), name.size(), &hv)) {
        state->throwException(ErrorObjectRef::create(state, ErrorObjectRef::Code::TypeError,
            StringRef::createFromUTF8(err, std::strlen(err))));
        return ValueRef::create(false);
    }
    return ValueRef::create(true);
}

static ValueRef *hostProxyHas(ExecutionStateRef *state, ValueRef *thisValue, size_t argc, ValueRef **argv, bool) {
    (void)state; (void)thisValue; (void)argc; (void)argv;
    // Every name is "in" the host object.
    return ValueRef::create(true);
}

static ValueRef *hostProxyGetOwnPropertyDescriptor(ExecutionStateRef *state, ValueRef *thisValue, size_t argc, ValueRef **argv, bool) {
    (void)thisValue; (void)argc; (void)argv;
    // Present + configurable so hasOwnProperty is true; value left undefined (get trap supplies real reads).
    auto *desc = ObjectRef::create(state);
    desc->defineDataProperty(state, StringRef::createFromASCII("value"), ValueRef::createUndefined(), true, true, true);
    desc->defineDataProperty(state, StringRef::createFromASCII("writable"), ValueRef::create(true), true, true, true);
    desc->defineDataProperty(state, StringRef::createFromASCII("enumerable"), ValueRef::create(true), true, true, true);
    desc->defineDataProperty(state, StringRef::createFromASCII("configurable"), ValueRef::create(true), true, true, true);
    return desc;
}

static ValueRef *hostProxyOwnKeys(ExecutionStateRef *state, ValueRef *thisValue, size_t argc, ValueRef **argv, bool) {
    (void)thisValue; (void)argc; (void)argv;
    auto *box = hostBoxFromCallee(state);
    if (!box || !box->names_fn) return ArrayObjectRef::create(state);
    const char **names = nullptr;
    const size_t *lens = nullptr;
    size_t count = 0;
    box->names_fn(box->instance_id, box->user_data, &names, &lens, &count);
    if (!names || count == 0) return ArrayObjectRef::create(state);

    std::vector<size_t> order;
    order.reserve(count);
    std::vector<std::pair<uint32_t, size_t>> idxs;
    for (size_t i = 0; i < count; i++) {
        uint32_t n = 0;
        std::string s(names[i], lens ? lens[i] : std::strlen(names[i]));
        if (isCanonicalArrayIndex(s, &n)) idxs.push_back({n, i});
    }
    std::sort(idxs.begin(), idxs.end(), [](const auto &a, const auto &b) {
        if (a.first != b.first) return a.first < b.first;
        return a.second < b.second;
    });
    for (auto &p : idxs) order.push_back(p.second);
    for (size_t i = 0; i < count; i++) {
        uint32_t n = 0;
        std::string s(names[i], lens ? lens[i] : std::strlen(names[i]));
        if (!isCanonicalArrayIndex(s, &n)) order.push_back(i);
    }

    auto *arr = ArrayObjectRef::create(state, (uint64_t)order.size());
    for (size_t i = 0; i < order.size(); i++) {
        size_t idx = order[i];
        size_t len = lens ? lens[idx] : std::strlen(names[idx]);
        arr->setIndexedProperty(state, ValueRef::create((int)i), StringRef::createFromUTF8(names[idx], len));
    }
    return arr;
}

static FunctionObjectRef *makeHostTrap(ExecutionStateRef *state, HostObjectBox *box,
                                       ValueRef *(*fn)(ExecutionStateRef *, ValueRef *, size_t, ValueRef **, bool),
                                       const char *name) {
    AtomicStringRef *an = AtomicStringRef::create(state->context(), name, std::strlen(name));
    FunctionObjectRef::NativeFunctionInfo info(an, fn, 0, true, false);
    auto *f = FunctionObjectRef::create(state, info);
    f->setExtraData(box);
    return f;
}

extern "C" EscargotValue escargot_host_object_create(EscargotContext *c, int32_t instance_id, void *user_data,
                                                     EscargotHostGetFn get_fn, EscargotHostSetFn set_fn,
                                                     EscargotHostNamesFn names_fn, EscargotHostFinalizeFn finalize_fn) {
    if (!c) return nullptr;
    auto *box = new HostObjectBox{instance_id, user_data, get_fn, set_fn, names_fn, finalize_fn, false, c, nullptr};
    auto *pf = new EscargotContextOpaque::PendingFinal{&fireHostPending, box, false};
    box->pending = pf;
    {
        std::lock_guard<std::mutex> lock(c->finals_mu);
        c->pending_finals.push_back(pf);
    }
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, HostObjectBox *bx) -> ValueRef * {
            auto *target = ObjectRef::create(state);
            auto *handler = ObjectRef::create(state);
            handler->defineDataProperty(state, StringRef::createFromASCII("get"), makeHostTrap(state, bx, hostProxyGet, "get"), true, false, true);
            handler->defineDataProperty(state, StringRef::createFromASCII("set"), makeHostTrap(state, bx, hostProxySet, "set"), true, false, true);
            handler->defineDataProperty(state, StringRef::createFromASCII("has"), makeHostTrap(state, bx, hostProxyHas, "has"), true, false, true);
            handler->defineDataProperty(state, StringRef::createFromASCII("getOwnPropertyDescriptor"),
                makeHostTrap(state, bx, hostProxyGetOwnPropertyDescriptor, "getOwnPropertyDescriptor"), true, false, true);
            handler->defineDataProperty(state, StringRef::createFromASCII("ownKeys"),
                makeHostTrap(state, bx, hostProxyOwnKeys, "ownKeys"), true, false, true);
            auto *proxy = ProxyObjectRef::create(state, target, handler);
            // Destroy-time finalize via pending_finals (same contract as External).
            target->setExtraData(bx);
            return proxy;
        },
        box);
    if (!er.isSuccessful()) {
        std::lock_guard<std::mutex> lock(c->finals_mu);
        auto &vec = c->pending_finals;
        vec.erase(std::remove(vec.begin(), vec.end(), pf), vec.end());
        delete pf;
        delete box;
        return nullptr;
    }
    return retain(c, er.result);
}


// ---- ES module loader (PlatformRef) ----

static void cacheModule(EscargotContextOpaque *c, const std::string &path, ScriptRef *script) {
    if (!c || !script) return;
    for (auto &e : c->module_cache) {
        if (e.first == path) {
            e.second = PersistentRefHolder<ScriptRef>(script);
            return;
        }
    }
    c->module_cache.emplace_back(path, PersistentRefHolder<ScriptRef>(script));
}

static ScriptRef *findCachedModule(EscargotContextOpaque *c, const std::string &path) {
    if (!c) return nullptr;
    for (auto &e : c->module_cache) {
        if (e.first == path) return e.second.get();
    }
    return nullptr;
}

static std::string resolveModuleId(EscargotContextOpaque *c, const std::string &referrer,
                                   const std::string &specifier) {
    if (c && c->mod_resolve) {
        char *resolved = c->mod_resolve(c->mod_ud, referrer.c_str(), specifier.c_str());
        if (resolved) {
            std::string out(resolved);
            if (c->mod_free_resolved) c->mod_free_resolved(c->mod_ud, resolved);
            else std::free(resolved);
            return out;
        }
    }
    return specifier;
}

PlatformRef::LoadModuleResult BridgePlatform::onLoadModule(
    ContextRef *relatedContext, ScriptRef *whereRequestFrom, StringRef *moduleSrc, ModuleType type) {
    EscargotContextOpaque *c = lookupCtx(relatedContext);
    if (!c || !c->mod_load) {
        return LoadModuleResult(ErrorObjectRef::Code::TypeError,
            StringRef::createFromASCII("module loading unsupported (no loader)"));
    }
    std::string referrer;
    if (whereRequestFrom && whereRequestFrom->src()) {
        referrer = whereRequestFrom->src()->toStdUTF8String();
        for (auto &e : c->module_cache) {
            if (e.second.get() == whereRequestFrom) {
                referrer = e.first;
                break;
            }
        }
    }
    std::string specifier = moduleSrc ? moduleSrc->toStdUTF8String() : std::string();
    std::string absPath = resolveModuleId(c, referrer, specifier);
    if (ScriptRef *cached = findCachedModule(c, absPath)) {
        return LoadModuleResult(cached);
    }
    const char *src_ptr = nullptr;
    size_t src_len = 0;
    if (!c->mod_load(c->mod_ud, absPath.c_str(), &src_ptr, &src_len) || !src_ptr) {
        std::string msg = "could not load module '" + absPath + "'";
        return LoadModuleResult(ErrorObjectRef::Code::ReferenceError,
            StringRef::createFromUTF8(msg.data(), msg.size()));
    }
    auto source = StringRef::createFromUTF8(src_ptr, src_len);
    auto srcName = StringRef::createFromUTF8(absPath.data(), absPath.size());
    ScriptParserRef::InitializeScriptResult parsed;
    if (type == ModuleJSON) {
        parsed = relatedContext->scriptParser()->initializeJSONModule(source, srcName);
    } else {
        parsed = relatedContext->scriptParser()->initializeScript(source, srcName, true);
    }
    if (!parsed.isSuccessful()) {
        return LoadModuleResult(parsed.parseErrorCode, parsed.parseErrorMessage);
    }
    // Cache before return so circular imports find this ScriptRef while its own
    // dependencies are still loading (didLoadModule also caches; cacheModule is idempotent).
    cacheModule(c, absPath, parsed.script.get());
    return LoadModuleResult(parsed.script.get());
}

void BridgePlatform::didLoadModule(ContextRef *relatedContext, OptionalRef<ScriptRef>,
                                   ScriptRef *loadedModule) {
    EscargotContextOpaque *c = lookupCtx(relatedContext);
    if (!c || !loadedModule) return;
    std::string path;
    if (loadedModule->src()) path = loadedModule->src()->toStdUTF8String();
    for (auto &e : c->module_cache) {
        if (e.second.get() == loadedModule) return;
    }
    cacheModule(c, path, loadedModule);
}

extern "C" void escargot_install_module_loader(EscargotContext *ctx, void *user_data,
                                               EscargotModResolveFn resolve,
                                               EscargotModLoadFn load,
                                               EscargotModFreeResolvedFn free_resolved) {
    if (!ctx) return;
    ctx->mod_ud = user_data;
    ctx->mod_resolve = resolve;
    ctx->mod_load = load;
    ctx->mod_free_resolved = free_resolved;
}

extern "C" void escargot_uninstall_module_loader(EscargotContext *ctx) {
    if (!ctx) return;
    ctx->mod_ud = nullptr;
    ctx->mod_resolve = nullptr;
    ctx->mod_load = nullptr;
    ctx->mod_free_resolved = nullptr;
    ctx->module_cache.clear();
}

static EscargotEvalResult evalModuleScript(EscargotContextOpaque *c, StringRef *source,
                                           StringRef *fname, const std::string &cache_key) {
    EscargotEvalResult out{nullptr, nullptr};
    auto parsed = c->ctx.get()->scriptParser()->initializeScript(source, fname, true);
    if (!parsed.isSuccessful()) {
        out.err = stringRefToUtf8(parsed.parseErrorMessage);
        if (!out.err) out.err = dupCString("module parse error");
        return out;
    }
    cacheModule(c, cache_key, parsed.script.get());
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, ScriptRef *script) -> ValueRef * {
            return script->execute(state);
        },
        parsed.script.get());
    while (c->rt && c->rt->vm.get() && c->rt->vm.get()->hasPendingJob()) {
        c->rt->vm.get()->executePendingJob();
    }
    if (!er.isSuccessful()) {
        out.err = stringRefToUtf8(er.resultOrErrorToString(c->ctx.get()));
        if (!out.err) out.err = dupCString("module evaluation error");
        return out;
    }
    ValueRef *result = er.result;
    if (!result || result->isUndefined() || result->isNull()) return out;
    if (result->isObject()) {
        out.result = escargot_json_stringify(c, result);
    } else {
        out.result = escargot_value_to_utf8(c, result);
    }
    return out;
}

extern "C" EscargotEvalResult escargot_eval_module(EscargotContext *c, const char *src, size_t src_len,
                                                   const char *filename, size_t filename_len) {
    EscargotEvalResult out{nullptr, nullptr};
    if (!c || !c->ctx.get() || !src) {
        out.err = dupCString("invalid context");
        return out;
    }
    auto source = StringRef::createFromUTF8(src, src_len);
    std::string fname_s(filename ? filename : "", filename_len);
    if (fname_s.empty()) fname_s = "<module>";
    auto fname = StringRef::createFromUTF8(fname_s.data(), fname_s.size());
    return evalModuleScript(c, source, fname, fname_s);
}

extern "C" EscargotEvalResult escargot_import_module(EscargotContext *c, const char *specifier) {
    EscargotEvalResult out{nullptr, nullptr};
    if (!c || !c->ctx.get() || !specifier) {
        out.err = dupCString("invalid context");
        return out;
    }
    if (!c->mod_load) {
        out.err = dupCString("no module loader configured");
        return out;
    }
    std::string absPath = resolveModuleId(c, "", specifier);
    if (ScriptRef *cached = findCachedModule(c, absPath)) {
        auto er = Evaluator::execute(c->ctx.get(),
            [](ExecutionStateRef *state, ScriptRef *script) -> ValueRef * {
                return script->execute(state);
            },
            cached);
        while (c->rt && c->rt->vm.get() && c->rt->vm.get()->hasPendingJob()) {
            c->rt->vm.get()->executePendingJob();
        }
        if (!er.isSuccessful()) {
            out.err = stringRefToUtf8(er.resultOrErrorToString(c->ctx.get()));
            if (!out.err) out.err = dupCString("module evaluation error");
        }
        return out;
    }
    const char *src_ptr = nullptr;
    size_t src_len = 0;
    if (!c->mod_load(c->mod_ud, absPath.c_str(), &src_ptr, &src_len) || !src_ptr) {
        std::string msg = std::string("could not load module '") + absPath + "'";
        out.err = dupCString(msg);
        return out;
    }
    auto source = StringRef::createFromUTF8(src_ptr, src_len);
    auto fname = StringRef::createFromUTF8(absPath.data(), absPath.size());
    return evalModuleScript(c, source, fname, absPath);
}


// ---- NativeHandle (opaque + call + finalize) ----
static const uint32_t kNativeHandleMagic = 0x4E484E44u; // 'NHND'

struct NativeHandleBox {
    uint32_t magic = kNativeHandleMagic;
    void *handle_data = nullptr;
    EscargotNativeFn call_fn = nullptr;
    EscargotNhFinalize finalize = nullptr;
    EscargotContextOpaque *owner = nullptr;
    EscargotContextOpaque::PendingFinal *pending = nullptr;
};

static void fireNativeHandlePending(void *data) {
    auto *bx = static_cast<NativeHandleBox *>(data);
    if (!bx) return;
    // Idempotent: GC may still run after teardown-forced fire, or vice versa.
    if (bx->magic != kNativeHandleMagic) return;
    bx->magic = 0;
    if (bx->pending) {
        bx->pending->fired = true;
        bx->pending = nullptr;
    }
    if (bx->finalize) {
        auto fin = bx->finalize;
        bx->finalize = nullptr;
        fin(bx->handle_data);
    }
    bx->handle_data = nullptr;
    delete bx;
}
// NOTE: Do NOT register Memory::gcRegisterFinalizer on the NH object while also
// using pending_finals teardown. Escargot has no unregister API; GC after
// context-free leftover fire UAF'd the deleted NativeHandleBox (adversarial /
// host_object suite ABRT). Teardown-forced finalize remains the contract.

static ValueRef *nativeHandleTrampoline(ExecutionStateRef *state, ValueRef *thisValue, size_t argc, ValueRef **argv,
                                          bool isConstructCall) {
    (void)isConstructCall;
    auto *self = state->resolveCallee()->asFunctionObject();
    auto *bx = static_cast<NativeHandleBox *>(self->extraData());
    if (!bx || bx->magic != kNativeHandleMagic || !bx->call_fn || !bx->owner) {
        state->throwException(ErrorObjectRef::create(state, ErrorObjectRef::Code::TypeError,
            StringRef::createFromASCII("NativeHandle is not callable")));
        return ValueRef::createUndefined();
    }
    EscargotContext *c = bx->owner;
    std::vector<EscargotValue> args(argc);
    for (size_t i = 0; i < argc; ++i) args[i] = argv[i];
    c->pending_throw.clear();
    EscargotValue out = bx->call_fn(c, thisValue, args.data(), argc, bx->handle_data);
    if (!c->pending_throw.empty()) {
        std::string msg = c->pending_throw;
        c->pending_throw.clear();
        state->throwException(ErrorObjectRef::create(state, ErrorObjectRef::Code::None,
            StringRef::createFromUTF8(msg.data(), msg.size())));
        return ValueRef::createUndefined();
    }
    return out ? asVal(out) : ValueRef::createUndefined();
}

extern "C" EscargotValue escargot_native_handle_create(EscargotContext *c, void *handle_data,
                                                       EscargotNativeFn call_fn, EscargotNhFinalize finalize) {
    if (!c || !handle_data) return nullptr;
    auto *box = new NativeHandleBox{};
    box->handle_data = handle_data;
    box->call_fn = call_fn;
    box->finalize = finalize;
    box->owner = c;
    auto *pf = new EscargotContextOpaque::PendingFinal{&fireNativeHandlePending, box, false};
    box->pending = pf;
    {
        std::lock_guard<std::mutex> lock(c->finals_mu);
        c->pending_finals.push_back(pf);
    }
    if (call_fn) {
        auto er = Evaluator::execute(c->ctx.get(),
            [](ExecutionStateRef *state, NativeHandleBox *b) -> ValueRef * {
                AtomicStringRef *an = AtomicStringRef::create(state->context(), "NativeHandle");
                FunctionObjectRef::NativeFunctionInfo info(an, nativeHandleTrampoline, 0, true, false);
                auto *f = FunctionObjectRef::create(state, info);
                f->setExtraData(b);
                return f;
            },
            box);
        if (!er.isSuccessful()) {
            std::lock_guard<std::mutex> lock(c->finals_mu);
            auto &vec = c->pending_finals;
            vec.erase(std::remove(vec.begin(), vec.end(), pf), vec.end());
            delete pf;
            delete box;
            return nullptr;
        }
        return retain(c, er.result);
    }
    auto er = Evaluator::execute(c->ctx.get(),
        [](ExecutionStateRef *state, NativeHandleBox *b) -> ValueRef * {
            auto *o = ObjectRef::create(state);
            o->setExtraData(b);
            return o;
        },
        box);
    if (!er.isSuccessful()) {
        std::lock_guard<std::mutex> lock(c->finals_mu);
        auto &vec = c->pending_finals;
        vec.erase(std::remove(vec.begin(), vec.end(), pf), vec.end());
        delete pf;
        delete box;
        return nullptr;
    }
    return retain(c, er.result);
}

extern "C" void *escargot_native_handle_get(EscargotContext *c, EscargotValue v) {
    (void)c;
    if (!v || !asVal(v)->isObject()) return nullptr;
    auto *data = asVal(v)->asObject()->extraData();
    if (!data) return nullptr;
    auto *bx = static_cast<NativeHandleBox *>(data);
    if (bx->magic != kNativeHandleMagic) return nullptr;
    return bx->handle_data;
}

extern "C" bool escargot_native_handle_is(EscargotContext *c, EscargotValue v) {
    return escargot_native_handle_get(c, v) != nullptr;
}
