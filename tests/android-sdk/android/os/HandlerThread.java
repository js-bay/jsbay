package android.os;

/** Host-only HandlerThread substitute used to compile and exercise dedicated engine ownership. */
public class HandlerThread extends Thread {
  private Looper looper;

  public HandlerThread(String name) {
    super(name);
  }

  @Override
  public void run() {
    Looper.prepare();
    looper = Looper.myLooper();
    Looper.loop();
  }

  public Looper getLooper() {
    return looper;
  }

  public boolean quitSafely() {
    Looper current = looper;
    if (current != null) current.quitSafely();
    return true;
  }
}
