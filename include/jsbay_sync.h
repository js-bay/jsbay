#ifndef JSBAY_SYNC_H
#define JSBAY_SYNC_H

/* Optional synchronous-native-call extension.  Include jsbay.h first. */
#include "jsbay.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Starts one native operation. It runs on the engine owner thread while the JavaScript call is active. `this_value` and `args` are borrowed and may only be inspected during this call. The start callback must return immediately; it completes exactly once later with jsbay_sync_complete(). */
typedef void (*jsbay_native_sync_start_t)(int instance_id, void *user_data,
    uint64_t request_id, jsbay_value_t this_value, size_t argc,
    const jsbay_value_t *args);

typedef enum {
    JSBAY_SYNC_PAYLOAD_UTF8_STRING = 0, /* jsbay_value_new_string / new_error */
    JSBAY_SYNC_PAYLOAD_BYTES = 1,       /* ArrayBuffer (opaque octets) / new_error */
    JSBAY_SYNC_PAYLOAD_JSON = 2,        /* explicit opt-in: parse on owner thread */
} jsbay_sync_payload_kind_t;

/* Typed byte completion. Permitted from a completion thread. Copies `data` once into the request and never enters a VM.
   outcome must be JSBAY_OK or JSBAY_EXCEPTION.
   UTF8_STRING: OK → string; EXCEPTION → Error(message). Data must be valid UTF-8.
   BYTES: OK → ArrayBuffer (no UTF-8 check; engine may adopt the copy); EXCEPTION → Error(message), data must be valid UTF-8.
   JSON: OK/EXCEPTION → JSON.parse on the owner (invalid JSON → exception). Data must be valid UTF-8.
   Returns STALE_VALUE for a timed-out, cancelled, already completed, closed, or unknown request. */
jsbay_status_t jsbay_sync_complete(uint64_t request_id,
    jsbay_status_t outcome, jsbay_sync_payload_kind_t kind, jsbay_utf8_t data);

/* Publish a global synchronous native function. timeout_ms must be finite and non-zero. The JS owner waits without pumping a JS or platform event loop. A completion that depends on that same owner queue would deadlock and must use an asynchronous API instead. */
jsbay_status_t jsbay_engine_bind_sync(int instance_id, jsbay_utf8_t name,
    jsbay_native_sync_start_t start, void *user_data,
    jsbay_host_finalize_t finalize, uint64_t timeout_ms,
    jsbay_value_t *out_function, jsbay_value_t *out_exception);

#ifdef __cplusplus
}
#endif

#endif /* JSBAY_SYNC_H */
