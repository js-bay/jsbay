package io.jsbay

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

open class DedicatedEngineThreadTimeoutException(
    message: String,
) : RuntimeException(message)

/** One [Engine] owned by a dedicated Looper thread. Matches the multi-instance host pattern: one owner thread per instance id, never the process main/UI thread. Construct with [start], post work with [post], and [close] on any thread (close runs on the owner thread). */
class DedicatedEngineThread private constructor(
    val id: Int,
    private val thread: Thread,
    private val handler: Any,
    private val postMethod: java.lang.reflect.Method,
    private val engineRef: AtomicReference<Engine?>,
) : AutoCloseable {
    /** The live engine. Only call Engine APIs from [post] or from code already running on the owner thread. */
    val engine: Engine
        get() = engineRef.get() ?: throw JsBayException(Status.INSTANCE_NOT_FOUND)

    /** Queues [action] on the owner thread. Returns false if the thread has already quit. */
    fun post(action: Runnable): Boolean =
        try {
            postMethod.invoke(handler, action) as Boolean
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

    fun close(timeoutMillis: Long) {
        // Never clear engineRef before a successful owner-thread destroy — otherwise instance ids are orphaned.
        val current = engineRef.get() ?: return
        if (Thread.currentThread() === thread) {
            try {
                current.close()
                engineRef.compareAndSet(current, null)
            } finally {
                LoopDriver.quitCurrentLooperSafely()
            }
            return
        }
        val done = CountDownLatch(1)
        val error = AtomicReference<Throwable?>(null)
        val destroyed = AtomicReference(false)
        val posted =
            post {
                try {
                    if (engineRef.get() !== current) return@post
                    current.close()
                    engineRef.compareAndSet(current, null)
                    destroyed.set(true)
                } catch (t: Throwable) {
                    error.set(t)
                } finally {
                    LoopDriver.quitCurrentLooperSafely()
                    done.countDown()
                }
            }
        if (!posted) {
            // Dead / quit Looper: Handler.post failed. Best-effort policy (R2): leave engineRef set so
            // the native instance id is not silently orphaned; caller must recover (process restart or
            // a last-ditch owner-thread destroy if the thread is somehow still alive). close() does not
            // call Native.destroy from a foreign thread.
            throw JsBayException(Status.INSTANCE_NOT_FOUND)
        }
        // Cancel the running execution generation so an infinite JS loop does not prevent the Looper from dispatching the destroy task.
        current.cancel()
        if (!done.await(timeoutMillis, TimeUnit.MILLISECONDS)) {
            // Timed out waiting for owner destroy; leave engineRef intact so the native id is not orphaned from Kotlin's view.
            throw DedicatedEngineThreadTimeoutException("Timed out waiting for dedicated engine thread shutdown")
        }
        error.get()?.let { throw it }
        if (!destroyed.get() && engineRef.get() === current) {
            throw JsBayException(Status.INSTANCE_NOT_FOUND)
        }
        thread.join(timeoutMillis)
    }

    override fun close() {
        close(30_000L)
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
