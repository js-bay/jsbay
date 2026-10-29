#ifndef JSBAY_H
#define JSBAY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { JSBAY_LOG_DEBUG = 0, JSBAY_LOG_INFO = 1, JSBAY_LOG_WARN = 2, JSBAY_LOG_ERROR = 3 } jsbay_log_level_t;
typedef void (*jsbay_log_handler_t)(int instance_id, jsbay_log_level_t level, const char *message, void *user_data);

typedef uint64_t jsbay_value_t; /* 0 is invalid; undefined has a non-zero handle. */
typedef struct { const uint8_t *data; size_t len; } jsbay_utf8_t;
typedef struct { uint8_t *data; size_t len; } jsbay_bytes_t;

typedef enum {
    JSBAY_OK = 0, JSBAY_EXCEPTION, JSBAY_INVALID_ARGUMENT,
    JSBAY_WRONG_THREAD, JSBAY_INSTANCE_NOT_FOUND, JSBAY_STALE_VALUE,
    JSBAY_OUT_OF_MEMORY, JSBAY_UNSUPPORTED, JSBAY_LOOP_FAILED,
} jsbay_status_t;
typedef enum {
    JSBAY_VALUE_UNDEFINED, JSBAY_VALUE_NULL, JSBAY_VALUE_BOOL,
    JSBAY_VALUE_NUMBER, JSBAY_VALUE_STRING, JSBAY_VALUE_OBJECT,
    JSBAY_VALUE_ARRAY, JSBAY_VALUE_FUNCTION,
    /* Appended after the original eight; existing values never change. */
    JSBAY_VALUE_SYMBOL, JSBAY_VALUE_BIGINT,
} jsbay_value_kind_t;

typedef struct {
    uint32_t struct_size;
    jsbay_utf8_t cache_dir;
    jsbay_utf8_t cache_version;
    bool *out_cache_hit;
} jsbay_engine_evaluate_options_t;

/* All out_* arguments in this header are required and must be non-NULL unless a declaration explicitly says otherwise. The only optional output is evaluate_options.out_cache_hit. */

/* instance_id is supplied by the caller. Except request_interrupt, stop_loop, suspend, resume, is_suspended, list, snapshot, set/get_admission_class, resource_global_usage, and destroy, every API here runs on the owning thread, including release. Every output is cleared before work begins. On JSBAY_OK, out_value is non-zero and out_exception is zero; on JSBAY_EXCEPTION, out_value is zero and out_exception is a non-zero live thrown JS value (it need not be an Error); all other failures leave both outputs zero. */

/* Process-wide build identity. No instance required; thread-safe. out must be non-NULL and struct_size must be at least sizeof(*out). On success the string pointers are library-owned NUL-terminated C strings that remain valid for the lifetime of the loaded library (do not free them). commit is "" when the build did not record a git revision. backend is the compile-time -Dbackend tag: "quickjs_ng", "quickjs", or "jsc". Returns false when out is NULL or struct_size is too small. */
typedef struct {
    uint32_t struct_size;
    const char *version;
    const char *commit;
    const char *backend;
} jsbay_engine_version_info_t;
bool jsbay_engine_version(jsbay_engine_version_info_t *out);

typedef struct {
    uint32_t struct_size;
    size_t max_timers;
    size_t max_tsfn_handles;
    size_t max_pending_calls;
    size_t max_pending_bytes;
    size_t max_pending_tasks;
} jsbay_resource_limits_t;

typedef struct {
    uint32_t struct_size;
    size_t timers;
    size_t tsfn_handles;
    size_t pending_calls;
    size_t native_tasks;
    size_t script_tasks;
    size_t pending_bytes;
    size_t max_timers;
    size_t max_tsfn_handles;
    size_t max_pending_calls;
    size_t max_pending_bytes;
    size_t max_pending_tasks;
} jsbay_resource_usage_t;

typedef struct {
    uint32_t struct_size;
    size_t timers;
    size_t tsfn_handles;
    size_t pending_calls;
    size_t native_tasks;
    size_t script_tasks;
    size_t pending_bytes;
    size_t max_timers;
    size_t max_tsfn_handles;
    size_t max_pending_calls;
    size_t max_native_tasks;
    size_t max_script_tasks;
    size_t max_pending_bytes;
    /* Appended: FG headroom (25% of each process cap) and effective BACKGROUND caps. Older callers may pass the legacy struct_size ending at max_pending_bytes. */
    size_t fg_headroom_timers;
    size_t fg_headroom_tsfn_handles;
    size_t fg_headroom_pending_calls;
    size_t fg_headroom_native_tasks;
    size_t fg_headroom_script_tasks;
    size_t fg_headroom_pending_bytes;
    size_t bg_effective_max_timers;
    size_t bg_effective_max_tsfn_handles;
    size_t bg_effective_max_pending_calls;
    size_t bg_effective_max_native_tasks;
    size_t bg_effective_max_script_tasks;
    size_t bg_effective_max_pending_bytes;
} jsbay_resource_global_usage_t;

typedef enum {
    JSBAY_ADMISSION_FOREGROUND = 0, /* default */
    JSBAY_ADMISSION_BACKGROUND = 1,
} jsbay_admission_class_t;

typedef struct {
    uint32_t struct_size;
    int instance_id;
    uint64_t generation;
    uint64_t owner_thread_id; /* 0 if missing */
    uint8_t loop_mode; /* 0 idle, 1 running, 2 attached */
    uint8_t flags; /* bit0 suspended, bit1 attached, bit2 reserved (unused), bit3 loop_failed, bit4 sync_wait */
    jsbay_admission_class_t admission_class;
    size_t timers_reserved;
    size_t timers_registered;
    size_t script_tasks_queued;
    size_t native_tasks_queued;
    size_t pending_bytes;
    size_t max_timers;
    size_t max_pending_tasks;
    size_t max_pending_bytes;
} jsbay_instance_snapshot_t;

bool jsbay_engine_create(int instance_id, jsbay_log_handler_t log_handler, void *log_user_data);
/* limits may be NULL for the same defaults as jsbay_engine_create. Otherwise struct_size must be sizeof(*limits). */
bool jsbay_engine_create_with_limits(int instance_id, jsbay_log_handler_t log_handler, void *log_user_data, const jsbay_resource_limits_t *limits);
/* Thread-safe. Joins teardown: when called off the owner thread it waits until the instance is gone (including waking a blocking run_loop). Prefer owner-thread destroy after releasing values when following the embed shutdown checklist. A destroy requested from a JS/native callback on the owner may defer physical cleanup until that callback unwinds; a later destroy joins that work. */
void jsbay_engine_destroy(int instance_id);
bool jsbay_engine_request_interrupt(int instance_id);
bool jsbay_engine_clear_interrupt(int instance_id);
bool jsbay_engine_set_execution_time_limit(int instance_id, uint64_t millis);
bool jsbay_engine_set_memory_limit(int instance_id, uint64_t bytes);
/* Replace per-instance Limits for future admissions. limits must be non-NULL with struct_size == sizeof(*limits). Existing reservations stay until released. */
bool jsbay_engine_set_resource_limits(int instance_id, const jsbay_resource_limits_t *limits);
/* Owner-thread snapshot of this instance's reservations and Limits. out->struct_size must be sizeof(*out) on entry. */
bool jsbay_engine_get_resource_usage(int instance_id, jsbay_resource_usage_t *out);
/* Process-wide reservation counts and caps. Callable from any thread. out->struct_size must be at least the legacy size through max_pending_bytes; pass sizeof(*out) for headroom fields. native_tasks and script_tasks are separate process pools. */
bool jsbay_resource_global_usage(jsbay_resource_global_usage_t *out);
/* Any thread. Affects future Budget.reserve only. Existing reservations unchanged. Default FOREGROUND. */
bool jsbay_engine_set_admission_class(int instance_id, jsbay_admission_class_t cls);
bool jsbay_engine_get_admission_class(int instance_id, jsbay_admission_class_t *out);

/* Any thread. Writes up to `cap` live, non-teardown-pending instance_ids (arbitrary order). Returns that total (may be > cap).
   out_ids may be NULL for a count-only query (typical: cap==0 && out_ids==NULL). Dying (teardown-pending) ids are omitted so list matches snapshot. */
size_t jsbay_engine_list(int *out_ids, size_t cap);
/* Any thread. Fills out; returns false if missing, teardown-pending, or bad struct_size. Snapshot may tear across locks; lengths only.
   flags bit2 is reserved/unused (teardown is refused by the control-plane lease, not reported). */
bool jsbay_engine_snapshot(int instance_id, jsbay_instance_snapshot_t *out);

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
} jsbay_memory_usage_t;
bool jsbay_engine_get_memory_usage(int instance_id, jsbay_memory_usage_t *out_usage);
/* Owner-thread forced GC pass. Returns false when missing/wrong thread. */
bool jsbay_engine_run_gc(int instance_id);

/* Best-effort telemetry events for host reporting. Not a CDP surface.
 * Handlers may run on the owner thread (evaluate / loop / console) or on a control-plane
 * thread (request_interrupt). Do not call engine/Value APIs from the handler. */
typedef enum {
    JSBAY_EVENT_LOG = 0,
    JSBAY_EVENT_EXECUTION_INTERRUPTED = 1,
    JSBAY_EVENT_MEMORY_LIMIT = 2,
    JSBAY_EVENT_LOOP_FAILED = 3,
} jsbay_engine_event_kind_t;
typedef struct {
    uint32_t struct_size;
    jsbay_engine_event_kind_t kind;
    int instance_id;
    int32_t status; /* jsbay_status_t when relevant, else 0 */
    uint64_t detail; /* e.g. limit bytes, elapsed ms — 0 if N/A */
    const char *message; /* optional UTF-8; may be NULL; valid only for the callback */
} jsbay_engine_event_t;
typedef void (*jsbay_engine_event_handler_t)(const jsbay_engine_event_t *event, void *user_data);
/* Owner-thread registration. Pass NULL handler to clear. Returns false if missing/wrong thread. */
bool jsbay_engine_set_event_handler(int instance_id, jsbay_engine_event_handler_t handler, void *user_data);

/* The only normal script execution entry point. source and filename are UTF-8 bytes. options may be NULL; otherwise struct_size must be sizeof(*options), and cache_dir/cache_version must both be empty or both non-empty. A cache failure evaluates source once. */
jsbay_status_t jsbay_engine_evaluate(int instance_id, jsbay_utf8_t source,
                                       jsbay_utf8_t filename,
                                       const jsbay_engine_evaluate_options_t *options,
                                       jsbay_value_t *out_value,
                                       jsbay_value_t *out_exception);

/* retain duplicates any live handle (including a callback-borrowed this/arg) into a new caller-owned handle. */
jsbay_status_t jsbay_value_retain(jsbay_value_t value, jsbay_value_t *out_value);
jsbay_status_t jsbay_value_release(jsbay_value_t value);
jsbay_status_t jsbay_engine_global(int instance_id, jsbay_value_t *out_value);
jsbay_status_t jsbay_value_undefined(int instance_id, jsbay_value_t *out_value);
jsbay_status_t jsbay_value_null(int instance_id, jsbay_value_t *out_value);
jsbay_status_t jsbay_value_new_bool(int instance_id, bool input, jsbay_value_t *out_value);
jsbay_status_t jsbay_value_new_number(int instance_id, double input, jsbay_value_t *out_value);
jsbay_status_t jsbay_value_new_string(int instance_id, jsbay_utf8_t input, jsbay_value_t *out_value);
jsbay_status_t jsbay_value_new_array_buffer(int instance_id, const uint8_t *data, size_t len, jsbay_value_t *out_value);
jsbay_status_t jsbay_value_new_json(int instance_id, jsbay_utf8_t input, jsbay_value_t *out_value, jsbay_value_t *out_exception);
jsbay_status_t jsbay_value_new_error(int instance_id, jsbay_utf8_t message, jsbay_value_t *out_value);
jsbay_status_t jsbay_value_new_object(int instance_id, jsbay_value_t *out_value);
jsbay_status_t jsbay_value_new_array(int instance_id, jsbay_value_t *out_value);
jsbay_status_t jsbay_value_type(jsbay_value_t value, jsbay_value_kind_t *out_kind);
jsbay_status_t jsbay_value_to_bool(jsbay_value_t value, bool *out_value);
jsbay_status_t jsbay_value_to_number(jsbay_value_t value, double *out_value);
jsbay_status_t jsbay_value_to_utf8(jsbay_value_t value, jsbay_bytes_t *out_bytes, jsbay_value_t *out_exception);
jsbay_status_t jsbay_value_to_json(jsbay_value_t value, jsbay_bytes_t *out_bytes, jsbay_value_t *out_exception);
jsbay_status_t jsbay_value_copy_buffer(jsbay_value_t value, jsbay_bytes_t *out_bytes, jsbay_value_t *out_exception);
/* Free library-owned bytes exactly once. A second free is undefined and typically aborts. */
void jsbay_free_bytes(jsbay_bytes_t bytes);
jsbay_status_t jsbay_value_get(jsbay_value_t object, jsbay_utf8_t key, jsbay_value_t *out_value, jsbay_value_t *out_exception);
jsbay_status_t jsbay_value_set(jsbay_value_t object, jsbay_utf8_t key, jsbay_value_t value, jsbay_value_t *out_exception);
/* args may be NULL only when argc is zero. */
jsbay_status_t jsbay_value_call(jsbay_value_t function, jsbay_value_t this_value, const jsbay_value_t *args, size_t argc, jsbay_value_t *out_value, jsbay_value_t *out_exception);
/* new function(...args). args may be NULL only when argc is zero. A non-constructor or a constructor that throws returns 1 with the JS exception in out_exception. */
jsbay_status_t jsbay_value_construct(jsbay_value_t function, const jsbay_value_t *args, size_t argc, jsbay_value_t *out_value, jsbay_value_t *out_exception);
/* key in object, including the prototype chain. A non-object throws a TypeError: returns 1 with the exception in out_exception and *out_has false. */
jsbay_status_t jsbay_value_has(jsbay_value_t object, jsbay_utf8_t key, bool *out_has, jsbay_value_t *out_exception);
/* Non-strict delete object[key]. A non-configurable property yields *out_deleted == false without throwing; a missing property yields true. undefined and null throw a TypeError. */
jsbay_status_t jsbay_value_delete(jsbay_value_t object, jsbay_utf8_t key, bool *out_deleted, jsbay_value_t *out_exception);
/* Equivalent to Object.keys(object): own, enumerable, string keys; integer keys ascending first, then creation order (a Proxy reports its ownKeys order). Inherited, non-enumerable and Symbol keys are excluded. out_array is a new JS array Value that the caller must release. */
jsbay_status_t jsbay_value_keys(jsbay_value_t object, jsbay_value_t *out_array, jsbay_value_t *out_exception);
/* value instanceof constructor, honoring Symbol.hasInstance. A constructor that is neither callable nor defines Symbol.hasInstance throws a TypeError: returns 1 with the exception in out_exception and *out_result false. */
jsbay_status_t jsbay_value_instance_of(jsbay_value_t value, jsbay_value_t constructor, bool *out_result, jsbay_value_t *out_exception);

typedef jsbay_status_t (*jsbay_host_callback_t)(int instance_id, void *user_data,
    jsbay_value_t this_value, size_t argc, const jsbay_value_t *args,
    jsbay_value_t *out_value, jsbay_value_t *out_exception);
typedef void (*jsbay_host_finalize_t)(void *user_data);
/* this_value and args are borrowed during the callback. Do not release them. Call jsbay_value_retain to keep an owned copy past return. A returned non-zero value/exception is consumed by the engine. */
jsbay_status_t jsbay_engine_bind(int instance_id, jsbay_utf8_t name,
                                   jsbay_host_callback_t callback, void *user_data,
                                   jsbay_host_finalize_t finalize,
                                   jsbay_value_t *out_function,
                                   jsbay_value_t *out_exception);

/* A platform scheduler posts an opaque task to the engine owner thread after delay_ms. schedule may be called from any thread, must enqueue asynchronously, and replaces its previous pending task. cancel may also be called from any thread (including during suspend): it must only drop the pending scheduled task so it will not run, and the Host binding must remain reusable for later schedule calls. Permanent teardown (refusing further schedules / freeing user_data) happens only when the SDK releases the binding after detach or destroy — not inside cancel. Neither callback may call engine/Value APIs. The SDK owns user_data through detach or destruction. */
typedef void (*jsbay_loop_task_t)(void *task_data);
typedef bool (*jsbay_loop_schedule_t)(void *user_data, uint64_t delay_ms,
    jsbay_loop_task_t task, void *task_data);
typedef void (*jsbay_loop_cancel_t)(void *user_data);
jsbay_status_t jsbay_engine_attach_loop(int instance_id,
    jsbay_loop_schedule_t schedule, jsbay_loop_cancel_t cancel, void *user_data);
jsbay_status_t jsbay_engine_detach_loop(int instance_id);
/* Returns JSBAY_LOOP_FAILED when the platform rejected scheduling. A failed loop remains stopped until explicitly reattached. */
jsbay_status_t jsbay_engine_loop_status(int instance_id);
/* Run on the owner thread until stopped. An attached platform loop must first be detached. Calling it from a synchronous native callback, queued task, or microtask returns JSBAY_INVALID_ARGUMENT because the current JavaScript turn must finish first. stop_loop is thread-safe; it ends an active run without destroying the engine. When no run is active the request applies to the next run, which consumes it, and attach_loop discards a request made before it. While a platform loop is attached it stops that loop's driving until jsbay_engine_detach_loop and a later attach, and detach discards the request. */
jsbay_status_t jsbay_engine_run_loop(int instance_id);
bool jsbay_engine_stop_loop(int instance_id);
/* Thread-safe keep-alive pause for multi-instance Hide/Show. Cancels a pending platform schedule without detaching the Host or clearing timers, tasks, binds, or globals. Distinct from stop_loop (ends a blocking run), detach_loop (drops the Host), and destroy. */
bool jsbay_engine_suspend(int instance_id);
/* Thread-safe resume after suspend. Does not recreate the engine; re-schedules attached work so overdue timers catch up on real monotonic time. */
bool jsbay_engine_resume(int instance_id);
bool jsbay_engine_is_suspended(int instance_id);
bool jsbay_engine_inspector_start(int instance_id, uint16_t port, uint16_t *out_port);
void jsbay_engine_inspector_stop(int instance_id);

#ifdef __cplusplus
}
#endif

#endif
