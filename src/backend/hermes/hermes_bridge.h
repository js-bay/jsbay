/* Native Hermes C bridge for jsbay (-Dbackend=hermes). Not a JSC shim. */
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JsbayHermesRuntimeOpaque JsbayHermesRuntime;
typedef struct JsbayHermesContextOpaque JsbayHermesContext;
typedef void *HermesValue;

typedef struct {
    char *result;
    char *err;
} HermesEvalResult;

void hermes_globals_ensure(void);

/* max_heap_bytes==0: Hermes default (3GiB). Create-time GCConfig.MaxHeapSize only. */
JsbayHermesRuntime *hermes_runtime_new(uint64_t max_heap_bytes);
void hermes_runtime_free(JsbayHermesRuntime *rt);
void hermes_runtime_gc(JsbayHermesRuntime *rt);

JsbayHermesContext *hermes_context_new(JsbayHermesRuntime *rt);
void hermes_context_free(JsbayHermesContext *ctx);

void hermes_context_set_opaque(JsbayHermesContext *ctx, void *opaque);
void *hermes_context_get_opaque(JsbayHermesContext *ctx);

HermesEvalResult hermes_eval(JsbayHermesContext *ctx, const char *src, size_t src_len,
                             const char *filename, size_t filename_len);
void hermes_eval_result_free(HermesEvalResult r);

HermesValue hermes_undefined(void);
HermesValue hermes_null(void);
HermesValue hermes_new_bool(JsbayHermesContext *ctx, bool v);
HermesValue hermes_new_int32(JsbayHermesContext *ctx, int32_t v);
HermesValue hermes_new_float64(JsbayHermesContext *ctx, double v);
HermesValue hermes_new_string(JsbayHermesContext *ctx, const char *utf8, size_t len);
HermesValue hermes_new_object(JsbayHermesContext *ctx);
HermesValue hermes_new_array(JsbayHermesContext *ctx, uint32_t len);

HermesValue hermes_dup(JsbayHermesContext *ctx, HermesValue v);
void hermes_free_value(JsbayHermesContext *ctx, HermesValue v);

bool hermes_is_undefined(HermesValue v);
bool hermes_is_null(HermesValue v);
bool hermes_is_bool(HermesValue v);
bool hermes_is_number(HermesValue v);
bool hermes_is_string(HermesValue v);
bool hermes_is_object(HermesValue v);
bool hermes_is_array(JsbayHermesContext *ctx, HermesValue v);
bool hermes_is_function(JsbayHermesContext *ctx, HermesValue v);
bool hermes_is_constructor(JsbayHermesContext *ctx, HermesValue v);

bool hermes_to_bool(HermesValue v);
int32_t hermes_to_int32(HermesValue v);
double hermes_to_float64(HermesValue v);

char *hermes_value_to_utf8(JsbayHermesContext *ctx, HermesValue v);
char *hermes_value_to_utf8_n(JsbayHermesContext *ctx, HermesValue v, size_t *out_len);
char *hermes_json_stringify(JsbayHermesContext *ctx, HermesValue v);
HermesValue hermes_json_parse(JsbayHermesContext *ctx, const char *utf8, size_t len);

HermesValue hermes_get_global(JsbayHermesContext *ctx);
HermesValue hermes_get_property(JsbayHermesContext *ctx, HermesValue obj, const char *key);
bool hermes_set_property(JsbayHermesContext *ctx, HermesValue obj, const char *key, HermesValue val);
bool hermes_has_property(JsbayHermesContext *ctx, HermesValue obj, const char *key);

HermesValue hermes_call(JsbayHermesContext *ctx, HermesValue fn, HermesValue this_val,
                        const HermesValue *args, size_t argc, char **out_err);

void hermes_process_pending_jobs(JsbayHermesContext *ctx);


/* ---- Value-returning eval (typed_eval) ---- */
typedef struct {
    HermesValue value; /* retained; NULL if threw/failed without value */
    char *err;         /* heap error text if threw; else NULL */
} HermesValueResult;

HermesValueResult hermes_eval_value(JsbayHermesContext *ctx, const char *src, size_t src_len,
                                    const char *filename, size_t filename_len);
void hermes_value_result_free_err(HermesValueResult r);

/* ---- Index / length ---- */
HermesValue hermes_get_index(JsbayHermesContext *ctx, HermesValue obj, uint32_t index);
uint32_t hermes_get_length(JsbayHermesContext *ctx, HermesValue obj);
bool hermes_set_index(JsbayHermesContext *ctx, HermesValue obj, uint32_t index, HermesValue val);
bool hermes_set_length(JsbayHermesContext *ctx, HermesValue obj, uint32_t length);
bool hermes_define_data_property(JsbayHermesContext *ctx, HermesValue obj, const char *key,
                                 HermesValue val, bool writable);
bool hermes_strict_equal(JsbayHermesContext *ctx, HermesValue a, HermesValue b);
HermesValue hermes_new_symbol(JsbayHermesContext *ctx, const char *desc, size_t desc_len);
HermesValue hermes_symbol_for(JsbayHermesContext *ctx, const char *key, size_t key_len);


/* ---- Date / BigInt / Map / Set ---- */
bool hermes_is_date(JsbayHermesContext *ctx, HermesValue v);
int64_t hermes_date_to_ms(JsbayHermesContext *ctx, HermesValue v);
HermesValue hermes_new_date(JsbayHermesContext *ctx, int64_t ms);

bool hermes_is_bigint(HermesValue v);
HermesValue hermes_new_bigint_i64(JsbayHermesContext *ctx, int64_t v);
HermesValue hermes_new_bigint_u64(JsbayHermesContext *ctx, uint64_t v);
bool hermes_bigint_to_i64(HermesValue v, int64_t *out);
bool hermes_bigint_to_u64(HermesValue v, uint64_t *out);
bool hermes_bigint_to_i64_ctx(JsbayHermesContext *ctx, HermesValue v, int64_t *out);
bool hermes_bigint_to_u64_ctx(JsbayHermesContext *ctx, HermesValue v, uint64_t *out);

bool hermes_is_map(JsbayHermesContext *ctx, HermesValue v);
bool hermes_is_set(JsbayHermesContext *ctx, HermesValue v);
HermesValue hermes_new_map(JsbayHermesContext *ctx);
HermesValue hermes_new_set(JsbayHermesContext *ctx);
bool hermes_map_set(JsbayHermesContext *ctx, HermesValue map, HermesValue key, HermesValue val);
bool hermes_set_add(JsbayHermesContext *ctx, HermesValue set, HermesValue val);
size_t hermes_map_size(JsbayHermesContext *ctx, HermesValue map);
size_t hermes_set_size(JsbayHermesContext *ctx, HermesValue set);
char *hermes_map_to_json(JsbayHermesContext *ctx, HermesValue map);
char *hermes_set_to_json(JsbayHermesContext *ctx, HermesValue set);
HermesValue hermes_new_map_from_json(JsbayHermesContext *ctx, const char *json, size_t len);
HermesValue hermes_new_set_from_json(JsbayHermesContext *ctx, const char *json, size_t len);

typedef bool (*HermesMapForEachFn)(JsbayHermesContext *ctx, void *cb_ctx, HermesValue key, HermesValue val);
typedef bool (*HermesSetForEachFn)(JsbayHermesContext *ctx, void *cb_ctx, HermesValue val);
bool hermes_map_foreach(JsbayHermesContext *ctx, HermesValue map, void *cb_ctx, HermesMapForEachFn cb);
bool hermes_set_foreach(JsbayHermesContext *ctx, HermesValue set, void *cb_ctx, HermesSetForEachFn cb);

/* ---- ArrayBuffer / TypedArray / DataView ---- */
bool hermes_is_array_buffer(JsbayHermesContext *ctx, HermesValue v);
bool hermes_is_typed_array(JsbayHermesContext *ctx, HermesValue v);
bool hermes_is_data_view(JsbayHermesContext *ctx, HermesValue v);
HermesValue hermes_new_array_buffer_copy(JsbayHermesContext *ctx, const uint8_t *bytes, size_t len);
typedef void (*HermesBufferDeleter)(void *user_data);
HermesValue hermes_new_array_buffer_no_copy(JsbayHermesContext *ctx, uint8_t *bytes, size_t len,
                                            HermesBufferDeleter deleter, void *user_data);
uint8_t *hermes_array_buffer_data(JsbayHermesContext *ctx, HermesValue ab, size_t *out_len);
/* kind: 0=Int8 1=Uint8 2=Uint8C 3=Int16 4=Uint16 5=Int32 6=Uint32 7=Float32 8=Float64 9=BigInt64 10=BigUint64 */
HermesValue hermes_new_typed_array(JsbayHermesContext *ctx, HermesValue ab, int kind,
                                   size_t byte_offset, size_t length);
uint8_t *hermes_typed_array_data(JsbayHermesContext *ctx, HermesValue ta, size_t *byte_offset,
                                 size_t *byte_length, int *kind);
HermesValue hermes_new_data_view(JsbayHermesContext *ctx, HermesValue ab, size_t byte_offset, size_t byte_length);
uint8_t *hermes_data_view_data(JsbayHermesContext *ctx, HermesValue dv, size_t *byte_offset, size_t *byte_length);

/* ---- Native function ---- */
typedef HermesValue (*HermesNativeFn)(JsbayHermesContext *ctx, HermesValue this_val,
                                      const HermesValue *args, size_t argc, void *user_data);
HermesValue hermes_make_function(JsbayHermesContext *ctx, const char *name, HermesNativeFn fn, void *user_data);
void hermes_throw(JsbayHermesContext *ctx, const char *message);

/* ---- Atoms (heap UTF-8 string handle) ---- */
typedef void *HermesAtom;
HermesAtom hermes_atom_new(JsbayHermesContext *ctx, const char *utf8, size_t len);
void hermes_atom_free(HermesAtom atom);
char *hermes_atom_to_utf8(JsbayHermesContext *ctx, HermesAtom atom);
HermesValue hermes_get_property_atom(JsbayHermesContext *ctx, HermesValue obj, HermesAtom atom);
bool hermes_set_property_atom(JsbayHermesContext *ctx, HermesValue obj, HermesAtom atom, HermesValue val);
bool hermes_has_property_atom(JsbayHermesContext *ctx, HermesValue obj, HermesAtom atom);

/* Errors */
bool hermes_is_error(JsbayHermesContext *ctx, HermesValue v);
/* kind: 0=Error 1=TypeError 2=RangeError 3=ReferenceError 4=SyntaxError 5=URIError 6=EvalError 8=AggregateError */
HermesValue hermes_new_error(JsbayHermesContext *ctx, int kind, const char *message);


/* ---- Op results ---- */
typedef struct {
    HermesValue value;
    HermesValue exception;
} HermesOpResult;

typedef struct {
    bool value;
    HermesValue exception;
} HermesBoolOpResult;

HermesOpResult hermes_set_property_result(JsbayHermesContext *ctx, HermesValue obj, const char *key, HermesValue val);
HermesOpResult hermes_construct(JsbayHermesContext *ctx, HermesValue ctor,
                                const HermesValue *args, size_t argc);
HermesBoolOpResult hermes_has_in(JsbayHermesContext *ctx, HermesValue obj, const char *key);
HermesBoolOpResult hermes_delete_property(JsbayHermesContext *ctx, HermesValue obj, const char *key);
HermesOpResult hermes_own_keys(JsbayHermesContext *ctx, HermesValue obj);
HermesBoolOpResult hermes_instance_of(JsbayHermesContext *ctx, HermesValue value, HermesValue ctor);

bool hermes_promise_create(JsbayHermesContext *ctx, HermesValue *out_promise,
                           HermesValue *out_resolve, HermesValue *out_reject);
bool hermes_is_promise(JsbayHermesContext *ctx, HermesValue v);
int hermes_promise_state(JsbayHermesContext *ctx, HermesValue v);
HermesValue hermes_promise_result(JsbayHermesContext *ctx, HermesValue v);
void hermes_promise_note_settled(JsbayHermesContext *ctx, HermesValue promise, int state, HermesValue result);

typedef void (*HermesExternalFinalizer)(void *ptr);
HermesValue hermes_new_external(JsbayHermesContext *ctx, void *ptr, HermesExternalFinalizer fin);
void *hermes_get_external(JsbayHermesContext *ctx, HermesValue v);
bool hermes_is_external(JsbayHermesContext *ctx, HermesValue v);

typedef void (*HermesWeakFinalizer)(void *user_data);
bool hermes_weak_attach_finalizer(JsbayHermesContext *ctx, HermesValue target,
                                  void *user_data, HermesWeakFinalizer cb);

/* Host object (JSI HostObject + Proxy for in/hasOwnProperty) */
typedef struct HermesHostValue {
    uint32_t tag; /* 0 undef, 1 number, 2 string */
    uint32_t reserved;
    double number;
    const char *ptr;
    size_t len;
} HermesHostValue;

typedef const char *(*HermesHostGetFn)(int32_t instance_id, void *user_data,
                                       const char *name, size_t name_len,
                                       HermesHostValue *out);
typedef const char *(*HermesHostSetFn)(int32_t instance_id, void *user_data,
                                       const char *name, size_t name_len,
                                       const HermesHostValue *value);
typedef void (*HermesHostNamesFn)(int32_t instance_id, void *user_data,
                                  const char ***out_names, const size_t **out_lens,
                                  size_t *out_count);
typedef void (*HermesHostFinalizeFn)(void *user_data);

HermesValue hermes_host_object_create(JsbayHermesContext *ctx, int32_t instance_id, void *user_data,
                                      HermesHostGetFn get_fn, HermesHostSetFn set_fn,
                                      HermesHostNamesFn names_fn, HermesHostFinalizeFn finalize_fn);

/* ---- Hermes .hbc bytecode ---- */
typedef struct {
    uint8_t *bytes; /* heap; caller frees with free() */
    size_t len;
    char *err;      /* heap; caller frees; NULL on success */
} HermesCompileResult;

/* Compile JS source to Hermes bytecode (.hbc). Uses hermesc at
   JSBAY_HERMESC or vendor/hermes-install/bin/hermesc relative to cwd. */
HermesCompileResult hermes_compile_bytecode(const char *src, size_t src_len,
                                            const char *filename, size_t filename_len);
void hermes_compile_result_free(HermesCompileResult r);

/* Evaluate previously compiled .hbc bytes in this runtime. */
HermesEvalResult hermes_run_bytecode(JsbayHermesContext *ctx, const uint8_t *bytes, size_t len);
/* decode_failed: 1 if bytes are not valid HBC / empty; 0 if JS threw after decode. */
HermesEvalResult hermes_run_bytecode_ex(JsbayHermesContext *ctx, const uint8_t *bytes, size_t len,
                                        int *out_decode_failed);

/* NativeHandle: opaque + optional call + finalize */
typedef void (*HermesNhFinalize)(void *handle_data);
HermesValue hermes_native_handle_create(JsbayHermesContext *ctx, void *handle_data,
                                        HermesNativeFn call_fn, HermesNhFinalize finalize);
void *hermes_native_handle_get(JsbayHermesContext *ctx, HermesValue v);
bool hermes_native_handle_is(JsbayHermesContext *ctx, HermesValue v);

/* ---- ES module loader (host-side ESM→CJS shim; Hermes pin has no native module codegen) ---- */
typedef char *(*HermesModResolveFn)(void *ud, const char *referrer, const char *specifier);
typedef bool (*HermesModLoadFn)(void *ud, const char *canonical_id, const char **out_src, size_t *out_len);
typedef void (*HermesModFreeResolvedFn)(void *ud, char *resolved);
void hermes_install_module_loader(JsbayHermesContext *ctx, void *user_data,
                                  HermesModResolveFn resolve, HermesModLoadFn load,
                                  HermesModFreeResolvedFn free_resolved);
void hermes_uninstall_module_loader(JsbayHermesContext *ctx);
HermesEvalResult hermes_eval_module(JsbayHermesContext *ctx, const char *src, size_t src_len,
                                    const char *filename, size_t filename_len);
HermesEvalResult hermes_import_module(JsbayHermesContext *ctx, const char *specifier);

/* Host Promise rejection tracker (Escargot-style). Prefer HermesInternal hooks;
   also used for module-shim top-level throws that settle via awaitThenable. */
typedef void (*HermesRejectionTrackerFn)(int32_t instance_id, bool handled,
                                         const char *reason, size_t reason_len, void *ud);
bool hermes_set_rejection_tracker(JsbayHermesContext *ctx, int32_t instance_id,
                                  HermesRejectionTrackerFn fn, void *ud);
void hermes_report_unhandled_rejection(JsbayHermesContext *ctx, const char *message);

#ifdef __cplusplus
}

namespace facebook { namespace hermes { class HermesRuntime; } }
facebook::hermes::HermesRuntime *hermes_context_rt(JsbayHermesContext *c);
void hermes_context_drain_microtasks(JsbayHermesContext *c);
#endif

