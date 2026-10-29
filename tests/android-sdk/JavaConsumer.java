package io.jsbay.consumer;

import io.jsbay.Callback;
import io.jsbay.Engine;
import io.jsbay.JsBayException;
import io.jsbay.Value;
import java.io.File;
import java.io.IOException;
import java.util.Arrays;

/** Java-only public SDK conformance consumer. */
public final class JavaConsumer {
  private static void require(boolean value, String message) {
    if (!value) throw new AssertionError(message);
  }

  private static File createCacheDirectory(String prefix) throws IOException {
    File directory = File.createTempFile(prefix, ".cache");
    if (!directory.delete() || !directory.mkdir()) {
      throw new IOException("cannot create cache directory");
    }
    return directory;
  }

  private static void rejected(Runnable action, io.jsbay.Status status, String message) {
    try {
      action.run();
      throw new AssertionError(message);
    } catch (JsBayException expected) {
      require(expected.getStatus() == status, message + ": " + expected.getStatus());
    }
  }

  private static void jsError(Runnable action, String name, String message) {
    try {
      action.run();
      throw new AssertionError(message);
    } catch (JsBayException expected) {
      require(
          expected.getStatus() == io.jsbay.Status.EXCEPTION && expected.getValue() != null,
          message + ": " + expected.getStatus());
      try (Value error = expected.getValue();
          Value actual = error.get("name")) {
        require(actual.string().equals(name), message + ": " + actual.string());
      }
    }
  }

  private static void runObjectOperations(Engine engine) {
    try (Value point = engine.evaluate("(function P(x){ this.x = x })", "java-construct.js");
        Value answer = engine.number(42);
        Value built = point.construct(java.util.List.of(answer));
        Value x = built.get("x")) {
      require(x.number() == 42, "Java construct passes arguments");
      require(built.instanceOf(point), "Java constructed value is instanceOf its constructor");
    }
    try (Value counter =
            engine.evaluate("(function Q(){ this.n = arguments.length })", "java-construct-n.js");
        Value built = counter.construct();
        Value n = built.get("n")) {
      require(n.number() == 0, "Java construct defaults to no arguments");
    }
    try (Value boom =
            engine.evaluate("(function B(){ throw new Error('ctor boom') })", "java-ctor-boom.js");
        Value arrow = engine.evaluate("(() => 1)", "java-arrow-construct.js")) {
      jsError(() -> boom.construct(), "Error", "Java construct propagates constructor throw");
      jsError(() -> arrow.construct(), "TypeError", "Java construct rejects non-constructor");
    }

    try (Value object = engine.evaluate("({a: 1})", "java-has.js");
        Value number = engine.number(42);
        Value trap =
            engine.evaluate(
                "new Proxy({}, { has(t, k) { throw new Error('trap') } })", "java-has-trap.js")) {
      require(object.has("a"), "Java has own property");
      require(object.has("toString"), "Java has inherited property");
      require(!object.has("zzz"), "Java has missing property is false");
      jsError(() -> number.has("a"), "TypeError", "Java has rejects non-object");
      jsError(() -> trap.has("a"), "Error", "Java has propagates Proxy trap throw");
    }

    try (Value object =
            engine.evaluate(
                "(() => { const o = {a: 1};"
                    + " Object.defineProperty(o, 'fixed', {value: 1, configurable: false});"
                    + " return o })()",
                "java-delete.js");
        Value undefined = engine.undefined();
        Value text = engine.string("abc")) {
      require(object.delete("a"), "Java delete configurable property");
      require(!object.has("a"), "Java deleted property is gone");
      require(!object.delete("fixed"), "Java delete non-configurable reports false");
      require(object.has("fixed"), "Java non-configurable property survives delete");
      require(object.delete("missing"), "Java delete missing property is true");
      jsError(() -> undefined.delete("a"), "TypeError", "Java delete rejects undefined");
      require(text.delete("zz"), "Java delete converts primitive with ToObject");
    }

    try (Value object =
            engine.evaluate(
                "(() => { const o = {b: 1, 2: 1, a: 1, 1: 1};"
                    + " Object.defineProperty(o, 'hidden', {value: 1, enumerable: false});"
                    + " o[Symbol('s')] = 1; return o })()",
                "java-keys.js");
        Value keys = object.keys();
        Value inherited =
            engine.evaluate("Object.create({inherited: 1})", "java-keys-inherited.js");
        Value inheritedKeys = inherited.keys();
        Value ordered =
            engine.evaluate(
                "new Proxy({}, { ownKeys() { return ['z', 'y'] },"
                    + " getOwnPropertyDescriptor() {"
                    + " return {value: 1, enumerable: true, configurable: true} } })",
                "java-keys-proxy.js");
        Value orderedKeys = ordered.keys();
        Value nothing = engine.evaluate("null", "java-keys-null.js")) {
      require(
          keys.json().equals("[\"1\",\"2\",\"b\",\"a\"]"),
          "Java keys order and filtering: " + keys.json());
      require(inheritedKeys.json().equals("[]"), "Java keys excludes inherited keys");
      require(
          orderedKeys.json().equals("[\"z\",\"y\"]"),
          "Java keys follows Proxy ownKeys order: " + orderedKeys.json());
      jsError(() -> nothing.keys(), "TypeError", "Java keys rejects null");
    }

    try (Value custom =
            engine.evaluate(
                "(class { static [Symbol.hasInstance](v) { return v === 7 } })",
                "java-has-instance.js");
        Value seven = engine.number(7);
        Value eight = engine.number(8);
        Value array = engine.evaluate("[]", "java-instance-array.js");
        Value arrayClass = engine.evaluate("Array", "java-instance-array-class.js");
        Value functionClass = engine.evaluate("Function", "java-instance-function-class.js");
        Value plain = engine.evaluate("({})", "java-instance-plain.js")) {
      require(seven.instanceOf(custom), "Java instanceOf honors Symbol.hasInstance");
      require(!eight.instanceOf(custom), "Java instanceOf Symbol.hasInstance can decline");
      require(array.instanceOf(arrayClass), "Java instanceOf matches prototype chain");
      require(!array.instanceOf(functionClass), "Java instanceOf rejects unrelated constructor");
      jsError(
          () -> array.instanceOf(plain),
          "TypeError",
          "Java instanceOf rejects non-callable constructor");
    }
  }

  private static void thrown(Runnable action, double value, String message) {
    try {
      action.run();
      throw new AssertionError(message);
    } catch (JsBayException expected) {
      require(expected.getValue() != null && expected.getValue().number() == value, message);
      expected.getValue().close();
    }
  }

  public static void runBridgeFaultRecovery() {
    try (Engine engine = new Engine(7119)) {
      boolean[] invoked = {false};
      try (Value broken =
          engine.bind(
              "bridgeFault",
              (self, args) -> {
                invoked[0] = true;
                throw new JsBayException(io.jsbay.Status.EXCEPTION, engine.number(1));
              })) {
        try {
          engine.evaluate("bridgeFault()", "android-bridge-fault.js");
          throw new AssertionError(
              "JNI bridge construction fault must reach JavaScript as an exception");
        } catch (JsBayException expected) {
          require(
              expected.getStatus() == io.jsbay.Status.EXCEPTION,
              "JNI bridge construction fault status");
          require(expected.getValue() != null, "JNI bridge construction fault value");
          expected.getValue().close();
        }
      }
      try (Value recovered = engine.bind("bridgeRecovery", (self, args) -> engine.number(42));
          Value answer = engine.evaluate("bridgeRecovery()", "android-bridge-recovery.js")) {
        require(answer.number() == 42, "JNI bridge did not recover after construction fault");
      }
    }
  }

  public static void run() {
    require(
        new JsBayException(io.jsbay.Status.INVALID_ARGUMENT).getValue() == null,
        "Java status-only exception constructor");
    final int mainInstanceId = 7101;
    try (Engine engine = new Engine(mainInstanceId)) {
      rejected(
          () -> new Engine(mainInstanceId),
          io.jsbay.Status.INVALID_ARGUMENT,
          "Java duplicate Engine id status");
      try (Value stillLive = engine.evaluate("40+2", "java-duplicate-id.js")) {
        require(stillLive.number() == 42, "Java duplicate id preserves original Engine");
      }
      try (Value object = engine.evaluate("({answer: 42})", "java-object.js");
          Value answer = object.get("answer");
          Value function = engine.evaluate("(function(x){ return x + 1 })", "java-function.js");
          Value input = engine.number(41);
          Value output = function.call(null, java.util.List.of(input))) {
        require(answer.number() == 42 && output.number() == 42, "Java live object/function");
      }
      Value[] borrowed = new Value[1];
      Value[] escaped = new Value[1];
      Callback echo =
          (self, arguments) -> {
            borrowed[0] = arguments.get(0);
            escaped[0] = arguments.get(0).retain();
            return escaped[0];
          };
      try (Value ignored = engine.bind("nativeEcho", echo);
          Value value = engine.evaluate("nativeEcho({answer: 42})", "java-callback.js");
          Value answer = value.get("answer")) {
        require(answer.number() == 42, "Java callback object identity");
      }
      rejected(
          () -> borrowed[0].number(),
          io.jsbay.Status.STALE_VALUE,
          "Java borrowed callback Value expires");
      rejected(
          borrowed[0]::close, io.jsbay.Status.STALE_VALUE, "Java borrowed callback close expires");
      try (Value kept = escaped[0];
          Value answer = kept.get("answer")) {
        require(answer.number() == 42, "Java retain escapes callback");
      }
      try (Value ignored =
          engine.bind(
              "throwSeven",
              (self, args) -> {
                throw new JsBayException(io.jsbay.Status.EXCEPTION, engine.number(7));
              })) {
        try {
          engine.evaluate("throwSeven()", "java-throw.js");
          throw new AssertionError("raw throw");
        } catch (JsBayException expected) {
          require(
              expected.getValue() != null && expected.getValue().number() == 7,
              "Java raw exception value");
          expected.getValue().close();
        }
      }
      try (Value ignored =
          engine.bind(
              "javaOrdinaryThrow",
              (self, args) -> {
                throw new RuntimeException("java-bridge-msg-79101");
              })) {
        try {
          engine.evaluate("javaOrdinaryThrow()", "java-ordinary-throw.js");
          throw new AssertionError("Java ordinary throw");
        } catch (JsBayException expected) {
          require(
              expected.getValue() != null
                  && expected.getValue().string().contains("java-bridge-msg-79101"),
              "Java ordinary Throwable message");
          expected.getValue().close();
        }
      }
      try (Value ignored =
          engine.bind(
              "javaUnicodeThrow",
              (self, args) -> {
                throw new RuntimeException("java-nul\u0000emoji😀");
              })) {
        try {
          engine.evaluate("javaUnicodeThrow()", "java-unicode-throw.js");
          throw new AssertionError("Java unicode throw");
        } catch (JsBayException expected) {
          require(
              expected.getValue() != null
                  && expected.getValue().string().contains("java-nul\u0000emoji😀"),
              "Java ordinary Throwable preserves NUL and emoji");
          expected.getValue().close();
        }
      }
      try (Value ignored =
          engine.bind(
              "javaHostileThrow",
              (self, args) -> {
                throw new RuntimeException("x") {
                  @Override
                  public String toString() {
                    throw new RuntimeException("hostile");
                  }
                };
              })) {
        try {
          engine.evaluate("javaHostileThrow()", "java-hostile-throw.js");
          throw new AssertionError("Java hostile throw");
        } catch (JsBayException expected) {
          require(
              expected.getValue() != null
                  && expected.getValue().string().contains("Java callback threw"),
              "Java hostile Throwable falls back");
          expected.getValue().close();
        }
      }
      Integer inspectorPort = engine.startInspector();
      require(inspectorPort != null && inspectorPort > 0, "Java inspector starts");
      engine.stopInspector();
      try (Value setter = engine.evaluate("({set x(v){throw 7}})", "java-setter.js");
          Value one = engine.number(1)) {
        thrown(() -> setter.set("x", one), 7, "Java setter preserves throw value");
      }
      try (Value stringThrow = engine.evaluate("({toString(){throw 9}})", "java-string-throw.js")) {
        thrown(stringThrow::string, 9, "Java toString preserves throw value");
      }
      try (Value jsonThrow = engine.evaluate("({toJSON(){throw 11}})", "java-json-throw.js")) {
        thrown(jsonThrow::json, 11, "Java toJSON preserves throw value");
      }
      try {
        engine.evaluate("throw 'java-display\\u0000😀'", "java-describe-and-close.js");
        throw new AssertionError("Java consuming description source");
      } catch (JsBayException expected) {
        require(
            expected.describeAndClose().equals("java-display\u0000😀"),
            "Java consuming description text");
        rejected(
            expected.getValue()::string,
            io.jsbay.Status.STALE_VALUE,
            "Java consuming description closes original");
      }
      try {
        engine.evaluate("throw {toString(){throw 9}}", "java-describe-and-close-secondary.js");
        throw new AssertionError("Java secondary consuming description source");
      } catch (JsBayException expected) {
        require(
            expected.describeAndClose().equals("JavaScript exception"),
            "Java secondary consuming description fallback");
        rejected(
            expected.getValue()::string,
            io.jsbay.Status.STALE_VALUE,
            "Java secondary consuming description closes original");
      }
      try (Value object = engine.objectValue();
          Value undefined = engine.undefined()) {
        try {
          object.number();
          throw new AssertionError("Java nonnumber must reject");
        } catch (JsBayException expected) {
          require(expected.getStatus() == io.jsbay.Status.INVALID_ARGUMENT, "Java number status");
        }
        try {
          object.bool();
          throw new AssertionError("Java nonbool must reject");
        } catch (JsBayException expected) {
          require(expected.getStatus() == io.jsbay.Status.INVALID_ARGUMENT, "Java bool status");
        }
        try {
          undefined.json();
          throw new AssertionError("Java undefined JSON must reject");
        } catch (JsBayException expected) {
          require(
              expected.getStatus() == io.jsbay.Status.INVALID_ARGUMENT,
              "Java JSON undefined status");
        }
      }
      try (Value ignored =
              engine.bind(
                  "reenter", (self, args) -> engine.evaluate("40 + 2", "java-reenter-inner.js"));
          Value result = engine.evaluate("reenter()", "java-reenter.js")) {
        require(result.number() == 42, "Java recursive callback");
      }
      Value[] binding = new Value[1];
      binding[0] =
          engine.bind(
              "closeBinding",
              (self, args) -> {
                binding[0].close();
                return engine.undefined();
              });
      try (Value result = engine.evaluate("closeBinding()", "java-close-callback.js")) {
        require(result.kind().name().equals("UNDEFINED"), "Java close in callback");
      }
      try (Engine other = new Engine(7103);
          Value foreign = other.number(1);
          Value object = engine.objectValue()) {
        rejected(
            () -> object.set("foreign", foreign),
            io.jsbay.Status.STALE_VALUE,
            "Java cross-engine reject");
        try (Value constructor = engine.evaluate("(function(){})", "java-cross-construct.js")) {
          rejected(
              () -> constructor.construct(java.util.List.of(foreign)),
              io.jsbay.Status.STALE_VALUE,
              "Java construct cross-engine argument reject");
          rejected(
              () -> object.instanceOf(foreign),
              io.jsbay.Status.STALE_VALUE,
              "Java instanceOf cross-engine constructor reject");
        }
      }
      runObjectOperations(engine);
      Engine deadEngine = new Engine(7104);
      Value stale = deadEngine.number(9);
      deadEngine.close();
      rejected(stale::number, io.jsbay.Status.STALE_VALUE, "Java destroyed Value expires");
      Engine callEngine = new Engine(7108);
      Value deadFunction = callEngine.evaluate("(()=>42)", "java-dead-call.js");
      Value deadReceiver = callEngine.objectValue();
      callEngine.close();
      rejected(
          deadFunction::call,
          io.jsbay.Status.STALE_VALUE,
          "Java closed Engine default receiver call");
      rejected(
          () -> deadFunction.call(deadReceiver),
          io.jsbay.Status.STALE_VALUE,
          "Java closed Engine explicit receiver call");
      deadFunction.close();
      deadReceiver.close();
      Value doubleClose = engine.number(1);
      doubleClose.close();
      doubleClose.close();
      Engine closedEngine = new Engine(7107);
      closedEngine.close();
      rejected(
          () -> closedEngine.number(1),
          io.jsbay.Status.INSTANCE_NOT_FOUND,
          "Java closed Engine status");
      try (Value closeBorrowed =
              engine.bind(
                  "javaCloseBorrowed",
                  (self, args) -> {
                    rejected(
                        args.get(0)::close,
                        io.jsbay.Status.INVALID_ARGUMENT,
                        "Java borrowed close status");
                    return engine.undefined();
                  });
          Value ignored = engine.evaluate("javaCloseBorrowed(1)", "java-borrowed-close.js")) {}
      try (Value borrowedDescription =
              engine.bind(
                  "javaBorrowedDescription",
                  (self, args) -> {
                    rejected(
                        () ->
                            new JsBayException(io.jsbay.Status.EXCEPTION, self).describeAndClose(),
                        io.jsbay.Status.INVALID_ARGUMENT,
                        "Java borrowed exception text");
                    return engine.undefined();
                  });
          Value ignored =
              engine.evaluate("javaBorrowedDescription()", "java-borrowed-description.js")) {}
      java.util.concurrent.atomic.AtomicReference<Throwable> wrongThread =
          new java.util.concurrent.atomic.AtomicReference<>();
      Thread worker =
          new Thread(
              () -> {
                try {
                  engine.number(1);
                } catch (Throwable error) {
                  wrongThread.set(error);
                }
              });
      worker.start();
      try {
        worker.join();
      } catch (InterruptedException error) {
        throw new AssertionError(error);
      }
      require(
          wrongThread.get() instanceof JsBayException
              && ((JsBayException) wrongThread.get()).getStatus() == io.jsbay.Status.WRONG_THREAD,
          "Java wrong thread status");
      String malformed = "\uD800";
      try (Value object = engine.objectValue()) {
        rejected(
            () -> engine.evaluate(malformed),
            io.jsbay.Status.INVALID_ARGUMENT,
            "Java malformed source");
        rejected(
            () -> engine.evaluate("1", malformed),
            io.jsbay.Status.INVALID_ARGUMENT,
            "Java malformed filename");
        rejected(
            () -> engine.evaluate("1", "x", malformed, "v"),
            io.jsbay.Status.INVALID_ARGUMENT,
            "Java malformed cache directory");
        rejected(
            () -> engine.evaluate("1", "x", "d", malformed),
            io.jsbay.Status.INVALID_ARGUMENT,
            "Java malformed cache version");
        rejected(
            () -> engine.bind(malformed, (self, args) -> engine.undefined()),
            io.jsbay.Status.INVALID_ARGUMENT,
            "Java malformed bind");
        rejected(
            () -> engine.string(malformed),
            io.jsbay.Status.INVALID_ARGUMENT,
            "Java malformed string");
        rejected(
            () -> engine.error(malformed),
            io.jsbay.Status.INVALID_ARGUMENT,
            "Java malformed error");
        rejected(
            () -> engine.json(malformed), io.jsbay.Status.INVALID_ARGUMENT, "Java malformed json");
        rejected(
            () -> object.get(malformed),
            io.jsbay.Status.INVALID_ARGUMENT,
            "Java malformed get key");
        rejected(
            () -> object.set(malformed, object),
            io.jsbay.Status.INVALID_ARGUMENT,
            "Java malformed set key");
      }
      try (Value ignored =
          engine.evaluate(
              "globalThis.javaMicro=0; queueMicrotask(()=>javaMicro=1);"
                  + " setTimeout(()=>globalThis.javaTimer=9,10)",
              "java-timer.js")) {
        require(engine.stopLoop(), "Java stop loop is thread-safe");
      }
      try {
        File cache = createCacheDirectory("jsbay-java-cache");
        try (Value cold =
                engine.evaluate(
                    "globalThis.javaCache=(globalThis.javaCache||0)+1;javaCache",
                    "java-cache.js",
                    cache.getAbsolutePath(),
                    "v1");
            Value warm =
                engine.evaluate(
                    "globalThis.javaCache=(globalThis.javaCache||0)+1;javaCache",
                    "java-cache.js",
                    cache.getAbsolutePath(),
                    "v1")) {
          require(
              cold.number() == 1 && warm.number() == 2 && engine.getLastCacheHit(),
              "Java cache executes once per evaluation");
        }
      } catch (java.io.IOException error) {
        throw new AssertionError(error);
      }
      byte[] input = new byte[] {0, 1, -1, 42};
      try (Value empty = engine.arrayBuffer(new byte[0]);
          Value buffer = engine.arrayBuffer(input)) {
        input[1] = 99;
        require(
            empty.bytes().length == 0 && Arrays.equals(buffer.bytes(), new byte[] {0, 1, -1, 42}),
            "Java ArrayBuffer copy-in/out");
        byte[] copied = buffer.bytes();
        copied[2] = 0;
        require(buffer.bytes()[2] == -1, "Java copy-out isolation");
      }
      try (Value view =
              engine.evaluate("new Uint8Array([8,9,0,255,7]).subarray(2,4)", "java-view.js");
          Value dataView =
              engine.evaluate(
                  "new DataView(new Uint8Array([8,9,0,255,7]).buffer,2,2)", "java-dataview.js")) {
        require(
            Arrays.equals(view.bytes(), new byte[] {0, -1})
                && Arrays.equals(dataView.bytes(), new byte[] {0, -1}),
            "Java buffer view offset");
      }
      try (Value surrogate = engine.evaluate("'\\uD800'", "java-surrogate.js");
          Value text = engine.evaluate("'A\\0😀'", "java-utf8.js")) {
        require(
            surrogate.string().equals("\uFFFD") && text.string().equals("A\u0000😀"),
            "Java UTF-8 replacement, emoji, and NUL");
      }
    }
    Engine closed = new Engine(mainInstanceId);
    closed.close();
    try (Engine replacement = new Engine(mainInstanceId);
        Value result = replacement.evaluate("40+2", "java-reused-id.js")) {
      require(!closed.requestInterrupt(), "Java closed Engine requestInterrupt rejects reused id");
      require(result.number() == 42, "Java replacement Engine remains runnable");
    }
  }
}
