package io.jsbay.consumer

import io.jsbay.AdmissionClass
import io.jsbay.DedicatedEngineThread
import io.jsbay.Engine
import io.jsbay.Value
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Real-device P0 keep-alive harness (ART + Looper). */
object DeviceP0Main {
    @JvmStatic
    fun main(args: Array<String>) {
        runSuspendResumeKeepsAlive()
        runAdmissionClassAndObservability()
        runBindSyncTyped()
        println("PASS: Android device P0 keep-alive")
    }

    private fun runSuspendResumeKeepsAlive() {
        val fired = AtomicBoolean(false)
        val firedLatch = CountDownLatch(1)
        val callbackRef = AtomicReference<Value?>()
        DedicatedEngineThread.start(7201, "jsbay-device-p0-suspend").use { dedicated ->
            dedicated.runOnOwner { engine ->
                val callback =
                    engine.bind("afterResume") { _, _ ->
                        fired.set(true)
                        firedLatch.countDown()
                        engine.undefined()
                    }
                callbackRef.set(callback)
                engine.evaluate("globalThis.__p0Keep = 42", "device-p0-keep.js").close()
                engine.evaluate("setTimeout(afterResume, 50)", "device-p0-suspend.js").close()
                check(engine.suspendLoop()) { "suspendLoop must succeed" }
                check(engine.isSuspended()) { "isSuspended after suspendLoop" }
            }

            Thread.sleep(120)
            check(!fired.get()) { "timer must not fire while suspended" }
            dedicated.runOnOwner { engine ->
                check(engine.isSuspended()) { "still suspended before resume" }
                engine.evaluate("globalThis.__p0Keep", "device-p0-keep-check.js").use { kept ->
                    check(kept.number() == 42.0) { "VM content lost while suspended: ${kept.number()}" }
                }
            }

            check(dedicated.engine.resumeLoop()) { "resumeLoop must succeed" }
            check(firedLatch.await(3, TimeUnit.SECONDS)) {
                "timer must fire after resume without LOOP_FAILED"
            }
            dedicated.runOnOwner { engine ->
                check(!engine.isSuspended()) { "isSuspended after resumeLoop" }
                engine.evaluate("1 + 1", "device-p0-alive.js").use { sum ->
                    check(sum.number() == 2.0) { "evaluate after resume failed" }
                }
                callbackRef.getAndSet(null)?.close()
            }
        }
        println("PASS: device suspend/resume keep-alive")
    }

    private fun runAdmissionClassAndObservability() {
        DedicatedEngineThread.start(7202, "jsbay-device-p0-admission").use { dedicated ->
            dedicated.runOnOwner { engine ->
                check(engine.getAdmissionClass() == AdmissionClass.FOREGROUND) {
                    "default admission class must be FOREGROUND"
                }
                check(engine.setAdmissionClass(AdmissionClass.BACKGROUND)) { "set BACKGROUND" }
                check(engine.getAdmissionClass() == AdmissionClass.BACKGROUND) { "get BACKGROUND" }
                val global = Engine.globalResourceUsage()
                check(global.fgHeadroomTimers >= 0 && global.bgEffectiveMaxTimers <= global.maxTimers) {
                    "headroom inconsistent fg=${global.fgHeadroomTimers} bgEff=${global.bgEffectiveMaxTimers} max=${global.maxTimers}"
                }
                check(global.fgHeadroomTimers > 0 || global.maxTimers < 4) {
                    "expected non-zero FG timer headroom for default caps"
                }
                check(engine.setAdmissionClass(AdmissionClass.FOREGROUND)) { "set FOREGROUND" }
                check(Engine.listEngines().contains(engine.id)) { "listEngines missing ${engine.id}" }
                val snap = engine.snapshot()
                check(snap != null && snap.instanceId == engine.id) { "snapshot missing or wrong id" }
                check(snap!!.admissionClass == AdmissionClass.FOREGROUND) { "snapshot admissionClass" }
            }
        }
        println("PASS: device admission class + list/snapshot")
    }

    private fun runBindSyncTyped() {
        DedicatedEngineThread.start(7203, "jsbay-device-p0-sync").use { dedicated ->
            dedicated.runOnOwner { engine ->
                engine
                    .bindSync("p0SyncStr", 2000) { call ->
                        Thread({
                            call.completion.resolveString("typed-ok")
                        }, "p0-sync-str").start()
                    }.use {
                        engine.evaluate("p0SyncStr()", "device-p0-sync-str.js").use { result ->
                            check(result.string() == "typed-ok") { "ResolveString mismatch: ${result.string()}" }
                        }
                    }
                engine
                    .bindSync("p0SyncBytes", 2000) { call ->
                        Thread({
                            call.completion.resolveBytes(byteArrayOf(9, 8, 7))
                        }, "p0-sync-bytes").start()
                    }.use {
                        engine
                            .evaluate(
                                "(function(){ var u = new Uint8Array(p0SyncBytes()); return u.length===3 && u[0]===9 && u[1]===8 && u[2]===7; })()",
                                "device-p0-sync-bytes.js",
                            ).use { ok ->
                                check(ok.bool()) { "ResolveBytes mismatch" }
                            }
                    }
            }
        }
        println("PASS: device bindSync ResolveString/ResolveBytes")
    }
}
