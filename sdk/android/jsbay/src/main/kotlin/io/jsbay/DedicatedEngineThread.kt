package io.jsbay

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

open class DedicatedEngineThreadTimeoutException(
    message: String,
) : RuntimeException(message)

/** One [Engine] owned by a dedicated Looper thread. Matches the multi-instance host pattern: one owner thread per instance id, never the process main/UI thread. Construct with [start], post work with [post], and request [close] on any thread (nonblocking; creator drain completes teardown). */
class DedicatedEngineThread private constructor(
    val id: Int,
    private val thread: Thread,
    private val handler: Any,
    private val postMethod: java.lang.reflect.Method,
    private val engineRef: AtomicReference<Engine?>,
) : AutoCloseable {
    private val lock = Any()
    private var isExecutingJob = false
    private var shutdownInterruptedJob = false

    /** The live engine. Only call Engine APIs from [post] or from code already running on the owner thread. */
    val engine: Engine
        get() = engineRef.get() ?: throw JsBayException(Status.INSTANCE_NOT_FOUND)

    /** Queues [action] on the owner thread. Returns false if the thread has already quit. */
    fun post(action: Runnable): Boolean =
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
            val liveEngine = engineRef.get() ?: throw JsBayException(Status.INSTANCE_NOT_FOUND)
            return action(liveEngine)
        }
        val done = CountDownLatch(1)
        val result = AtomicReference<Any?>(ABSENT)
        val error = AtomicReference<Throwable?>(null)
        val posted =
            post {
                try {
                    result.set(action(engine))
                } catch (t: Throwable) {
                    error.set(t)
                } finally {
                    done.countDown()
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

    /** Explicit bounded compatibility wait. Never call from a requester that the creator is joining; prefer requestClose. Timeout is not completion. */
    fun close(timeoutMillis: Long) {
        require(timeoutMillis > 0) { "A positive close timeout is required" }
        if (Thread.currentThread() === thread) {
            close()
            if (closeStatus() != CloseStatus.COMPLETE) {
                throw DedicatedEngineThreadTimeoutException(
                    "Creator callback cannot wait for its own drain; destruction pending",
                )
            }
            return
        }
        val budget = TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        val started = System.nanoTime()
        val done = CountDownLatch(1)
        val error = AtomicReference<Throwable?>(null)
        val posted =
            synchronized(lock) {
                val current = engineRef.get()
                if (isExecutingJob && current != null) {
                    current.requestInterrupt()
                    shutdownInterruptedJob = true
                }
                post {
                    try {
                        close()
                    } catch (failure: Throwable) {
                        error.set(failure)
                    } finally {
                        done.countDown()
                    }
                }
            }
        if (!posted) {
            if (!thread.isAlive && closeStatus() == CloseStatus.COMPLETE) return
            requestClose()
            throw DedicatedEngineThreadTimeoutException("Owner unavailable; destruction pending")
        }
        val remaining = budget - (System.nanoTime() - started)
        if (remaining <= 0 || !done.await(remaining, TimeUnit.NANOSECONDS)) {
            requestClose()
            throw DedicatedEngineThreadTimeoutException(
                "Timed out awaiting creator drain; completion is not acknowledged",
            )
        }
        error.get()?.let { throw it }
        val joinRemaining = budget - (System.nanoTime() - started)
        if (joinRemaining > 0 && thread.isAlive) {
            thread.join(joinRemaining / 1_000_000, (joinRemaining % 1_000_000).toInt())
        }
        if (thread.isAlive || closeStatus() != CloseStatus.COMPLETE) {
            throw DedicatedEngineThreadTimeoutException("Creator drain or thread-exit acknowledgement pending")
        }
    }

    private val closePosted = AtomicBoolean(false)

    /** Nonblocking on every thread. A stopped owner leaves the native generation pending. */
    fun requestClose(): CloseStatus {
        val current = engineRef.get() ?: return CloseStatus.COMPLETE
        val status = current.requestClose()
        if (closePosted.compareAndSet(false, true)) {
            if (!post {
                    closePosted.set(false)
                    finishClose(current)
                }
            ) {
                closePosted.set(false)
            }
        }
        return status
    }

    /** Data-only VM progress, not proof that the Looper thread has exited. */
    fun closeStatus(): CloseStatus = engineRef.get()?.closeStatus() ?: CloseStatus.COMPLETE

    private fun finishClose(current: Engine) {
        if (current.drainClose() == CloseStatus.COMPLETE) {
            engineRef.compareAndSet(current, null)
            LoopDriver.quitCurrentLooperSafely()
        }
    }

    /** Migration: close requests asynchronously; use closeStatus, never block the creator joining a requester. */
    override fun close() {
        val current = engineRef.get() ?: return
        requestClose()
        if (Thread.currentThread() === thread) finishClose(current)
    }

    companion object {
        private val ABSENT = Any()

        /** Starts a dedicated Looper thread, constructs [Engine] there (auto-attaches LoopDriver), and returns a handle. The creating caller's thread is not the Engine owner. Use [post] / [runOnOwner] for Engine work, then [close]. */
        @JvmStatic
        @JvmOverloads
        fun start(
            id: Int,
            name: String = "jsbay-$id",
            options: EngineOptions = EngineOptions(),
        ): DedicatedEngineThread {
            val ready = CountDownLatch(1)
            val failure = AtomicReference<Throwable?>(null)
            val engineRef = AtomicReference<Engine?>(null)
            val handlerRef = AtomicReference<Any?>(null)
            val postRef = AtomicReference<java.lang.reflect.Method?>(null)
            val threadRef = AtomicReference<Thread?>(null)
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
                        loopCurrentLooper()
                    }
                }, name)
            threadRef.set(thread)
            thread.start()
            ready.await()
            failure.get()?.let { thrown ->
                thread.join(5_000)
                throw thrown
            }
            return DedicatedEngineThread(
                id,
                thread,
                handlerRef.get()!!,
                postRef.get()!!,
                engineRef,
            )
        }

        private fun loopCurrentLooper() {
            try {
                val looperClass = Class.forName("android.os.Looper")
                try {
                    looperClass.getMethod("loop").invoke(null)
                    return
                } catch (_: NoSuchMethodException) {
                    // Host stub: park until quit clears the thread-local Looper.
                }
                val myLooper = looperClass.getMethod("myLooper")
                while (myLooper.invoke(null) != null) {
                    Thread.sleep(10)
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } catch (_: ReflectiveOperationException) {
                // No Looper loop available.
            }
        }
    }
}
