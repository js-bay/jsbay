#ifndef JSBAY_ASYNC_H
#define JSBAY_ASYNC_H

#include "jsbay.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    JSBAY_ASYNC_PAYLOAD_UTF8_STRING = 0,
    JSBAY_ASYNC_PAYLOAD_BYTES = 1,
    JSBAY_ASYNC_PAYLOAD_JSON = 2,
    JSBAY_ASYNC_PAYLOAD_UNDEFINED = 3,
} jsbay_async_payload_kind_t;

/* Owner thread only. Creates a pending Promise and an opaque request id. All output pointers are required. The returned Promise is caller-owned. */
jsbay_status_t jsbay_promise_create(int instance_id, uint64_t *out_request_id,
                                    jsbay_value_t *out_promise, jsbay_value_t *out_exception);

/* Owner thread only. Settles once with a borrowed Value from the same instance. */
jsbay_status_t jsbay_promise_settle(uint64_t request_id, jsbay_status_t outcome,
                                    jsbay_value_t value);

/* Copies data and queues settlement on the owner thread. Safe from any thread. `outcome` must be JSBAY_OK or JSBAY_EXCEPTION. UTF8_STRING and BYTES exceptions become Error messages; JSON is parsed for either outcome and malformed JSON rejects with its parse error. An admission already in progress returns retryable JSBAY_OUT_OF_MEMORY; after acceptance, later attempts return JSBAY_STALE_VALUE. Owner-side result allocation failure rejects with an Error retained at request creation. */
jsbay_status_t jsbay_async_complete(uint64_t request_id, jsbay_status_t outcome,
                                    jsbay_async_payload_kind_t kind, jsbay_utf8_t data);

/* Queues one rejection with a neutral cancellation Error. Safe from any thread. */
jsbay_status_t jsbay_async_cancel(uint64_t request_id);

#ifdef __cplusplus
}
#endif

#endif /* JSBAY_ASYNC_H */
