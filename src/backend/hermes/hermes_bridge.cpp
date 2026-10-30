#include "hermes_bridge.h"

#include <hermes/hermes.h>
#include <jsi/instrumentation.h>
#include <jsi/jsi.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <memory>
#include <limits>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
#include <fstream>
#include <sstream>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/wait.h>

namespace jsi = facebook::jsi;
using FbHermesRuntime = facebook::hermes::HermesRuntime;

struct JsbayHermesRuntimeOpaque {
    std::unique_ptr<FbHermesRuntime> rt;
};

struct JsbayHermesContextOpaque {
    JsbayHermesRuntimeOpaque *owner = nullptr;
    FbHermesRuntime *rt = nullptr;
    void *opaque = nullptr;
    std::mutex protect_mu;
    std::unordered_map<jsi::Value *, std::pair<int, std::unique_ptr<jsi::Value>>> protect;
    std::string pending_throw;
    struct PendingFinal {
        void (*fire)(void *);
        void *data;
        bool fired;
    };
    std::mutex finals_mu;
    std::vector<PendingFinal *> pending_finals;
    // Promise state side-table for Deferreds we create (pointer identity of retained Value*).
    std::mutex promise_mu;
    std::unordered_map<jsi::Value *, std::pair<int, jsi::Value *>> promise_state; // state, result retained ptr
    // Captured at context_new before user code can replace page Object.keys / DataView.
    std::unique_ptr<jsi::Function> pristine_object_keys;
    std::unique_ptr<jsi::Object> pristine_dataview_proto;
    // Pristine %TypedArray%.prototype getters (ignore instance exotic own getters).
    std::unique_ptr<jsi::Function> pristine_ta_buffer_get;
    std::unique_ptr<jsi::Function> pristine_ta_byte_offset_get;
    std::unique_ptr<jsi::Function> pristine_ta_byte_length_get;
    // %TypedArray% intrinsic (Uint8Array.__proto__) — instanceof brand check without global Uint8Array.
    std::unique_ptr<jsi::Function> pristine_typed_array_ctor;
    // Host Promise rejection tracker (Escargot-style queue + flush after microtasks)
    HermesRejectionTrackerFn rejection_fn = nullptr;
    void *rejection_ud = nullptr;
    int32_t rejection_instance_id = 0;
    std::vector<std::pair<bool, std::string>> pending_rejections;
    bool rejection_hook_installed = false;
    int32_t rejection_timer_next = 1;
    std::unordered_map<int32_t, std::shared_ptr<bool>> rejection_timer_cancelled;
};

static void hermes_flush_pending_rejections(JsbayHermesContext *c);

static jsi::Value *asVal(HermesValue v) { return static_cast<jsi::Value *>(v); }

static HermesValue retainOwned(JsbayHermesContextOpaque *c, std::unique_ptr<jsi::Value> heap) {
    jsi::Value *ptr = heap.get();
    std::lock_guard<std::mutex> lock(c->protect_mu);
    c->protect.emplace(ptr, std::make_pair(1, std::move(heap)));
    return ptr;
}

static HermesValue retainMove(JsbayHermesContextOpaque *c, jsi::Value &&v) {
    return retainOwned(c, std::make_unique<jsi::Value>(std::move(v)));
}

static void release(JsbayHermesContextOpaque *c, jsi::Value *v) {
    if (!c || !v) return;
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

static std::string valueToDisplayString(FbHermesRuntime &rt, const jsi::Value &result) {
    if (result.isUndefined()) return "undefined";
    if (result.isNull()) return "null";
    if (result.isBool()) return result.getBool() ? "true" : "false";
    if (result.isNumber()) {
        double d = result.getNumber();
        char buf[64];
        if (d == (double)(int64_t)d && d >= -9.0e15 && d <= 9.0e15) {
            std::snprintf(buf, sizeof(buf), "%lld", (long long)(int64_t)d);
        } else {
            std::snprintf(buf, sizeof(buf), "%.17g", d);
        }
        return buf;
    }
    if (result.isString()) return result.getString(rt).utf8(rt);
    // Eval display: prefer JSON for objects/arrays (match Escargot eval path).
    try {
        auto JSON = rt.global().getPropertyAsObject(rt, "JSON");
        auto stringify = JSON.getPropertyAsFunction(rt, "stringify");
        jsi::Value jsoned = stringify.call(rt, result);
        if (jsoned.isString()) return jsoned.getString(rt).utf8(rt);
    } catch (...) {
    }
    try {
        return result.toString(rt).utf8(rt);
    } catch (...) {
        return "[object Object]";
    }
}

static std::string valueToJsString(FbHermesRuntime &rt, const jsi::Value &result) {
    if (result.isUndefined()) return "undefined";
    if (result.isNull()) return "null";
    if (result.isBool()) return result.getBool() ? "true" : "false";
    if (result.isNumber()) {
        double d = result.getNumber();
        char buf[64];
        if (d == (double)(int64_t)d && d >= -9.0e15 && d <= 9.0e15) {
            std::snprintf(buf, sizeof(buf), "%lld", (long long)(int64_t)d);
        } else {
            std::snprintf(buf, sizeof(buf), "%.17g", d);
        }
        return buf;
    }
    if (result.isString()) return result.getString(rt).utf8(rt);
    try {
        return result.toString(rt).utf8(rt);
    } catch (...) {
        return "[object Object]";
    }
}

extern "C" void hermes_globals_ensure(void) {}

// max_heap_bytes==0 → Hermes default MaxHeapSize (3GiB). Non-zero sets GCConfig at
// Runtime create time only; there is no runtime setMemoryLimit on Hermes.
extern "C" JsbayHermesRuntime *hermes_runtime_new(uint64_t max_heap_bytes) {
    auto *rt = new JsbayHermesRuntimeOpaque();
    auto gc_builder = ::hermes::vm::GCConfig::Builder();
    if (max_heap_bytes != 0) {
        const auto cap = static_cast<::hermes::vm::gcheapsize_t>(
            std::min<uint64_t>(
                max_heap_bytes,
                static_cast<uint64_t>(std::numeric_limits<::hermes::vm::gcheapsize_t>::max())));
        // Hermes raises MaxHeapSize to InitHeapSize when Max < Init; keep Init <= cap.
        const auto default_init = static_cast<::hermes::vm::gcheapsize_t>(32u << 20);
        const auto init = std::min(cap, default_init);
        gc_builder.withInitHeapSize(init).withMaxHeapSize(cap);
    }
    auto conf = ::hermes::vm::RuntimeConfig::Builder()
        .withMicrotaskQueue(true)
        .withES6Class(true)
        .withEnableHermesInternal(true)
        .withEnableHermesInternalTestMethods(true) // detachArrayBuffer for transfer polyfill
        .withAsyncBreakCheckInEval(true) // requestInterrupt → asyncTriggerTimeout
        .withGCConfig(gc_builder.build())
        .build();
    rt->rt = facebook::hermes::makeHermesRuntime(conf);
    return rt;
}
extern "C" void hermes_runtime_free(JsbayHermesRuntime *rt) { delete rt; }
extern "C" void hermes_runtime_gc(JsbayHermesRuntime *rt) {
    if (!rt || !rt->rt) return;
    try {
        rt->rt->instrumentation().collectGarbage("jsbay");
    } catch (...) {
    }
}
extern "C" uint64_t hermes_runtime_allocated_bytes(JsbayHermesRuntime *rt) {
    if (!rt || !rt->rt) return 0;
    try {
        auto info = rt->rt->instrumentation().getHeapInfo(false);
        auto it = info.find("hermes_allocatedBytes");
        if (it != info.end()) return static_cast<uint64_t>(it->second > 0 ? it->second : 0);
        it = info.find("hermes_heapSize");
        if (it != info.end()) return static_cast<uint64_t>(it->second > 0 ? it->second : 0);
    } catch (...) {
    }
    return 0;
}
extern "C" uint64_t hermes_runtime_heap_size(JsbayHermesRuntime *rt) {
    if (!rt || !rt->rt) return 0;
    try {
        auto info = rt->rt->instrumentation().getHeapInfo(false);
        auto it = info.find("hermes_heapSize");
        if (it != info.end()) return static_cast<uint64_t>(it->second > 0 ? it->second : 0);
    } catch (...) {
    }
    return 0;
}

// IHermes async break — callable from any thread. Requires AsyncBreakCheckInEval.
extern "C" void hermes_runtime_async_trigger_timeout(JsbayHermesRuntime *rt) {
    if (!rt || !rt->rt) return;
    try {
        rt->rt->asyncTriggerTimeout();
    } catch (...) {
    }
}
extern "C" void hermes_runtime_watch_time_limit(JsbayHermesRuntime *rt, uint32_t timeout_ms) {
    if (!rt || !rt->rt) return;
    try {
        rt->rt->watchTimeLimit(timeout_ms);
    } catch (...) {
    }
}
extern "C" void hermes_runtime_unwatch_time_limit(JsbayHermesRuntime *rt) {
    if (!rt || !rt->rt) return;
    try {
        rt->rt->unwatchTimeLimit();
    } catch (...) {
    }
}

// asyncTriggerTimeout sets a sticky Timeout AsyncBreak bit that survives unwatchTimeLimit.
// A no-op eval with AsyncBreakCheckInEval clears it (throws once). Call after idle stop/destroy.
extern "C" void hermes_runtime_drain_async_timeout(JsbayHermesRuntime *rt) {
    if (!rt || !rt->rt) return;
    try {
        rt->rt->unwatchTimeLimit();
    } catch (...) {
    }
    try {
        (void)rt->rt->evaluateJavaScript(
            std::make_shared<jsi::StringBuffer>(""), "<jsbay-drain-timeout>");
    } catch (...) {
        // Expected: "Javascript execution has timed out." — bit cleared.
    }
}

extern "C" JsbayHermesContext *hermes_context_new(JsbayHermesRuntime *rt) {
    if (!rt || !rt->rt) return nullptr;
    auto *c = new JsbayHermesContextOpaque();
    c->owner = rt;
    c->rt = rt->rt.get();
    // Hermes Promise scheduling expects global setImmediate; map it to the JSI microtask queue.
    try {
        auto setImmediate = jsi::Function::createFromHostFunction(
            *c->rt, jsi::PropNameID::forAscii(*c->rt, "setImmediate"), 1,
            [](jsi::Runtime &runtime, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                if (count > 0 && args[0].isObject() && args[0].getObject(runtime).isFunction(runtime)) {
                    runtime.queueMicrotask(args[0].getObject(runtime).getFunction(runtime));
                }
                return jsi::Value::undefined();
            });
        c->rt->global().setProperty(*c->rt, "setImmediate", setImmediate);
    } catch (...) {
    }
    // ArrayBuffer.prototype.transfer — Hermes pin has no native transfer; polyfill via
    // copy + HermesInternal.detachArrayBuffer (test-methods). Escargot has native transfer.
    try {
        static const char kTransferPoly[] = R"JS(
(function () {
  if (typeof ArrayBuffer === 'undefined') return;
  var HI = typeof HermesInternal !== 'undefined' ? HermesInternal : null;
  if (!HI || typeof HI.detachArrayBuffer !== 'function') return;
  var detachedSet = typeof WeakSet === 'function' ? new WeakSet() : null;
  if (typeof ArrayBuffer.prototype.transfer !== 'function') {
    ArrayBuffer.prototype.transfer = function (newByteLength) {
      var src = this;
      if (!(src instanceof ArrayBuffer))
        throw new TypeError('Method ArrayBuffer.prototype.transfer called on incompatible receiver');
      if (detachedSet && detachedSet.has(src))
        throw new TypeError('Cannot perform ArrayBuffer.prototype.transfer on a detached ArrayBuffer');
      var len = src.byteLength;
      var n = (newByteLength === undefined || newByteLength === null) ? len : Number(newByteLength);
      if (!Number.isFinite(n) || n < 0) throw new RangeError('Invalid array buffer length');
      n = Math.floor(n);
      var dst = new ArrayBuffer(n);
      var copy = Math.min(len, n);
      if (copy > 0) new Uint8Array(dst, 0, copy).set(new Uint8Array(src, 0, copy));
      HI.detachArrayBuffer(src);
      if (detachedSet) detachedSet.add(src);
      return dst;
    };
  }
  if (Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, 'detached') == null) {
    Object.defineProperty(ArrayBuffer.prototype, 'detached', {
      configurable: true,
      enumerable: false,
      get: function () {
        return !!(detachedSet && detachedSet.has(this));
      }
    });
  }
})();
)JS";
        c->rt->evaluateJavaScript(std::make_shared<jsi::StringBuffer>(kTransferPoly), "<jsbay-ab-transfer>");
    } catch (...) {
    }
    try {
        auto keys = c->rt->global()
            .getPropertyAsFunction(*c->rt, "Object")
            .getPropertyAsFunction(*c->rt, "keys");
        c->pristine_object_keys = std::make_unique<jsi::Function>(std::move(keys));
    } catch (...) {
        c->pristine_object_keys.reset();
    }
    try {
        auto proto = c->rt->global()
            .getPropertyAsFunction(*c->rt, "DataView")
            .getProperty(*c->rt, "prototype")
            .asObject(*c->rt);
        c->pristine_dataview_proto = std::make_unique<jsi::Object>(std::move(proto));
    } catch (...) {
        c->pristine_dataview_proto.reset();
    }
    try {
        // Evaluate once so we grab real accessor .get functions off %TypedArray%.prototype.
        const char *kGrab = R"JS(
            (function () {
              var TAP = Object.getPrototypeOf(Uint8Array.prototype);
              return [
                Object.getOwnPropertyDescriptor(TAP, 'buffer').get,
                Object.getOwnPropertyDescriptor(TAP, 'byteOffset').get,
                Object.getOwnPropertyDescriptor(TAP, 'byteLength').get,
                Uint8Array.__proto__
              ];
            })()
        )JS";
        auto arrVal = c->rt->evaluateJavaScript(std::make_shared<jsi::StringBuffer>(kGrab), "<jsbay-ta-getters>");
        auto arr = arrVal.asObject(*c->rt).asArray(*c->rt);
        c->pristine_ta_buffer_get = std::make_unique<jsi::Function>(
            arr.getValueAtIndex(*c->rt, 0).asObject(*c->rt).asFunction(*c->rt));
        c->pristine_ta_byte_offset_get = std::make_unique<jsi::Function>(
            arr.getValueAtIndex(*c->rt, 1).asObject(*c->rt).asFunction(*c->rt));
        c->pristine_ta_byte_length_get = std::make_unique<jsi::Function>(
            arr.getValueAtIndex(*c->rt, 2).asObject(*c->rt).asFunction(*c->rt));
        c->pristine_typed_array_ctor = std::make_unique<jsi::Function>(
            arr.getValueAtIndex(*c->rt, 3).asObject(*c->rt).asFunction(*c->rt));
    } catch (const std::exception &e) {
        c->pristine_ta_buffer_get.reset();
        c->pristine_ta_byte_offset_get.reset();
        c->pristine_ta_byte_length_get.reset();
        c->pristine_typed_array_ctor.reset();
    } catch (...) {
        c->pristine_ta_buffer_get.reset();
        c->pristine_ta_byte_offset_get.reset();
        c->pristine_ta_byte_length_get.reset();
        c->pristine_typed_array_ctor.reset();
    }
    return c;
}
extern "C" void hermes_uninstall_module_loader(JsbayHermesContext *ctx);

extern "C" void hermes_context_free(JsbayHermesContext *ctx) {
    if (!ctx) return;
    // Drop ESM cache (jsi::Object) before tearing down the Runtime / protect table.
    hermes_uninstall_module_loader(ctx);
    {
        std::lock_guard<std::mutex> lock(ctx->protect_mu);
        ctx->protect.clear();
    }
    std::vector<JsbayHermesContextOpaque::PendingFinal *> leftover;
    {
        std::lock_guard<std::mutex> lock(ctx->finals_mu);
        leftover.swap(ctx->pending_finals);
    }
    for (auto *pf : leftover) {
        if (!pf) continue;
        if (!pf->fired) {
            pf->fired = true;
            if (pf->fire) pf->fire(pf->data);
        }
        delete pf;
    }
    {
        std::lock_guard<std::mutex> lock(ctx->promise_mu);
        for (auto &kv : ctx->promise_state) {
            if (kv.second.second) release(ctx, kv.second.second);
        }
        ctx->promise_state.clear();
    }
    delete ctx;
}
extern "C" void hermes_context_set_opaque(JsbayHermesContext *ctx, void *opaque) {
    if (ctx) ctx->opaque = opaque;
}
extern "C" void *hermes_context_get_opaque(JsbayHermesContext *ctx) {
    return ctx ? ctx->opaque : nullptr;
}


static std::string formatJSError(const jsi::JSError &e) {
    // Message alone omits sourceURL; stack is "Error: msg\n    at ... (file:line:col)".
    const std::string &stack = e.getStack();
    if (!stack.empty()) return stack;
    return e.getMessage();
}

extern "C" HermesEvalResult hermes_eval(JsbayHermesContext *c, const char *src, size_t src_len,
                                        const char *filename, size_t filename_len) {
    HermesEvalResult out{nullptr, nullptr};
    if (!c || !c->rt) {
        out.err = dupCString("no context");
        return out;
    }
    try {
        std::string code(src ? src : "", src_len);
        std::string url(filename ? filename : "", filename_len);
        if (url.empty()) url = "<eval>";
        jsi::Value result = c->rt->evaluateJavaScript(
            std::make_shared<jsi::StringBuffer>(std::move(code)), url);
        if (result.isUndefined() || result.isNull()) {
            // Match Escargot/jsbay: nullish completion yields null result, no err.
            return out;
        }
        out.result = dupCString(valueToDisplayString(*c->rt, result));
    } catch (const jsi::JSError &e) {
        out.err = dupCString(formatJSError(e));
    } catch (const std::exception &e) {
        out.err = dupCString(e.what());
    } catch (...) {
        out.err = dupCString("unknown JS error");
    }
    return out;
}
extern "C" void hermes_eval_result_free(HermesEvalResult r) {
    std::free(r.result);
    std::free(r.err);
}

extern "C" HermesValue hermes_undefined(void) { return nullptr; }
extern "C" HermesValue hermes_null(void) {
    static jsi::Value kNull = jsi::Value::null();
    return &kNull;
}
extern "C" HermesValue hermes_new_bool(bool v) { return new jsi::Value(v); }
extern "C" HermesValue hermes_new_int32(int32_t v) { return new jsi::Value((double)v); }
extern "C" HermesValue hermes_new_float64(double v) { return new jsi::Value(v); }

extern "C" HermesValue hermes_new_string(JsbayHermesContext *c, const char *utf8, size_t len) {
    if (!c || !c->rt) return nullptr;
    try {
        return retainMove(c, jsi::Value(jsi::String::createFromUtf8(*c->rt, std::string(utf8 ? utf8 : "", len))));
    } catch (...) { return nullptr; }
}
extern "C" HermesValue hermes_new_object(JsbayHermesContext *c) {
    if (!c || !c->rt) return nullptr;
    try { return retainMove(c, jsi::Value(jsi::Object(*c->rt))); }
    catch (...) { return nullptr; }
}
extern "C" HermesValue hermes_new_array(JsbayHermesContext *c, uint32_t len) {
    if (!c || !c->rt) return nullptr;
    try { return retainMove(c, jsi::Value(jsi::Array(*c->rt, len))); }
    catch (...) { return nullptr; }
}

extern "C" HermesValue hermes_dup(JsbayHermesContext *c, HermesValue v) {
    if (!v) return nullptr;
    if (!c) return v;
    std::lock_guard<std::mutex> lock(c->protect_mu);
    auto it = c->protect.find(asVal(v));
    if (it != c->protect.end()) {
        it->second.first += 1;
        return v;
    }
    return v;
}
extern "C" void hermes_free_value(JsbayHermesContext *c, HermesValue v) { release(c, asVal(v)); }

extern "C" bool hermes_is_undefined(HermesValue v) { return !v || asVal(v)->isUndefined(); }
extern "C" bool hermes_is_null(HermesValue v) { return v && asVal(v)->isNull(); }
extern "C" bool hermes_is_bool(HermesValue v) { return v && asVal(v)->isBool(); }
extern "C" bool hermes_is_number(HermesValue v) { return v && asVal(v)->isNumber(); }
extern "C" bool hermes_is_string(HermesValue v) { return v && asVal(v)->isString(); }
extern "C" bool hermes_is_object(HermesValue v) { return v && asVal(v)->isObject(); }
extern "C" bool hermes_is_array(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v || !asVal(v)->isObject()) return false;
    try { return asVal(v)->getObject(*c->rt).isArray(*c->rt); }
    catch (...) { return false; }
}
extern "C" bool hermes_is_function(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v || !asVal(v)->isObject()) return false;
    try { return asVal(v)->getObject(*c->rt).isFunction(*c->rt); }
    catch (...) { return false; }
}

extern "C" bool hermes_is_constructor(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v || !asVal(v)->isObject()) return false;
    try {
        auto &rt = *c->rt;
        auto o = asVal(v)->getObject(rt);
        if (!o.isFunction(rt)) return false;
        // ES IsConstructor: Reflect.construct(fn, []) succeeds iff [[Construct]] exists.
        // Probe via a cached helper so we never invoke the user constructor body with a
        // wrong newTarget, and so JS TypeErrors stay in-engine (no host ABRT).
        static const char *kHelper =
            "(function(f){try{Reflect.construct(function(){},[],f);return true;}"
            "catch(e){return false;}})";
        auto helper = rt.global()
                          .getPropertyAsFunction(rt, "eval")
                          .call(rt, kHelper)
                          .asObject(rt)
                          .asFunction(rt);
        auto out = helper.call(rt, o);
        return out.isBool() && out.getBool();
    } catch (...) {
        return false;
    }
}

extern "C" bool hermes_to_bool(HermesValue v) { return v && asVal(v)->isBool() && asVal(v)->getBool(); }
extern "C" int32_t hermes_to_int32(HermesValue v) {
    if (!v || !asVal(v)->isNumber()) return 0;
    double d = asVal(v)->getNumber();
    if (std::isnan(d) || std::isinf(d)) return 0;
    return (int32_t)d; // truncate toward zero
}
extern "C" double hermes_to_float64(HermesValue v) {
    if (!v || !asVal(v)->isNumber()) return 0;
    return asVal(v)->getNumber();
}

extern "C" char *hermes_value_to_utf8(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v) return dupCString("undefined");
    try { return dupCString(valueToJsString(*c->rt, *asVal(v))); }
    catch (...) { return nullptr; }
}
/* Length-aware UTF-8 (preserves embedded NUL). Caller frees; *out_len excludes terminator. */
extern "C" char *hermes_value_to_utf8_n(JsbayHermesContext *c, HermesValue v, size_t *out_len) {
    if (out_len) *out_len = 0;
    if (!c || !c->rt || !v) return nullptr;
    try {
        std::string s;
        if (asVal(v)->isString()) {
            s = asVal(v)->getString(*c->rt).utf8(*c->rt);
        } else {
            s = valueToJsString(*c->rt, *asVal(v));
        }
        char *out = static_cast<char *>(std::malloc(s.size() + 1));
        if (!out) return nullptr;
        if (!s.empty()) std::memcpy(out, s.data(), s.size());
        out[s.size()] = 0;
        if (out_len) *out_len = s.size();
        return out;
    } catch (...) { return nullptr; }
}
extern "C" char *hermes_json_stringify(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v) return nullptr;
    try {
        auto JSON = c->rt->global().getPropertyAsObject(*c->rt, "JSON");
        auto stringify = JSON.getPropertyAsFunction(*c->rt, "stringify");
        jsi::Value jsoned = stringify.call(*c->rt, *asVal(v));
        if (!jsoned.isString()) return nullptr;
        return dupCString(jsoned.getString(*c->rt).utf8(*c->rt));
    } catch (...) { return nullptr; }
}
extern "C" HermesValue hermes_json_parse(JsbayHermesContext *c, const char *utf8, size_t len) {
    if (!c || !c->rt) return nullptr;
    try {
        auto JSON = c->rt->global().getPropertyAsObject(*c->rt, "JSON");
        auto parse = JSON.getPropertyAsFunction(*c->rt, "parse");
        auto s = jsi::String::createFromUtf8(*c->rt, std::string(utf8 ? utf8 : "", len));
        return retainMove(c, parse.call(*c->rt, s));
    } catch (...) { return nullptr; }
}

extern "C" HermesValue hermes_get_global(JsbayHermesContext *c) {
    if (!c || !c->rt) return nullptr;
    try { return retainMove(c, jsi::Value(c->rt->global())); }
    catch (...) { return nullptr; }
}
extern "C" HermesValue hermes_get_property(JsbayHermesContext *c, HermesValue obj, const char *key) {
    if (!c || !c->rt || !obj || !asVal(obj)->isObject()) return nullptr;
    try {
        return retainMove(c, asVal(obj)->getObject(*c->rt).getProperty(*c->rt, key));
    } catch (...) { return nullptr; }
}
extern "C" bool hermes_set_property(JsbayHermesContext *c, HermesValue obj, const char *key, HermesValue val) {
    if (!c || !c->rt || !obj || !asVal(obj)->isObject()) return false;
    try {
        jsi::Value v = val ? jsi::Value(*c->rt, *asVal(val)) : jsi::Value::undefined();
        asVal(obj)->getObject(*c->rt).setProperty(*c->rt, key, v);
        return true;
    } catch (...) { return false; }
}
extern "C" bool hermes_has_property(JsbayHermesContext *c, HermesValue obj, const char *key) {
    if (!c || !c->rt || !obj || !asVal(obj)->isObject()) return false;
    try {
        return asVal(obj)->getObject(*c->rt).hasProperty(*c->rt, key);
    } catch (...) { return false; }
}

extern "C" HermesValue hermes_call(JsbayHermesContext *c, HermesValue fn, HermesValue this_val,
                                   const HermesValue *args, size_t argc, char **out_err) {
    if (out_err) *out_err = nullptr;
    if (!c || !c->rt || !fn) {
        if (out_err) *out_err = dupCString("bad call");
        return nullptr;
    }
    try {
        if (!asVal(fn)->isObject() || !asVal(fn)->getObject(*c->rt).isFunction(*c->rt)) {
            if (out_err) *out_err = dupCString("not a function");
            return nullptr;
        }
        auto f = asVal(fn)->getObject(*c->rt).asFunction(*c->rt);
        std::vector<jsi::Value> argv;
        argv.reserve(argc);
        for (size_t i = 0; i < argc; ++i) {
            if (args && args[i]) argv.emplace_back(jsi::Value(*c->rt, *asVal(args[i])));
            else argv.emplace_back(jsi::Value::undefined());
        }
        jsi::Object thisObj = (this_val && asVal(this_val)->isObject())
            ? asVal(this_val)->getObject(*c->rt)
            : c->rt->global();
        jsi::Value result = f.callWithThis(*c->rt, thisObj, (const jsi::Value *)argv.data(), argc);
        return retainMove(c, std::move(result));
    } catch (const jsi::JSError &e) {
        if (out_err) *out_err = dupCString(e.getMessage());
        return nullptr;
    } catch (const std::exception &e) {
        if (out_err) *out_err = dupCString(e.what());
        return nullptr;
    } catch (...) {
        if (out_err) *out_err = dupCString("call failed");
        return nullptr;
    }
}

extern "C" void hermes_process_pending_jobs(JsbayHermesContext *c) {
    if (!c || !c->rt) return;
    try {
        // drainMicrotasks returns true when the queue is empty.
        while (!c->rt->drainMicrotasks(-1)) {
        }
    } catch (...) {
    }
    hermes_flush_pending_rejections(c);
}

// ---- Extended capability APIs (native Hermes/JSI; not a JSC shim) ----

struct VectorBuffer : public jsi::MutableBuffer {
    std::vector<uint8_t> data_;
    explicit VectorBuffer(std::vector<uint8_t> &&d) : data_(std::move(d)) {}
    VectorBuffer(const uint8_t *p, size_t n) : data_(n) {
        if (p && n) std::memcpy(data_.data(), p, n);
    }
    size_t size() const override { return data_.size(); }
    uint8_t *data() override { return data_.data(); }
};

struct ExternalBuffer : public jsi::MutableBuffer {
    uint8_t *ptr_;
    size_t len_;
    HermesBufferDeleter deleter_;
    void *user_data_;
    ExternalBuffer(uint8_t *p, size_t n, HermesBufferDeleter d, void *u)
        : ptr_(p), len_(n), deleter_(d), user_data_(u) {}
    ~ExternalBuffer() override {
        if (deleter_) deleter_(user_data_);
    }
    size_t size() const override { return len_; }
    uint8_t *data() override { return ptr_; }
};

struct HostFnState {
    JsbayHermesContextOpaque *ctx = nullptr;
    HermesNativeFn fn = nullptr;
    void *user_data = nullptr;
};

static bool instanceOfGlobal(FbHermesRuntime &rt, const jsi::Value &v, const char *ctorName) {
    if (!v.isObject()) return false;
    try {
        auto Object = rt.global().getPropertyAsObject(rt, "Object");
        auto proto = Object.getPropertyAsObject(rt, "prototype");
        auto toString = proto.getPropertyAsFunction(rt, "toString");
        auto s = toString.callWithThis(rt, v.getObject(rt));
        if (!s.isString()) return false;
        std::string tag = s.getString(rt).utf8(rt);
        std::string expect = std::string("[object ") + ctorName + "]";
        return tag == expect;
    } catch (...) {
        return false;
    }
}

extern "C" HermesValueResult hermes_eval_value(JsbayHermesContext *c, const char *src, size_t src_len,
                                               const char *filename, size_t filename_len) {
    HermesValueResult out{nullptr, nullptr};
    if (!c || !c->rt) {
        out.err = dupCString("no context");
        return out;
    }
    try {
        std::string code(src ? src : "", src_len);
        std::string url(filename ? filename : "", filename_len);
        if (url.empty()) url = "<eval>";
        jsi::Value result = c->rt->evaluateJavaScript(
            std::make_shared<jsi::StringBuffer>(std::move(code)), url);
        out.value = retainMove(c, std::move(result));
    } catch (const jsi::JSError &e) {
        try {
            out.value = retainMove(c, jsi::Value(*c->rt, e.value()));
        } catch (...) {
            out.value = nullptr;
        }
        out.err = dupCString(formatJSError(e));
    } catch (const std::exception &e) {
        out.err = dupCString(e.what());
    } catch (...) {
        out.err = dupCString("unknown JS error");
    }
    return out;
}
extern "C" void hermes_value_result_free_err(HermesValueResult r) {
    std::free(r.err);
}

extern "C" HermesValue hermes_get_index(JsbayHermesContext *c, HermesValue obj, uint32_t index) {
    if (!c || !c->rt || !obj || !asVal(obj)->isObject()) return nullptr;
    try {
        auto o = asVal(obj)->getObject(*c->rt);
        if (o.isArray(*c->rt)) {
            auto arr = o.getArray(*c->rt);
            // Out-of-range / hole → JS undefined (not C null), matching arrayGet contract.
            if (index >= arr.size(*c->rt)) {
                return retainMove(c, jsi::Value::undefined());
            }
            return retainMove(c, arr.getValueAtIndex(*c->rt, index));
        }
        return retainMove(c, o.getProperty(*c->rt, std::to_string(index).c_str()));
    } catch (...) {
        try { return retainMove(c, jsi::Value::undefined()); }
        catch (...) { return nullptr; }
    }
}
extern "C" uint32_t hermes_get_length(JsbayHermesContext *c, HermesValue obj) {
    if (!c || !c->rt || !obj) return 0;
    try {
        if (asVal(obj)->isString()) {
            return (uint32_t)asVal(obj)->getString(*c->rt).length(*c->rt);
        }
        if (!asVal(obj)->isObject()) return 0;
        auto len = asVal(obj)->getObject(*c->rt).getProperty(*c->rt, "length");
        if (!len.isNumber()) return 0;
        double d = len.getNumber();
        if (d < 0) d = 0;
        if (d > 0xffffffffu) d = 0xffffffffu;
        return (uint32_t)d;
    } catch (...) { return 0; }
}

extern "C" bool hermes_set_index(JsbayHermesContext *c, HermesValue obj, uint32_t index, HermesValue val) {
    if (!c || !c->rt || !obj || !asVal(obj)->isObject()) return false;
    try {
        jsi::Value v = val ? jsi::Value(*c->rt, *asVal(val)) : jsi::Value::undefined();
        auto o = asVal(obj)->getObject(*c->rt);
        if (o.isArray(*c->rt)) {
            o.getArray(*c->rt).setValueAtIndex(*c->rt, index, v);
            return true;
        }
        o.setProperty(*c->rt, std::to_string(index).c_str(), v);
        return true;
    } catch (...) { return false; }
}

extern "C" bool hermes_set_length(JsbayHermesContext *c, HermesValue obj, uint32_t length) {
    if (!c || !c->rt || !obj || !asVal(obj)->isObject()) return false;
    try {
        asVal(obj)->getObject(*c->rt).setProperty(*c->rt, "length", (double)length);
        return true;
    } catch (...) { return false; }
}

extern "C" bool hermes_define_data_property(JsbayHermesContext *c, HermesValue obj, const char *key,
                                           HermesValue val, bool writable) {
    if (!c || !c->rt || !obj || !key || !asVal(obj)->isObject()) return false;
    try {
        auto &rt = *c->rt;
        auto Object = rt.global().getPropertyAsFunction(rt, "Object");
        auto defineProp = Object.getPropertyAsFunction(rt, "defineProperty");
        jsi::Object desc(rt);
        desc.setProperty(rt, "value", val ? jsi::Value(rt, *asVal(val)) : jsi::Value::undefined());
        desc.setProperty(rt, "writable", writable);
        desc.setProperty(rt, "enumerable", true);
        desc.setProperty(rt, "configurable", true);
        defineProp.call(rt, *asVal(obj), key, desc);
        return true;
    } catch (...) { return false; }
}

extern "C" bool hermes_strict_equal(JsbayHermesContext *c, HermesValue a, HermesValue b) {
    if (!c || !c->rt) return a == b;
    try {
        jsi::Value left = a ? jsi::Value(*c->rt, *asVal(a)) : jsi::Value::undefined();
        jsi::Value right = b ? jsi::Value(*c->rt, *asVal(b)) : jsi::Value::undefined();
        return jsi::Value::strictEquals(*c->rt, left, right);
    } catch (...) { return false; }
}

extern "C" HermesValue hermes_new_symbol(JsbayHermesContext *c, const char *desc, size_t desc_len) {
    if (!c || !c->rt) return nullptr;
    try {
        auto &rt = *c->rt;
        auto Sym = rt.global().getPropertyAsFunction(rt, "Symbol");
        if (desc && desc_len > 0) {
            auto s = jsi::String::createFromUtf8(rt, reinterpret_cast<const uint8_t *>(desc), desc_len);
            return retainMove(c, Sym.call(rt, s));
        }
        return retainMove(c, Sym.call(rt));
    } catch (...) { return nullptr; }
}

extern "C" HermesValue hermes_symbol_for(JsbayHermesContext *c, const char *key, size_t key_len) {
    if (!c || !c->rt) return nullptr;
    try {
        auto &rt = *c->rt;
        auto Sym = rt.global().getPropertyAsObject(rt, "Symbol");
        auto forFn = Sym.getPropertyAsFunction(rt, "for");
        auto s = jsi::String::createFromUtf8(rt, reinterpret_cast<const uint8_t *>(key ? key : ""), key_len);
        return retainMove(c, forFn.call(rt, s));
    } catch (...) { return nullptr; }
}

extern "C" bool hermes_is_date(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v) return false;
    return instanceOfGlobal(*c->rt, *asVal(v), "Date");
}
extern "C" int64_t hermes_date_to_ms(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v) return 0;
    try {
        auto o = asVal(v)->getObject(*c->rt);
        auto getTime = o.getPropertyAsFunction(*c->rt, "getTime");
        auto r = getTime.callWithThis(*c->rt, o);
        if (!r.isNumber()) return 0;
        return (int64_t)r.getNumber();
    } catch (...) { return 0; }
}
extern "C" HermesValue hermes_new_date(JsbayHermesContext *c, int64_t ms) {
    if (!c || !c->rt) return nullptr;
    try {
        auto Date = c->rt->global().getPropertyAsFunction(*c->rt, "Date");
        return retainMove(c, Date.callAsConstructor(*c->rt, (double)ms));
    } catch (...) { return nullptr; }
}

extern "C" bool hermes_is_bigint(HermesValue v) {
    return v && asVal(v)->isBigInt();
}
extern "C" HermesValue hermes_new_bigint_i64(JsbayHermesContext *c, int64_t v) {
    if (!c || !c->rt) return nullptr;
    try { return retainMove(c, jsi::Value(jsi::BigInt::fromInt64(*c->rt, v))); }
    catch (...) { return nullptr; }
}
extern "C" HermesValue hermes_new_bigint_u64(JsbayHermesContext *c, uint64_t v) {
    if (!c || !c->rt) return nullptr;
    try { return retainMove(c, jsi::Value(jsi::BigInt::fromUint64(*c->rt, v))); }
    catch (...) { return nullptr; }
}
extern "C" bool hermes_bigint_to_i64(HermesValue v, int64_t *out) {
    if (!v || !asVal(v)->isBigInt() || !out) return false;
    // Need runtime — not available. Use truncate via a thread-local? Fail without ctx.
    // Stored BigInt PointerValue can be truncated only with Runtime. Return false.
    (void)v; (void)out;
    return false;
}
extern "C" bool hermes_bigint_to_u64(HermesValue v, uint64_t *out) {
    (void)v; (void)out;
    return false;
}

// BigInt conversion needs runtime — provide ctx-aware helpers used from Zig via thin wrappers
extern "C" bool hermes_bigint_to_i64_ctx(JsbayHermesContext *c, HermesValue v, int64_t *out) {
    if (!c || !c->rt || !v || !asVal(v)->isBigInt() || !out) return false;
    try {
        auto bi = asVal(v)->getBigInt(*c->rt);
        *out = (int64_t)c->rt->truncate(bi);
        return true;
    } catch (...) { return false; }
}
extern "C" bool hermes_bigint_to_u64_ctx(JsbayHermesContext *c, HermesValue v, uint64_t *out) {
    if (!c || !c->rt || !v || !asVal(v)->isBigInt() || !out) return false;
    try {
        auto bi = asVal(v)->getBigInt(*c->rt);
        *out = c->rt->truncate(bi);
        return true;
    } catch (...) { return false; }
}

extern "C" bool hermes_is_map(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v) return false;
    return instanceOfGlobal(*c->rt, *asVal(v), "Map");
}
extern "C" bool hermes_is_set(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v) return false;
    return instanceOfGlobal(*c->rt, *asVal(v), "Set");
}
extern "C" HermesValue hermes_new_map(JsbayHermesContext *c) {
    if (!c || !c->rt) return nullptr;
    try {
        auto Map = c->rt->global().getPropertyAsFunction(*c->rt, "Map");
        return retainMove(c, Map.callAsConstructor(*c->rt));
    } catch (...) { return nullptr; }
}
extern "C" HermesValue hermes_new_set(JsbayHermesContext *c) {
    if (!c || !c->rt) return nullptr;
    try {
        auto Set = c->rt->global().getPropertyAsFunction(*c->rt, "Set");
        return retainMove(c, Set.callAsConstructor(*c->rt));
    } catch (...) { return nullptr; }
}
extern "C" bool hermes_map_set(JsbayHermesContext *c, HermesValue map, HermesValue key, HermesValue val) {
    if (!c || !c->rt || !map || !asVal(map)->isObject()) return false;
    try {
        auto o = asVal(map)->getObject(*c->rt);
        auto set = o.getPropertyAsFunction(*c->rt, "set");
        jsi::Value k = key ? jsi::Value(*c->rt, *asVal(key)) : jsi::Value::undefined();
        jsi::Value v = val ? jsi::Value(*c->rt, *asVal(val)) : jsi::Value::undefined();
        set.callWithThis(*c->rt, o, k, v);
        return true;
    } catch (...) { return false; }
}
extern "C" bool hermes_set_add(JsbayHermesContext *c, HermesValue set, HermesValue val) {
    if (!c || !c->rt || !set || !asVal(set)->isObject()) return false;
    try {
        auto o = asVal(set)->getObject(*c->rt);
        auto add = o.getPropertyAsFunction(*c->rt, "add");
        jsi::Value v = val ? jsi::Value(*c->rt, *asVal(val)) : jsi::Value::undefined();
        add.callWithThis(*c->rt, o, v);
        return true;
    } catch (...) { return false; }
}
extern "C" size_t hermes_map_size(JsbayHermesContext *c, HermesValue map) {
    if (!c || !c->rt || !map || !asVal(map)->isObject()) return 0;
    try {
        auto s = asVal(map)->getObject(*c->rt).getProperty(*c->rt, "size");
        return s.isNumber() ? (size_t)s.getNumber() : 0;
    } catch (...) { return 0; }
}
extern "C" size_t hermes_set_size(JsbayHermesContext *c, HermesValue set) {
    if (!c || !c->rt || !set || !asVal(set)->isObject()) return 0;
    try {
        auto s = asVal(set)->getObject(*c->rt).getProperty(*c->rt, "size");
        return s.isNumber() ? (size_t)s.getNumber() : 0;
    } catch (...) { return 0; }
}

static char *stashAndEvalJson(JsbayHermesContext *c, HermesValue v, const char *slot, const char *expr) {
    if (!c || !c->rt || !v) return nullptr;
    try {
        c->rt->global().setProperty(*c->rt, slot, *asVal(v));
        jsi::Value result = c->rt->evaluateJavaScript(
            std::make_shared<jsi::StringBuffer>(expr), "<bridge>");
        c->rt->global().setProperty(*c->rt, slot, jsi::Value::undefined());
        if (!result.isString()) return nullptr;
        return dupCString(result.getString(*c->rt).utf8(*c->rt));
    } catch (...) {
        try { c->rt->global().setProperty(*c->rt, slot, jsi::Value::undefined()); } catch (...) {}
        return nullptr;
    }
}

extern "C" char *hermes_map_to_json(JsbayHermesContext *c, HermesValue map) {
    return stashAndEvalJson(c, map, "__jsbay_tmp_map",
                            "JSON.stringify(Array.from(__jsbay_tmp_map.entries()))");
}
extern "C" char *hermes_set_to_json(JsbayHermesContext *c, HermesValue set) {
    return stashAndEvalJson(c, set, "__jsbay_tmp_set",
                            "JSON.stringify(Array.from(__jsbay_tmp_set.values()))");
}
extern "C" HermesValue hermes_new_map_from_json(JsbayHermesContext *c, const char *json, size_t len) {
    if (!c || !c->rt || !json) return nullptr;
    try {
        auto parsed = hermes_json_parse(c, json, len);
        if (!parsed) return nullptr;
        c->rt->global().setProperty(*c->rt, "__jsbay_tmp_arr", *asVal(parsed));
        hermes_free_value(c, parsed);
        jsi::Value result = c->rt->evaluateJavaScript(
            std::make_shared<jsi::StringBuffer>("new Map(__jsbay_tmp_arr)"), "<bridge>");
        c->rt->global().setProperty(*c->rt, "__jsbay_tmp_arr", jsi::Value::undefined());
        return retainMove(c, std::move(result));
    } catch (...) {
        try { c->rt->global().setProperty(*c->rt, "__jsbay_tmp_arr", jsi::Value::undefined()); } catch (...) {}
        return nullptr;
    }
}
extern "C" HermesValue hermes_new_set_from_json(JsbayHermesContext *c, const char *json, size_t len) {
    if (!c || !c->rt || !json) return nullptr;
    try {
        auto parsed = hermes_json_parse(c, json, len);
        if (!parsed) return nullptr;
        c->rt->global().setProperty(*c->rt, "__jsbay_tmp_arr", *asVal(parsed));
        hermes_free_value(c, parsed);
        jsi::Value result = c->rt->evaluateJavaScript(
            std::make_shared<jsi::StringBuffer>("new Set(__jsbay_tmp_arr)"), "<bridge>");
        c->rt->global().setProperty(*c->rt, "__jsbay_tmp_arr", jsi::Value::undefined());
        return retainMove(c, std::move(result));
    } catch (...) {
        try { c->rt->global().setProperty(*c->rt, "__jsbay_tmp_arr", jsi::Value::undefined()); } catch (...) {}
        return nullptr;
    }
}

extern "C" bool hermes_map_foreach(JsbayHermesContext *c, HermesValue map, void *cb_ctx, HermesMapForEachFn cb) {
    if (!c || !c->rt || !map || !cb) return false;
    if (!hermes_is_map(c, map)) return false;
    try {
        auto o = asVal(map)->getObject(*c->rt);
        auto forEach = o.getPropertyAsFunction(*c->rt, "forEach");
        // forEach callback(value, key, map) — note Map order is value first
        auto host = jsi::Function::createFromHostFunction(
            *c->rt, jsi::PropNameID::forAscii(*c->rt, "cb"), 3,
            [c, cb_ctx, cb](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                HermesValue val = (count > 0) ? retainMove(c, jsi::Value(rt, args[0])) : nullptr;
                HermesValue key = (count > 1) ? retainMove(c, jsi::Value(rt, args[1])) : nullptr;
                bool cont = cb(c, cb_ctx, key, val);
                hermes_free_value(c, key);
                hermes_free_value(c, val);
                if (!cont) throw jsi::JSError(rt, "__jsbay_foreach_stop");
                return jsi::Value::undefined();
            });
        forEach.callWithThis(*c->rt, o, host);
        return true;
    } catch (const jsi::JSError &e) {
        if (e.getMessage().find("__jsbay_foreach_stop") != std::string::npos) return true;
        return false;
    } catch (...) { return false; }
}
extern "C" bool hermes_set_foreach(JsbayHermesContext *c, HermesValue set, void *cb_ctx, HermesSetForEachFn cb) {
    if (!c || !c->rt || !set || !cb) return false;
    if (!hermes_is_set(c, set)) return false;
    try {
        auto o = asVal(set)->getObject(*c->rt);
        auto forEach = o.getPropertyAsFunction(*c->rt, "forEach");
        auto host = jsi::Function::createFromHostFunction(
            *c->rt, jsi::PropNameID::forAscii(*c->rt, "cb"), 1,
            [c, cb_ctx, cb](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                HermesValue val = (count > 0) ? retainMove(c, jsi::Value(rt, args[0])) : nullptr;
                bool cont = cb(c, cb_ctx, val);
                hermes_free_value(c, val);
                if (!cont) throw jsi::JSError(rt, "__jsbay_foreach_stop");
                return jsi::Value::undefined();
            });
        forEach.callWithThis(*c->rt, o, host);
        return true;
    } catch (const jsi::JSError &e) {
        if (e.getMessage().find("__jsbay_foreach_stop") != std::string::npos) return true;
        return false;
    } catch (...) { return false; }
}

extern "C" bool hermes_is_array_buffer(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v || !asVal(v)->isObject()) return false;
    try { return asVal(v)->getObject(*c->rt).isArrayBuffer(*c->rt); }
    catch (...) { return false; }
}
static bool hermesBrandIsDataView(FbHermesRuntime &rt, const jsi::Object &o) {
    try {
        auto Object = rt.global().getPropertyAsObject(rt, "Object");
        auto proto = Object.getPropertyAsObject(rt, "prototype");
        auto toString = proto.getPropertyAsFunction(rt, "toString");
        auto s = toString.callWithThis(rt, o);
        return s.isString() && s.getString(rt).utf8(rt) == "[object DataView]";
    } catch (...) {
        return false;
    }
}

static bool hermesBrandIsTypedArray(JsbayHermesContext *c, const jsi::Object &o) {
    if (!c || !c->rt || !c->pristine_typed_array_ctor) return false;
    try {
        return c->rt->instanceOf(o, *c->pristine_typed_array_ctor);
    } catch (...) {
        return false;
    }
}

extern "C" bool hermes_is_typed_array(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v || !asVal(v)->isObject()) return false;
    try {
        auto o = asVal(v)->getObject(*c->rt);
        // Do not use JSI isTypedArray — it reads globalThis.Uint8Array (test replaces it).
        return hermesBrandIsTypedArray(c, o);
    } catch (...) { return false; }
}
static jsi::Value hermesDataViewProtoGet(JsbayHermesContext *c, jsi::Object &o, const char *prop) {
    auto &rt = *c->rt;
    if (!c->pristine_dataview_proto) return jsi::Value::undefined();
    auto Object = rt.global().getPropertyAsFunction(rt, "Object");
    auto getDesc = Object.getPropertyAsFunction(rt, "getOwnPropertyDescriptor");
    auto descVal = getDesc.call(rt, *c->pristine_dataview_proto, prop);
    if (!descVal.isObject()) return jsi::Value::undefined();
    auto getter = descVal.getObject(rt).getProperty(rt, "get");
    if (!getter.isObject() || !getter.getObject(rt).isFunction(rt)) return jsi::Value::undefined();
    return getter.getObject(rt).asFunction(rt).callWithThis(rt, o);
}

// Call cached pristine %TypedArray%.prototype getters (ignore instance exotic own getters).
static jsi::Value hermesTypedArrayProtoGet(JsbayHermesContext *c, jsi::Object &o, const char *prop) {
    auto &rt = *c->rt;
    jsi::Function *getter = nullptr;
    if (std::strcmp(prop, "buffer") == 0) getter = c->pristine_ta_buffer_get.get();
    else if (std::strcmp(prop, "byteOffset") == 0) getter = c->pristine_ta_byte_offset_get.get();
    else if (std::strcmp(prop, "byteLength") == 0) getter = c->pristine_ta_byte_length_get.get();
    if (!getter) return jsi::Value::undefined();
    return getter->callWithThis(rt, o);
}

extern "C" bool hermes_is_data_view(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v || !asVal(v)->isObject()) return false;
    try {
        auto o = asVal(v)->getObject(*c->rt);
        return hermesBrandIsDataView(*c->rt, o);
    } catch (...) {
        return false;
    }
}
extern "C" HermesValue hermes_new_array_buffer_copy(JsbayHermesContext *c, const uint8_t *bytes, size_t len) {
    if (!c || !c->rt) return nullptr;
    try {
        // Prefer JS ArrayBuffer constructor — empty MutableBuffer path is unreliable on Hermes.
        auto AB = c->rt->global().getPropertyAsFunction(*c->rt, "ArrayBuffer");
        jsi::Value ab = AB.callAsConstructor(*c->rt, (double)len);
        if (len > 0 && bytes) {
            auto buf = ab.getObject(*c->rt).getArrayBuffer(*c->rt);
            uint8_t *dst = buf.data(*c->rt);
            if (dst) std::memcpy(dst, bytes, len);
        }
        return retainMove(c, std::move(ab));
    } catch (...) { return nullptr; }
}
extern "C" HermesValue hermes_new_array_buffer_no_copy(JsbayHermesContext *c, uint8_t *bytes, size_t len,
                                                      HermesBufferDeleter deleter, void *user_data) {
    if (!c || !c->rt) return nullptr;
    try {
        auto buf = std::make_shared<ExternalBuffer>(bytes, len, deleter, user_data);
        return retainMove(c, jsi::Value(jsi::ArrayBuffer(*c->rt, std::move(buf))));
    } catch (...) { return nullptr; }
}
extern "C" uint8_t *hermes_array_buffer_data(JsbayHermesContext *c, HermesValue ab, size_t *out_len) {
    if (!c || !c->rt || !ab || !asVal(ab)->isObject()) return nullptr;
    try {
        auto o = asVal(ab)->getObject(*c->rt);
        if (!o.isArrayBuffer(*c->rt)) return nullptr;
        auto buf = o.getArrayBuffer(*c->rt);
        if (out_len) *out_len = buf.size(*c->rt);
        // Hermes may return nullptr data pointer for empty buffers; treat as valid empty.
        uint8_t *data = buf.data(*c->rt);
        if (!data && out_len && *out_len == 0) {
            static uint8_t empty_byte = 0;
            return &empty_byte;
        }
        return data;
    } catch (...) { return nullptr; }
}

static const char *typedArrayCtorName(int kind) {
    switch (kind) {
        case 0: return "Int8Array";
        case 1: return "Uint8Array";
        case 2: return "Uint8ClampedArray";
        case 3: return "Int16Array";
        case 4: return "Uint16Array";
        case 5: return "Int32Array";
        case 6: return "Uint32Array";
        case 7: return "Float32Array";
        case 8: return "Float64Array";
        case 9: return "BigInt64Array";
        case 10: return "BigUint64Array";
        default: return "Uint8Array";
    }
}
static int typedArrayKindFromName(const std::string &name) {
    if (name == "Int8Array") return 0;
    if (name == "Uint8Array") return 1;
    if (name == "Uint8ClampedArray") return 2;
    if (name == "Int16Array") return 3;
    if (name == "Uint16Array") return 4;
    if (name == "Int32Array") return 5;
    if (name == "Uint32Array") return 6;
    if (name == "Float32Array") return 7;
    if (name == "Float64Array") return 8;
    if (name == "BigInt64Array") return 9;
    if (name == "BigUint64Array") return 10;
    return 1;
}

extern "C" HermesValue hermes_new_typed_array(JsbayHermesContext *c, HermesValue ab, int kind,
                                              size_t byte_offset, size_t length) {
    if (!c || !c->rt || !ab) return nullptr;
    try {
        auto Ctor = c->rt->global().getPropertyAsFunction(*c->rt, typedArrayCtorName(kind));
        // new Ctor(ab, byteOffset, length)
        return retainMove(c, Ctor.callAsConstructor(*c->rt, *asVal(ab), (double)byte_offset, (double)length));
    } catch (...) { return nullptr; }
}
extern "C" uint8_t *hermes_typed_array_data(JsbayHermesContext *c, HermesValue ta, size_t *byte_offset,
                                            size_t *byte_length, int *kind) {
    if (!c || !c->rt || !ta || !asVal(ta)->isObject()) return nullptr;
    try {
        auto o = asVal(ta)->getObject(*c->rt);
        if (!hermesBrandIsTypedArray(c, o)) return nullptr;
        // JSI TypedArray::buffer/byteOffset/byteLength default to getProperty and fire
        // exotic own getters. Use pristine %TypedArray%.prototype getters instead.
        auto bufVal = hermesTypedArrayProtoGet(c, o, "buffer");
        auto offVal = hermesTypedArrayProtoGet(c, o, "byteOffset");
        auto lenVal = hermesTypedArrayProtoGet(c, o, "byteLength");
        if (!bufVal.isObject() || !bufVal.getObject(*c->rt).isArrayBuffer(*c->rt)) return nullptr;
        auto buf = bufVal.getObject(*c->rt).getArrayBuffer(*c->rt);
        size_t off = offVal.isNumber() ? (size_t)offVal.getNumber() : 0;
        size_t blen = lenVal.isNumber() ? (size_t)lenVal.getNumber() : 0;
        if (byte_offset) *byte_offset = off;
        if (byte_length) *byte_length = blen;
        if (kind) {
            // Object.prototype.toString — does not fire own constructor getter.
            std::string name;
            try {
                auto Object = c->rt->global().getPropertyAsFunction(*c->rt, "Object");
                auto proto = Object.getProperty(*c->rt, "prototype").asObject(*c->rt);
                auto toString = proto.getProperty(*c->rt, "toString").asObject(*c->rt).asFunction(*c->rt);
                auto tag = toString.callWithThis(*c->rt, o);
                if (tag.isString()) {
                    auto s = tag.getString(*c->rt).utf8(*c->rt);
                    // "[object Uint8Array]" → "Uint8Array"
                    if (s.size() > 16 && s.rfind("[object ", 0) == 0 && s.back() == ']') {
                        name = s.substr(8, s.size() - 9);
                    }
                }
            } catch (...) {
            }
            *kind = typedArrayKindFromName(name);
        }
        uint8_t *data = buf.data(*c->rt);
        if (!data) {
            if (blen == 0) {
                static uint8_t empty_ta_sentinel;
                return &empty_ta_sentinel;
            }
            return nullptr;
        }
        return data + off;
    } catch (...) { return nullptr; }
}
extern "C" HermesValue hermes_new_data_view(JsbayHermesContext *c, HermesValue ab, size_t byte_offset, size_t byte_length) {
    if (!c || !c->rt || !ab) return nullptr;
    try {
        auto DV = c->rt->global().getPropertyAsFunction(*c->rt, "DataView");
        return retainMove(c, DV.callAsConstructor(*c->rt, *asVal(ab), (double)byte_offset, (double)byte_length));
    } catch (...) { return nullptr; }
}
extern "C" uint8_t *hermes_data_view_data(JsbayHermesContext *c, HermesValue dv, size_t *byte_offset, size_t *byte_length) {
    if (!c || !c->rt || !dv || !asVal(dv)->isObject()) return nullptr;
    try {
        auto o = asVal(dv)->getObject(*c->rt);
        if (!hermesBrandIsDataView(*c->rt, o)) return nullptr;
        // Use pristine DataView.prototype getters so own-property shadows are ignored.
        auto bufVal = hermesDataViewProtoGet(c, o, "buffer");
        auto offVal = hermesDataViewProtoGet(c, o, "byteOffset");
        auto lenVal = hermesDataViewProtoGet(c, o, "byteLength");
        if (!bufVal.isObject() || !bufVal.getObject(*c->rt).isArrayBuffer(*c->rt)) return nullptr;
        auto buf = bufVal.getObject(*c->rt).getArrayBuffer(*c->rt);
        size_t off = offVal.isNumber() ? (size_t)offVal.getNumber() : 0;
        size_t len = lenVal.isNumber() ? (size_t)lenVal.getNumber() : 0;
        if (byte_offset) *byte_offset = off;
        if (byte_length) *byte_length = len;
        uint8_t *data = buf.data(*c->rt);
        if (!data) {
            if (len == 0) {
                static uint8_t empty_dv_sentinel;
                return &empty_dv_sentinel;
            }
            return nullptr;
        }
        // Return view-relative pointer; Zig dataViewInfo zeros byte_offset for getDataView.
        return data + off;
    } catch (...) { return nullptr; }
}

extern "C" HermesValue hermes_make_function(JsbayHermesContext *c, const char *name, HermesNativeFn fn, void *user_data) {
    if (!c || !c->rt || !fn) return nullptr;
    try {
        auto *state = new HostFnState{c, fn, user_data};
        std::string n = name ? name : "native";
        auto host = jsi::Function::createFromHostFunction(
            *c->rt, jsi::PropNameID::forUtf8(*c->rt, n), 0,
            [state](jsi::Runtime &rt, const jsi::Value &thisVal, const jsi::Value *args, size_t count) -> jsi::Value {
                JsbayHermesContextOpaque *ctx = state->ctx;
                std::vector<HermesValue> argv;
                argv.reserve(count);
                for (size_t i = 0; i < count; ++i) {
                    argv.push_back(retainMove(ctx, jsi::Value(rt, args[i])));
                }
                HermesValue this_h = retainMove(ctx, jsi::Value(rt, thisVal));
                ctx->pending_throw.clear();
                HermesValue out = state->fn(ctx, this_h, argv.data(), count, state->user_data);
                hermes_free_value(ctx, this_h);
                for (auto a : argv) hermes_free_value(ctx, a);
                if (!ctx->pending_throw.empty()) {
                    std::string msg = ctx->pending_throw;
                    ctx->pending_throw.clear();
                    if (out) hermes_free_value(ctx, out);
                    // Must share one libstdc++ with hermesvm/jsi (see addHermesSources: shared .so,
                    // not a second static libstdc++.a) or JSError RTTI/unwind ABRTs.
                    throw jsi::JSError(rt, msg);
                }
                if (!out) return jsi::Value::undefined();
                jsi::Value result(rt, *asVal(out));
                hermes_free_value(ctx, out);
                return result;
            });
        return retainMove(c, jsi::Value(std::move(host)));
    } catch (...) { return nullptr; }
}

extern "C" void hermes_throw(JsbayHermesContext *c, const char *message) {
    if (!c) return;
    c->pending_throw = message ? message : "Error";
}

extern "C" HermesAtom hermes_atom_new(JsbayHermesContext *, const char *utf8, size_t len) {
    return new std::string(utf8 ? utf8 : "", len);
}
extern "C" void hermes_atom_free(HermesAtom atom) {
    delete static_cast<std::string *>(atom);
}
extern "C" char *hermes_atom_to_utf8(JsbayHermesContext *, HermesAtom atom) {
    if (!atom) return nullptr;
    return dupCString(*static_cast<std::string *>(atom));
}
extern "C" HermesValue hermes_get_property_atom(JsbayHermesContext *c, HermesValue obj, HermesAtom atom) {
    if (!c || !c->rt || !obj || !atom || !asVal(obj)->isObject()) return nullptr;
    try {
        auto &s = *static_cast<std::string *>(atom);
        auto pid = jsi::PropNameID::forUtf8(*c->rt, reinterpret_cast<const uint8_t *>(s.data()), s.size());
        return retainMove(c, asVal(obj)->getObject(*c->rt).getProperty(*c->rt, pid));
    } catch (...) { return nullptr; }
}
extern "C" bool hermes_set_property_atom(JsbayHermesContext *c, HermesValue obj, HermesAtom atom, HermesValue val) {
    if (!c || !c->rt || !obj || !atom || !asVal(obj)->isObject()) return false;
    try {
        auto &s = *static_cast<std::string *>(atom);
        auto pid = jsi::PropNameID::forUtf8(*c->rt, reinterpret_cast<const uint8_t *>(s.data()), s.size());
        jsi::Value v = val ? jsi::Value(*c->rt, *asVal(val)) : jsi::Value::undefined();
        asVal(obj)->getObject(*c->rt).setProperty(*c->rt, pid, v);
        return true;
    } catch (...) { return false; }
}
extern "C" bool hermes_has_property_atom(JsbayHermesContext *c, HermesValue obj, HermesAtom atom) {
    if (!c || !c->rt || !obj || !atom || !asVal(obj)->isObject()) return false;
    try {
        auto &s = *static_cast<std::string *>(atom);
        auto pid = jsi::PropNameID::forUtf8(*c->rt, reinterpret_cast<const uint8_t *>(s.data()), s.size());
        return asVal(obj)->getObject(*c->rt).hasProperty(*c->rt, pid);
    } catch (...) { return false; }
}


extern "C" bool hermes_is_error(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v) return false;
    return instanceOfGlobal(*c->rt, *asVal(v), "Error");
}
extern "C" HermesValue hermes_new_error(JsbayHermesContext *c, int kind, const char *message) {
    if (!c || !c->rt) return nullptr;
    const char *ctor = "Error";
    switch (kind) {
    case 1: ctor = "TypeError"; break;
    case 2: ctor = "RangeError"; break;
    case 3: ctor = "ReferenceError"; break;
    case 4: ctor = "SyntaxError"; break;
    case 5: ctor = "URIError"; break;
    case 6: ctor = "EvalError"; break;
    case 8: ctor = "AggregateError"; break;
    default: break;
    }
    try {
        auto Ctor = c->rt->global().getPropertyAsFunction(*c->rt, ctor);
        if (kind == 8) {
            // AggregateError(errors, message)
            auto arr = c->rt->global().getPropertyAsFunction(*c->rt, "Array").callAsConstructor(*c->rt);
            return retainMove(c, Ctor.callAsConstructor(*c->rt, arr, message ? message : ""));
        }
        return retainMove(c, Ctor.callAsConstructor(*c->rt, message ? message : ""));
    } catch (...) { return nullptr; }
}

// ---- Round 3: construct / has / delete / keys / instanceof / promise / external / weak ----

static HermesOpResult hopFail(JsbayHermesContextOpaque *c, jsi::Value &&exc) {
    HermesOpResult out{nullptr, nullptr};
    out.exception = retainMove(c, std::move(exc));
    return out;
}
static HermesOpResult hopOk(JsbayHermesContextOpaque *c, jsi::Value &&v) {
    HermesOpResult out{nullptr, nullptr};
    out.value = retainMove(c, std::move(v));
    return out;
}
static HermesBoolOpResult hboolFail(JsbayHermesContextOpaque *c, jsi::Value &&exc) {
    HermesBoolOpResult out{false, nullptr};
    out.exception = retainMove(c, std::move(exc));
    return out;
}
static HermesBoolOpResult hboolOk(bool v) { return HermesBoolOpResult{v, nullptr}; }

static jsi::Value makeTypeError(jsi::Runtime &rt, const char *msg) {
    // Prefer a real TypeError even if the page replaced globalThis.TypeError.
    try {
        auto Error = rt.global().getPropertyAsFunction(rt, "Error");
        auto err = Error.callAsConstructor(rt, msg ? msg : "TypeError");
        if (err.isObject()) {
            err.getObject(rt).setProperty(rt, "name", "TypeError");
        }
        // If page TypeError is still a proper function with [[Construct]] and prototype, prefer it
        // only when its name stays TypeError after construct — otherwise keep the Error+name path.
        try {
            auto TE = rt.global().getPropertyAsFunction(rt, "TypeError");
            auto te = TE.callAsConstructor(rt, msg ? msg : "TypeError");
            if (te.isObject()) {
                auto name = te.getObject(rt).getProperty(rt, "name");
                if (name.isString() && name.getString(rt).utf8(rt) == "TypeError") {
                    return te;
                }
            }
        } catch (...) {}
        return err;
    } catch (...) {
        return jsi::String::createFromUtf8(rt, msg ? msg : "TypeError");
    }
}


static bool hermesIsConstructor(jsi::Runtime &rt, const jsi::Value &v) {
    if (!v.isObject() || !v.getObject(rt).isFunction(rt)) return false;
    auto fn = v.getObject(rt);
    try {
        auto Reflect = rt.global().getPropertyAsObject(rt, "Reflect");
        auto constructFn = Reflect.getPropertyAsFunction(rt, "construct");
        auto Object = rt.global().getPropertyAsFunction(rt, "Object");
        jsi::Array empty(rt, 0);
        // Reflect.construct(Object, [], newTarget) throws if newTarget is not a constructor,
        // without invoking newTarget.
        constructFn.call(rt, Object, empty, fn);
    } catch (...) {
        return false;
    }
    // Hermes incorrectly treats concise methods as constructible. Real constructors either
    // own a `prototype` data property or are bound functions of a constructor.
    try {
        auto hop = rt.global()
            .getPropertyAsFunction(rt, "Object")
            .getPropertyAsObject(rt, "prototype")
            .getPropertyAsFunction(rt, "hasOwnProperty");
        auto has = hop.callWithThis(rt, fn, "prototype");
        if (has.isBool() && has.getBool()) return true;
        auto FProto = rt.global()
            .getPropertyAsFunction(rt, "Function")
            .getPropertyAsObject(rt, "prototype");
        auto toString = FProto.getPropertyAsFunction(rt, "toString");
        auto sVal = toString.callWithThis(rt, fn);
        if (sVal.isString()) {
            std::string s = sVal.getString(rt).utf8(rt);
            if (s.compare(0, 15, "function bound ") == 0) return true;
            if (s.compare(0, 5, "class") == 0 || s.find("class ") != std::string::npos) {
                // class expressions/declarations are constructors even when prototype check races
                return true;
            }
        }
    } catch (...) {
        return true; // Reflect said yes; keep that if introspection fails
    }
    return false;
}

extern "C" HermesOpResult hermes_construct(JsbayHermesContext *c, HermesValue ctor,
                                           const HermesValue *args, size_t argc) {
    HermesOpResult out{nullptr, nullptr};
    if (!c || !c->rt || !ctor) return out;
    try {
        if (!hermesIsConstructor(*c->rt, *asVal(ctor))) {
            return hopFail(c, makeTypeError(*c->rt, "value is not a constructor"));
        }
        auto f = asVal(ctor)->getObject(*c->rt).asFunction(*c->rt);
        std::vector<jsi::Value> argv;
        argv.reserve(argc);
        for (size_t i = 0; i < argc; i++) {
            if (args && args[i]) argv.emplace_back(jsi::Value(*c->rt, *asVal(args[i])));
            else argv.emplace_back(jsi::Value::undefined());
        }
        return hopOk(c, f.callAsConstructor(*c->rt, (const jsi::Value *)argv.data(), argc));
    } catch (const jsi::JSError &e) {
        return hopFail(c, jsi::Value(*c->rt, e.value()));
    } catch (...) {
        return out;
    }
}

extern "C" HermesBoolOpResult hermes_has_in(JsbayHermesContext *c, HermesValue obj, const char *key) {
    if (!c || !c->rt || !obj || !key) return hboolOk(false);
    try {
        if (!asVal(obj)->isObject()) {
            return hboolFail(c, makeTypeError(*c->rt, "cannot use 'in' operator to search for a key in a non-object"));
        }
        bool found = asVal(obj)->getObject(*c->rt).hasProperty(*c->rt, key);
        return hboolOk(found);
    } catch (const jsi::JSError &e) {
        return hboolFail(c, jsi::Value(*c->rt, e.value()));
    } catch (...) {
        return hboolOk(false);
    }
}

extern "C" HermesBoolOpResult hermes_delete_property(JsbayHermesContext *c, HermesValue obj, const char *key) {
    if (!c || !c->rt || !obj || !key) return hboolOk(false);
    try {
        if (asVal(obj)->isNull() || asVal(obj)->isUndefined()) {
            return hboolFail(c, makeTypeError(*c->rt, "Cannot convert undefined or null to object"));
        }
        jsi::Object target = asVal(obj)->isObject()
            ? asVal(obj)->getObject(*c->rt)
            : c->rt->global().getPropertyAsFunction(*c->rt, "Object").call(*c->rt, *asVal(obj)).asObject(*c->rt);
        // Reflect.deleteProperty — non-strict boolean result, trap exceptions.
        auto Reflect = c->rt->global().getPropertyAsObject(*c->rt, "Reflect");
        auto del = Reflect.getPropertyAsFunction(*c->rt, "deleteProperty");
        jsi::Value ok = del.call(*c->rt, target, key);
        return hboolOk(ok.isBool() && ok.getBool());
    } catch (const jsi::JSError &e) {
        return hboolFail(c, jsi::Value(*c->rt, e.value()));
    } catch (...) {
        return hboolOk(false);
    }
}

extern "C" HermesOpResult hermes_own_keys(JsbayHermesContext *c, HermesValue obj) {
    HermesOpResult out{nullptr, nullptr};
    if (!c || !c->rt || !obj) return out;
    try {
        auto &rt = *c->rt;
        if (asVal(obj)->isNull() || asVal(obj)->isUndefined()) {
            return hopFail(c, makeTypeError(rt, "Cannot convert undefined or null to object"));
        }
        jsi::Object target = asVal(obj)->isObject()
            ? asVal(obj)->getObject(rt)
            : rt.global().getPropertyAsFunction(rt, "Object").call(rt, *asVal(obj)).asObject(rt);

        if (!c->pristine_object_keys) {
            return hopFail(c, makeTypeError(rt, "Object.keys unavailable"));
        }

        auto Object = rt.global().getPropertyAsFunction(rt, "Object");
        auto getOwnDesc = Object.getPropertyAsFunction(rt, "getOwnPropertyDescriptor");
        auto defineProp = Object.getPropertyAsFunction(rt, "defineProperty");
        auto delProp = rt.global().getPropertyAsObject(rt, "Reflect").getPropertyAsFunction(rt, "deleteProperty");
        auto ArrayProto = rt.global()
            .getPropertyAsFunction(rt, "Array")
            .getPropertyAsObject(rt, "prototype");

        struct Saved { std::string key; jsi::Value desc; };
        std::vector<Saved> saved;
        for (int i = 0; i < 64; i++) {
            std::string ks = std::to_string(i);
            jsi::Value desc = getOwnDesc.call(rt, ArrayProto, ks);
            if (!desc.isObject()) continue;
            jsi::Object d = desc.getObject(rt);
            if (!d.getProperty(rt, "get").isObject() && !d.getProperty(rt, "set").isObject()) continue;
            saved.push_back(Saved{ks, jsi::Value(rt, desc)});
            delProp.call(rt, ArrayProto, ks);
        }

        jsi::Value keysVal;
        try {
            keysVal = c->pristine_object_keys->call(rt, target);
        } catch (...) {
            for (auto &s : saved) defineProp.call(rt, ArrayProto, s.key, s.desc);
            throw;
        }
        for (auto &s : saved) defineProp.call(rt, ArrayProto, s.key, s.desc);

        // Re-copy via defineProperty into a fresh array so even if Object.keys used [[Set]],
        // the returned array was built while setters were masked; still rebuild for safety.
        if (!keysVal.isObject()) return hopOk(c, jsi::Value(jsi::Array(rt, 0)));
        jsi::Array names = keysVal.getObject(rt).asArray(rt);
        size_t n = names.size(rt);
        std::vector<jsi::Value> elems;
        elems.reserve(n);
        for (size_t i = 0; i < n; i++) elems.emplace_back(names.getValueAtIndex(rt, i));

        // Mask again while defining the result array elements.
        saved.clear();
        for (int i = 0; i < 64; i++) {
            std::string ks = std::to_string(i);
            jsi::Value desc = getOwnDesc.call(rt, ArrayProto, ks);
            if (!desc.isObject()) continue;
            jsi::Object d = desc.getObject(rt);
            if (!d.getProperty(rt, "get").isObject() && !d.getProperty(rt, "set").isObject()) continue;
            saved.push_back(Saved{ks, jsi::Value(rt, desc)});
            delProp.call(rt, ArrayProto, ks);
        }
        jsi::Array result = jsi::Array(rt, 0);
        for (size_t i = 0; i < elems.size(); i++) {
            jsi::Object desc(rt);
            desc.setProperty(rt, "value", elems[i]);
            desc.setProperty(rt, "writable", true);
            desc.setProperty(rt, "enumerable", true);
            desc.setProperty(rt, "configurable", true);
            defineProp.call(rt, result, (double)i, desc);
        }
        result.setProperty(rt, "length", (double)elems.size());
        for (auto &s : saved) defineProp.call(rt, ArrayProto, s.key, s.desc);
        return hopOk(c, jsi::Value(std::move(result)));
    } catch (const jsi::JSError &e) {
        return hopFail(c, jsi::Value(*c->rt, e.value()));
    } catch (...) {
        return out;
    }
}

extern "C" HermesBoolOpResult hermes_instance_of(JsbayHermesContext *c, HermesValue value, HermesValue ctor) {
    if (!c || !c->rt || !value || !ctor) return hboolOk(false);
    try {
        auto checker = c->rt->global()
            .getPropertyAsFunction(*c->rt, "Function")
            .callAsConstructor(*c->rt, "v", "c", "return v instanceof c;")
            .asObject(*c->rt)
            .asFunction(*c->rt);
        jsi::Value r = checker.call(*c->rt, *asVal(value), *asVal(ctor));
        return hboolOk(r.isBool() && r.getBool());
    } catch (const jsi::JSError &e) {
        return hboolFail(c, jsi::Value(*c->rt, e.value()));
    } catch (...) {
        return hboolOk(false);
    }
}

extern "C" bool hermes_promise_create(JsbayHermesContext *c, HermesValue *out_promise,
                                      HermesValue *out_resolve, HermesValue *out_reject) {
    if (!c || !c->rt || !out_promise || !out_resolve || !out_reject) return false;
    *out_promise = *out_resolve = *out_reject = nullptr;
    try {
        struct Cap {
            jsi::Value resolve;
            jsi::Value reject;
            bool got = false;
        };
        auto cap = std::make_shared<Cap>();
        auto executor = jsi::Function::createFromHostFunction(
            *c->rt, jsi::PropNameID::forAscii(*c->rt, "executor"), 2,
            [cap](jsi::Runtime &rt, const jsi::Value &, const jsi::Value *args, size_t count) -> jsi::Value {
                if (count >= 1) cap->resolve = jsi::Value(rt, args[0]);
                if (count >= 2) cap->reject = jsi::Value(rt, args[1]);
                cap->got = true;
                return jsi::Value::undefined();
            });
        auto Promise = c->rt->global().getPropertyAsFunction(*c->rt, "Promise");
        jsi::Value promise = Promise.callAsConstructor(*c->rt, executor);
        if (!cap->got || cap->resolve.isUndefined() || cap->reject.isUndefined()) return false;
        *out_promise = retainMove(c, std::move(promise));
        *out_resolve = retainMove(c, std::move(cap->resolve));
        *out_reject = retainMove(c, std::move(cap->reject));
        {
            std::lock_guard<std::mutex> lock(c->promise_mu);
            c->promise_state[asVal(*out_promise)] = {0, nullptr}; // pending
        }
        return true;
    } catch (...) {
        if (*out_promise) hermes_free_value(c, *out_promise);
        if (*out_resolve) hermes_free_value(c, *out_resolve);
        if (*out_reject) hermes_free_value(c, *out_reject);
        *out_promise = *out_resolve = *out_reject = nullptr;
        return false;
    }
}

extern "C" void hermes_promise_note_settled(JsbayHermesContext *c, HermesValue promise, int state, HermesValue result) {
    if (!c || !promise) return;
    std::lock_guard<std::mutex> lock(c->promise_mu);
    auto it = c->promise_state.find(asVal(promise));
    if (it == c->promise_state.end()) return;
    if (it->second.second) release(c, it->second.second);
    jsi::Value *res = nullptr;
    if (result) {
        res = asVal(retainMove(c, jsi::Value(*c->rt, *asVal(result))));
    }
    it->second = {state, res};
}

extern "C" bool hermes_is_promise(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v) return false;
    try {
        if (!asVal(v)->isObject()) return false;
        auto Promise = c->rt->global().getPropertyAsFunction(*c->rt, "Promise");
        return asVal(v)->getObject(*c->rt).instanceOf(*c->rt, Promise);
    } catch (...) {
        return false;
    }
}

extern "C" int hermes_promise_state(JsbayHermesContext *c, HermesValue v) {
    if (!c || !v) return -1;
    std::lock_guard<std::mutex> lock(c->promise_mu);
    auto it = c->promise_state.find(asVal(v));
    if (it == c->promise_state.end()) {
        // Not a tracked Deferred — still detect Promise objects as unknown (-1) unless pending probe.
        return hermes_is_promise(c, v) ? 0 : -1; // treat unknown JS promises as pending-ish; state/result limited
    }
    return it->second.first;
}

extern "C" HermesValue hermes_promise_result(JsbayHermesContext *c, HermesValue v) {
    if (!c || !v) return nullptr;
    std::lock_guard<std::mutex> lock(c->promise_mu);
    auto it = c->promise_state.find(asVal(v));
    if (it == c->promise_state.end()) return nullptr;
    if (it->second.first != 1 && it->second.first != 2) return nullptr;
    if (!it->second.second) return nullptr;
    return retainMove(c, jsi::Value(*c->rt, *it->second.second));
}

struct HermesExtState : jsi::NativeState {
    void *ptr;
    HermesExternalFinalizer fin;
    JsbayHermesContextOpaque *owner;
    JsbayHermesContextOpaque::PendingFinal *pending;
    HermesExtState(void *p, HermesExternalFinalizer f, JsbayHermesContextOpaque *o,
                   JsbayHermesContextOpaque::PendingFinal *pf)
        : ptr(p), fin(f), owner(o), pending(pf) {}
    ~HermesExtState() override {
        // Teardown fires via pending_finals; avoid double-fire with destructor.
        (void)pending;
        (void)owner;
    }
};

struct HermesExtBox {
    void *ptr;
    HermesExternalFinalizer fin;
};
static void fireHermesExtBox(void *data) {
    auto *bx = static_cast<HermesExtBox *>(data);
    if (bx->fin) bx->fin(bx->ptr);
    bx->fin = nullptr;
    delete bx;
}

extern "C" HermesValue hermes_new_external(JsbayHermesContext *c, void *ptr, HermesExternalFinalizer fin) {
    if (!c || !c->rt) return nullptr;
    try {
        auto *box = new HermesExtBox{ptr, fin};
        auto *pf = new JsbayHermesContextOpaque::PendingFinal{&fireHermesExtBox, box, false};
        {
            std::lock_guard<std::mutex> lock(c->finals_mu);
            c->pending_finals.push_back(pf);
        }
        auto state = std::make_shared<HermesExtState>(ptr, fin, c, pf);
        jsi::Object o(*c->rt);
        o.setNativeState(*c->rt, state);
        return retainMove(c, jsi::Value(std::move(o)));
    } catch (...) {
        return nullptr;
    }
}

extern "C" void *hermes_get_external(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v || !asVal(v)->isObject()) return nullptr;
    try {
        auto o = asVal(v)->getObject(*c->rt);
        if (!o.hasNativeState<HermesExtState>(*c->rt)) return nullptr;
        return o.getNativeState<HermesExtState>(*c->rt)->ptr;
    } catch (...) {
        return nullptr;
    }
}

extern "C" bool hermes_is_external(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v || !asVal(v)->isObject()) return false;
    try {
        return asVal(v)->getObject(*c->rt).hasNativeState<HermesExtState>(*c->rt);
    } catch (...) {
        return false;
    }
}

struct HermesWeakState : jsi::NativeState {
    void *user_data;
    HermesWeakFinalizer cb;
    JsbayHermesContextOpaque *owner;
    JsbayHermesContextOpaque::PendingFinal *pending;
    HermesWeakState(void *u, HermesWeakFinalizer f, JsbayHermesContextOpaque *o,
                    JsbayHermesContextOpaque::PendingFinal *pf)
        : user_data(u), cb(f), owner(o), pending(pf) {}
    ~HermesWeakState() override {
        (void)pending;
        (void)owner;
    }
};

struct HermesWeakBox {
    void *user_data;
    HermesWeakFinalizer cb;
};
static void fireHermesWeakBox(void *data) {
    auto *bx = static_cast<HermesWeakBox *>(data);
    if (bx->cb) bx->cb(bx->user_data);
    bx->cb = nullptr;
    delete bx;
}

extern "C" bool hermes_weak_attach_finalizer(JsbayHermesContext *c, HermesValue target,
                                             void *user_data, HermesWeakFinalizer cb) {
    if (!c || !c->rt || !target || !cb) return false;
    if (!asVal(target)->isObject()) return false;
    try {
        auto *box = new HermesWeakBox{user_data, cb};
        auto *pf = new JsbayHermesContextOpaque::PendingFinal{&fireHermesWeakBox, box, false};
        {
            std::lock_guard<std::mutex> lock(c->finals_mu);
            c->pending_finals.push_back(pf);
        }
        auto state = std::make_shared<HermesWeakState>(user_data, cb, c, pf);
        jsi::Object holder(*c->rt);
        holder.setNativeState(*c->rt, state);
        static std::atomic<uint64_t> seq{0};
        char keybuf[64];
        std::snprintf(keybuf, sizeof(keybuf), "__$jsbay_hermes_Finalizer%llu$__",
                      (unsigned long long)seq.fetch_add(1));
        auto Object = c->rt->global().getPropertyAsObject(*c->rt, "Object");
        auto defProp = Object.getPropertyAsFunction(*c->rt, "defineProperty");
        jsi::Object desc(*c->rt);
        desc.setProperty(*c->rt, "value", holder);
        desc.setProperty(*c->rt, "writable", true);
        desc.setProperty(*c->rt, "enumerable", false);
        desc.setProperty(*c->rt, "configurable", true);
        defProp.call(*c->rt, *asVal(target),
                     jsi::String::createFromUtf8(*c->rt, keybuf), desc);
        return true;
    } catch (...) {
        return false;
    }
}



// ---- Host object via JS Proxy + non-throwing HostFunctions (avoid libjsi exception ABI) ----

struct HermesHostBox {
    int32_t instance_id = 0;
    void *user_data = nullptr;
    HermesHostGetFn get_fn = nullptr;
    HermesHostSetFn set_fn = nullptr;
    HermesHostNamesFn names_fn = nullptr;
    HermesHostFinalizeFn finalize_fn = nullptr;
    bool finalized = false;
    JsbayHermesContextOpaque *ctx = nullptr;
    JsbayHermesContextOpaque::PendingFinal *pending = nullptr;
};

static void fireHermesHostPending(void *data) {
    auto *box = static_cast<HermesHostBox *>(data);
    if (!box) return;
    box->pending = nullptr;
    if (!box->finalized) {
        box->finalized = true;
        auto fin = box->finalize_fn;
        box->finalize_fn = nullptr;
        if (fin) fin(box->user_data);
    }
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

static HermesHostBox *boxFromHostFnThis(jsi::Runtime &rt, const jsi::Value &thisVal) {
    if (!thisVal.isObject()) return nullptr;
    // We stash the box pointer as a number on the helper object's __box field is unsafe.
    // Instead host functions close over box via std::shared_ptr captured in the lambda... 
    // For createFromHostFunction we need the box ptr; callers pass it via a holder object.
    (void)rt;
    return nullptr;
}

static jsi::Value hostValueToJsi(jsi::Runtime &rt, const HermesHostValue &hv) {
    if (hv.tag == 1) return jsi::Value(hv.number);
    if (hv.tag == 2) {
        const char *p = hv.ptr ? hv.ptr : "";
        return jsi::String::createFromUtf8(rt, std::string(p, hv.len));
    }
    return jsi::Value::undefined();
}

static void jsiToHostValue(jsi::Runtime &rt, const jsi::Value &value, HermesHostValue *hv, std::string *str_storage) {
    hv->tag = 0;
    hv->reserved = 0;
    hv->number = 0;
    hv->ptr = nullptr;
    hv->len = 0;
    if (value.isUndefined() || value.isNull()) return;
    if (value.isNumber()) {
        hv->tag = 1;
        hv->number = value.getNumber();
        return;
    }
    if (value.isString()) {
        *str_storage = value.getString(rt).utf8(rt);
        hv->tag = 2;
        hv->ptr = str_storage->data();
        hv->len = str_storage->size();
    }
}

// NativeState carries the box so HostFunctions can recover it without throwing.
class HermesHostNativeState : public jsi::NativeState {
public:
    HermesHostBox *box;
    explicit HermesHostNativeState(HermesHostBox *b) : box(b) {}
    // Do not delete box here — pending_finals / explicit finalize owns it.
    ~HermesHostNativeState() override = default;
};

extern "C" HermesValue hermes_host_object_create(JsbayHermesContext *c, int32_t instance_id, void *user_data,
                                                 HermesHostGetFn get_fn, HermesHostSetFn set_fn,
                                                 HermesHostNamesFn names_fn, HermesHostFinalizeFn finalize_fn) {
    if (!c || !c->rt) return nullptr;
    auto *box = new HermesHostBox{instance_id, user_data, get_fn, set_fn, names_fn, finalize_fn, false, c, nullptr};
    auto *pf = new JsbayHermesContextOpaque::PendingFinal{&fireHermesHostPending, box, false};
    box->pending = pf;
    {
        std::lock_guard<std::mutex> lock(c->finals_mu);
        c->pending_finals.push_back(pf);
    }
    try {
        jsi::Runtime &rt = *c->rt;
        // Holder carries NativeState → box for traps.
        jsi::Object holder(rt);
        holder.setNativeState(rt, std::make_shared<HermesHostNativeState>(box));

        auto getFn = jsi::Function::createFromHostFunction(
            rt, jsi::PropNameID::forAscii(rt, "__ho_get"), 2,
            [](jsi::Runtime &runtime, const jsi::Value &thisVal, const jsi::Value *args, size_t count) -> jsi::Value {
                auto ns = thisVal.isObject() ? thisVal.getObject(runtime).getNativeState(runtime) : nullptr;
                auto *st = dynamic_cast<HermesHostNativeState *>(ns.get());
                jsi::Object out(runtime);
                if (!st || !st->box) {
                    out.setProperty(runtime, "err", jsi::String::createFromUtf8(runtime, "dead host object"));
                    return out;
                }
                std::string name;
                if (count >= 1) {
                    if (args[0].isString()) name = args[0].getString(runtime).utf8(runtime);
                    else if (args[0].isSymbol()) {
                        out.setProperty(runtime, "v", jsi::Value::undefined());
                        return out;
                    } else {
                        name = args[0].toString(runtime).utf8(runtime);
                    }
                }
                HermesHostValue hv{};
                hv.tag = 0;
                if (st->box->get_fn) {
                    if (const char *err = st->box->get_fn(st->box->instance_id, st->box->user_data, name.data(), name.size(), &hv)) {
                        out.setProperty(runtime, "err", jsi::String::createFromUtf8(runtime, err));
                        return out;
                    }
                }
                out.setProperty(runtime, "v", hostValueToJsi(runtime, hv));
                return out;
            });

        auto setFn = jsi::Function::createFromHostFunction(
            rt, jsi::PropNameID::forAscii(rt, "__ho_set"), 3,
            [](jsi::Runtime &runtime, const jsi::Value &thisVal, const jsi::Value *args, size_t count) -> jsi::Value {
                auto ns = thisVal.isObject() ? thisVal.getObject(runtime).getNativeState(runtime) : nullptr;
                auto *st = dynamic_cast<HermesHostNativeState *>(ns.get());
                if (!st || !st->box) return jsi::String::createFromUtf8(runtime, "dead host object");
                std::string name;
                if (count >= 1) {
                    if (args[0].isString()) name = args[0].getString(runtime).utf8(runtime);
                    else name = args[0].toString(runtime).utf8(runtime);
                }
                if (!st->box->set_fn) {
                    return jsi::String::createFromUtf8(runtime, "TypeError: cannot set property");
                }
                HermesHostValue hv{};
                std::string str_storage;
                jsi::Value val = count >= 2 ? jsi::Value(runtime, args[1]) : jsi::Value::undefined();
                jsiToHostValue(runtime, val, &hv, &str_storage);
                if (const char *err = st->box->set_fn(st->box->instance_id, st->box->user_data, name.data(), name.size(), &hv)) {
                    return jsi::String::createFromUtf8(runtime, err);
                }
                return jsi::Value::undefined(); // success
            });

        auto namesFn = jsi::Function::createFromHostFunction(
            rt, jsi::PropNameID::forAscii(rt, "__ho_names"), 0,
            [](jsi::Runtime &runtime, const jsi::Value &thisVal, const jsi::Value *, size_t) -> jsi::Value {
                auto ns = thisVal.isObject() ? thisVal.getObject(runtime).getNativeState(runtime) : nullptr;
                auto *st = dynamic_cast<HermesHostNativeState *>(ns.get());
                if (!st || !st->box || !st->box->names_fn) return jsi::Array(runtime, 0);
                const char **names = nullptr;
                const size_t *lens = nullptr;
                size_t count = 0;
                st->box->names_fn(st->box->instance_id, st->box->user_data, &names, &lens, &count);
                if (!names || count == 0) return jsi::Array(runtime, 0);

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
                jsi::Array arr(runtime, order.size());
                for (size_t i = 0; i < order.size(); i++) {
                    size_t idx = order[i];
                    size_t len = lens ? lens[idx] : std::strlen(names[idx]);
                    arr.setValueAtIndex(runtime, i, jsi::String::createFromUtf8(runtime, std::string(names[idx], len)));
                }
                return arr;
            });

        holder.setProperty(rt, "__get", getFn);
        holder.setProperty(rt, "__set", setFn);
        holder.setProperty(rt, "__names", namesFn);

        rt.global().setProperty(rt, "__jsbay_ho_holder", holder);
        jsi::Value proxy = rt.evaluateJavaScript(
            std::make_shared<jsi::StringBuffer>(R"JS(
(function () {
  var h = globalThis.__jsbay_ho_holder;
  delete globalThis.__jsbay_ho_holder;
  return new Proxy({}, {
    has: function () { return true; },
    getOwnPropertyDescriptor: function () {
      return { configurable: true, enumerable: true, writable: true, value: undefined };
    },
    get: function (_t, prop) {
      if (prop === Symbol.toStringTag) return undefined;
      var r = h.__get(prop);
      if (r && typeof r.err === 'string') {
        var e = new Error(r.err);
        throw e;
      }
      return r ? r.v : undefined;
    },
    set: function (_t, prop, value) {
      var err = h.__set(prop, value);
      if (typeof err === 'string') {
        // Plain Error; message may already start with "TypeError: "
        var e = new Error(err);
        throw e;
      }
      return true;
    },
    ownKeys: function () {
      return h.__names();
    }
  });
})()
)JS"),
            "<jsbay-host-proxy>");
        return retainMove(c, std::move(proxy));
    } catch (const std::exception &e) {
        (void)e;
        std::lock_guard<std::mutex> lock(c->finals_mu);
        auto &vec = c->pending_finals;
        vec.erase(std::remove(vec.begin(), vec.end(), pf), vec.end());
        delete pf;
        delete box;
        return nullptr;
    } catch (...) {
        std::lock_guard<std::mutex> lock(c->finals_mu);
        auto &vec = c->pending_finals;
        vec.erase(std::remove(vec.begin(), vec.end(), pf), vec.end());
        delete pf;
        delete box;
        return nullptr;
    }
}


// ---- Hermes .hbc bytecode ----

struct HbcBuffer : public jsi::Buffer {
    std::vector<uint8_t> data_;
    explicit HbcBuffer(std::vector<uint8_t> &&d) : data_(std::move(d)) {}
    HbcBuffer(const uint8_t *p, size_t n) : data_(p, p + n) {}
    size_t size() const override { return data_.size(); }
    const uint8_t *data() const override { return data_.data(); }
};

static std::string findHermesc() {
    if (const char *env = std::getenv("JSBAY_HERMESC")) {
        if (env[0]) return std::string(env);
    }
    // Relative to repo root (cwd for `zig build test`). Override with JSBAY_HERMESC.
    const char *candidates[] = {
        "vendor/hermes-install/bin/hermesc",
        nullptr,
    };
    for (int i = 0; candidates[i]; ++i) {
        if (access(candidates[i], X_OK) == 0) return candidates[i];
    }
    return "hermesc";
}

extern "C" HermesCompileResult hermes_compile_bytecode(const char *src, size_t src_len,
                                                       const char *filename, size_t filename_len) {
    HermesCompileResult out{nullptr, 0, nullptr};
    if (!src) {
        out.err = dupCString("null source");
        return out;
    }
    // Prefer a temp path whose basename matches the caller's filename so -g1
    // debug info / stack traces carry "my-module.js" etc.
    std::string base = "script.js";
    if (filename && filename_len) {
        std::string f(filename, filename_len);
        auto slash = f.find_last_of("/\\");
        base = (slash == std::string::npos) ? f : f.substr(slash + 1);
        if (base.empty()) base = "script.js";
        // Sanitize for shell / filesystem: strip <>:"|?* and whitespace.
        std::string clean;
        for (char ch : base) {
            if (ch == '<' || ch == '>' || ch == ':' || ch == '"' || ch == '|' ||
                ch == '?' || ch == '*' || ch == ' ' || ch == '\t' || ch == '\n') {
                clean.push_back('_');
            } else {
                clean.push_back(ch);
            }
        }
        base = clean.empty() ? "script.js" : clean;
    }
    std::string js_path = std::string("/tmp/jsbay-hbc-XXXXXX-") + base;
    // mkstemps needs the template to end with the suffix after XXXXXX
    // Use a fixed suffix ".js" template then rename to include basename.
    char js_tmpl[] = "/tmp/jsbay-hbc-XXXXXX.js";
    char hbc_path[] = "/tmp/jsbay-hbc-XXXXXX.hbc";
    int js_fd = mkstemps(js_tmpl, 3);
    if (js_fd < 0) {
        out.err = dupCString("mkstemps js failed");
        return out;
    }
    int hbc_fd = mkstemps(hbc_path, 4);
    if (hbc_fd < 0) {
        close(js_fd);
        unlink(js_tmpl);
        out.err = dupCString("mkstemps hbc failed");
        return out;
    }
    close(hbc_fd);
    unlink(hbc_path);

    // Rename js temp to end with caller basename for debug info.
    js_path = std::string(js_tmpl);
    {
        std::string renamed = std::string(js_tmpl);
        // replace trailing .js with -basename (keep unique XXXXXX prefix)
        if (renamed.size() > 3) renamed = renamed.substr(0, renamed.size() - 3) + "-" + base;
        if (rename(js_tmpl, renamed.c_str()) == 0) js_path = renamed;
    }

    ssize_t wrote = write(js_fd, src, src_len);
    close(js_fd);
    if (wrote < 0 || (size_t)wrote != src_len) {
        unlink(js_path.c_str());
        out.err = dupCString("write source failed");
        return out;
    }

    std::string hermesc = findHermesc();
    // -g1 embeds location info (incl. source path basename) for stack traces.
    // Use fork/exec (not system()) so filenames with shell metacharacters are safe.
    std::string out_arg = std::string("-out=") + hbc_path;
    char err_tmpl[] = "/tmp/jsbay-hermesc-XXXXXX.err";
    int err_fd = mkstemps(err_tmpl, 4);
    std::string err_path = (err_fd >= 0) ? std::string(err_tmpl) : std::string();
    pid_t pid = fork();
    int rc = -1;
    if (pid == 0) {
        if (err_fd >= 0) {
            dup2(err_fd, 2);
            close(err_fd);
        }
        execl(hermesc.c_str(), hermesc.c_str(), "-O0", "-g1", "-emit-binary",
              out_arg.c_str(), js_path.c_str(), (char *)nullptr);
        _exit(127);
    } else if (pid > 0) {
        if (err_fd >= 0) close(err_fd);
        int status = 0;
        waitpid(pid, &status, 0);
        rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    } else {
        if (err_fd >= 0) close(err_fd);
        if (!err_path.empty()) unlink(err_path.c_str());
        unlink(js_path.c_str());
        out.err = dupCString("fork hermesc failed");
        return out;
    }
    unlink(js_path.c_str());
    if (rc != 0) {
        std::string err = "hermesc failed";
        if (!err_path.empty()) {
            std::ifstream ef(err_path);
            if (ef) {
                std::ostringstream ss;
                ss << ef.rdbuf();
                std::string body = ss.str();
                if (!body.empty()) err = body;
            }
            unlink(err_path.c_str());
        }
        out.err = dupCString(err);
        unlink(hbc_path);
        return out;
    }
    if (!err_path.empty()) unlink(err_path.c_str());
    std::ifstream in(hbc_path, std::ios::binary);
    if (!in) {
        out.err = dupCString("failed to read hermesc output");
        unlink(hbc_path);
        return out;
    }
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    in.close();
    unlink(hbc_path);
    if (bytes.empty()) {
        out.err = dupCString("empty hermesc output");
        return out;
    }
    out.bytes = static_cast<uint8_t *>(std::malloc(bytes.size()));
    if (!out.bytes) {
        out.err = dupCString("oom");
        return out;
    }
    std::memcpy(out.bytes, bytes.data(), bytes.size());
    out.len = bytes.size();
    return out;
}

extern "C" void hermes_compile_result_free(HermesCompileResult r) {
    std::free(r.bytes);
    std::free(r.err);
}

extern "C" HermesEvalResult hermes_run_bytecode(JsbayHermesContext *ctx, const uint8_t *bytes, size_t len) {
    int ignore = 0;
    return hermes_run_bytecode_ex(ctx, bytes, len, &ignore);
}

extern "C" HermesEvalResult hermes_run_bytecode_ex(JsbayHermesContext *c, const uint8_t *bytes, size_t len,
                                                   int *out_decode_failed) {
    HermesEvalResult out{nullptr, nullptr};
    if (out_decode_failed) *out_decode_failed = 0;
    if (!c || !c->rt) {
        out.err = dupCString("no context");
        if (out_decode_failed) *out_decode_failed = 1;
        return out;
    }
    if (!bytes || len == 0) {
        out.err = dupCString("bytecode buffer is empty");
        if (out_decode_failed) *out_decode_failed = 1;
        return out;
    }
    try {
        auto buf = std::make_shared<HbcBuffer>(bytes, len);
        jsi::Value result = c->rt->evaluateJavaScript(std::move(buf), "<bytecode>");
        if (result.isUndefined() || result.isNull()) return out;
        out.result = dupCString(valueToDisplayString(*c->rt, result));
    } catch (const jsi::JSError &e) {
        // Hermes throws JSError both for corrupt bytecode and for script throws.
        // Heuristic: messages mentioning bytecode/HBC/magic/format => decode_failed.
        std::string msg = e.getMessage();
        std::string stack;
        try { stack = e.getStack(); } catch (...) {}
        if (!stack.empty()) {
            msg.push_back('\n');
            msg += stack;
        }
        bool decode = false;
        const char *needles[] = {"bytecode", "Bytecode", "HBC", "magic", "buffer", "format", "truncated", nullptr};
        for (int i = 0; needles[i]; ++i) {
            if (msg.find(needles[i]) != std::string::npos) { decode = true; break; }
        }
        if (stack.empty() && len < 64) decode = true;
        if (out_decode_failed) *out_decode_failed = decode ? 1 : 0;
        out.err = dupCString(msg);
    } catch (const std::exception &e) {
        if (out_decode_failed) *out_decode_failed = 1;
        out.err = dupCString(e.what());
    } catch (...) {
        if (out_decode_failed) *out_decode_failed = 1;
        out.err = dupCString("unknown bytecode error");
    }
    return out;
}


// ---- NativeHandle (opaque + call + finalize) ----
struct HermesNhBox {
    void *handle_data = nullptr;
    HermesNativeFn call_fn = nullptr;
    HermesNhFinalize finalize = nullptr;
    JsbayHermesContextOpaque *owner = nullptr;
};
static void fireHermesNhBox(void *data) {
    auto *bx = static_cast<HermesNhBox *>(data);
    if (!bx) return;
    if (bx->finalize) {
        auto fin = bx->finalize;
        bx->finalize = nullptr;
        fin(bx->handle_data);
    }
    bx->handle_data = nullptr;
    delete bx;
}
// Shared claim: NativeState may finalize GC-precisely; pending_finals always
// owns claim lifetime (delete). Never delete claim from NativeState.
struct HermesNhClaim {
    HermesNhBox *box = nullptr;
    bool fired = false;
};
static void fireHermesNhClaim(void *data) {
    auto *cl = static_cast<HermesNhClaim *>(data);
    if (!cl) return;
    if (!cl->fired) {
        cl->fired = true;
        if (cl->box) {
            fireHermesNhBox(cl->box);
            cl->box = nullptr;
        }
    }
    delete cl; // pending_finals path only
}
struct HermesNhState : jsi::NativeState {
    HermesNhClaim *claim;
    explicit HermesNhState(HermesNhClaim *cl) : claim(cl) {}
    ~HermesNhState() override {
        // GC-precise: claim finalize without freeing the claim shell (teardown owns it).
        if (!claim || claim->fired) return;
        claim->fired = true;
        if (claim->box) {
            fireHermesNhBox(claim->box);
            claim->box = nullptr;
        }
        claim = nullptr; // do not touch again; pending_finals will delete shell
    }
};

extern "C" HermesValue hermes_native_handle_create(JsbayHermesContext *c, void *handle_data,
                                                   HermesNativeFn call_fn, HermesNhFinalize finalize) {
    if (!c || !c->rt || !handle_data) return nullptr;
    try {
        auto *box = new HermesNhBox{handle_data, call_fn, finalize, c};
        auto *claim = new HermesNhClaim{box, false};
        // pending_finals owns the claim lifetime if NativeState never runs first.
        auto *pf = new JsbayHermesContextOpaque::PendingFinal{&fireHermesNhClaim, claim, false};
        {
            std::lock_guard<std::mutex> lock(c->finals_mu);
            c->pending_finals.push_back(pf);
        }
        auto state = std::make_shared<HermesNhState>(claim);
        if (call_fn) {
            auto host = jsi::Function::createFromHostFunction(
                *c->rt, jsi::PropNameID::forUtf8(*c->rt, "NativeHandle"), 0,
                [box](jsi::Runtime &rt, const jsi::Value &thisVal, const jsi::Value *args, size_t count) -> jsi::Value {
                    JsbayHermesContextOpaque *ctx = box->owner;
                    if (!ctx || !box->call_fn) return jsi::Value::undefined();
                    std::vector<HermesValue> argv;
                    argv.reserve(count);
                    for (size_t i = 0; i < count; ++i) argv.push_back(retainMove(ctx, jsi::Value(rt, args[i])));
                    HermesValue this_h = retainMove(ctx, jsi::Value(rt, thisVal));
                    ctx->pending_throw.clear();
                    HermesValue out = box->call_fn(ctx, this_h, argv.data(), count, box->handle_data);
                    hermes_free_value(ctx, this_h);
                    for (auto a : argv) hermes_free_value(ctx, a);
                    if (!ctx->pending_throw.empty()) {
                        std::string msg = ctx->pending_throw;
                        ctx->pending_throw.clear();
                        if (out) hermes_free_value(ctx, out);
                        throw jsi::JSError(rt, msg);
                    }
                    if (!out) return jsi::Value::undefined();
                    jsi::Value result(rt, *asVal(out));
                    hermes_free_value(ctx, out);
                    return result;
                });
            // Attach NativeState on a property holder? HostFunction may not support setNativeState.
            // Store mapping: also set a hidden prop with an object carrying NativeState.
            jsi::Object holder(*c->rt);
            holder.setNativeState(*c->rt, state);
            host.setProperty(*c->rt, jsi::PropNameID::forUtf8(*c->rt, "__jsbay_nh"), holder);
            return retainMove(c, jsi::Value(std::move(host)));
        }
        jsi::Object o(*c->rt);
        o.setNativeState(*c->rt, state);
        return retainMove(c, jsi::Value(std::move(o)));
    } catch (...) {
        return nullptr;
    }
}

extern "C" void *hermes_native_handle_get(JsbayHermesContext *c, HermesValue v) {
    if (!c || !c->rt || !v || !asVal(v)->isObject()) return nullptr;
    try {
        auto o = asVal(v)->getObject(*c->rt);
        if (o.hasNativeState<HermesNhState>(*c->rt)) {
            auto *st = o.getNativeState<HermesNhState>(*c->rt).get();
            if (!st || !st->claim || !st->claim->box) return nullptr;
            return st->claim->box->handle_data;
        }
        // Callable path: look at __jsbay_nh holder
        auto pid = jsi::PropNameID::forUtf8(*c->rt, "__jsbay_nh");
        if (o.hasProperty(*c->rt, pid)) {
            auto hv = o.getProperty(*c->rt, pid);
            if (hv.isObject()) {
                auto ho = hv.getObject(*c->rt);
                if (ho.hasNativeState<HermesNhState>(*c->rt)) {
                    auto *st = ho.getNativeState<HermesNhState>(*c->rt).get();
                    if (!st || !st->claim || !st->claim->box) return nullptr;
                    return st->claim->box->handle_data;
                }
            }
        }
        return nullptr;
    } catch (...) {
        return nullptr;
    }
}

extern "C" bool hermes_native_handle_is(JsbayHermesContext *c, HermesValue v) {
    return hermes_native_handle_get(c, v) != nullptr;
}

facebook::hermes::HermesRuntime *hermes_context_rt(JsbayHermesContext *c) {
    return c ? c->rt : nullptr;
}
static void hermes_flush_pending_rejections(JsbayHermesContext *c) {
    if (!c || !c->rejection_fn) return;
    auto pending = std::move(c->pending_rejections);
    c->pending_rejections.clear();
    for (auto &p : pending) {
        try {
            c->rejection_fn(c->rejection_instance_id, p.first, p.second.c_str(), p.second.size(),
                            c->rejection_ud);
        } catch (...) {
        }
    }
}

void hermes_context_drain_microtasks(JsbayHermesContext *c) {
    if (!c || !c->rt) return;
    try { c->rt->drainMicrotasks(); } catch (...) {}
    hermes_flush_pending_rejections(c);
}

extern "C" void hermes_report_unhandled_rejection(JsbayHermesContext *ctx, const char *message) {
    if (!ctx || !ctx->rejection_fn) return;
    ctx->pending_rejections.emplace_back(false, message ? message : "Promise rejected");
}

extern "C" bool hermes_set_rejection_tracker(JsbayHermesContext *ctx, int32_t instance_id,
                                              HermesRejectionTrackerFn fn, void *ud) {
    if (!ctx || !ctx->rt) return false;
    ctx->rejection_fn = fn;
    ctx->rejection_ud = ud;
    ctx->rejection_instance_id = instance_id;
    if (!fn) return true;

    if (!ctx->rejection_hook_installed) {
        try {
            auto &rt = *ctx->rt;
            auto hi = rt.global().getProperty(rt, "HermesInternal");
            if (!hi.isObject()) {
                return true;
            }
            auto hiObj = hi.getObject(rt);
            auto st = rt.global().getProperty(rt, "setTimeout");
            auto ct = rt.global().getProperty(rt, "clearTimeout");
            if (st.isObject() && st.getObject(rt).isFunction(rt)) {
                auto orig = std::make_shared<jsi::Function>(st.getObject(rt).getFunction(rt));
                std::shared_ptr<jsi::Function> origClear;
                if (ct.isObject() && ct.getObject(rt).isFunction(rt)) {
                    origClear = std::make_shared<jsi::Function>(ct.getObject(rt).getFunction(rt));
                }
                auto wrap = jsi::Function::createFromHostFunction(
                    rt, jsi::PropNameID::forAscii(rt, "setTimeout"), 2,
                    [orig, ctx](jsi::Runtime &rt0, const jsi::Value &, const jsi::Value *args,
                                size_t count) -> jsi::Value {
                        if (count >= 2 && ctx->rejection_fn && args[1].isNumber()) {
                            double d = args[1].getNumber();
                            if ((d == 100.0 || d == 2000.0) &&
                                args[0].isObject() && args[0].getObject(rt0).isFunction(rt0)) {
                                auto cancelled = std::make_shared<bool>(false);
                                int32_t tid = ctx->rejection_timer_next++;
                                if (tid <= 0) tid = ctx->rejection_timer_next = 1;
                                ctx->rejection_timer_cancelled[tid] = cancelled;
                                auto fn = std::make_shared<jsi::Function>(
                                    args[0].getObject(rt0).getFunction(rt0));
                                // Defer one extra microtask turn so a `.catch` attached in the
                                // same drain (Escargot/QJS semantics) can clearTimeout first.
                                rt0.queueMicrotask(jsi::Function::createFromHostFunction(
                                    rt0, jsi::PropNameID::forAscii(rt0, "rejTO1"), 0,
                                    [cancelled, fn, ctx, tid](jsi::Runtime &rt1, const jsi::Value &,
                                                              const jsi::Value *, size_t) -> jsi::Value {
                                        if (*cancelled) {
                                            ctx->rejection_timer_cancelled.erase(tid);
                                            return jsi::Value::undefined();
                                        }
                                        rt1.queueMicrotask(jsi::Function::createFromHostFunction(
                                            rt1, jsi::PropNameID::forAscii(rt1, "rejTO2"), 0,
                                            [cancelled, fn, ctx, tid](jsi::Runtime &rt2, const jsi::Value &,
                                                                      const jsi::Value *, size_t) -> jsi::Value {
                                                ctx->rejection_timer_cancelled.erase(tid);
                                                if (*cancelled) return jsi::Value::undefined();
                                                try {
                                                    fn->call(rt2);
                                                } catch (...) {
                                                }
                                                return jsi::Value::undefined();
                                            }));
                                        return jsi::Value::undefined();
                                    }));
                                return jsi::Value((double)tid);
                            }
                        }
                        return orig->call(rt0, args, count);
                    });
                rt.global().setProperty(rt, "setTimeout", wrap);
                auto wrapClear = jsi::Function::createFromHostFunction(
                    rt, jsi::PropNameID::forAscii(rt, "clearTimeout"), 1,
                    [origClear, ctx](jsi::Runtime &rt0, const jsi::Value &, const jsi::Value *args,
                                     size_t count) -> jsi::Value {
                        if (count >= 1 && args[0].isNumber()) {
                            int32_t tid = (int32_t)args[0].getNumber();
                            auto it = ctx->rejection_timer_cancelled.find(tid);
                            if (it != ctx->rejection_timer_cancelled.end()) {
                                *it->second = true;
                                ctx->rejection_timer_cancelled.erase(it);
                                return jsi::Value::undefined();
                            }
                        }
                        if (origClear) return origClear->call(rt0, args, count);
                        return jsi::Value::undefined();
                    });
                rt.global().setProperty(rt, "clearTimeout", wrapClear);
            }

            auto enable = hiObj.getProperty(rt, "enablePromiseRejectionTracker");
            if (enable.isObject() && enable.getObject(rt).isFunction(rt)) {
                auto hostUnhandled = jsi::Function::createFromHostFunction(
                    rt, jsi::PropNameID::forAscii(rt, "onUnhandled"), 2,
                    [ctx](jsi::Runtime &rt0, const jsi::Value &, const jsi::Value *args,
                          size_t count) -> jsi::Value {
                        std::string msg = "Promise rejected";
                        if (count >= 2) {
                            try {
                                if (args[1].isString()) msg = args[1].getString(rt0).utf8(rt0);
                                else if (args[1].isObject()) {
                                    auto o = args[1].getObject(rt0);
                                    if (o.hasProperty(rt0, "message")) {
                                        auto m = o.getProperty(rt0, "message");
                                        if (m.isString()) msg = m.getString(rt0).utf8(rt0);
                                    }
                                    if (msg == "Promise rejected")
                                        msg = args[1].toString(rt0).utf8(rt0);
                                } else {
                                    msg = args[1].toString(rt0).utf8(rt0);
                                }
                            } catch (...) {
                            }
                        }
                        if (ctx->rejection_fn)
                            ctx->pending_rejections.emplace_back(false, msg);
                        return jsi::Value::undefined();
                    });
                auto hostHandled = jsi::Function::createFromHostFunction(
                    rt, jsi::PropNameID::forAscii(rt, "onHandled"), 2,
                    [ctx](jsi::Runtime &rt0, const jsi::Value &, const jsi::Value *args,
                          size_t count) -> jsi::Value {
                        std::string msg = "Promise rejection handled";
                        if (count >= 2) {
                            try {
                                if (args[1].isString()) msg = args[1].getString(rt0).utf8(rt0);
                                else msg = args[1].toString(rt0).utf8(rt0);
                            } catch (...) {
                            }
                        }
                        if (ctx->rejection_fn)
                            ctx->pending_rejections.emplace_back(true, msg);
                        return jsi::Value::undefined();
                    });
                jsi::Object opts(rt);
                opts.setProperty(rt, "allRejections", true);
                opts.setProperty(rt, "onUnhandled", hostUnhandled);
                opts.setProperty(rt, "onHandled", hostHandled);
                enable.getObject(rt).getFunction(rt).callWithThis(rt, hiObj, opts);
                ctx->rejection_hook_installed = true;
            }
        } catch (const std::exception &) {
        } catch (...) {
        }
    }
    return true;
}
