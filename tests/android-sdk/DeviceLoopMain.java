package io.jsbay.consumer;

import android.os.Looper;
import io.jsbay.Engine;
import io.jsbay.Value;

/** Android ART entry point that verifies automatic Looper scheduling. */
public final class DeviceLoopMain {
  public static void main(String[] args) {
    Looper.prepare();
    ConsumerMain.main(args);
    try (Engine engine = new Engine(7130)) {
      boolean[] timerRan = {false};
      try (Value callback =
              engine.bind(
                  "stopOnTimer",
                  (self, ignored) -> {
                    timerRan[0] = true;
                    if (!engine.stopLoop()) {
                      throw new AssertionError("Looper timer cannot stop the core loop");
                    }
                    Looper.myLooper().quitSafely();
                    return engine.undefined();
                  });
          Value ignored = engine.evaluate("setTimeout(stopOnTimer, 1)", "android-device-loop.js")) {
        Looper.loop();
      }
      if (!timerRan[0]) {
        throw new AssertionError("Looper did not run the JavaScript timer");
      }
    }
    System.out.println("PASS: Android ART automatic Looper consumer");
  }
}
