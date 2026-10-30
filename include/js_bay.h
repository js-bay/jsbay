#ifndef JS_BAY_H
#define JS_BAY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { JS_BAY_LOG_DEBUG = 0, JS_BAY_LOG_INFO = 1, JS_BAY_LOG_WARN = 2, JS_BAY_LOG_ERROR = 3 } js_bay_log_level_t;
typedef void (*js_bay_log_handler_t)(int instance_id, js_bay_log_level_t level, const char *message, void *user_data);

typedef uint64_t js_bay_value_t; /* 0 is invalid; undefined has a non-zero handle. */
typedef struct { const uint8_t *data; size_t len; } js_bay_utf8_t;
typedef struct { uint8_t *data; size_t len; } js_bay_bytes_t;

typedef enum {
    JS_BAY_OK = 0, JS_BAY_EXCEPTION, JS_BAY_INVALID_ARGUMENT,
    JS_BAY_WRONG_THREAD, JS_BAY_INSTANCE_NOT_FOUND, JS_BAY_STALE_VALUE,
    JS_BAY_OUT_OF_MEMORY, JS_BAY_UNSUPPORTED, JS_BAY_LOOP_FAILED,
} js_bay_status_t;
typedef enum {
    JS_BAY_VALUE_UNDEFINED, JS_BAY_VALUE_NULL, JS_BAY_VALUE_BOOL,
    JS_BAY_VALUE_NUMBER, JS_BAY_VALUE_STRING, JS_BAY_VALUE_OBJECT,
    JS_BAY_VALUE_ARRAY, JS_BAY_VALUE_FUNCTION,
    /* Appended after the original eight; existing values never change. */
    JS_BAY_VALUE_SYMBOL, JS_BAY_VALUE_BIGINT,
} js_bay_value_kind_t;

typedef struct {
    uint32_t struct_size;
    js_bay_utf8_t cache_dir;
    js_bay_utf8_t cache_version;
    bool *out_cache_hit;
} js_bay_engine_evaluate_options_t;

/* All out_* arguments in this header are required and must be non-NULL unless a declaration explicitly says otherwise. The only optional output is evaluate_options.out_cache_hit. */

/* instance_id is supplied by the caller. Except request_interrupt and stop_loop, every API here runs on the owning thread, including release. Every output is cleared before work begins. On JS_BAY_OK, out_value is non-zero and out_exception is zero; on JS_BAY_EXCEPTION, out_value is zero and out_exception is a non-zero live thrown JS value (it need not be an Error); all other failures leave both outputs zero. */
bool js_bay_engine_create(int instance_id, js_bay_log_handler_t log_handler, void *log_user_data);

/* Extended create. struct_size must be set to sizeof(*opts). max_heap_size is create-time only:
 * Hermes → GCConfig.MaxHeapSize (0 = Hermes / -Dhermes-max-heap default). Escargot/JSC/QuickJS: ignored
 * (QuickJS uses js_bay_engine_set_memory_limit at runtime). NULL opts behaves like js_bay_engine_create. */
typedef struct {
    uint32_t struct_size;
    js_bay_log_handler_t log_handler;
    void *log_user_data;
    uint64_t max_heap_size;
} js_bay_engine_create_options_t;
bool js_bay_engine_create2(int instance_id, const js_bay_engine_create_options_t *opts);

void js_bay_engine_destroy(int instance_id);
/* Mid-script cancel when the backend supports it (QuickJS/NG, JSC). Escargot/Hermes experimental
 * spikes: returns false — no mid-script user interrupt. Hermes stop/destroy still interrupts via
 * a separate lifecycle path. */
bool js_bay_engine_request_interrupt(int instance_id);
bool js_bay_engine_clear_interrupt(int instance_id);
bool js_bay_engine_set_execution_time_limit(int instance_id, uint64_t millis);
/* Runtime heap cap. QuickJS/NG: yes. JSC: false. Escargot/Hermes spikes: always false
 * (Hermes create-time max heap is js_bay_engine_create2.max_heap_size / Zig EngineConfig). */
bool js_bay_engine_set_memory_limit(int instance_id, uint64_t bytes);

/* Owner-thread snapshot of runtime allocator stats (mirrors Zig runtime_control.MemoryUsage).
 * Backends that cannot report a field leave it zero. struct_size must be set by the caller to
 * sizeof(*out_usage) before the call; the library writes min(struct_size, sizeof(library struct)).
 * Returns false when the instance is missing, the caller is not the owner thread, or out_usage is NULL. */
typedef struct {
    uint32_t struct_size;
    uint64_t malloc_count;
    uint64_t malloc_size;
    uint64_t malloc_limit;
    uint64_t memory_used_count;
    uint64_t memory_used_size;
    uint64_t atom_count;
    uint64_t atom_size;
    uint64_t obj_count;
    uint64_t obj_size;
    uint64_t shape_count;
} js_bay_memory_usage_t;
bool js_bay_engine_get_memory_usage(int instance_id, js_bay_memory_usage_t *out_usage);
/* Owner-thread forced GC pass. Returns false when missing/wrong thread. */
bool js_bay_engine_run_gc(int instance_id);

/* Best-effort telemetry events for host reporting. Not a CDP surface.
 * Handlers may run on the owner thread (evaluate / loop / console) or on a control-plane
 * thread (request_interrupt). Do not call engine/Value APIs from the handler. */
typedef enum {
    JS_BAY_EVENT_LOG = 0,
    JS_BAY_EVENT_EXECUTION_INTERRUPTED = 1,
    JS_BAY_EVENT_MEMORY_LIMIT = 2,
    JS_BAY_EVENT_LOOP_FAILED = 3,
} js_bay_engine_event_kind_t;
typedef struct {
    uint32_t struct_size;
    js_bay_engine_event_kind_t kind;
    int instance_id;
    int32_t status; /* js_bay_status_t when relevant, else 0 */
    uint64_t detail; /* e.g. limit bytes, elapsed ms — 0 if N/A */
    const char *message; /* optional UTF-8; may be NULL; valid only for the callback */
} js_bay_engine_event_t;
typedef void (*js_bay_engine_event_handler_t)(const js_bay_engine_event_t *event, void *user_data);
/* Owner-thread registration. Pass NULL handler to clear. Returns false if missing/wrong thread. */
bool js_bay_engine_set_event_handler(int instance_id, js_bay_engine_event_handler_t handler, void *user_data);

/* The only normal script execution entry point. source and filename are UTF-8 bytes. options may be NULL; otherwise struct_size must be sizeof(*options), and cache_dir/cache_version must both be empty or both non-empty. A cache failure evaluates source once. */
js_bay_status_t js_bay_engine_evaluate(int instance_id, js_bay_utf8_t source,
                                       js_bay_utf8_t filename,
                                       const js_bay_engine_evaluate_options_t *options,
                                       js_bay_value_t *out_value,
                                       js_bay_value_t *out_exception);

/* retain duplicates any live handle (including a callback-borrowed this/arg) into a new caller-owned handle. */
js_bay_status_t js_bay_value_retain(js_bay_value_t value, js_bay_value_t *out_value);
js_bay_status_t js_bay_value_release(js_bay_value_t value);
js_bay_status_t js_bay_engine_global(int instance_id, js_bay_value_t *out_value);
js_bay_status_t js_bay_value_undefined(int instance_id, js_bay_value_t *out_value);
js_bay_status_t js_bay_value_null(int instance_id, js_bay_value_t *out_value);
js_bay_status_t js_bay_value_new_bool(int instance_id, bool input, js_bay_value_t *out_value);
js_bay_status_t js_bay_value_new_number(int instance_id, double input, js_bay_value_t *out_value);
js_bay_status_t js_bay_value_new_string(int instance_id, js_bay_utf8_t input, js_bay_value_t *out_value);
js_bay_status_t js_bay_value_new_array_buffer(int instance_id, const uint8_t *data, size_t len, js_bay_value_t *out_value);
js_bay_status_t js_bay_value_new_json(int instance_id, js_bay_utf8_t input, js_bay_value_t *out_value, js_bay_value_t *out_exception);
js_bay_status_t js_bay_value_new_error(int instance_id, js_bay_utf8_t message, js_bay_value_t *out_value);
js_bay_status_t js_bay_value_new_object(int instance_id, js_bay_value_t *out_value);
js_bay_status_t js_bay_value_new_array(int instance_id, js_bay_value_t *out_value);
js_bay_status_t js_bay_value_type(js_bay_value_t value, js_bay_value_kind_t *out_kind);
js_bay_status_t js_bay_value_to_bool(js_bay_value_t value, bool *out_value);
js_bay_status_t js_bay_value_to_number(js_bay_value_t value, double *out_value);
js_bay_status_t js_bay_value_to_utf8(js_bay_value_t value, js_bay_bytes_t *out_bytes, js_bay_value_t *out_exception);
js_bay_status_t js_bay_value_to_json(js_bay_value_t value, js_bay_bytes_t *out_bytes, js_bay_value_t *out_exception);
js_bay_status_t js_bay_value_copy_buffer(js_bay_value_t value, js_bay_bytes_t *out_bytes, js_bay_value_t *out_exception);
/* Free library-owned bytes exactly once. A second free is undefined and typically aborts. */
void js_bay_free_bytes(js_bay_bytes_t bytes);
js_bay_status_t js_bay_value_get(js_bay_value_t object, js_bay_utf8_t key, js_bay_value_t *out_value, js_bay_value_t *out_exception);
js_bay_status_t js_bay_value_set(js_bay_value_t object, js_bay_utf8_t key, js_bay_value_t value, js_bay_value_t *out_exception);
/* args may be NULL only when argc is zero. */
js_bay_status_t js_bay_value_call(js_bay_value_t function, js_bay_value_t this_value, const js_bay_value_t *args, size_t argc, js_bay_value_t *out_value, js_bay_value_t *out_exception);
/* new function(...args). args may be NULL only when argc is zero. A non-constructor or a constructor that throws returns 1 with the JS exception in out_exception. */
js_bay_status_t js_bay_value_construct(js_bay_value_t function, const js_bay_value_t *args, size_t argc, js_bay_value_t *out_value, js_bay_value_t *out_exception);
/* key in object, including the prototype chain. A non-object throws a TypeError: returns 1 with the exception in out_exception and *out_has false. */
js_bay_status_t js_bay_value_has(js_bay_value_t object, js_bay_utf8_t key, bool *out_has, js_bay_value_t *out_exception);
/* Non-strict delete object[key]. A non-configurable property yields *out_deleted == false without throwing; a missing property yields true. undefined and null throw a TypeError. */
js_bay_status_t js_bay_value_delete(js_bay_value_t object, js_bay_utf8_t key, bool *out_deleted, js_bay_value_t *out_exception);
/* Equivalent to Object.keys(object): own, enumerable, string keys; integer keys ascending first, then creation order (a Proxy reports its ownKeys order). Inherited, non-enumerable and Symbol keys are excluded. out_array is a new JS array Value that the caller must release. */
js_bay_status_t js_bay_value_keys(js_bay_value_t object, js_bay_value_t *out_array, js_bay_value_t *out_exception);
/* value instanceof constructor, honoring Symbol.hasInstance. A constructor that is neither callable nor defines Symbol.hasInstance throws a TypeError: returns 1 with the exception in out_exception and *out_result false. */
js_bay_status_t js_bay_value_instance_of(js_bay_value_t value, js_bay_value_t constructor, bool *out_result, js_bay_value_t *out_exception);

typedef js_bay_status_t (*js_bay_host_callback_t)(int instance_id, void *user_data,
    js_bay_value_t this_value, size_t argc, const js_bay_value_t *args,
    js_bay_value_t *out_value, js_bay_value_t *out_exception);
typedef void (*js_bay_host_finalize_t)(void *user_data);
/* this_value and args are borrowed during the callback. Do not release them. Call js_bay_value_retain to keep an owned copy past return. A returned non-zero value/exception is consumed by the engine. */
js_bay_status_t js_bay_engine_bind(int instance_id, js_bay_utf8_t name,
                                   js_bay_host_callback_t callback, void *user_data,
                                   js_bay_host_finalize_t finalize,
                                   js_bay_value_t *out_function,
                                   js_bay_value_t *out_exception);

/* A platform scheduler posts an opaque task to the engine owner thread after delay_ms. It may be called from any thread, must enqueue asynchronously, and replaces its previous pending task. cancel runs on the owner thread and must prevent every pending task from running after it returns. Neither callback may call engine/Value APIs. The SDK owns user_data through detach or destruction. */
typedef void (*js_bay_loop_task_t)(void *task_data);
typedef bool (*js_bay_loop_schedule_t)(void *user_data, uint64_t delay_ms,
    js_bay_loop_task_t task, void *task_data);
typedef void (*js_bay_loop_cancel_t)(void *user_data);
js_bay_status_t js_bay_engine_attach_loop(int instance_id,
    js_bay_loop_schedule_t schedule, js_bay_loop_cancel_t cancel, void *user_data);
js_bay_status_t js_bay_engine_detach_loop(int instance_id);
/* Returns JS_BAY_LOOP_FAILED when the platform rejected scheduling. A failed loop remains stopped until explicitly reattached. */
js_bay_status_t js_bay_engine_loop_status(int instance_id);
/* Run on the owner thread until stopped. An attached platform loop must first be detached. Calling it from a synchronous native callback, queued task, or microtask returns JS_BAY_INVALID_ARGUMENT because the current JavaScript turn must finish first. stop_loop is thread-safe; it ends an active run without destroying the engine. */
js_bay_status_t js_bay_engine_run_loop(int instance_id);
bool js_bay_engine_stop_loop(int instance_id);
bool js_bay_engine_inspector_start(int instance_id, uint16_t port, uint16_t *out_port);
void js_bay_engine_inspector_stop(int instance_id);

#ifdef __cplusplus
}
#endif

#endif
