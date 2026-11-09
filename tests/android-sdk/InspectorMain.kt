package com.example.jsbay.inspector

import io.jsbay.DedicatedEngineThread

/** Keeps the engine owner available while a host CDP client controls execution. */
fun main() {
    DedicatedEngineThread.start(7131).use { owner ->
        val port = owner.runOnOwner { it.startInspector() }
        check(port != null) { "Inspector did not start" }
        println("READY $port")
        System.out.flush()
        try {
            readlnOrNull()
        } finally {
            owner.runOnOwner { it.stopInspector() }
        }
    }
    println("CLEAN_EXIT")
}
