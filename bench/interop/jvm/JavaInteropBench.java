package io.jsbay.interop;

import io.jsbay.Engine;
import io.jsbay.Value;

public final class JavaInteropBench {
  private static final int WARMUP = 100;
  private static final int ITERATIONS = 1000;
  private static final int PAYLOAD_BYTES = 4096;

  private static long elapsed(Runnable action, int count) {
    for (int index = 0; index < WARMUP; ++index) action.run();
    long started = System.nanoTime();
    for (int index = 0; index < count; ++index) action.run();
    return System.nanoTime() - started;
  }

  private static void number(Engine engine, String source) {
    try (Value value = engine.evaluate(source, "interop.js")) {
      if (value.number() != 42.0) throw new IllegalStateException("unexpected benchmark result");
    }
  }

  private static long lifecycle() {
    for (int index = 0; index < WARMUP; ++index) {
      try (Engine engine = new Engine(2_300_000 + index)) {
        number(engine, "42");
      }
    }
    long started = System.nanoTime();
    for (int index = 0; index < 100; ++index) {
      try (Engine engine = new Engine(2_310_000 + index)) {
        number(engine, "42");
      }
    }
    return System.nanoTime() - started;
  }

  public static void main(String[] args) {
    try (Engine engine = new Engine(2_200_001);
        Value callback = engine.bind("benchCallback", (self, arguments) -> engine.number(42.0))) {
      long eval =
          elapsed(() -> number(engine, "var n=0; for(var i=0;i<64;i++)n+=i; 42"), ITERATIONS);
      long hostCallback = elapsed(() -> number(engine, "benchCallback()"), ITERATIONS);
      long textJson =
          elapsed(
              () -> {
                try (Value value =
                    engine.evaluate("({text:'public interop',count:42})", "text-json.js")) {
                  if (!value.json().equals("{\"text\":\"public interop\",\"count\":42}"))
                    throw new IllegalStateException("unexpected JSON");
                }
              },
              ITERATIONS);
      byte[] input = new byte[PAYLOAD_BYTES];
      java.util.Arrays.fill(input, (byte) 7);
      long bufferCopy =
          elapsed(
              () -> {
                try (Value value = engine.arrayBuffer(input)) {
                  if (!java.util.Arrays.equals(value.bytes(), input)) {
                    throw new IllegalStateException("buffer mismatch");
                  }
                }
              },
              ITERATIONS);
      long life = lifecycle();
      if (callback.kind().name().equals("FUNCTION") == false) {
        throw new IllegalStateException("callback closed unexpectedly");
      }
      System.out.printf("%d %d %d %d %d%n", eval, hostCallback, textJson, bufferCopy, life);
    }
  }
}
