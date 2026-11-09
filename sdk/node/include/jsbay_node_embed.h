#ifndef JSBAY_NODE_EMBED_H
#define JSBAY_NODE_EMBED_H

#include <node_api.h>

#include "jsbay.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*jsbay_node_destroy_callback_t)(void *user_data);
typedef void (*jsbay_node_task_observer_t)(void *user_data, bool entering);

/* Creates an Engine wrapper for a caller-owned instance id. The caller retains user_data until this function succeeds. The log handler follows the JsBay C ABI callback rules and runs only while the Engine is alive. After a successful return, destroy_callback receives user_data exactly once after the native engine is destroyed. It may release native and Node-API references, including during environment cleanup, but must not call JavaScript or create or use JsBay values. */
napi_value jsbay_node_create(napi_env env, int instance_id, jsbay_log_handler_t log_handler, void *user_data, jsbay_node_destroy_callback_t destroy_callback);

/* Requests engine shutdown. It is safe to call repeatedly. */
void jsbay_node_close(napi_env env, napi_value engine);

/* Observes SDK-owned loop task execution. Calls are balanced on the owner thread. The callback must not call Node-API or JsBay APIs. */
bool jsbay_node_set_task_observer(napi_env env, napi_value engine, jsbay_node_task_observer_t observer, void *user_data);

#ifdef __cplusplus
}
#endif

#endif
