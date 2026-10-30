package io.jsbay.consumer;

import android.os.Handler;
import android.os.HandlerThread;
import io.jsbay.Engine;
import io.jsbay.JsBayException;
import io.jsbay.MemoryUsage;
import io.jsbay.Status;
import io.jsbay.Value;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Adversarial Android extreme matrix: burst create/destroy, close races, wrong-thread storms,
 * memory/time hammer + recover.
 *
 * <p>Greppable PASS:/FAIL:/SKIP: lines. Does NOT enable Zig fault-injection in-process (that lives
 * in tests/process-isolation harness under a child process).
 */
public final class ExtremeMatrixMain {
  private static int failures = 0;
  private static final int BURST_N = 16;
  private static final int WRONG_STORM = 32;
  private static final int HAMMER_ROUNDS = 8;

  public static void main(String[] args) throws Exception {
    caseBurstParallelEngines();
    caseCloseWhileSpinning();
    caseWrongThreadStorm();
    caseMemoryTimeHammerRecover();
    caseRapidCreateDestroySameId();
    if (failures != 0) {
      System.out.println("FAIL: extreme-matrix failures=" + failures);
      System.exit(1);
    }
    System.out.println("PASS: extreme-matrix harness complete");
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

  /** Many HandlerThreads each own an engine; evaluate then close in parallel. */
  private static void caseBurstParallelEngines() throws Exception {
    final String name = "burst-parallel-engines-" + BURST_N;
    final CountDownLatch ready = new CountDownLatch(BURST_N);
    final CountDownLatch done = new CountDownLatch(BURST_N);
    final AtomicInteger ok = new AtomicInteger();
    final AtomicInteger bad = new AtomicInteger();
    final List<HandlerThread> threads = new ArrayList<>();

    for (int i = 0; i < BURST_N; i++) {
      final int id = 9200 + i;
      HandlerThread ht =
          Engine.createOnBackground(
              id,
              null,
              null,
              engine -> {
                try {
                  ready.countDown();
                  try (Value v = engine.evaluate(String.valueOf(id) + "+1", "burst.js")) {
                    if (v.number() != (double) (id + 1)) {
                      throw new AssertionError("bad eval id=" + id);
                    }
                  }
                  engine.close();
                  ok.incrementAndGet();
                } catch (Throwable t) {
                  bad.incrementAndGet();
                  System.out.println("NOTE: burst id=" + id + " " + t);
                } finally {
                  done.countDown();
                }
                return kotlin.Unit.INSTANCE;
              });
      threads.add(ht);
    }

    if (!ready.await(20, TimeUnit.SECONDS)) {
      fail(name, "ready latch timeout");
    } else if (!done.await(30, TimeUnit.SECONDS)) {
      fail(name, "done latch timeout ok=" + ok.get() + " bad=" + bad.get());
    } else if (bad.get() != 0 || ok.get() != BURST_N) {
      fail(name, "ok=" + ok.get() + " bad=" + bad.get());
    } else {
      pass(name);
    }

    for (HandlerThread ht : threads) {
      ht.quitSafely();
      ht.join(2000);
    }
  }

  /** Spin evaluate; interrupt from another thread; then close on owner and reuse id. */
  private static void caseCloseWhileSpinning() throws Exception {
    final String name = "close-while-spinning";
    final CountDownLatch ownerReady = new CountDownLatch(1);
    final CountDownLatch evalStarted = new CountDownLatch(1);
    final CountDownLatch ownerDone = new CountDownLatch(1);
    final AtomicReference<Throwable> error = new AtomicReference<>();
    final AtomicReference<Engine> engineRef = new AtomicReference<>();

    HandlerThread ht =
        Engine.createOnBackground(
            9301,
            null,
            null,
            engine -> {
              engineRef.set(engine);
              ownerReady.countDown();
              try {
                evalStarted.countDown();
                try {
                  engine.setExecutionTimeLimit(80);
                  try (Value ignored = engine.evaluate("for(;;){}", "spin.js")) {
                    throw new AssertionError("spin should not complete");
                  } catch (JsBayException expected) {
                    if (expected.getValue() != null) expected.getValue().close();
                  }
                } finally {
                  engine.clearInterrupt();
                  engine.setExecutionTimeLimit(0);
                }
                engine.close();
              } catch (Throwable t) {
                error.set(t);
              } finally {
                ownerDone.countDown();
              }
              return kotlin.Unit.INSTANCE;
            });

    if (!ownerReady.await(5, TimeUnit.SECONDS)) {
      fail(name, "owner not ready");
      ht.quitSafely();
      return;
    }
    evalStarted.await(2, TimeUnit.SECONDS);
    Engine eng = engineRef.get();
    boolean interrupted = eng != null && eng.requestInterrupt();
    // Also poke stopLoop while spinning.
    if (eng != null) eng.stopLoop();

    if (!ownerDone.await(15, TimeUnit.SECONDS)) {
      fail(name, "owner hung after interrupt interrupted=" + interrupted);
      ht.quitSafely();
      return;
    }
    ht.quitSafely();
    ht.join(2000);
    if (error.get() != null) {
      fail(name, String.valueOf(error.get()));
      return;
    }

    // Reuse instance id on a fresh background owner.
    final CountDownLatch reuseDone = new CountDownLatch(1);
    final AtomicReference<Throwable> reuseErr = new AtomicReference<>();
    HandlerThread ht2 =
        Engine.createOnBackground(
            9301,
            null,
            null,
            engine -> {
              try {
                try (Value v = engine.evaluate("2*21", "reuse.js")) {
                  if (v.number() != 42.0) throw new AssertionError("reuse eval");
                }
                engine.close();
              } catch (Throwable t) {
                reuseErr.set(t);
              } finally {
                reuseDone.countDown();
              }
              return kotlin.Unit.INSTANCE;
            });
    if (!reuseDone.await(10, TimeUnit.SECONDS)) {
      fail(name, "reuse hung");
      ht2.quitSafely();
      return;
    }
    ht2.quitSafely();
    ht2.join(2000);
    if (reuseErr.get() != null) {
      fail(name, "reuse: " + reuseErr.get());
      return;
    }
    pass(name + " interrupt=" + interrupted);
  }

  /** Flood WRONG_THREAD probes from many threads against one owner engine. */
  private static void caseWrongThreadStorm() throws Exception {
    final String name = "wrong-thread-storm-" + WRONG_STORM;
    try (Engine engine = new Engine(9401)) {
      final CountDownLatch start = new CountDownLatch(1);
      final CountDownLatch done = new CountDownLatch(WRONG_STORM);
      final AtomicInteger wrong = new AtomicInteger();
      final AtomicInteger other = new AtomicInteger();
      Thread[] workers = new Thread[WRONG_STORM];
      for (int i = 0; i < WRONG_STORM; i++) {
        workers[i] =
            new Thread(
                () -> {
                  try {
                    start.await(5, TimeUnit.SECONDS);
                    try {
                      engine.evaluate("1", "wt.js").close();
                      other.incrementAndGet();
                    } catch (JsBayException e) {
                      if (e.getStatus() == Status.WRONG_THREAD) wrong.incrementAndGet();
                      else other.incrementAndGet();
                    } catch (Throwable t) {
                      other.incrementAndGet();
                    }
                  } catch (InterruptedException ie) {
                    other.incrementAndGet();
                  } finally {
                    done.countDown();
                  }
                },
                "wt-" + i);
        workers[i].start();
      }
      start.countDown();
      if (!done.await(15, TimeUnit.SECONDS)) {
        fail(name, "storm hang");
        return;
      }
      for (Thread t : workers) t.join(1000);
      try (Value v = engine.evaluate("3+4", "owner.js")) {
        if (v.number() != 7.0) {
          fail(name, "owner broken after storm");
          return;
        }
      }
      if (wrong.get() != WRONG_STORM) {
        fail(name, "wrong=" + wrong.get() + " other=" + other.get());
        return;
      }
      pass(name);
    } catch (Throwable t) {
      fail(name, String.valueOf(t));
    }
  }

  /** Alternate memory-limit OOM and time-limit interrupt, recover each round. */
  private static void caseMemoryTimeHammerRecover() throws Exception {
    final String name = "memory-time-hammer-" + HAMMER_ROUNDS;
    try (Engine engine = new Engine(9501)) {
      int recovered = 0;
      for (int round = 0; round < HAMMER_ROUNDS; round++) {
        MemoryUsage before = engine.getMemoryUsage();
        boolean memSet =
            engine.setMemoryLimit(Math.max(before.getMallocSize() + 32 * 1024, 128 * 1024));
        boolean hitMem = false;
        if (memSet) {
          try (Value ignored = engine.evaluate("new ArrayBuffer(4 * 1024 * 1024)", "oom.js")) {
            // soft backends may succeed
          } catch (JsBayException expected) {
            hitMem = true;
            if (expected.getValue() != null) expected.getValue().close();
          }
        }
        engine.setMemoryLimit(0);
        engine.runGc();

        if (!engine.setExecutionTimeLimit(40)) {
          fail(name, "time limit rejected round=" + round);
          return;
        }
        Thread killer =
            new Thread(
                () -> {
                  try {
                    Thread.sleep(10);
                  } catch (InterruptedException ignored) {
                  }
                  engine.requestInterrupt();
                },
                "hammer-int-" + round);
        killer.start();
        boolean hitTime = false;
        try (Value ignored = engine.evaluate("for(;;){}", "spin-h.js")) {
          // unexpected
        } catch (JsBayException expected) {
          hitTime = true;
          if (expected.getValue() != null) expected.getValue().close();
        }
        killer.join(2000);
        engine.clearInterrupt();
        engine.setExecutionTimeLimit(0);

        try (Value v = engine.evaluate(String.valueOf(round) + "+1", "rec.js")) {
          if (v.number() != (double) (round + 1)) {
            fail(name, "recover eval failed round=" + round);
            return;
          }
        }
        recovered++;
        System.out.println(
            "NOTE: hammer round=" + round + " hitMem=" + hitMem + " hitTime=" + hitTime);
      }
      if (recovered != HAMMER_ROUNDS) {
        fail(name, "recovered=" + recovered);
        return;
      }
      pass(name);
    } catch (Throwable t) {
      fail(name, String.valueOf(t));
    }
  }

  /** Serialize create→evaluate→close on same id many times on one background thread. */
  private static void caseRapidCreateDestroySameId() throws Exception {
    final String name = "rapid-create-destroy-same-id";
    final int rounds = 40;
    final CountDownLatch done = new CountDownLatch(1);
    final AtomicReference<Throwable> error = new AtomicReference<>();
    final HandlerThread thread = new HandlerThread("jsbay-rapid");
    thread.start();
    new Handler(thread.getLooper())
        .post(
            () -> {
              try {
                for (int i = 0; i < rounds; i++) {
                  Engine engine = new Engine(9601);
                  try (Value v = engine.evaluate("1+1", "rapid.js")) {
                    if (v.number() != 2.0) throw new AssertionError("rapid eval");
                  }
                  engine.close();
                }
              } catch (Throwable t) {
                error.set(t);
              } finally {
                done.countDown();
              }
            });
    if (!done.await(60, TimeUnit.SECONDS)) {
      fail(name, "timeout");
      thread.quitSafely();
      return;
    }
    thread.quitSafely();
    thread.join(2000);
    if (error.get() != null) {
      fail(name, String.valueOf(error.get()));
      return;
    }
    pass(name + " rounds=" + rounds);
  }
}
