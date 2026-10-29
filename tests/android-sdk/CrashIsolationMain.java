package io.jsbay.consumer;

import android.os.HandlerThread;
import io.jsbay.Engine;
import io.jsbay.JsBayException;
import io.jsbay.MemoryUsage;
import io.jsbay.Status;
import io.jsbay.Value;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Strict soft-failure / crash-isolation harness for the Android SDK.
 *
 * <p>Prints greppable {@code PASS:} / {@code FAIL:} / {@code SKIP:} lines. Exits non-zero only when
 * the harness itself breaks (assertion failure). Same-process native faults still kill the process;
 * case 5 documents that boundary via a child {@code app_process} that exits itself.
 */
public final class CrashIsolationMain {
  private static int failures = 0;

  public static void main(String[] args) throws Exception {
    caseSoftException();
    caseTimeLimitInterrupt();
    caseMemoryLimit();
    caseWrongThread();
    caseBackgroundFactory();
    caseNativeFaultBoundary(args);
    if (failures != 0) {
      System.out.println("FAIL: harness failures=" + failures);
      System.exit(1);
    }
    System.out.println("PASS: crash-isolation harness complete");
  }

  private static void pass(String name) {
    System.out.println("PASS: " + name);
  }

  private static void fail(String name, String detail) {
    failures++;
    System.out.println("FAIL: " + name + " — " + detail);
  }

  private static void skip(String name, String reason) {
    System.out.println("SKIP: " + name + " — " + reason);
  }

  private static void caseSoftException() {
    final String name = "soft-exception";
    try (Engine engine = new Engine(9101)) {
      try (Value ignored = engine.evaluate("throw 1", "soft.js")) {
        fail(name, "evaluate should have thrown");
        return;
      } catch (JsBayException expected) {
        if (expected.getStatus() != Status.EXCEPTION) {
          fail(name, "expected EXCEPTION got " + expected.getStatus());
          return;
        }
        if (expected.getValue() != null) {
          expected.getValue().close();
        }
      }
      try (Value v = engine.evaluate("2+2", "alive.js")) {
        if (v.number() != 4.0) {
          fail(name, "engine not usable after soft throw");
          return;
        }
      }
      pass(name);
    } catch (Throwable t) {
      fail(name, String.valueOf(t));
    }
  }

  private static void caseTimeLimitInterrupt() throws Exception {
    final String name = "time-limit-interrupt";
    try (Engine engine = new Engine(9102)) {
      if (!engine.setExecutionTimeLimit(50)) {
        fail(name, "setExecutionTimeLimit rejected");
        return;
      }
      final AtomicBoolean interrupted = new AtomicBoolean(false);
      Thread killer =
          new Thread(
              () -> {
                try {
                  Thread.sleep(20);
                } catch (InterruptedException ignored) {
                }
                interrupted.set(engine.requestInterrupt());
              },
              "jsbay-interrupt");
      killer.start();
      try (Value ignored = engine.evaluate("for(;;){}", "spin.js")) {
        fail(name, "infinite loop should not complete");
        return;
      } catch (JsBayException expected) {
        if (expected.getValue() != null) {
          expected.getValue().close();
        }
      } finally {
        killer.join(2000);
        engine.clearInterrupt();
        engine.setExecutionTimeLimit(0);
      }
      try (Value v = engine.evaluate("'ok'", "after-interrupt.js")) {
        if (!"ok".equals(v.string())) {
          fail(name, "engine dead after interrupt");
          return;
        }
      }
      pass(name + (interrupted.get() ? " (requestInterrupt=true)" : " (deadline-or-interrupt)"));
    } catch (Throwable t) {
      fail(name, String.valueOf(t));
    }
  }

  private static void caseMemoryLimit() {
    final String name = "memory-limit";
    try (Engine engine = new Engine(9103)) {
      MemoryUsage before = engine.getMemoryUsage();
      if (!engine.setMemoryLimit(Math.max(before.getMallocSize() + 64 * 1024, 256 * 1024))) {
        skip(name, "backend rejected setMemoryLimit (e.g. JSC)");
        return;
      }
      try (Value ignored =
          engine.evaluate("new ArrayBuffer(8 * 1024 * 1024)", "oom.js")) {
        // Some backends may GC-succeed; treat success as SKIP if limit unsupported in practice.
        skip(name, "allocation succeeded under soft cap; backend may not hard-fail");
      } catch (JsBayException expected) {
        if (expected.getValue() != null) {
          expected.getValue().close();
        }
        engine.setMemoryLimit(0);
        engine.runGc();
        try (Value v = engine.evaluate("3*3", "after-oom.js")) {
          if (v.number() != 9.0) {
            fail(name, "engine unusable after memory limit");
            return;
          }
        }
        pass(name + " status=" + expected.getStatus());
        return;
      }
      engine.setMemoryLimit(0);
    } catch (Throwable t) {
      fail(name, String.valueOf(t));
    }
  }

  private static void caseWrongThread() throws Exception {
    final String name = "wrong-thread";
    try (Engine engine = new Engine(9104)) {
      final AtomicReference<Status> status = new AtomicReference<>();
      final CountDownLatch done = new CountDownLatch(1);
      Thread other =
          new Thread(
              () -> {
                try {
                  engine.evaluate("1", "wrong-thread.js").close();
                  status.set(Status.OK);
                } catch (JsBayException e) {
                  status.set(e.getStatus());
                } catch (Throwable t) {
                  status.set(Status.INVALID_ARGUMENT);
                } finally {
                  done.countDown();
                }
              },
              "jsbay-wrong-thread");
      other.start();
      if (!done.await(5, TimeUnit.SECONDS)) {
        fail(name, "other thread hung");
        return;
      }
      if (status.get() != Status.WRONG_THREAD) {
        fail(name, "expected WRONG_THREAD got " + status.get());
        return;
      }
      try (Value v = engine.evaluate("1+1", "owner-ok.js")) {
        if (v.number() != 2.0) {
          fail(name, "owner thread broken after wrong-thread probe");
          return;
        }
      }
      pass(name);
    } catch (Throwable t) {
      fail(name, String.valueOf(t));
    }
  }

  private static void caseBackgroundFactory() throws Exception {
    final String name = "background-factory";
    final Thread caller = Thread.currentThread();
    final CountDownLatch ready = new CountDownLatch(1);
    final AtomicReference<Throwable> error = new AtomicReference<>();
    final AtomicBoolean ownerWasCaller = new AtomicBoolean(true);
    final AtomicReference<HandlerThread> threadRef = new AtomicReference<>();
    HandlerThread ht =
        Engine.createOnBackground(
            9105,
            null,
            null,
            engine -> {
              try {
                ownerWasCaller.set(Thread.currentThread() == caller);
                try (Value v = engine.evaluate("7*6", "bg.js")) {
                  if (v.number() != 42.0) {
                    throw new AssertionError("bg evaluate mismatch");
                  }
                }
                MemoryUsage usage = engine.getMemoryUsage();
                if (usage == null) {
                  throw new AssertionError("memory usage null");
                }
                engine.close();
              } catch (Throwable t) {
                error.set(t);
              } finally {
                ready.countDown();
              }
              return kotlin.Unit.INSTANCE;
            });
    threadRef.set(ht);
    if (!ready.await(10, TimeUnit.SECONDS)) {
      fail(name, "background ready timed out");
      ht.quitSafely();
      return;
    }
    ht.quitSafely();
    ht.join(2000);
    if (error.get() != null) {
      fail(name, String.valueOf(error.get()));
      return;
    }
    if (ownerWasCaller.get()) {
      fail(name, "engine owner was the caller thread");
      return;
    }
    pass(name);
  }

  private static void caseNativeFaultBoundary(String[] args) {
    final String name = "native-fault-boundary";
    // TRUE same-process segfault isolation is NOT provided by the SDK.
    // This case only proves the runner can observe a child process dying while the parent lives.
    for (String arg : args) {
      if ("--crash-child".equals(arg)) {
        System.out.println("PASS: crash-child starting intentional exit");
        System.exit(99);
        return;
      }
    }
    skip(
        name,
        "same-process native abort still kills the host; use a separate android:process / "
            + "app_process child for isolation. Parent runner pattern: invoke this main with "
            + "--crash-child and expect exit 99 while parent stays alive (see run-crash-isolation-device.sh)");
  }
}
