package io.jsbay

import java.util.ArrayDeque
import kotlin.jvm.JvmName
import kotlin.jvm.JvmSynthetic

class Engine
    @JvmOverloads
    constructor(
        val id: Int,
        options: EngineOptions = EngineOptions(),
    ) : AutoCloseable {
        /** Convenience: create with per-instance Limits and default main-Looper refusal. */
        constructor(id: Int, limits: ResourceLimits?) : this(id, EngineOptions(limits = limits))

        /** Convenience: create with optional log/event handlers (wiring observability). */
        constructor(
            id: Int,
            logHandler: LogHandler?,
            eventHandler: EventHandler? = null,
        ) : this(id, EngineOptions(logHandler = logHandler, eventHandler = eventHandler))

        private val owner = Thread.currentThread()

        @Volatile private var closed = false
        private var loopBinding: Long = 0
        private val lifecycleLock = Any()
        private val callbackScopes = ArrayDeque<CallbackScope>()
        private var backgroundThread: android.os.HandlerThread? = null

        init {
            val limits = options.limits
            val logHandler = options.logHandler
            val eventHandler = options.eventHandler
            val created =
                when {
                    logHandler != null || eventHandler != null ->
                        Native.createWithHandlers(id, logHandler, eventHandler)
                    limits != null ->
                        Native.createWithLimits(
                            id,
                            limits.maxTimers,
                            limits.maxTsfnHandles,
                            limits.maxPendingCalls,
                            limits.maxPendingBytes,
                            limits.maxPendingTasks,
                        )
                    else -> Native.create(id)
                }
            if (!created) throw JsBayException(Status.INVALID_ARGUMENT)
            // Handlers path uses plain create under the hood; apply limits afterward when both are set.
            if ((logHandler != null || eventHandler != null) && limits != null) {
                if (!Native.setResourceLimits(
                        id,
                        limits.maxTimers,
                        limits.maxTsfnHandles,
                        limits.maxPendingCalls,
                        limits.maxPendingBytes,
                        limits.maxPendingTasks,
                    )
                ) {
                    Native.destroy(id)
                    throw JsBayException(Status.INVALID_ARGUMENT)
                }
            }
            if (LoopDriver.hasCurrentLooper()) {
                if (LoopDriver.isCurrentMainLooper() && !options.allowMainLooperAttach) {
                    Native.destroy(id)
                    throw JsBayException(Status.INVALID_ARGUMENT)
                }
                loopBinding = Native.attachLoop(id)
                if (loopBinding == 0L) {
                    val status = Status.of(Native.loopStatus(id))
                    Native.destroy(id)
                    throw JsBayException(if (status == Status.OK) Status.INVALID_ARGUMENT else status)
                }
            }
        }

        internal fun checkOwner() {
            if (Thread.currentThread() !== owner) {
                throw JsBayException(Status.WRONG_THREAD)
            }
            if (closed) throw JsBayException(Status.INSTANCE_NOT_FOUND)
            val loopStatus = Status.of(Native.loopStatus(id))
            if (loopStatus != Status.OK) throw JsBayException(loopStatus)
        }

        internal fun isClosed(): Boolean = closed

        internal fun text(value: String): String {
            if (!value.hasValidSurrogatePairs()) throw JsBayException(Status.INVALID_ARGUMENT)
            return value
        }

        internal fun wrap(
            result: LongArray,
            trackScope: Boolean = true,
        ): Value {
            val status = Status.of(result[0].toInt())
            if (status == Status.OK) {
                return owned(result[1], trackScope)
            }
            throw JsBayException(status, if (result[2] != 0L) owned(result[2], trackScope) else null)
        }

        internal fun flag(result: LongArray): Boolean {
            val status = Status.of(result[0].toInt())
            if (status == Status.OK) {
                return result[1] != 0L
            }
            throw JsBayException(status, if (result[2] != 0L) owned(result[2]) else null)
        }

        internal fun owned(
            handle: Long,
            trackScope: Boolean = true,
        ): Value {
            if (handle == 0L) {
                throw JsBayException(Status.INVALID_ARGUMENT)
            }
            return Value(this, handle).also { if (trackScope) callbackScopes.lastOrNull()?.owned?.add(it) }
        }

        internal fun same(value: Value) {
            if (value.engine !== this) throw JsBayException(Status.STALE_VALUE)
        }

        @JvmSynthetic
        @JvmName("beginCallbackScopeForNative")
        internal fun beginCallbackScopeForNative(): CallbackScope {
            checkOwner()
            return CallbackScope().also(callbackScopes::addLast)
        }

        @JvmSynthetic
        @JvmName("endCallbackScopeForNative")
        internal fun endCallbackScopeForNative(scope: CallbackScope) {
            if (callbackScopes.lastOrNull() !== scope) {
                throw JsBayException(Status.INVALID_ARGUMENT)
            }
            callbackScopes.removeLast()
            scope.invalidate()
        }

        @JvmSynthetic
        @JvmName("borrowedForNative")
        internal fun borrowedForNative(handle: Long): Value {
            checkOwner()
            val scope =
                callbackScopes.peekLast() ?: throw JsBayException(Status.INVALID_ARGUMENT)
            return Value(this, handle, true).also(scope::recordBorrowed)
        }

        var lastCacheHit: Boolean = false
            private set

        @JvmOverloads fun evaluate(
            source: String,
            filename: String = "<eval>",
            cacheDirectory: String? = null,
            cacheVersion: String? = null,
        ): Value {
            checkOwner()
            val r =
                Native.evaluate(
                    id,
                    text(source).toByteArray(Charsets.UTF_8),
                    text(filename),
                    cacheDirectory?.let(::text),
                    cacheVersion?.let(::text),
                )
            lastCacheHit =
                r.size > 3 &&
                r[3] != 0L
            return wrap(r)
        }

        fun undefined(): Value {
            checkOwner()
            return wrap(Native.undefined(id))
        }

        fun nullValue(): Value {
            checkOwner()
            return wrap(Native.nullValue(id))
        }

        fun global(): Value {
            checkOwner()
            return wrap(Native.global(id))
        }

        fun bind(
            name: String,
            callback: Callback,
        ): Value {
            checkOwner()
            currentNativeEngine.set(this)
            try {
                return wrap(Native.bind(id, text(name), callback))
            } finally {
                currentNativeEngine.remove()
            }
        }

        fun bindSync(
            name: String,
            timeoutMillis: Long,
            starter: SyncStarter,
        ): Value {
            checkOwner()
            require(timeoutMillis > 0) { "timeoutMillis must be positive" }
            currentNativeEngine.set(this)
            try {
                return wrap(Native.bindSync(id, text(name), starter, timeoutMillis))
            } finally {
                currentNativeEngine.remove()
            }
        }

        @JvmOverloads fun startInspector(port: Int = 0): Int? {
            checkOwner()
            require(port in 0..65535) { "port must be between 0 and 65535" }
            return Native.startInspector(id, port.toShort()).takeIf {
                it !=
                    0
            }
        }

        fun stopInspector() {
            checkOwner()
            Native.stopInspector(id)
        }

        fun boolean(value: Boolean): Value {
            checkOwner()
            return wrap(Native.newBool(id, value))
        }

        fun number(value: Double): Value {
            checkOwner()
            return wrap(Native.newNumber(id, value))
        }

        fun string(value: String): Value {
            checkOwner()
            return wrap(Native.newString(id, text(value)))
        }

        fun json(value: String): Value {
            checkOwner()
            return wrap(Native.newJson(id, text(value)))
        }

        fun error(message: String): Value {
            checkOwner()
            return wrap(Native.newError(id, text(message)))
        }

        fun objectValue(): Value {
            checkOwner()
            return wrap(Native.newObject(id))
        }

        fun array(): Value {
            checkOwner()
            return wrap(Native.newArray(id))
        }

        fun arrayBuffer(value: ByteArray): Value {
            checkOwner()
            return wrap(Native.newArrayBuffer(id, value))
        }

        /** Runs the blocking loop on the creating thread when that thread has no Android Looper. Do not call this on the process main/UI thread. */
        fun runLoop() {
            checkOwner()
            if (loopBinding != 0L) throw JsBayException(Status.INVALID_ARGUMENT)
            val status = Status.of(Native.runLoop(id))
            if (status != Status.OK) throw JsBayException(status)
        }

        /** May be called from any thread, including a native callback. While the platform Looper drives the loop, this stops that automatic driving until the engine is closed. */
        fun stopLoop(): Boolean =
            synchronized(lifecycleLock) {
                !closed && Native.stopLoop(id)
            }

        /**
         * Keep-alive pause for multi-runtime Hide. Cancels pending loop tasks without
         * detaching the Looper binding or clearing timers/VM state. May be called from any thread.
         */
        fun suspendLoop(): Boolean =
            synchronized(lifecycleLock) {
                !closed && Native.suspendLoop(id)
            }

        /** Resume after [suspendLoop]. Does not recreate the engine. May be called from any thread. */
        fun resumeLoop(): Boolean =
            synchronized(lifecycleLock) {
                !closed && Native.resumeLoop(id)
            }

        fun isSuspended(): Boolean =
            synchronized(lifecycleLock) {
                !closed && Native.isSuspended(id)
            }

        /** Future timer/task admissions only. Pair Hide→BACKGROUND and Show→FOREGROUND with suspend/resume. */
        fun setAdmissionClass(cls: AdmissionClass): Boolean =
            synchronized(lifecycleLock) {
                !closed && Native.setAdmissionClass(id, cls.native)
            }

        fun getAdmissionClass(): AdmissionClass? =
            synchronized(lifecycleLock) {
                if (closed) return@synchronized null
                AdmissionClass.fromNative(Native.getAdmissionClass(id))
            }

        fun requestInterrupt(): Boolean =
            synchronized(lifecycleLock) {
                !closed &&
                    Native.requestInterrupt(id)
            }

        fun clearInterrupt(): Boolean {
            checkOwner()
            return Native.clearInterrupt(id)
        }

        fun setExecutionTimeLimit(millis: Long): Boolean {
            checkOwner()
            return Native.timeLimit(id, millis)
        }

        fun setMemoryLimit(bytes: Long): Boolean {
            checkOwner()
            return Native.memoryLimit(id, bytes)
        }

        fun setResourceLimits(limits: ResourceLimits): Boolean {
            checkOwner()
            return Native.setResourceLimits(
                id,
                limits.maxTimers,
                limits.maxTsfnHandles,
                limits.maxPendingCalls,
                limits.maxPendingBytes,
                limits.maxPendingTasks,
            )
        }

        fun resourceUsage(): ResourceUsage {
            checkOwner()
            val raw = Native.resourceUsage(id) ?: throw JsBayException(Status.INVALID_ARGUMENT)
            require(raw.size >= 11) { "resource usage payload truncated" }
            return ResourceUsage(
                timers = raw[0],
                tsfnHandles = raw[1],
                pendingCalls = raw[2],
                nativeTasks = raw[3],
                scriptTasks = raw[4],
                pendingBytes = raw[5],
                limits =
                    ResourceLimits(
                        maxTimers = raw[6],
                        maxTsfnHandles = raw[7],
                        maxPendingCalls = raw[8],
                        maxPendingBytes = raw[9],
                        maxPendingTasks = raw[10],
                    ),
            )
        }

        fun getMemoryUsage(): MemoryUsage {
            checkOwner()
            val raw = Native.getMemoryUsage(id) ?: throw JsBayException(Status.INSTANCE_NOT_FOUND)
            return MemoryUsage(
                mallocCount = raw.getOrElse(0) { 0 },
                mallocSize = raw.getOrElse(1) { 0 },
                mallocLimit = raw.getOrElse(2) { 0 },
                memoryUsedCount = raw.getOrElse(3) { 0 },
                memoryUsedSize = raw.getOrElse(4) { 0 },
                atomCount = raw.getOrElse(5) { 0 },
                atomSize = raw.getOrElse(6) { 0 },
                objCount = raw.getOrElse(7) { 0 },
                objSize = raw.getOrElse(8) { 0 },
                shapeCount = raw.getOrElse(9) { 0 },
            )
        }

        fun runGc(): Boolean {
            checkOwner()
            return Native.runGc(id)
        }

        fun setEventHandler(handler: EventHandler?): Boolean {
            checkOwner()
            return Native.setEventHandler(id, handler)
        }

        override fun close() {
            val destroy =
                synchronized(lifecycleLock) {
                    if (closed) {
                        false
                    } else {
                        if (Thread.currentThread() !== owner) {
                            throw JsBayException(Status.WRONG_THREAD)
                        }
                        true
                    }
                }
            if (!destroy) return
            if (loopBinding != 0L) {
                val detach = Status.of(Native.detachLoop(id, loopBinding))
                if (detach != Status.OK) {
                    throw JsBayException(detach)
                }
                loopBinding = 0
            }
            synchronized(lifecycleLock) { closed = true }
            Native.destroy(id)
        }

        /** Any-thread control-plane snapshot of this engine; null if closed/tearing down. */
        fun snapshot(): InstanceSnapshot? =
            synchronized(lifecycleLock) {
                if (closed) return@synchronized null
                parseSnapshot(Native.snapshotEngine(id))
            }

        companion object {
            /** Live non-teardown-pending instance ids (arbitrary order). Any thread. */
            fun listEngines(): IntArray = Native.listEngines()

            /** Any-thread snapshot by id; null if missing or teardown-pending. */
            fun snapshot(id: Int): InstanceSnapshot? = parseSnapshot(Native.snapshotEngine(id))

            private fun parseSnapshot(raw: LongArray?): InstanceSnapshot? {
                if (raw == null) return null
                require(raw.size >= 14) { "instance snapshot payload truncated" }
                return InstanceSnapshot(
                    instanceId = raw[0].toInt(),
                    generation = raw[1],
                    ownerThreadId = raw[2],
                    loopMode = raw[3].toInt(),
                    flags = raw[4].toInt(),
                    admissionClass = AdmissionClass.fromNative(raw[5].toInt()) ?: AdmissionClass.FOREGROUND,
                    timersReserved = raw[6],
                    timersRegistered = raw[7],
                    scriptTasksQueued = raw[8],
                    nativeTasksQueued = raw[9],
                    pendingBytes = raw[10],
                    maxTimers = raw[11],
                    maxPendingTasks = raw[12],
                    maxPendingBytes = raw[13],
                )
            }

            fun globalResourceUsage(): ResourceGlobalUsage {
                val raw = Native.globalResourceUsage() ?: throw JsBayException(Status.INVALID_ARGUMENT)
                require(raw.size >= 24) { "global resource usage payload truncated" }
                return ResourceGlobalUsage(
                    timers = raw[0],
                    tsfnHandles = raw[1],
                    pendingCalls = raw[2],
                    nativeTasks = raw[3],
                    scriptTasks = raw[4],
                    pendingBytes = raw[5],
                    maxTimers = raw[6],
                    maxTsfnHandles = raw[7],
                    maxPendingCalls = raw[8],
                    maxNativeTasks = raw[9],
                    maxScriptTasks = raw[10],
                    maxPendingBytes = raw[11],
                    fgHeadroomTimers = raw[12],
                    fgHeadroomTsfnHandles = raw[13],
                    fgHeadroomPendingCalls = raw[14],
                    fgHeadroomNativeTasks = raw[15],
                    fgHeadroomScriptTasks = raw[16],
                    fgHeadroomPendingBytes = raw[17],
                    bgEffectiveMaxTimers = raw[18],
                    bgEffectiveMaxTsfnHandles = raw[19],
                    bgEffectiveMaxPendingCalls = raw[20],
                    bgEffectiveMaxNativeTasks = raw[21],
                    bgEffectiveMaxScriptTasks = raw[22],
                    bgEffectiveMaxPendingBytes = raw[23],
                )
            }

            private val currentNativeEngine = ThreadLocal<Engine>()

            /**
             * Creates the engine on a dedicated [android.os.HandlerThread] named `jsbay-<id>`.
             * [ready] runs on that owner thread; every Engine/Value call must stay there.
             * `requestInterrupt` / `stopLoop` remain cross-thread. The returned thread is owned by
             * the caller — quit it after [Engine.close] on the owner thread.
             */
            @JvmStatic
            @JvmOverloads
            fun createOnBackground(
                id: Int,
                logHandler: LogHandler? = null,
                eventHandler: EventHandler? = null,
                ready: (Engine) -> Unit,
            ): android.os.HandlerThread {
                val thread = android.os.HandlerThread("jsbay-$id")
                thread.start()
                android.os.Handler(thread.looper).post {
                    val engine = Engine(id, logHandler, eventHandler)
                    engine.backgroundThread = thread
                    ready(engine)
                }
                return thread
            }

            @JvmStatic @JvmSynthetic
            @JvmName("currentForNative")
            internal fun currentForNative(): Engine =
                currentNativeEngine.get() ?: throw JsBayException(Status.INVALID_ARGUMENT)

            @JvmStatic @JvmSynthetic
            @JvmName("raiseForNative")
            internal fun raiseForNative(
                engine: Engine,
                status: Int,
                exception: Long,
            ): Unit =
                throw JsBayException(
                    Status.of(status),
                    if (exception != 0L) {
                        engine.owned(exception)
                    } else {
                        null
                    },
                )
        }
    }

internal class CallbackScope {
    internal val owned = ArrayList<Value>()
    private val borrowed = ArrayList<Value>()

    internal fun recordBorrowed(value: Value) {
        borrowed.add(value)
    }

    internal fun invalidate() {
        borrowed.forEach(Value::invalidateFromScope)
        owned.asReversed().forEach { value -> runCatching { value.close() }.onFailure { value.invalidateFromScope() } }
    }
}
