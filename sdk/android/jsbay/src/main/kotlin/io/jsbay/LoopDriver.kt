package io.jsbay

/** Owns one pending core loop task on the Engine's creating Looper. */
internal class LoopDriver(
    private val nativeBinding: Long,
    private val engineId: Int,
) {
    private val handler: Any
    private val removeCallbacks: java.lang.reflect.Method
    private val postDelayed: java.lang.reflect.Method
    private var pending: Runnable? = null
    private var pendingGeneration = 0L
    private var closed = false

    init {
        val looperClass = Class.forName("android.os.Looper")
        val looper = looperClass.getMethod("myLooper").invoke(null) ?: error("LoopDriver requires a Looper")
        val handlerClass = Class.forName("android.os.Handler")
        handler = handlerClass.getConstructor(looperClass).newInstance(looper)
        removeCallbacks = handlerClass.getMethod("removeCallbacks", Runnable::class.java)
        postDelayed = handlerClass.getMethod("postDelayed", Runnable::class.java, Long::class.javaPrimitiveType!!)
    }

    @Synchronized
    fun schedule(
        delayMilliseconds: Long,
        generation: Long,
    ): Boolean {
        if (closed) return false
        pending?.let { removeCallbacks.invoke(handler, it) }
        val next = Runnable { run(generation) }
        pending = next
        pendingGeneration = generation
        return postDelayed.invoke(handler, next, delayMilliseconds) as Boolean
    }

    /** Soft cancel: drop the pending Host callback only. Binding stays reusable for suspend/resume. */
    @Synchronized
    fun cancel() {
        pending?.let { removeCallbacks.invoke(handler, it) }
        pending = null
        pendingGeneration = 0
    }

    /** Hard teardown used only when the native loop binding is being freed after detach/destroy. */
    @Synchronized
    fun shutdown() {
        closed = true
        pending?.let { removeCallbacks.invoke(handler, it) }
        pending = null
        pendingGeneration = 0
    }

    private fun run(generation: Long) {
        synchronized(this) {
            if (closed || pendingGeneration != generation) return
            pending = null
            pendingGeneration = 0
        }
        Native.runLoopTask(nativeBinding, generation)
        synchronized(this) {
            if (closed) return
        }
        val loopStatus = Status.of(Native.loopStatus(engineId))
        if (loopStatus != Status.OK) throw JsBayException(loopStatus)
    }

    companion object {
        fun hasCurrentLooper(): Boolean =
            try {
                Class.forName("android.os.Looper").getMethod("myLooper").invoke(null) != null
            } catch (_: ReflectiveOperationException) {
                false
            }

        /** True when the current thread's Looper is the process main Looper. When `getMainLooper` is absent (host stubs without a main Looper), returns false so non-main prepared Loopers still auto-attach. */
        fun isCurrentMainLooper(): Boolean {
            return try {
                val looperClass = Class.forName("android.os.Looper")
                val current = looperClass.getMethod("myLooper").invoke(null) ?: return false
                val main = looperClass.getMethod("getMainLooper").invoke(null) ?: return false
                current === main
            } catch (_: ReflectiveOperationException) {
                false
            }
        }

        /** Prepares a Looper on the current thread when the Android Looper API is present. */
        fun prepareCurrentLooper() {
            val looperClass = Class.forName("android.os.Looper")
            if (looperClass.getMethod("myLooper").invoke(null) == null) {
                looperClass.getMethod("prepare").invoke(null)
            }
        }

        /** Quits the current thread's Looper when a quit API is available. */
        fun quitCurrentLooperSafely() {
            try {
                val looperClass = Class.forName("android.os.Looper")
                val looper = looperClass.getMethod("myLooper").invoke(null) ?: return
                try {
                    looperClass.getMethod("quitSafely").invoke(looper)
                } catch (_: NoSuchMethodException) {
                    try {
                        looperClass.getMethod("quit").invoke(looper)
                    } catch (_: NoSuchMethodException) {
                        // Host stubs may only support prepare/advanceBy.
                    }
                }
            } catch (_: ReflectiveOperationException) {
                // No Looper on this runtime.
            }
        }
    }
}
