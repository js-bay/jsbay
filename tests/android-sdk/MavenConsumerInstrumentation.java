package com.example.jsbay.mavenconsumer;

import android.app.Activity;
import android.app.Instrumentation;
import android.os.Bundle;
import io.jsbay.CloseStatus;
import io.jsbay.Engine;
import io.jsbay.Value;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicReference;

public final class MavenConsumerInstrumentation extends Instrumentation {
  private String expectedBackend;

  @Override
  public void onCreate(Bundle arguments) {
    super.onCreate(arguments);
    expectedBackend = arguments.getString("backend");
    start();
  }

  private static void verifyAsyncClose() throws Exception {
    Engine engine = new Engine(2);
    AtomicReference<Throwable> failure = new AtomicReference<>();
    Thread[] requesters = new Thread[4];
    for (int i = 0; i < requesters.length; i++) {
      requesters[i] =
          new Thread(
              () -> {
                try {
                  for (int n = 0; n < 16; n++) {
                    if (engine.requestClose() != CloseStatus.PENDING
                        || engine.closeStatus() != CloseStatus.PENDING) {
                      throw new AssertionError(
                          "Foreign request must stay pending until creator drains");
                    }
                  }
                } catch (Throwable error) {
                  failure.compareAndSet(null, error);
                }
              });
      requesters[i].start();
    }
    for (Thread requester : requesters) {
      requester.join(3000);
      if (requester.isAlive()) throw new AssertionError("Foreign request blocked creator join");
    }
    if (failure.get() != null) throw new AssertionError("Foreign request failed", failure.get());
    if (engine.closeStatus() != CloseStatus.PENDING
        || engine.drainClose() != CloseStatus.COMPLETE
        || engine.requestClose() != CloseStatus.COMPLETE
        || engine.closeStatus() != CloseStatus.COMPLETE) {
      throw new AssertionError("Creator drain and duplicate request completion");
    }
    engine.close();
    engine.close();
  }

  @Override
  public void onStart() {
    Bundle result = new Bundle();
    try {
      String packagedBackend;
      try (BufferedReader marker =
          new BufferedReader(
              new InputStreamReader(
                  getTargetContext().getAssets().open("jsbay-backend.txt"),
                  StandardCharsets.UTF_8))) {
        packagedBackend = marker.readLine();
      }
      if (expectedBackend == null || !expectedBackend.equals(packagedBackend)) {
        throw new AssertionError("Unexpected packaged backend: " + packagedBackend);
      }
      try (Engine engine = new Engine(1);
          Value value = engine.evaluate("6 * 7", "maven-consumer.js")) {
        if (value.number() != 42) {
          throw new AssertionError("Unexpected JavaScript result: " + value.number());
        }
      }
      verifyAsyncClose();
      result.putString("jsbayAsyncClose", "creator-drained");
      result.putString("jsbayResult", packagedBackend + ":42");
      finish(Activity.RESULT_OK, result);
    } catch (Throwable error) {
      result.putString("stream", android.util.Log.getStackTraceString(error));
      finish(Activity.RESULT_CANCELED, result);
    }
  }
}
