package android.os;

/** Host-only Android HandlerThread substitute for JVM consumer compilation. */
public class HandlerThread extends Thread {
  private Looper looper;

  public HandlerThread(String name) {
    super(name);
  }

  @Override
  public synchronized void start() {
    if (looper == null) {
      looper = new Looper();
    }
    // Host stub: do not start a real thread; consumers only need the type/API surface.
  }

  public Looper getLooper() {
    return looper;
  }

  public boolean quit() {
    if (looper == null) return false;
    looper.quit();
    return true;
  }

  public boolean quitSafely() {
    if (looper == null) return false;
    looper.quitSafely();
    return true;
  }
}
