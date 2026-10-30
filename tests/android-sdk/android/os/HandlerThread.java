package android.os;

/** Host-only Android HandlerThread substitute for JVM consumer / host matrix tests. */
public class HandlerThread extends Thread {
  private Looper looper;
  private volatile boolean started;

  public HandlerThread(String name) {
    super(name);
  }

  @Override
  public synchronized void start() {
    if (started) return;
    started = true;
    super.start();
  }

  @Override
  public void run() {
    Looper.prepare();
    synchronized (this) {
      looper = Looper.myLooper();
      notifyAll();
    }
    Looper.loop();
  }

  public Looper getLooper() {
    if (!started) return null;
    synchronized (this) {
      while (looper == null && isAlive()) {
        try {
          wait();
        } catch (InterruptedException error) {
          Thread.currentThread().interrupt();
          return null;
        }
      }
      return looper;
    }
  }

  public boolean quit() {
    Looper l = getLooper();
    if (l == null) return false;
    l.quit();
    return true;
  }

  public boolean quitSafely() {
    return quit();
  }
}
