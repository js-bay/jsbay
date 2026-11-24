package io.jsbay

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

open class DedicatedEngineThreadTimeoutException(
    message: String,
) : RuntimeException(message)

/** Observable lifecycle states of a dedicated engine thread. */
enum class DedicatedEngineThreadState {
    RUNNING,
    CLOSING,
    CLOSED,
    FAILED,
}

/** One [Engine] owned by a dedicated Looper thread. Matches the multi-instance host pattern: one owner thread per instance id, never the process main/UI thread. Construct with [start], post work with [post], and [close] on any thread (close runs on the owner thread). */
class DedicatedEngineThread private constructor(
    val id: Int,
    private val thread: Thread,
    private val handler: Any,
    private val postMethod: java.lang.reflect.Method,
    private val engineRef: AtomicReference<Engine?>,
) : AutoCloseable {
    private val lock = Any()
    private var state = DedicatedEngineThreadState.RUNNING
    private var isExecutingJob = false
    private var shutdownInterruptedJob = false
    private var shutdownError: Throwable? = null
    private val shutdownLatch = CountDownLatch(1)

    /** Returns the current lifecycle state of the dedicated engine thread. */
    val lifecycleState: DedicatedEngineThreadState
        get() = synchronized(lock) { state }

    /** Indicates whether the dedicated engine thread is currently shutting down. */
    val isClosing: Boolean
        get() = lifecycleState == DedicatedEngineThreadState.CLOSING

    /** Indicates whether the dedicated engine thread has completely shut down. */
    val isClosed: Boolean
        get() =
            when (lifecycleState) {
                DedicatedEngineThreadState.CLOSED, DedicatedEngineThreadState.FAILED -> true
                DedicatedEngineThreadState.RUNNING, DedicatedEngineThreadState.CLOSING -> false
            }

    /** The live engine. Only call Engine APIs from [post] or from code already running on the owner thread. */
    val engine: Engine
        get() = engineRef.get() ?: throw JsBayException(Status.INSTANCE_NOT_FOUND)

    /** Queues [action] on the owner thread. Returns false if the thread has already quit or is closing. */
    fun post(action: Runnable): Boolean =
        synchronized(lock) {
            if (state != DedicatedEngineThreadState.RUNNING) {
                return false
            }
            postInternal(action)
        }

    private fun postInternal(action: Runnable): Boolean =
        try {
            val wrapped =
                Runnable {
                    synchronized(lock) {
                        isExecutingJob = true
                    }
                    try {
                        action.run()
                    } finally {
                        synchronized(lock) {
                            isExecutingJob = false
                            if (shutdownInterruptedJob) {
                                shutdownInterruptedJob = false
                                engineRef.get()?.clearInterrupt()
                            }
                        }
                    }
                }
            postMethod.invoke(handler, wrapped) as Boolean
        } catch (_: ReflectiveOperationException) {
            false
        }

    /** Runs [action] synchronously on the owner thread. Calls made from the owner thread execute inline to avoid deadlock. Propagates exceptions thrown by [action]. */
    fun <T> runOnOwner(action: (Engine) -> T): T {
        if (Thread.currentThread() === thread) {
            val liveEngine =
                synchronized(lock) {
                    when (state) {
                        DedicatedEngineThreadState.RUNNING, DedicatedEngineThreadState.CLOSING -> engineRef.get()
                        DedicatedEngineThreadState.CLOSED, DedicatedEngineThreadState.FAILED -> null
                    }
                } ?: throw JsBayException(Status.INSTANCE_NOT_FOUND)
            return action(liveEngine)
        }
        val done = CountDownLatch(1)
        val result = AtomicReference<Any?>(ABSENT)
        val error = AtomicReference<Throwable?>(null)
        val posted =
            synchronized(lock) {
                if (state != DedicatedEngineThreadState.RUNNING) {
                    false
                } else {
                    postInternal {
                        try {
                            result.set(action(engine))
                        } catch (t: Throwable) {
                            error.set(t)
                        } finally {
                            done.countDown()
                        }
                    }
                }
            }
        if (!posted) throw JsBayException(Status.INSTANCE_NOT_FOUND)
        done.await()
        error.get()?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return result.get() as T
    }

    /** Requests asynchronous interruption of JavaScript execution on the owner thread. Safe to call from any thread. */
    fun requestInterrupt(): Boolean = engineRef.get()?.requestInterrupt() ?: false

    /** Cancels execution on the owner thread. Safe to call from any thread. */
    fun cancel(): Boolean = engineRef.get()?.cancel() ?: false

    /** Clears a previously requested user interrupt before evaluating more JavaScript. Must run on the owner thread. */
    fun clearInterrupt(): Boolean = runOnOwner { it.clearInterrupt() }

    /** Sets an execution time limit in milliseconds for upcoming work on the owner thread. Must run on the owner thread. */
    fun setExecutionTimeLimit(millis: Long): Boolean = runOnOwner { it.setExecutionTimeLimit(millis) }

    /** Sets an execution budget in milliseconds applied to each outer evaluation. Must run on the owner thread. */
    fun setExecutionBudget(millis: Long): Boolean = runOnOwner { it.setExecutionBudget(millis) }

    /** Sets the memory limit in bytes. Must run on the owner thread. */
    fun setMemoryLimit(bytes: Long): Boolean = runOnOwner { it.setMemoryLimit(bytes) }

    fun close(timeoutMillis: Long) {
        if (Thread.currentThread() === thread) {
            // Reentrant or inline close from owner thread: execute shutdown directly.
            try {
                val current = engineRef.get()
                current?.close()
                engineRef.compareAndSet(current, null)
                synchronized(lock) {
                    if (state == DedicatedEngineThreadState.RUNNING) {
                        state = DedicatedEngineThreadState.CLOSING
                    }
                }
            } catch (t: Throwable) {
                synchronized(lock) {
                    shutdownError = t
                    state = DedicatedEngineThreadState.FAILED
                }
                throw t
            } finally {
                LoopDriver.quitCurrentLooperSafely()
            }
            return
        }

        val current = engineRef.get()
        synchronized(lock) {
            when (state) {
                DedicatedEngineThreadState.CLOSED, DedicatedEngineThreadState.FAILED -> {
                    shutdownError?.let { throw it }
                    return
                }
                DedicatedEngineThreadState.CLOSING -> {
                    if (isExecutingJob && !shutdownInterruptedJob) {
                        current?.requestInterrupt()
                        shutdownInterruptedJob = true
                    }
                }
                DedicatedEngineThreadState.RUNNING -> {
                    state = DedicatedEngineThreadState.CLOSING
                    if (current != null) {
                        if (isExecutingJob) {
                            current.requestInterrupt()
                            shutdownInterruptedJob = true
                        }
                        val posted =
                            postInternal {
                                try {
                                    if (engineRef.get() === current) {
                                        current.close()
                                        engineRef.compareAndSet(current, null)
                                    }
                                } catch (t: Throwable) {
                                    synchronized(lock) {
                                        if (shutdownError == null) {
                                            shutdownError = t
                                        }
                                        state = DedicatedEngineThreadState.FAILED
                                    }
                                } finally {
                                    LoopDriver.quitCurrentLooperSafely()
                                }
                            }
                        if (!posted) {
                            if (state != DedicatedEngineThreadState.CLOSED &&
                                state != DedicatedEngineThreadState.FAILED
                            ) {
                                state = DedicatedEngineThreadState.RUNNING
                            }
                            throw JsBayException(Status.INSTANCE_NOT_FOUND)
                        }
                    }
                }
            }
        }

        if (!shutdownLatch.await(timeoutMillis, TimeUnit.MILLISECONDS)) {
            current?.cancel()
            throw DedicatedEngineThreadTimeoutException("Timed out waiting for dedicated engine thread shutdown")
        }
        shutdownError?.let { throw it }
        thread.join(timeoutMillis)
    }

    private fun onOwnerLoopExited(loopError: Throwable? = null) {
        val lingeringEngine: Engine? =
            synchronized(lock) {
                val current = engineRef.get()
                if (current != null) {
                    engineRef.set(null)
                }
                if (state == DedicatedEngineThreadState.RUNNING) {
                    state = DedicatedEngineThreadState.CLOSING
                }
                current
            }
        var closeError: Throwable? = loopError
        if (lingeringEngine != null) {
            try {
                lingeringEngine.close()
            } catch (t: Throwable) {
                if (closeError == null) {
                    closeError = t
                }
            }
        }
        synchronized(lock) {
            if (state != DedicatedEngineThreadState.FAILED) {
                if (closeError != null) {
                    shutdownError = closeError
                    state = DedicatedEngineThreadState.FAILED
                } else {
                    state = DedicatedEngineThreadState.CLOSED
                }
            } else if (shutdownError == null && closeError != null) {
                shutdownError = closeError
            }
        }
        shutdownLatch.countDown()
    }

    override fun close() {
        close(30_000L)
    }

    companion object {
        private val ABSENT = Any()

        /** Creates and starts an engine on a private dedicated thread. */
        @JvmSynthetic
        operator fun invoke(
            id: Int,
            name: String = "jsbay-$id",
            options: EngineOptions = EngineOptions(),
        ): DedicatedEngineThread = start(id, name, options)

        /** Starts a dedicated Looper thread, constructs [Engine] there (auto-attaches LoopDriver), and returns a handle. The creating caller's thread is not the Engine owner. Use [post] / [runOnOwner] for Engine work, then [close]. */
        @JvmStatic
        @JvmOverloads
        fun start(
            id: Int,
            name: String = "jsbay-$id",
            options: EngineOptions = EngineOptions(),
        ): DedicatedEngineThread {
            val ready = CountDownLatch(1)
            val startedLatch = CountDownLatch(1)
            val failure = AtomicReference<Throwable?>(null)
            val engineRef = AtomicReference<Engine?>(null)
            val handlerRef = AtomicReference<Any?>(null)
            val postRef = AtomicReference<java.lang.reflect.Method?>(null)
            val threadRef = AtomicReference<Thread?>(null)
            val instanceRef = AtomicReference<DedicatedEngineThread?>(null)
            val thread =
                Thread({
                    try {
                        LoopDriver.prepareCurrentLooper()
                        if (LoopDriver.isCurrentMainLooper() && !options.allowMainLooperAttach) {
                            throw JsBayException(Status.INVALID_ARGUMENT)
                        }
                        val created = Engine(id, options)
                        val looperClass = Class.forName("android.os.Looper")
                        val looper =
                            looperClass.getMethod("myLooper").invoke(null)
                                ?: throw JsBayException(Status.INVALID_ARGUMENT)
                        val handlerClass = Class.forName("android.os.Handler")
                        val handler = handlerClass.getConstructor(looperClass).newInstance(looper)
                        val post = handlerClass.getMethod("post", Runnable::class.java)
                        engineRef.set(created)
                        handlerRef.set(handler)
                        postRef.set(post)
                    } catch (t: Throwable) {
                        failure.set(t)
                    } finally {
                        ready.countDown()
                    }
                    if (failure.get() == null) {
                        startedLatch.await()
                        var loopError: Throwable? = null
                        try {
                            loopError = loopCurrentLooper()
                        } catch (t: Throwable) {
                            loopError = t
                        } finally {
                            instanceRef.get()?.onOwnerLoopExited(loopError)
                        }
                    }
                }, name)
            threadRef.set(thread)
            thread.start()
            ready.await()
            failure.get()?.let { thrown ->
                thread.join(5_000)
                throw thrown
            }
            val instance =
                DedicatedEngineThread(
                    id,
                    thread,
                    handlerRef.get()!!,
                    postRef.get()!!,
                    engineRef,
                )
            instanceRef.set(instance)
            startedLatch.countDown()
            return instance
        }

        private fun loopCurrentLooper(): Throwable? {
            try {
                val looperClass = Class.forName("android.os.Looper")
                try {
                    looperClass.getMethod("loop").invoke(null)
                    return null
                } catch (_: NoSuchMethodException) {
                    // Host stub: park until quit clears the thread-local Looper.
                }
                val myLooper = looperClass.getMethod("myLooper")
                while (myLooper.invoke(null) != null) {
                    Thread.sleep(10)
                }
                return null
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return e
            } catch (e: java.lang.reflect.InvocationTargetException) {
                return e.targetException ?: e
            } catch (_: ReflectiveOperationException) {
                return null
            }
        }
    }
}
