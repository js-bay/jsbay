package io.jsbay

/** Library-owned class: libjsbay_android uses RegisterNatives, never Java_* symbols. */
internal object Native {
    init {
        System.loadLibrary("jsbay_android")
    }

    external fun create(id: Int): Boolean

    external fun createWithLimits(
        id: Int,
        maxTimers: Long,
        maxTsfnHandles: Long,
        maxPendingCalls: Long,
        maxPendingBytes: Long,
        maxPendingTasks: Long,
    ): Boolean

    external fun setResourceLimits(
        id: Int,
        maxTimers: Long,
        maxTsfnHandles: Long,
        maxPendingCalls: Long,
        maxPendingBytes: Long,
        maxPendingTasks: Long,
    ): Boolean

    external fun resourceUsage(id: Int): LongArray?

    external fun globalResourceUsage(): LongArray?

    external fun createWithHandlers(
        id: Int,
        logHandler: LogHandler?,
        eventHandler: EventHandler?,
    ): Boolean

    external fun destroy(id: Int)

    external fun setEventHandler(
        id: Int,
        eventHandler: EventHandler?,
    ): Boolean

    external fun getMemoryUsage(id: Int): LongArray?

    external fun runGc(id: Int): Boolean

    external fun requestInterrupt(id: Int): Boolean

    external fun clearInterrupt(id: Int): Boolean

    external fun timeLimit(
        id: Int,
        millis: Long,
    ): Boolean

    external fun memoryLimit(
        id: Int,
        bytes: Long,
    ): Boolean

    external fun attachLoop(id: Int): Long

    external fun detachLoop(
        id: Int,
        binding: Long,
    ): Int

    external fun loopStatus(id: Int): Int

    external fun runLoop(id: Int): Int

    external fun stopLoop(id: Int): Boolean

    external fun suspendLoop(id: Int): Boolean

    external fun resumeLoop(id: Int): Boolean

    external fun isSuspended(id: Int): Boolean

    external fun setAdmissionClass(id: Int, cls: Int): Boolean

    external fun getAdmissionClass(id: Int): Int

    external fun listEngines(): IntArray

    external fun snapshotEngine(id: Int): LongArray?

    external fun runLoopTask(
        binding: Long,
        generation: Long,
    )

    external fun evaluate(
        id: Int,
        source: ByteArray,
        filename: String,
        dir: String?,
        version: String?,
    ): LongArray

    external fun retain(value: Long): LongArray

    external fun release(
        engine: Engine,
        value: Long,
    )

    external fun type(
        engine: Engine,
        value: Long,
    ): Int

    external fun number(
        engine: Engine,
        value: Long,
    ): Double

    external fun bool(
        engine: Engine,
        value: Long,
    ): Boolean

    external fun toUtf8(
        engine: Engine,
        value: Long,
    ): String

    external fun toJson(
        engine: Engine,
        value: Long,
    ): String

    external fun get(
        value: Long,
        key: String,
    ): LongArray

    external fun set(
        engine: Engine,
        objectValue: Long,
        key: String,
        value: Long,
    )

    external fun call(
        function: Long,
        thisValue: Long,
        args: LongArray,
    ): LongArray

    external fun construct(
        function: Long,
        args: LongArray,
    ): LongArray

    external fun has(
        value: Long,
        key: String,
    ): LongArray

    external fun delete(
        value: Long,
        key: String,
    ): LongArray

    external fun keys(value: Long): LongArray

    external fun instanceOf(
        value: Long,
        constructor: Long,
    ): LongArray

    external fun undefined(id: Int): LongArray

    external fun nullValue(id: Int): LongArray

    external fun global(id: Int): LongArray

    external fun bind(
        id: Int,
        name: String,
        callback: Callback,
    ): LongArray

    external fun bindSync(
        id: Int,
        name: String,
        starter: SyncStarter,
        timeoutMillis: Long,
    ): LongArray

    external fun syncComplete(
        requestId: Long,
        outcome: Int,
        kind: Int,
        data: ByteArray,
    ): Int

    external fun startInspector(
        id: Int,
        port: Short,
    ): Int

    external fun stopInspector(id: Int)

    external fun newBool(
        id: Int,
        value: Boolean,
    ): LongArray

    external fun newNumber(
        id: Int,
        value: Double,
    ): LongArray

    external fun newString(
        id: Int,
        value: String,
    ): LongArray

    external fun newJson(
        id: Int,
        value: String,
    ): LongArray

    external fun newError(
        id: Int,
        value: String,
    ): LongArray

    external fun newObject(id: Int): LongArray

    external fun newArray(id: Int): LongArray

    external fun newArrayBuffer(
        id: Int,
        value: ByteArray,
    ): LongArray

    external fun copyBuffer(
        engine: Engine,
        value: Long,
    ): ByteArray
}
