package io.jsbay

/** Snapshot of engine allocator stats from `jsbay_engine_get_memory_usage`. */
data class MemoryUsage(
    val mallocCount: Long = 0,
    val mallocSize: Long = 0,
    val mallocLimit: Long = 0,
    val memoryUsedCount: Long = 0,
    val memoryUsedSize: Long = 0,
    val atomCount: Long = 0,
    val atomSize: Long = 0,
    val objCount: Long = 0,
    val objSize: Long = 0,
    val shapeCount: Long = 0,
)

fun interface LogHandler {
    fun onLog(
        instanceId: Int,
        level: Int,
        message: String,
    )
}

/** Telemetry kinds matching `jsbay_engine_event_kind_t`. */
object EngineEventKind {
    const val LOG = 0
    const val EXECUTION_INTERRUPTED = 1
    const val MEMORY_LIMIT = 2
    const val LOOP_FAILED = 3
}

fun interface EventHandler {
    fun onEvent(
        kind: Int,
        instanceId: Int,
        status: Int,
        detail: Long,
        message: String?,
    )
}
