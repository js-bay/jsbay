package io.jsbay

/** Per-instance native admission budgets. Zero rejects every reservation of that resource. */
data class ResourceLimits(
    val maxTimers: Long = 4096,
    val maxTsfnHandles: Long = 256,
    val maxPendingCalls: Long = 4096,
    val maxPendingBytes: Long = 8L * 1024L * 1024L,
    val maxPendingTasks: Long = 4096,
) {
    init {
        require(maxTimers >= 0 && maxTsfnHandles >= 0 && maxPendingCalls >= 0 && maxPendingBytes >= 0 && maxPendingTasks >= 0) {
            "resource limits must be non-negative"
        }
    }
}

/** Snapshot of one instance's reservations and active Limits. */
data class ResourceUsage(
    val timers: Long,
    val tsfnHandles: Long,
    val pendingCalls: Long,
    val nativeTasks: Long,
    val scriptTasks: Long,
    val pendingBytes: Long,
    val limits: ResourceLimits,
)

/** Process-wide reservation counts and caps. nativeTasks and scriptTasks are separate pools. */
data class ResourceGlobalUsage(
    val timers: Long,
    val tsfnHandles: Long,
    val pendingCalls: Long,
    val nativeTasks: Long,
    val scriptTasks: Long,
    val pendingBytes: Long,
    val maxTimers: Long,
    val maxTsfnHandles: Long,
    val maxPendingCalls: Long,
    val maxNativeTasks: Long,
    val maxScriptTasks: Long,
    val maxPendingBytes: Long,
    val fgHeadroomTimers: Long,
    val fgHeadroomTsfnHandles: Long,
    val fgHeadroomPendingCalls: Long,
    val fgHeadroomNativeTasks: Long,
    val fgHeadroomScriptTasks: Long,
    val fgHeadroomPendingBytes: Long,
    val bgEffectiveMaxTimers: Long,
    val bgEffectiveMaxTsfnHandles: Long,
    val bgEffectiveMaxPendingCalls: Long,
    val bgEffectiveMaxNativeTasks: Long,
    val bgEffectiveMaxScriptTasks: Long,
    val bgEffectiveMaxPendingBytes: Long,
)

/** Any-thread ops view of one live instance. Lengths only; may tear across locks. */
data class InstanceSnapshot(
    val instanceId: Int,
    val generation: Long,
    val ownerThreadId: Long,
    val loopMode: Int,
    val flags: Int,
    val admissionClass: AdmissionClass,
    val timersReserved: Long,
    val timersRegistered: Long,
    val scriptTasksQueued: Long,
    val nativeTasksQueued: Long,
    val pendingBytes: Long,
    val maxTimers: Long,
    val maxPendingTasks: Long,
    val maxPendingBytes: Long,
)
