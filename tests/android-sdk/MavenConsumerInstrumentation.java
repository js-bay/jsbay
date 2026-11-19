package com.example.jsbay.mavenconsumer;

import android.app.Activity;
import android.app.Instrumentation;
import android.os.Bundle;
import io.jsbay.Engine;
import io.jsbay.Value;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

public final class MavenConsumerInstrumentation extends Instrumentation {
  private String expectedBackend;

  @Override
  public void onCreate(Bundle arguments) {
    super.onCreate(arguments);
    expectedBackend = arguments.getString("backend");
    start();
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
      result.putString("jsbayResult", packagedBackend + ":42");
      finish(Activity.RESULT_OK, result);
    } catch (Throwable error) {
      result.putString("stream", android.util.Log.getStackTraceString(error));
      finish(Activity.RESULT_CANCELED, result);
    }
  }
}
