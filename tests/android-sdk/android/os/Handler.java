package android.os;

/** Host-only Android Handler substitute used to exercise reflection-based scheduling. */
public final class Handler {
  private final Looper looper;

  public Handler(Looper looper) {
    this.looper = looper;
  }

  public boolean post(Runnable runnable) {
    return postDelayed(runnable, 0);
  }

  public boolean postDelayed(Runnable runnable, long delayMilliseconds) {
    if (Looper.takeRejectedPost()) return false;
    return looper.post(runnable, delayMilliseconds);
  }

  public void removeCallbacks(Runnable runnable) {
    looper.remove(runnable);
  }
}
