#ifndef JSBAY_BYTECODE_H
#define JSBAY_BYTECODE_H
#include "jsbay.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Low-level trusted-build API. Normal scripts should use evaluate with cache options instead. Bytecode bytes are released with jsbay_free_bytes. */
jsbay_status_t jsbay_engine_compile_bytecode(int instance_id, jsbay_utf8_t source,
                                                jsbay_utf8_t filename,
                                                jsbay_bytes_t *out_bytecode,
                                                jsbay_value_t *out_exception);
jsbay_status_t jsbay_engine_run_bytecode(int instance_id, const uint8_t *bytecode,
                                            size_t bytecode_len,
                                            jsbay_value_t *out_value,
                                            jsbay_value_t *out_exception);
#ifdef __cplusplus
}
#endif
#endif
