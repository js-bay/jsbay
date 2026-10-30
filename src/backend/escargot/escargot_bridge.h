/* Native Escargot C bridge for jsbay (-Dbackend=escargot). Not a JSC shim. */
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EscargotRuntimeOpaque EscargotRuntime;
typedef struct EscargotContextOpaque EscargotContext;
/* ValueRef* as opaque; never a JSC JSValueRef. */
typedef void *EscargotValue;

typedef struct {
    char *result; /* heap, caller frees; NULL if none */
    char *err;    /* heap, caller frees; NULL if none */
} EscargotEvalResult;

void escargot_globals_ensure(void);
/* Per-thread TLS/GC for Escargot engine_thread (Globals::initializeThread/finalizeThread). */
void escargot_thread_enter(void);
void escargot_thread_leave(void);
bool escargot_supports_threading(void);

EscargotRuntime *escargot_runtime_new(void);
void escargot_runtime_free(EscargotRuntime *rt);
void escargot_runtime_gc(EscargotRuntime *rt);

EscargotContext *escargot_context_new(EscargotRuntime *rt);
void escargot_context_free(EscargotContext *ctx);

void escargot_context_set_opaque(EscargotContext *ctx, void *opaque);
void *escargot_context_get_opaque(EscargotContext *ctx);

EscargotEvalResult escargot_eval(EscargotContext *ctx, const char *src, size_t src_len,
                                 const char *filename, size_t filename_len);
void escargot_eval_result_free(EscargotEvalResult r);

EscargotValue escargot_undefined(void);
EscargotValue escargot_null(void);
EscargotValue escargot_new_bool(bool v);
EscargotValue escargot_new_int32(int32_t v);
EscargotValue escargot_new_float64(double v);
EscargotValue escargot_new_string(EscargotContext *ctx, const char *utf8, size_t len);
EscargotValue escargot_new_object(EscargotContext *ctx);
EscargotValue escargot_new_array(EscargotContext *ctx, uint32_t len);

EscargotValue escargot_dup(EscargotContext *ctx, EscargotValue v);
void escargot_free_value(EscargotContext *ctx, EscargotValue v);

bool escargot_is_undefined(EscargotValue v);
bool escargot_is_null(EscargotValue v);
bool escargot_is_bool(EscargotValue v);
bool escargot_is_number(EscargotValue v);
bool escargot_is_string(EscargotValue v);
bool escargot_is_object(EscargotValue v);
bool escargot_is_array(EscargotContext *ctx, EscargotValue v);
bool escargot_is_function(EscargotContext *ctx, EscargotValue v);
bool escargot_is_constructor(EscargotContext *ctx, EscargotValue v);

bool escargot_to_bool(EscargotValue v);
int32_t escargot_to_int32(EscargotValue v);
double escargot_to_float64(EscargotValue v);

/* Heap UTF-8; caller frees with free(). NULL on failure. */
char *escargot_value_to_utf8(EscargotContext *ctx, EscargotValue v);
char *escargot_value_to_utf8_n(EscargotContext *ctx, EscargotValue v, size_t *out_len);
char *escargot_json_stringify(EscargotContext *ctx, EscargotValue v);
EscargotValue escargot_json_parse(EscargotContext *ctx, const char *utf8, size_t len);

EscargotValue escargot_get_global(EscargotContext *ctx);
EscargotValue escargot_get_property(EscargotContext *ctx, EscargotValue obj, const char *key);
bool escargot_set_property(EscargotContext *ctx, EscargotValue obj, const char *key, EscargotValue val);
bool escargot_has_property(EscargotContext *ctx, EscargotValue obj, const char *key);

EscargotValue escargot_call(EscargotContext *ctx, EscargotValue fn, EscargotValue this_val,
                            const EscargotValue *args, size_t argc, char **out_err);

void escargot_process_pending_jobs(EscargotContext *ctx);

/* Host promise rejection tracker. fn=NULL clears. Reports after microtask drain. */
typedef void (*EscargotRejectionTrackerFn)(int32_t instance_id, bool handled,
                                           const char *reason, size_t reason_len, void *userdata);
void escargot_set_rejection_tracker(EscargotContext *ctx, int32_t instance_id,
                                    EscargotRejectionTrackerFn fn, void *userdata);

/* ---- Value-returning eval (typed_eval) ---- */
typedef struct {
    EscargotValue value; /* retained; NULL if threw/failed */
    char *err;           /* heap error text if threw; else NULL */
} EscargotValueResult;

EscargotValueResult escargot_eval_value(EscargotContext *ctx, const char *src, size_t src_len,
                                        const char *filename, size_t filename_len);
void escargot_value_result_free_err(EscargotValueResult r); /* frees err only; value stays retained */

/* ---- Index / length ---- */
EscargotValue escargot_get_index(EscargotContext *ctx, EscargotValue obj, uint32_t index);
bool escargot_set_index(EscargotContext *ctx, EscargotValue obj, uint32_t index, EscargotValue val);
bool escargot_set_length(EscargotContext *ctx, EscargotValue obj, uint32_t length);
bool escargot_define_data_property(EscargotContext *ctx, EscargotValue obj, const char *key,
                                   EscargotValue val, bool writable);
EscargotValue escargot_new_symbol(EscargotContext *ctx, const char *desc, size_t desc_len);
EscargotValue escargot_symbol_for(EscargotContext *ctx, const char *key, size_t key_len);
bool escargot_strict_equal(EscargotContext *ctx, EscargotValue a, EscargotValue b);

uint32_t escargot_get_length(EscargotContext *ctx, EscargotValue obj); /* 0 if missing */

/* ---- Date / BigInt / Map / Set ---- */
bool escargot_is_date(EscargotContext *ctx, EscargotValue v);
int64_t escargot_date_to_ms(EscargotContext *ctx, EscargotValue v); /* 0 on fail */
EscargotValue escargot_new_date(EscargotContext *ctx, int64_t ms);

bool escargot_is_bigint(EscargotValue v);
EscargotValue escargot_new_bigint_i64(int64_t v);
EscargotValue escargot_new_bigint_u64(uint64_t v);
bool escargot_bigint_to_i64(EscargotValue v, int64_t *out);
bool escargot_bigint_to_u64(EscargotValue v, uint64_t *out);

bool escargot_is_map(EscargotValue v);
bool escargot_is_set(EscargotValue v);
EscargotValue escargot_new_map(EscargotContext *ctx);
EscargotValue escargot_new_set(EscargotContext *ctx);
bool escargot_map_set(EscargotContext *ctx, EscargotValue map, EscargotValue key, EscargotValue val);
bool escargot_set_add(EscargotContext *ctx, EscargotValue set, EscargotValue val);
size_t escargot_map_size(EscargotContext *ctx, EscargotValue map);
size_t escargot_set_size(EscargotContext *ctx, EscargotValue set);
/* JSON [["k",v],...] for Map; JSON [v,...] for Set. Caller frees. */
char *escargot_map_to_json(EscargotContext *ctx, EscargotValue map);
char *escargot_set_to_json(EscargotContext *ctx, EscargotValue set);
EscargotValue escargot_new_map_from_json(EscargotContext *ctx, const char *json, size_t len);
EscargotValue escargot_new_set_from_json(EscargotContext *ctx, const char *json, size_t len);

typedef bool (*EscargotMapForEachFn)(EscargotContext *ctx, void *cb_ctx, EscargotValue key, EscargotValue val);
typedef bool (*EscargotSetForEachFn)(EscargotContext *ctx, void *cb_ctx, EscargotValue val);
bool escargot_map_foreach(EscargotContext *ctx, EscargotValue map, void *cb_ctx, EscargotMapForEachFn cb);
bool escargot_set_foreach(EscargotContext *ctx, EscargotValue set, void *cb_ctx, EscargotSetForEachFn cb);

/* ---- ArrayBuffer / TypedArray / DataView ---- */
bool escargot_is_array_buffer(EscargotValue v);
bool escargot_is_typed_array(EscargotValue v);
bool escargot_is_data_view(EscargotValue v);
EscargotValue escargot_new_array_buffer_copy(EscargotContext *ctx, const uint8_t *bytes, size_t len);
/* No-copy: deleter(user_data) called when buffer collected. */
typedef void (*EscargotBufferDeleter)(void *user_data);
EscargotValue escargot_new_array_buffer_no_copy(EscargotContext *ctx, uint8_t *bytes, size_t len,
                                                 EscargotBufferDeleter deleter, void *user_data);
uint8_t *escargot_array_buffer_data(EscargotContext *ctx, EscargotValue ab, size_t *out_len);
/* kind: 0=Int8 1=Uint8 2=Uint8C 3=Int16 4=Uint16 5=Int32 6=Uint32 7=Float32 8=Float64 9=BigInt64 10=BigUint64 */
EscargotValue escargot_new_typed_array(EscargotContext *ctx, EscargotValue ab, int kind,
                                       size_t byte_offset, size_t length);
uint8_t *escargot_typed_array_data(EscargotContext *ctx, EscargotValue ta, size_t *byte_offset,
                                   size_t *byte_length, int *kind);
EscargotValue escargot_new_data_view(EscargotContext *ctx, EscargotValue ab, size_t byte_offset, size_t byte_length);
uint8_t *escargot_data_view_data(EscargotContext *ctx, EscargotValue dv, size_t *byte_offset, size_t *byte_length);

/* ---- Native function ---- */
typedef EscargotValue (*EscargotNativeFn)(EscargotContext *ctx, EscargotValue this_val,
                                          const EscargotValue *args, size_t argc, void *user_data);
EscargotValue escargot_make_function(EscargotContext *ctx, const char *name, EscargotNativeFn fn, void *user_data);

/* ---- Atoms (AtomicStringRef* as opaque handle) ---- */
typedef void *EscargotAtom;
EscargotAtom escargot_atom_new(EscargotContext *ctx, const char *utf8, size_t len);
void escargot_atom_free(EscargotAtom atom); /* no-op: AtomicStringRef is VM-lifetime */
char *escargot_atom_to_utf8(EscargotContext *ctx, EscargotAtom atom); /* heap; caller frees */
EscargotValue escargot_get_property_atom(EscargotContext *ctx, EscargotValue obj, EscargotAtom atom);
bool escargot_set_property_atom(EscargotContext *ctx, EscargotValue obj, EscargotAtom atom, EscargotValue val);
bool escargot_has_property_atom(EscargotContext *ctx, EscargotValue obj, EscargotAtom atom);

/* Throw a JS Error with message from native callback */
void escargot_throw(EscargotContext *ctx, const char *message);

/* ---- Errors ---- */
bool escargot_is_error(EscargotValue v);
/* kind: 0=Error 1=TypeError 2=RangeError 3=SyntaxError 4=ReferenceError 5=URIError 6=EvalError */
EscargotValue escargot_new_error(EscargotContext *ctx, int kind, const char *message);

/* ---- Op results (value + optional retained exception) ---- */
typedef struct {
    EscargotValue value;
    EscargotValue exception;
} EscargotOpResult;

typedef struct {
    bool value;
    EscargotValue exception;
} EscargotBoolOpResult;

EscargotOpResult escargot_set_property_result(EscargotContext *ctx, EscargotValue obj, const char *key, EscargotValue val);
EscargotOpResult escargot_construct(EscargotContext *ctx, EscargotValue ctor,
                                    const EscargotValue *args, size_t argc);
EscargotBoolOpResult escargot_has_in(EscargotContext *ctx, EscargotValue obj, const char *key);
EscargotBoolOpResult escargot_delete_property(EscargotContext *ctx, EscargotValue obj, const char *key);
EscargotOpResult escargot_own_keys(EscargotContext *ctx, EscargotValue obj);
EscargotBoolOpResult escargot_instance_of(EscargotContext *ctx, EscargotValue value, EscargotValue ctor);

/* Promise Deferred host hooks */
bool escargot_promise_create(EscargotContext *ctx, EscargotValue *out_promise,
                             EscargotValue *out_resolve, EscargotValue *out_reject);
bool escargot_is_promise(EscargotContext *ctx, EscargotValue v);
/* -1 = not a promise; 0 pending; 1 fulfilled; 2 rejected */
int escargot_promise_state(EscargotContext *ctx, EscargotValue v);
EscargotValue escargot_promise_result(EscargotContext *ctx, EscargotValue v);

/* External opaque pointer wrapper */
typedef void (*EscargotExternalFinalizer)(void *ptr);
EscargotValue escargot_new_external(EscargotContext *ctx, void *ptr, EscargotExternalFinalizer fin);
void *escargot_get_external(EscargotContext *ctx, EscargotValue v);
bool escargot_is_external(EscargotContext *ctx, EscargotValue v);

/* Weak finalizer holder attach (N-API-style) */
typedef void (*EscargotWeakFinalizer)(void *user_data);
bool escargot_weak_attach_finalizer(EscargotContext *ctx, EscargotValue target,
                                    void *user_data, EscargotWeakFinalizer cb);

/* Host object (JSI-style get/set/enumerate traps) */
typedef struct EscargotHostValue {
    uint32_t tag; /* 0 undef, 1 number, 2 string */
    uint32_t reserved;
    double number;
    const char *ptr;
    size_t len;
} EscargotHostValue;

typedef const char *(*EscargotHostGetFn)(int32_t instance_id, void *user_data,
                                         const char *name, size_t name_len,
                                         EscargotHostValue *out);
typedef const char *(*EscargotHostSetFn)(int32_t instance_id, void *user_data,
                                         const char *name, size_t name_len,
                                         const EscargotHostValue *value);
/* out_names[i] has length out_lens[i]; storage must outlive the call. */
typedef void (*EscargotHostNamesFn)(int32_t instance_id, void *user_data,
                                    const char ***out_names, const size_t **out_lens,
                                    size_t *out_count);
typedef void (*EscargotHostFinalizeFn)(void *user_data);

EscargotValue escargot_host_object_create(EscargotContext *ctx, int32_t instance_id, void *user_data,
                                          EscargotHostGetFn get_fn, EscargotHostSetFn set_fn,
                                          EscargotHostNamesFn names_fn, EscargotHostFinalizeFn finalize_fn);

/* ---- ES module loader (PlatformRef onLoadModule) ---- */
/* resolve: return heap canonical id or NULL to use specifier as-is.
   load: return true + out_src/out_len (host-owned bytes, valid after return).
   free_resolved: free a non-NULL resolve result. */
typedef char *(*EscargotModResolveFn)(void *user_data, const char *referrer, const char *specifier);
typedef bool (*EscargotModLoadFn)(void *user_data, const char *canonical_id,
                                  const char **out_src, size_t *out_len);
typedef void (*EscargotModFreeResolvedFn)(void *user_data, char *ptr);

void escargot_install_module_loader(EscargotContext *ctx, void *user_data,
                                    EscargotModResolveFn resolve,
                                    EscargotModLoadFn load,
                                    EscargotModFreeResolvedFn free_resolved);
void escargot_uninstall_module_loader(EscargotContext *ctx);

EscargotEvalResult escargot_eval_module(EscargotContext *ctx, const char *src, size_t src_len,
                                        const char *filename, size_t filename_len);
EscargotEvalResult escargot_import_module(EscargotContext *ctx, const char *specifier);

/* NativeHandle: opaque + optional call + finalize (thickening stub) */
typedef void (*EscargotNhFinalize)(void *handle_data);
EscargotValue escargot_native_handle_create(EscargotContext *ctx, void *handle_data,
                                            EscargotNativeFn call_fn, EscargotNhFinalize finalize);
void *escargot_native_handle_get(EscargotContext *ctx, EscargotValue v);
bool escargot_native_handle_is(EscargotContext *ctx, EscargotValue v);

#ifdef __cplusplus
}
#endif
