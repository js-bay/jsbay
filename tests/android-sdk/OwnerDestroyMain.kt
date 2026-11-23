package io.jsbay

import android.os.Handler
import android.os.HandlerThread
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Real ART checks; counters are available only in the independent diagnostic core. */
object OwnerDestroyMain {
    private external fun probeReset(id: Int)

    private external fun probeStats(): LongArray

    private external fun probeTid(): Long

    private external fun probeCommit(): String

    private fun pending() {
        check(probeStats().take(2) == listOf(0L, 0L))
        check(probeStats()[3] == 0L)
    }

    private fun released(owner: Long) {
        val stats = probeStats()
        check(stats.contentEquals(longArrayOf(1, 1, owner, 1, owner))) { stats.joinToString() }
    }

    @JvmStatic fun main(args: Array<String>) {
        try {
            verify(args)
        } catch (failure: Throwable) {
            failure.printStackTrace(System.err)
            throw failure
        }
    }

    private fun verify(args: Array<String>) {
        System.loadLibrary("jsbay_owner_probe")
        check(probeCommit() == System.getProperty("jsbay.expectedCommit"))
        if (args.firstOrNull() == "owner-exited") {
            val ref = AtomicReference<Engine>()
            val worker =
                Thread {
                    val engine = Engine(92020)
                    probeReset(engine.id)
                    ref.set(engine)
                }
            worker.start()
            worker.join(3000)
            check(!worker.isAlive)
            val engine = ref.get()
            check(engine.requestClose() == CloseStatus.PENDING)
            check(engine.closeStatus() == CloseStatus.PENDING)
            check(Native.drainDestroy(engine.id, NativeGeneration.value(engine), 0) == CloseStatus.WRONG_THREAD.native)
            pending()
            println("PASS: exited creator remains PENDING; no VM release claimed")
            return
        }
        val engine = Engine(92001)
        val owner = probeTid()
        val generation = Engine.snapshot(engine.id)!!.generation
        probeReset(engine.id)
        check(engine.closeStatus() == CloseStatus.LIVE)
        val held = engine.number(17.0)
        val completions = AtomicInteger(0)
        val completionStatus = AtomicReference<SubmissionStatus>()
        val completionTid = AtomicReference<Long>()
        check(
            engine.postScript("throw new Error('must never execute')") {
                completionStatus.set(it.status)
                completionTid.set(probeTid())
                completions.incrementAndGet()
            },
        )
        val failures = AtomicReference<Throwable>()
        val workers =
            List(8) {
                Thread {
                    try {
                        check(engine.requestClose() == CloseStatus.PENDING)
                    } catch (
                        error: Throwable,
                    ) {
                        failures.set(error)
                    }
                }
            }
        workers.forEach(Thread::start)
        workers.forEach {
            it.join(3000)
            check(!it.isAlive)
        }
        failures.get()?.let { throw it }
        pending()
        check(engine.closeStatus() == CloseStatus.PENDING)
        check(completions.get() == 0)
        try {
            held.number()
            error("pending Value unexpectedly admitted")
        } catch (failure: JsBayException) {
            check(failure.status == Status.STALE_VALUE)
        }
        held.close()
        check(engine.drainClose() == CloseStatus.COMPLETE)
        check(completions.get() == 1)
        check(completionStatus.get() == SubmissionStatus.CANCELLED)
        check(completionTid.get() == owner)
        released(owner)
        engine.close()
        check(engine.requestClose() == CloseStatus.COMPLETE)
        val replacement = Engine(engine.id)
        check(Native.requestDestroy(engine.id, generation) == CloseStatus.STALE.native)
        check(engine.closeStatus() == CloseStatus.COMPLETE)
        replacement.evaluate("40+2").use { check(it.number() == 42.0) }
        replacement.close()
        println("PASS: concurrent requests, manual creator drain, duplicate close, generation isolation")

        val callbackEngine = Engine(92002)
        probeReset(callbackEngine.id)
        callbackEngine
            .bind("closeFromCallback") { _, _ ->
                val result = callbackEngine.number(2.0)
                callbackEngine.close()
                check(callbackEngine.closeStatus() == CloseStatus.PENDING)
                check(callbackEngine.drainClose() == CloseStatus.PENDING)
                pending()
                result
            }.close()
        try {
            callbackEngine.evaluate("closeFromCallback()")
            error("closed evaluation unexpectedly succeeded")
        } catch (error: JsBayException) {
            check(error.status == Status.INSTANCE_NOT_FOUND)
        }
        pending()
        check(callbackEngine.drainClose() == CloseStatus.COMPLETE)
        released(owner)
        println("PASS: callback reentry defers VM/JNI release until creator drain")

        val thread = HandlerThread("jsbay-close-owner")
        thread.start()
        val handler = Handler(thread.looper)
        val done = CountDownLatch(1)
        val error = AtomicReference<Throwable>()
        handler.post {
            try {
                val loopEngine = Engine(92003)
                val loopOwner = probeTid()
                val loopGeneration = Engine.snapshot(loopEngine.id)!!.generation
                val field = Engine::class.java.getDeclaredField("loopBinding").apply { isAccessible = true }
                val oldHandle = field.getLong(loopEngine)
                probeReset(loopEngine.id)
                val request = Thread { loopEngine.requestClose() }
                request.start()
                request.join(3000)
                check(!request.isAlive)
                pending()
                handler.post {
                    try {
                        check(loopEngine.closeStatus() == CloseStatus.COMPLETE)
                        released(loopOwner)
                        val next = Engine(loopEngine.id)
                        check(field.getLong(next) != oldHandle)
                        check(Native.drainDestroy(next.id, loopGeneration, oldHandle) == CloseStatus.STALE.native)
                        Native.runLoopTask(oldHandle, 1)
                        next.evaluate("6*7").use { check(it.number() == 42.0) }
                        next.close()
                    } catch (failure: Throwable) {
                        error.set(failure)
                    } finally {
                        done.countDown()
                    }
                }
            } catch (failure: Throwable) {
                error.set(failure)
                done.countDown()
            }
        }
        check(done.await(5, TimeUnit.SECONDS))
        thread.quitSafely()
        thread.join(3000)
        check(!thread.isAlive)
        error.get()?.let { throw it }
        println("PASS: real Looper async drain, creator join, native handle reuse isolation")
        val dedicated = DedicatedEngineThread.start(7915)
        val dedicatedDone = CountDownLatch(1)
        dedicated.runOnOwner { current ->
            probeReset(current.id)
            val creatorTid = probeTid()
            val requester = Thread { dedicated.close() }
            requester.start()
            requester.join(3000)
            check(!requester.isAlive)
            check(dedicated.closeStatus() == CloseStatus.PENDING)
            check(probeStats().contentEquals(longArrayOf(0, 0, 0, 0, 0)))
            check(
                dedicated.post {
                    try {
                        check(dedicated.closeStatus() == CloseStatus.COMPLETE)
                        check(probeStats().contentEquals(longArrayOf(1, 1, creatorTid, 1, creatorTid)))
                    } catch (failure: Throwable) {
                        error.set(failure)
                    } finally {
                        dedicatedDone.countDown()
                    }
                },
            )
        }
        check(dedicatedDone.await(5, TimeUnit.SECONDS))
        error.get()?.let { throw it }
        dedicated.close()
        println("PASS: DedicatedEngineThread asynchronous close while creator joins requester")
        Class.forName("io.jsbay.consumer.OwnerCloseJava").getMethod("verify").invoke(null)
        println("PASS: Java consumer owner/request/drain lifecycle")
    }

    /** Capture a published token before the isolated creator exits. */
    private object NativeGeneration {
        fun value(engine: Engine): Long {
            val field = Engine::class.java.getDeclaredField("generation").apply { isAccessible = true }
            return field.getLong(engine)
        }
    }
}
