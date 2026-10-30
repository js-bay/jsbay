package io.jsbay.consumer;

import android.os.Looper;
import io.jsbay.DedicatedEngineThread;
import io.jsbay.Engine;
import io.jsbay.EngineOptions;
import io.jsbay.Value;

/** Host-only entry point that gives the SDK a fake Android Looper. */
public final class HostLoopMain {
  public static void main(String[] args) {
    Looper.prepare();
    JavaConsumer.run();
    KotlinConsumerKt.runKotlinConsumer();
    runHostLoopDriver(Looper.myLooper());
    runStaleStopLoop(Looper.myLooper());
    runRejectedLoopDriver();
    runMainLooperAttachGuard();
    runDedicatedEngineThread();
    runSuspendResumeKeepsLoopAlive(Looper.myLooper());
    System.out.println("PASS: Android Java and Kotlin consumers");
  }

  private static void runStaleStopLoop(Looper looper) {
    Engine closed = new Engine(7124);
    closed.close();
    try (Engine replacement = new Engine(7124)) {
      if (closed.stopLoop()) {
        throw new AssertionError("closed Engine must not stop a replacement loop");
      }
      boolean[] stopped = {false};
      try (Value callback =
              replacement.bind(
                  "stopReplacement",
                  (self, args) -> {
                    stopped[0] = replacement.stopLoop();
                    return replacement.undefined();
                  });
          Value ignored =
              replacement.evaluate("setTimeout(stopReplacement, 1)", "host-loop-reused-stop.js")) {
        looper.advanceBy(100);
      }
      if (!stopped[0]) {
        throw new AssertionError("replacement Engine can stop its own loop");
      }
    }
  }

  private static void runHostLoopDriver(Looper looper) {
    try (Engine engine = new Engine(7120)) {
      boolean[] callbackRan = {false};
      boolean[] stopped = {false};
      try (Value callback =
              engine.bind(
                  "stopLoop",
                  (self, args) -> {
                    callbackRan[0] = true;
                    stopped[0] = engine.stopLoop();
                    return engine.undefined();
                  });
          Value ignored = engine.evaluate("setTimeout(stopLoop, 1)", "host-loop-stop.js")) {
        looper.advanceBy(100);
      }
      if (!callbackRan[0] || !stopped[0]) {
        throw new AssertionError("Looper driver runs a timer callback that stops the loop");
      }
    }

    Engine closedEngine = new Engine(7121);
    boolean[] callbackAfterClose = {false};
    Value callback =
        closedEngine.bind(
            "afterClose",
            (self, args) -> {
              callbackAfterClose[0] = true;
              return closedEngine.undefined();
            });
    closedEngine.evaluate("setTimeout(afterClose, 1)", "host-loop-close.js").close();
    closedEngine.close();
    looper.advanceBy(100);
    callback.close();
    if (callbackAfterClose[0]) {
      throw new AssertionError("Looper driver cancels a queued callback during close");
    }

    Engine closingEngine = new Engine(7122);
    boolean[] laterCallbackRan = {false};
    Value closeCallback =
        closingEngine.bind(
            "hostClose",
            (self, args) -> {
              closingEngine.close();
              return closingEngine.undefined();
            });
    Value laterCallback =
        closingEngine.bind(
            "laterCallback",
            (self, args) -> {
              laterCallbackRan[0] = true;
              return closingEngine.undefined();
            });
    closingEngine
        .evaluate(
            "setTimeout(hostClose, 1); setTimeout(laterCallback, 2)", "host-loop-close-callback.js")
        .close();
    looper.advanceBy(100);
    closeCallback.close();
    laterCallback.close();
    if (laterCallbackRan[0]) {
      throw new AssertionError("Looper driver runs a callback after a timer closes the engine");
    }
    try (Engine rebuilt = new Engine(7122)) {
      rebuilt.close();
    }
  }

  private static void runRejectedLoopDriver() {
    Looper.rejectNextPost();
    try {
      new Engine(7123);
      throw new AssertionError("Looper rejection must reject engine creation");
    } catch (io.jsbay.JsBayException error) {
      if (error.getStatus() != io.jsbay.Status.LOOP_FAILED) {
        throw new AssertionError("Looper rejection status: " + error.getStatus());
      }
    }
    try (Engine rebuilt = new Engine(7123)) {
      rebuilt.close();
    }
  }

  private static void runMainLooperAttachGuard() {
    Looper.clearMainLooperForTest();
    java.util.concurrent.atomic.AtomicReference<Throwable> failure =
        new java.util.concurrent.atomic.AtomicReference<>();
    Thread main =
        new Thread(
            () -> {
              try {
                Looper.prepareMainLooper();
                try {
                  new Engine(7140);
                  throw new AssertionError("main Looper attach must be refused by default");
                } catch (io.jsbay.JsBayException error) {
                  if (error.getStatus() != io.jsbay.Status.INVALID_ARGUMENT) {
                    throw new AssertionError("main Looper refusal status: " + error.getStatus());
                  }
                }
                try (Engine allowed = new Engine(7140, new EngineOptions(true))) {
                  allowed.close();
                }
              } catch (Throwable error) {
                failure.set(error);
              } finally {
                Looper.clearMainLooperForTest();
              }
            },
            "jsbay-main-looper-guard");
    main.start();
    try {
      main.join();
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
      throw new AssertionError(error);
    }
    if (failure.get() != null) {
      throw new AssertionError(failure.get());
    }
  }

  private static void runDedicatedEngineThread() {
    try (DedicatedEngineThread dedicated =
        DedicatedEngineThread.start(7141, "jsbay-dedicated-7141")) {
      String answer =
          dedicated.runOnOwner(
              engine -> {
                try (Value value = engine.evaluate("1 + 2", "dedicated.js")) {
                  return Double.toString(value.number());
                }
              });
      if (!"3.0".equals(answer)) {
        throw new AssertionError("dedicated Engine evaluate: " + answer);
      }
    }
  }

  /**
   * P0-1 regression: suspend soft-cancels a pending Host schedule; resume must not latch
   * LOOP_FAILED.
   */
  private static void runSuspendResumeKeepsLoopAlive(Looper looper) {
    try (Engine engine = new Engine(7142)) {
      boolean[] fired = {false};
      boolean[] stopped = {false};
      try (Value callback =
              engine.bind(
                  "afterResume",
                  (self, args) -> {
                    fired[0] = true;
                    stopped[0] = engine.stopLoop();
                    return engine.undefined();
                  });
          Value ignored = engine.evaluate("setTimeout(afterResume, 50)", "host-loop-suspend.js")) {
        if (!engine.suspendLoop()) {
          throw new AssertionError("suspendLoop must succeed with a live Engine");
        }
        if (!engine.isSuspended()) {
          throw new AssertionError("isSuspended after suspendLoop");
        }
        // Time would have fired the timer while hidden; scheduling must stay gated.
        looper.advanceBy(100);
        if (fired[0]) {
          throw new AssertionError("timer must not fire while suspended");
        }
        if (!engine.resumeLoop()) {
          throw new AssertionError("resumeLoop must succeed");
        }
        if (engine.isSuspended()) {
          throw new AssertionError("isSuspended after resumeLoop");
        }
        looper.advanceBy(100);
      }
      if (!fired[0] || !stopped[0]) {
        throw new AssertionError("timer must fire after resume without LOOP_FAILED");
      }
    }
  }
}
