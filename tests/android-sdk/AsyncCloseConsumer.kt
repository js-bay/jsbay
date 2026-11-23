package io.jsbay.consumer

import android.os.Handler
import android.os.HandlerThread
import io.jsbay.CloseStatus
import io.jsbay.DedicatedEngineThread
import io.jsbay.Engine
import io.jsbay.JsBayException
import io.jsbay.Status
import io.jsbay.SubmissionStatus
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Public-API consumer for actual packaged classes, with no diagnostic release counters. */
object AsyncCloseConsumer {
    @JvmStatic fun main(args: Array<String>) {
        try {
            if (args.firstOrNull() == "quit-owner") quitOwner() else verify()
        } catch (failure: Throwable) {
            failure.printStackTrace(System.err)
            throw failure
        }
    }

    private fun verify() {
        val engine = Engine(94101)
        val completions = AtomicInteger()
        val callbackError = AtomicReference<Throwable>()
        check(
            engine.postScript("throw new Error('must not execute')") {
                try {
                    check(it.status == SubmissionStatus.CANCELLED)
                    check(engine.requestClose() == CloseStatus.PENDING)
                    check(engine.closeStatus() == CloseStatus.PENDING)
                    check(engine.drainClose() == CloseStatus.PENDING)
                    completions.incrementAndGet()
                } catch (failure: Throwable) {
                    callbackError.set(failure)
                }
            },
        )
        requestConcurrently { engine.requestClose() }
        check(engine.closeStatus() == CloseStatus.PENDING)
        check(completions.get() == 0)
        check(engine.drainClose() == CloseStatus.COMPLETE)
        callbackError.get()?.let { throw it }
        check(completions.get() == 1)
        engine.close()
        println("PASS: queued cancellation callback requests/status/drain reentry")

        val callbackEngine = Engine(94102)
        callbackEngine
            .bind("closeInCallback") { _, _ ->
                val returned = callbackEngine.number(2.0)
                requestConcurrently { callbackEngine.requestClose() }
                check(callbackEngine.closeStatus() == CloseStatus.PENDING)
                callbackEngine.close()
                check(callbackEngine.drainClose() == CloseStatus.PENDING)
                returned
            }.close()
        try {
            callbackEngine.evaluate("closeInCallback()")
            error("pending callback evaluation unexpectedly succeeded")
        } catch (failure: JsBayException) {
            check(failure.status == Status.INSTANCE_NOT_FOUND)
        }
        check(callbackEngine.drainClose() == CloseStatus.COMPLETE)
        println("PASS: VM callback creator joins concurrent foreign requesters")

        val self = DedicatedEngineThread.start(94103)
        self.runOnOwner {
            self.close()
            check(self.closeStatus() == CloseStatus.COMPLETE)
        }
        self.close()
        println("PASS: dedicated helper self-thread close")
        dedicated(false, 94104)
        dedicated(true, 94105)
    }

    private fun requestConcurrently(request: () -> CloseStatus) {
        val error = AtomicReference<Throwable>()
        val threads =
            List(8) {
                Thread {
                    try {
                        repeat(16) { check(request() == CloseStatus.PENDING) }
                    } catch (
                        failure: Throwable,
                    ) {
                        error.set(failure)
                    }
                }
            }
        threads.forEach(Thread::start)
        threads.forEach {
            it.join(3000)
            check(!it.isAlive)
        }
        error.get()?.let { throw it }
    }

    private fun dedicated(
        reentrant: Boolean,
        id: Int,
    ) {
        val dedicated = DedicatedEngineThread.start(id)
        val done = CountDownLatch(1)
        val error = AtomicReference<Throwable>()
        dedicated.runOnOwner { engine ->
            if (reentrant) {
                engine
                    .bind("closeHelper") { _, _ ->
                        val result = engine.number(1.0)
                        dedicated.close()
                        check(dedicated.requestClose() == CloseStatus.PENDING)
                        check(engine.drainClose() == CloseStatus.PENDING)
                        result
                    }.close()
                try {
                    engine.evaluate("closeHelper()")
                    error("pending helper evaluation unexpectedly succeeded")
                } catch (failure: JsBayException) {
                    check(failure.status == Status.INSTANCE_NOT_FOUND)
                }
            } else {
                requestConcurrently { dedicated.requestClose() }
            }
            check(dedicated.closeStatus() == CloseStatus.PENDING)
            check(
                dedicated.post {
                    try {
                        check(dedicated.closeStatus() == CloseStatus.COMPLETE)
                    } catch (
                        failure: Throwable,
                    ) {
                        error.set(failure)
                    } finally {
                        done.countDown()
                    }
                },
            )
        }
        check(done.await(5, TimeUnit.SECONDS))
        error.get()?.let { throw it }
        dedicated.close()
        println("PASS: dedicated helper ${if (reentrant) "callback reentry" else "concurrent foreign requests"}")
    }

    private fun quitOwner() {
        val thread = HandlerThread("async-close-exited-owner")
        thread.start()
        val engine = AtomicReference<Engine>()
        val ready = CountDownLatch(1)
        val error = AtomicReference<Throwable>()
        check(
            Handler(thread.looper).post {
                try {
                    engine.set(Engine(94106))
                } catch (
                    failure: Throwable,
                ) {
                    error.set(failure)
                } finally {
                    ready.countDown()
                }
            },
        )
        check(ready.await(5, TimeUnit.SECONDS))
        error.get()?.let { throw it }
        thread.quitSafely()
        thread.join(3000)
        check(!thread.isAlive)
        repeat(16) {
            check(engine.get().requestClose() == CloseStatus.PENDING)
            check(engine.get().closeStatus() == CloseStatus.PENDING)
        }
        try {
            engine.get().drainClose()
            error("foreign drain unexpectedly admitted")
        } catch (failure: JsBayException) {
            check(failure.status == Status.WRONG_THREAD)
        }
        println("PASS: exited Looper rejects posts and stays pending; no release claim")
    }
}
