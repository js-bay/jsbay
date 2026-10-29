package android.os;

import java.util.PriorityQueue;

/** Host-only Android Looper substitute used to exercise reflection-based scheduling. */
public final class Looper {
  private static final ThreadLocal<Looper> CURRENT = new ThreadLocal<>();
  private static volatile Looper MAIN;
  private static boolean rejectNextPost;
  private final PriorityQueue<Entry> queue = new PriorityQueue<>();
  private long sequence;
  private volatile boolean quit;

  private Looper() {}

  public static void prepare() {
    if (CURRENT.get() != null) throw new IllegalStateException("Looper already prepared");
    CURRENT.set(new Looper());
  }

  /** Marks the current thread's Looper as the process main Looper (host tests only). */
  public static void prepareMainLooper() {
    prepare();
    MAIN = CURRENT.get();
  }

  public static Looper myLooper() {
    return CURRENT.get();
  }

  public static Looper getMainLooper() {
    return MAIN;
  }

  public static synchronized void rejectNextPost() {
    rejectNextPost = true;
  }

  static synchronized boolean takeRejectedPost() {
    if (!rejectNextPost) return false;
    rejectNextPost = false;
    return true;
  }

  /** Clears the host-only main Looper marker between tests. */
  public static void clearMainLooperForTest() {
    MAIN = null;
  }

  boolean post(Runnable runnable, long delayMilliseconds) {
    if (quit) return false;
    if (delayMilliseconds < 0) return false;
    synchronized (queue) {
      queue.add(new Entry(nowMilliseconds() + delayMilliseconds, sequence++, runnable));
      queue.notifyAll();
    }
    return true;
  }

  void remove(Runnable runnable) {
    synchronized (queue) {
      queue.removeIf(entry -> entry.runnable == runnable);
    }
  }

  public void quit() {
    quit = true;
    synchronized (queue) {
      queue.clear();
      queue.notifyAll();
    }
    if (CURRENT.get() == this) {
      CURRENT.remove();
    }
    if (MAIN == this) {
      MAIN = null;
    }
  }

  public void quitSafely() {
    quit();
  }

  public static void loop() {
    Looper me = myLooper();
    if (me == null) throw new RuntimeException("No Looper; Looper.prepare() was not called on this thread");
    while (!me.quit) {
      Entry next = null;
      synchronized (me.queue) {
        while (!me.quit && next == null) {
          Entry peeked = me.queue.peek();
          if (peeked == null) {
            try {
              me.queue.wait();
            } catch (InterruptedException error) {
              Thread.currentThread().interrupt();
              return;
            }
            continue;
          }
          long delay = peeked.when - nowMilliseconds();
          if (delay > 0) {
            try {
              me.queue.wait(delay);
            } catch (InterruptedException error) {
              Thread.currentThread().interrupt();
              return;
            }
            continue;
          }
          me.queue.remove();
          next = peeked;
        }
      }
      if (next == null) return;
      next.runnable.run();
    }
  }

  public void advanceBy(long milliseconds) {
    if (milliseconds < 0) throw new IllegalArgumentException("milliseconds");
    long deadline = nowMilliseconds() + milliseconds;
    while (true) {
      Entry entry;
      synchronized (queue) {
        entry = queue.peek();
        if (entry == null || entry.when > deadline) {
          entry = null;
        } else {
          queue.remove();
        }
      }
      if (entry == null) {
        sleep(deadline - nowMilliseconds());
        return;
      }
      sleep(entry.when - nowMilliseconds());
      entry.runnable.run();
    }
  }

  private static long nowMilliseconds() {
    return System.nanoTime() / 1_000_000L;
  }

  private static void sleep(long milliseconds) {
    if (milliseconds <= 0) return;
    try {
      Thread.sleep(milliseconds);
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
      throw new AssertionError(error);
    }
  }

  private static final class Entry implements Comparable<Entry> {
    private final long when;
    private final long sequence;
    private final Runnable runnable;

    private Entry(long when, long sequence, Runnable runnable) {
      this.when = when;
      this.sequence = sequence;
      this.runnable = runnable;
    }

    @Override
    public int compareTo(Entry other) {
      int byWhen = Long.compare(when, other.when);
      return byWhen != 0 ? byWhen : Long.compare(sequence, other.sequence);
    }
  }
}
