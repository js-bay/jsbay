import { Engine, JsException, JsBayStatusError, JsBayStatus, Value } from '@js-bay/harmony';

function expect(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(message);
  }
}

function expectThrows(operation: () => void, message: string): void {
  let thrown = false;
  try {
    operation();
  } catch (_) {
    thrown = true;
  }
  expect(thrown, message);
}

function expectStatus(operation: () => void, status: JsBayStatus, message: string): void {
  try {
    operation();
  } catch (cause) {
    expect(cause instanceof JsBayStatusError && (cause as JsBayStatusError).status === status, message);

    return;
  }
  throw new Error(message);
}

/* This is deliberately exported so a Worker consumer can invoke it on a device. It covers synchronous callback scope ownership without creating a second JavaScript or QuickJS thread. */
export function harmonyConformance(): boolean {
  const engine = Engine.create(904);
  let escaped: Value | undefined;
  let borrowed: Value | undefined;
  try {
    const binding = engine.bind('scopeProbe', (_this: Value, args: Value[]): Value => {
      borrowed = args[0];
      escaped = args[0].retain();
      /* Drop many scope-owned wrappers. N-API may collect them before this callback returns; the native scope keeps each wrapper alive. */
      for (let index = 0; index < 128; index += 1) {
        engine.newObject();
      }

      return engine.newNumber(args[0].toNumber() + 1);
    });
    try {
      const value = engine.evaluate('scopeProbe(41)', 'scope-probe.js');
      try {
        expect(value.toNumber() === 42, 'callback return');
      } finally {
        value.close();
      }
    } finally {
      binding.close();
    }

    expectThrows(() => borrowed!.toNumber(), 'borrowed callback value must expire');
    expect(escaped !== undefined && escaped.toNumber() === 41, 'retained callback value must escape');
    escaped!.close();

    const setup = engine.evaluate('globalThis.__harmonyTick = [0, 0]; queueMicrotask(() => __harmonyTick[0] = 1); setTimeout(() => { __harmonyTick[1] = 1; stopConformanceLoop(); }, 10); 0', 'tick.js');
    setup.close();
    const microtask = engine.evaluate('__harmonyTick[0]', 'microtask.js');
    try {
      expect(microtask.toNumber() === 1, 'microtask checkpoint');
    } finally {
      microtask.close();
    }
    const stopBinding = engine.bind('stopConformanceLoop', (): Value => {
      engine.stopLoop();

      return engine.undefined();
    });
    engine.runLoop();
    stopBinding.close();
    const timer = engine.evaluate('__harmonyTick[1]', 'timer.js');
    try {
      expect(timer.toNumber() === 1, 'self-driven timer');
    } finally {
      timer.close();
    }

    let arbitraryThrow = false;
    try {
      engine.evaluate('throw { code: 7 }', 'throw.js');
    } catch (cause) {
      expect(cause instanceof JsException, 'throw must retain its JavaScript value');
      const code = (cause as JsException).value.get('code');
      try {
        arbitraryThrow = code.toNumber() === 7;
      } finally {
        code.close(); (cause as JsException).value.close();
      }
    }
    expect(arbitraryThrow, 'arbitrary JavaScript throw');
    const throwBinding = engine.bind('throwValue', (_this: Value, _args: Value[]): Value => {
      throw new JsException(engine.newNumber(7));
    });
    try {
      const caught = engine.evaluate('try { throwValue() } catch (error) { error }', 'callback-throw.js');
      try {
        expect(caught.toNumber() === 7, 'callback JsException preserves its Value');
      } finally {
        caught.close();
      }
    } finally {
      throwBinding.close();
    }

    const noCache = engine.evaluate('1', 'cache-none.js');
    try {
      expect(noCache.toNumber() === 1, 'evaluate without cache');
    } finally {
      noCache.close();
    }
    const cached = engine.evaluate('2', 'cache-both.js', '/data/storage/el2/base/cache', 'v1');
    try {
      expect(cached.toNumber() === 2, 'evaluate with cache');
    } finally {
      cached.close();
    }
    expectStatus(() => engine.evaluate('1', 'cache-dir.js', '/data/storage/el2/base/cache'), JsBayStatus.InvalidArgument, 'cache dir without version');
    expectStatus(() => engine.evaluate('1', 'cache-version.js', undefined, 'v1'), JsBayStatus.InvalidArgument, 'cache version without dir');

    const malformed = '\uD800';
    expectStatus(() => engine.evaluate(malformed, 'unicode.js'), JsBayStatus.InvalidArgument, 'source lone surrogate');
    expectStatus(() => engine.evaluate('1', malformed), JsBayStatus.InvalidArgument, 'filename lone surrogate');
    expectStatus(() => engine.evaluate('1', 'unicode-cache.js', malformed, 'v1'), JsBayStatus.InvalidArgument, 'cache dir lone surrogate');
    expectStatus(() => engine.evaluate('1', 'unicode-cache.js', '/data/storage/el2/base/cache', malformed), JsBayStatus.InvalidArgument, 'cache version lone surrogate');
    expectStatus(() => engine.newString(malformed), JsBayStatus.InvalidArgument, 'newString lone surrogate');
    expectStatus(() => engine.newJson(malformed), JsBayStatus.InvalidArgument, 'newJson lone surrogate');
    expectStatus(() => engine.newError(malformed), JsBayStatus.InvalidArgument, 'newError lone surrogate');
    expectStatus(() => engine.bind(malformed, (_this: Value, _args: Value[]): Value => engine.undefined()), JsBayStatus.InvalidArgument, 'bind name lone surrogate');
    const textObject = engine.newObject();
    const textValue = engine.newNumber(1);
    try {
      expectStatus(() => textObject.get(malformed), JsBayStatus.InvalidArgument, 'get key lone surrogate');
      expectStatus(() => textObject.set(malformed, textValue), JsBayStatus.InvalidArgument, 'set key lone surrogate');
    } finally {
      textObject.close(); textValue.close();
    }

    let borrowedClose: Value | undefined;
    const borrowedBinding = engine.bind('borrowedClose', (_this: Value, args: Value[]): Value => {
      borrowedClose = args[0];
      expectStatus(() => borrowedClose!.close(), JsBayStatus.InvalidArgument, 'borrowed close during callback');

      return engine.newNumber(1);
    });
    try {
      const returned = engine.evaluate('borrowedClose(2)', 'borrowed-close.js');
      returned.close();
    } finally {
      borrowedBinding.close();
    }
    expectStatus(() => borrowedClose!.toNumber(), JsBayStatus.StaleValue, 'borrowed close after callback');
    const idempotent = engine.newNumber(3);
    idempotent.close();
    idempotent.close();
    const undefinedValue = engine.undefined();
    try {
      expectStatus(() => undefinedValue.toJson(), JsBayStatus.InvalidArgument, 'JSON undefined status');
    } finally {
      undefinedValue.close();
    }
    const setter = engine.evaluate('(() => { const o = {}; Object.defineProperty(o, "x", { set() { throw 7 } }); return o })()', 'setter.js');
    const one = engine.newNumber(1);
    try {
      let setterThrow = false;
      try {
        setter.set('x', one);
      } catch (cause) {
        expect(cause instanceof JsException, 'setter throw must be a JavaScript exception');
        const exceptionValue = (cause as JsException).value;
        try {
          setterThrow = exceptionValue.toNumber() === 7;
        } finally {
          exceptionValue.close();
        }
      }
      expect(setterThrow, 'setter primitive throw');
    } finally {
      setter.close(); one.close();
    }
    const stringer = engine.evaluate('({ toString() { throw 7 } })', 'to-string.js');
    try {
      let stringThrow = false;
      try {
        stringer.toUtf8();
      } catch (cause) {
        expect(cause instanceof JsException, 'toUtf8 throw must be a JavaScript exception');
        const exceptionValue = (cause as JsException).value;
        try {
          stringThrow = exceptionValue.toNumber() === 7;
        } finally {
          exceptionValue.close();
        }
      }
      expect(stringThrow, 'toUtf8 primitive throw');
    } finally {
      stringer.close();
    }

    const bytes = new ArrayBuffer(4);
    const view = new Uint8Array(bytes);
    view[0] = 1; view[1] = 2; view[2] = 3; view[3] = 4;
    const sourceView = new Uint8Array(bytes, 1, 2);
    const binary = engine.newArrayBuffer(sourceView);
    try {
      view[1] = 99;
      const copied = new Uint8Array(binary.copyBuffer());
      expect(copied.length === 2 && copied[0] === 2 && copied[1] === 3, 'typed array visible window copy');
    } finally {
      binary.close();
    }
    const typed = engine.evaluate('new Uint8Array([8, 7, 6]).subarray(1)', 'typed.js');
    const dataView = engine.evaluate('new DataView(new Uint8Array([5, 4, 3]).buffer, 1, 2)', 'dataview.js');
    try {
      expect(new Uint8Array(typed.copyBuffer())[0] === 7, 'JavaScript TypedArray copy');
      expect(new Uint8Array(dataView.copyBuffer())[0] === 4, 'JavaScript DataView copy');
    } finally {
      typed.close(); dataView.close();
    }

    const other = Engine.create(905);
    try {
      const foreign = engine.newNumber(1);
      const target = other.newObject();
      try {
        expectStatus(() => target.set('x', foreign), JsBayStatus.StaleValue, 'cross-instance values must fail');
      } finally {
        foreign.close(); target.close();
      }
    } finally {
      other.close();
    }

    const stale = engine.newNumber(9);
    engine.close();
    engine.close();
    expectStatus(() => stale.toNumber(), JsBayStatus.StaleValue, 'destroy invalidates values');

    return true;
  } finally {
    if (escaped !== undefined) {
      try {
        escaped.close();
      } catch (_) {}
    }
    engine.close();
  }
}
