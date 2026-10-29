package io.jsbay

/**
 * Creation policy for [Engine].
 *
 * Automatic LoopDriver attach uses the creating thread's Looper. Attaching to the process main Looper schedules JavaScript on the UI thread, which janks and deadlocks when many engines share it. The default refuses that attach; hosts that truly need it must set [allowMainLooperAttach]. Prefer [DedicatedEngineThread] (one owner thread per instance id).
 *
 * Optional [limits] maps to `jsbay_engine_create_with_limits` (or post-create `setResourceLimits` when handlers are also supplied) so multi-instance hosts can set a private admission budget at create time.
 *
 * Optional [logHandler] / [eventHandler] map to `jsbay_engine_create` with host hooks (see Observability).
 */
data class EngineOptions
    @JvmOverloads
    constructor(
        val allowMainLooperAttach: Boolean = false,
        val limits: ResourceLimits? = null,
        val logHandler: LogHandler? = null,
        val eventHandler: EventHandler? = null,
    )
