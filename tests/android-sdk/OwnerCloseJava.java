package io.jsbay.consumer;

import io.jsbay.CloseStatus;
import io.jsbay.Engine;
import java.util.concurrent.atomic.AtomicReference;

/** Java manual-owner example: request on a producer, drain on the original creator. */
public final class OwnerCloseJava {
  public static void verify() throws Exception {
    Engine engine = new Engine(92009);
    AtomicReference<CloseStatus> status = new AtomicReference<>();
    Thread requester = new Thread(() -> status.set(engine.requestClose()));
    requester.start();
    requester.join(3000);
    if (requester.isAlive()
        || status.get() != CloseStatus.PENDING
        || engine.closeStatus() != CloseStatus.PENDING
        || engine.drainClose() != CloseStatus.COMPLETE) {
      throw new AssertionError("creator drain contract");
    }
    engine.close();
  }
}
