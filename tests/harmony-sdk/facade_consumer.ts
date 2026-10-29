import { Engine, JsBayStatus, JsBayStatusError, JsException, Value, ValueKind } from './JsBay';

function expect(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(message);
  }
}

function expectStatus(operation: () => void, status: JsBayStatus, message: string): void {
  try {
    operation();
  } catch (cause) {
    expect(cause instanceof JsBayStatusError && (cause as JsBayStatusError).status === status, `${message}: ${(cause as JsBayStatusError).status}`);

    return;
  }
  throw new Error(message);
}

function evaluated(engine: Engine, source: string, filename: string, body: (value: Value) => void): void {
  const value = engine.evaluate(source, filename);
  try {
    body(value);
  } finally {
    value.close();
  }
}

function expectJsError(operation: () => void, name: string, message: string): void {
  try {
    operation();
  } catch (cause) {
    expect(cause instanceof JsException, `${message}: expected a JavaScript exception`);
    const thrown = (cause as JsException).value;
    try {
      const actual = thrown.get('name');
      try {
        expect(actual.string() === name, `${message}: expected ${name}, received ${actual.string()}`);
      } finally {
        actual.close();
      }
    } finally {
      thrown.close();
    }

    return;
  }
  throw new Error(`${message}: did not throw`);
}

function keyNames(keys: Value): string {
  const length = keys.get('length');
  try {
    const names: string[] = [];
    for (let index = 0; index < length.toNumber(); index += 1) {
      const name = keys.get(String(index));
      try {
        names.push(name.string());
      } finally {
        name.close();
      }
    }

    return names.join(',');
  } finally {
    length.close();
  }
}

function checkObjectOperations(engine: Engine): void {
  evaluated(engine, '(function P(x) { this.x = x })', 'facade-construct.js', (point: Value): void => {
    const answer = engine.newNumber(42);
    try {
      const built = point.construct([answer]);
      try {
        const x = built.get('x');
        try {
          expect(x.toNumber() === 42, 'facade construct passes arguments');
        } finally {
          x.close();
        }
        expect(built.instanceOf(point), 'facade constructed value is instanceOf its constructor');
      } finally {
        built.close();
      }
    } finally {
      answer.close();
    }
  });
  evaluated(engine, '(function Q() { this.n = arguments.length })', 'facade-construct-n.js', (counter: Value): void => {
    const built = counter.construct();
    try {
      const n = built.get('n');
      try {
        expect(n.toNumber() === 0, 'facade construct defaults to no arguments');
      } finally {
        n.close();
      }
    } finally {
      built.close();
    }
  });
  evaluated(engine, "(function B() { throw new Error('ctor boom') })", 'facade-ctor-boom.js', (boom: Value): void => {
    expectJsError((): void => { boom.construct().close(); }, 'Error', 'facade construct propagates constructor throw');
  });
  evaluated(engine, '(() => 1)', 'facade-arrow-construct.js', (arrow: Value): void => {
    expectJsError((): void => { arrow.construct().close(); }, 'TypeError', 'facade construct rejects non-constructor');
  });

  evaluated(engine, '({ a: 1 })', 'facade-has.js', (target: Value): void => {
    expect(target.has('a'), 'facade has own property');
    expect(target.has('toString'), 'facade has inherited property');
    expect(!target.has('zzz'), 'facade has missing property is false');
  });
  const number = engine.newNumber(42);
  try {
    expectJsError((): void => { number.has('a'); }, 'TypeError', 'facade has rejects non-object');
  } finally {
    number.close();
  }
  evaluated(engine, "new Proxy({}, { has(t, k) { throw new Error('trap') } })", 'facade-has-trap.js', (trap: Value): void => {
    expectJsError((): void => { trap.has('a'); }, 'Error', 'facade has propagates Proxy trap throw');
  });

  evaluated(engine, "(() => { const o = { a: 1 }; Object.defineProperty(o, 'fixed', { value: 1, configurable: false }); return o })()", 'facade-delete.js', (target: Value): void => {
    expect(target.delete('a'), 'facade delete configurable property');
    expect(!target.has('a'), 'facade deleted property is gone');
    expect(!target.delete('fixed'), 'facade delete non-configurable reports false');
    expect(target.has('fixed'), 'facade non-configurable property survives delete');
    expect(target.delete('missing'), 'facade delete missing property is true');
  });
  const undefinedTarget = engine.undefined();
  try {
    expectJsError((): void => { undefinedTarget.delete('a'); }, 'TypeError', 'facade delete rejects undefined');
  } finally {
    undefinedTarget.close();
  }
  const primitiveText = engine.newString('abc');
  try {
    expect(primitiveText.delete('zz'), 'facade delete converts primitive with ToObject');
  } finally {
    primitiveText.close();
  }

  evaluated(engine, "(() => { const o = { b: 1, 2: 1, a: 1, 1: 1 }; Object.defineProperty(o, 'hidden', { value: 1, enumerable: false }); o[Symbol('s')] = 1; return o })()", 'facade-keys.js', (target: Value): void => {
    const keys = target.keys();
    try {
      expect(keyNames(keys) === '1,2,b,a', `facade keys order and filtering: ${keyNames(keys)}`);
    } finally {
      keys.close();
    }
  });
  evaluated(engine, 'Object.create({ inherited: 1 })', 'facade-keys-inherited.js', (target: Value): void => {
    const keys = target.keys();
    try {
      expect(keyNames(keys) === '', 'facade keys excludes inherited keys');
    } finally {
      keys.close();
    }
  });
  evaluated(engine, "new Proxy({}, { ownKeys() { return ['z', 'y'] }, getOwnPropertyDescriptor() { return { value: 1, enumerable: true, configurable: true } } })", 'facade-keys-proxy.js', (target: Value): void => {
    const keys = target.keys();
    try {
      expect(keyNames(keys) === 'z,y', `facade keys follows Proxy ownKeys order: ${keyNames(keys)}`);
    } finally {
      keys.close();
    }
  });
  evaluated(engine, 'null', 'facade-keys-null.js', (nothing: Value): void => {
    expectJsError((): void => { nothing.keys().close(); }, 'TypeError', 'facade keys rejects null');
  });

  evaluated(engine, '(class { static [Symbol.hasInstance](v) { return v === 7 } })', 'facade-has-instance.js', (custom: Value): void => {
    const seven = engine.newNumber(7);
    const eight = engine.newNumber(8);
    try {
      expect(seven.instanceOf(custom), 'facade instanceOf honors Symbol.hasInstance');
      expect(!eight.instanceOf(custom), 'facade instanceOf Symbol.hasInstance can decline');
    } finally {
      seven.close(); eight.close();
    }
  });
  evaluated(engine, '[]', 'facade-instance-array.js', (array: Value): void => {
    evaluated(engine, 'Array', 'facade-instance-array-class.js', (arrayClass: Value): void => {
      expect(array.instanceOf(arrayClass), 'facade instanceOf matches prototype chain');
    });
    evaluated(engine, 'Function', 'facade-instance-function-class.js', (functionClass: Value): void => {
      expect(!array.instanceOf(functionClass), 'facade instanceOf rejects unrelated constructor');
    });
    evaluated(engine, '({})', 'facade-instance-plain.js', (plain: Value): void => {
      expectJsError((): void => { array.instanceOf(plain); }, 'TypeError', 'facade instanceOf rejects non-callable constructor');
    });
  });
}

const engine = Engine.create(1101);
try {
  const binding = engine.bind('throwValue', (_this: Value, _args: Value[]): Value => {
    throw new JsException(engine.newNumber(7));
  });
  try {
    const caught = engine.evaluate('try { throwValue() } catch (error) { error }', 'facade-throw.js');
    try {
      expect(caught.toNumber() === 7, 'facade callback must preserve JsException Value');
    } finally {
      caught.close();
    }
  } finally {
    binding.close();
  }

  const syncInline = engine.bindSync('syncInline', 100n, (requestId: bigint, _this: Value, args: Value[]): void => {
    expect(typeof requestId === 'bigint', 'facade sync request ID is bigint');
    expect(args[0].toNumber() === 41, 'facade sync argument');
    expect(Engine.completeSyncString(requestId, '41') === JsBayStatus.Ok, 'facade sync completion');
  });
  try {
    const result = engine.evaluate('Number(syncInline(41)) + 1', 'facade-sync-inline.js');
    try {
      expect(result.toNumber() === 42, 'facade sync result');
    } finally {
      result.close();
    }
  } finally {
    syncInline.close();
  }
  const syncReject = engine.bindSync('syncReject', 100n, (requestId: bigint, _this: Value, _args: Value[]): void => {
    expect(Engine.rejectSync(requestId, 'sync rejected') === JsBayStatus.Ok, 'facade sync rejection completion');
  });
  try {
    const result = engine.evaluate('try { syncReject() } catch (error) { error }', 'facade-sync-reject.js');
    try {
      expect(String(result.string()).includes('sync rejected'), 'facade sync rejection value');
    } finally {
      result.close();
    }
  } finally {
    syncReject.close();
  }

  const nul = engine.newString('harmony\u0000😀');
  try {
    expect(nul.string() === 'harmony\u0000😀', 'Value.string preserves NUL and Unicode');
  } finally {
    nul.close();
  }
  const borrowedDescription = engine.bind('borrowedDescription', (thisValue: Value, _args: Value[]): Value => {
    expectStatus(() => new JsException(thisValue).describeAndClose(), JsBayStatus.InvalidArgument, 'Harmony borrowed exception text is rejected before conversion');

    return engine.undefined();
  });
  try {
    const value = engine.evaluate('borrowedDescription()', 'borrowed-description.js');
    value.close();
  } finally {
    borrowedDescription.close();
  }
  let expiredThis: Value | undefined;
  let expiredArgument: Value | undefined;
  const expiredDescription = engine.bind('expiredDescription', (thisValue: Value, args: Value[]): Value => {
    expiredThis = thisValue;
    expiredArgument = args[0];

    return engine.undefined();
  });
  try {
    const value = engine.evaluate('expiredDescription(1)', 'expired-description.js');
    value.close();
  } finally {
    expiredDescription.close();
  }
  expectStatus(() => new JsException(expiredThis!).describeAndClose(), JsBayStatus.StaleValue, 'Harmony expired callback this is stale before description');
  expectStatus(() => new JsException(expiredArgument!).describeAndClose(), JsBayStatus.StaleValue, 'Harmony expired callback argument is stale before description');
  try {
    engine.evaluate("throw 'harmony-display\\u0000😀'", 'describe-and-close.js'); throw new Error('Harmony consuming description source');
  } catch (cause) {
    expect(cause instanceof JsException, 'Harmony description source must preserve Value');
    const error = cause as JsException;
    expect(error.describeAndClose() === 'harmony-display\u0000😀', 'Harmony consuming description text');
    expectStatus(() => error.value.toUtf8(), JsBayStatus.StaleValue, 'Harmony consuming description closes original');
  }
  try {
    engine.evaluate('throw {toString(){throw 9}}', 'describe-and-close-secondary.js'); throw new Error('Harmony secondary consuming description source');
  } catch (cause) {
    expect(cause instanceof JsException, 'Harmony secondary description source must preserve Value');
    const error = cause as JsException;
    expect(error.describeAndClose() === 'JavaScript exception', 'Harmony secondary description fallback');
    expectStatus(() => error.value.toUtf8(), JsBayStatus.StaleValue, 'Harmony secondary consuming description closes original');
  }

  expect(engine.requestInterrupt() === true, 'facade interrupt can be requested');
  expect(engine.clearInterrupt() === true, 'facade clearInterrupt clears the request');
  const nullValue = engine.null();
  try {
    expect(nullValue.type() === ValueKind.Null, 'facade null method keeps its public property name');
  } finally {
    nullValue.close();
  }
  const symbolValue = engine.evaluate("Symbol('kind')", 'symbol-kind.js');
  try {
    expect(symbolValue.type() === ValueKind.Symbol, 'facade symbol kind');
  } finally {
    symbolValue.close();
  }
  const bigIntValue = engine.evaluate('1n', 'bigint-kind.js');
  try {
    expect(bigIntValue.type() === ValueKind.BigInt, 'facade bigint kind');
  } finally {
    bigIntValue.close();
  }

  const noCache = engine.evaluate('1', 'cache-none.js');
  try {
    expect(noCache.toNumber() === 1, 'evaluate without cache');
  } finally {
    noCache.close();
  }
  const cached = engine.evaluate('2', 'cache-both.js', '/tmp/jsbay-normalization/facade-cache', 'v1');
  try {
    expect(cached.toNumber() === 2, 'evaluate with cache');
  } finally {
    cached.close();
  }
  expectStatus(() => engine.evaluate('1', 'cache-dir.js', '/tmp/jsbay-normalization/facade-cache'), JsBayStatus.InvalidArgument, 'cache directory without version');
  expectStatus(() => engine.evaluate('1', 'cache-version.js', undefined, 'v1'), JsBayStatus.InvalidArgument, 'cache version without directory');

  const malformed = '\uD800';
  expectStatus(() => engine.evaluate(malformed, 'unicode.js'), JsBayStatus.InvalidArgument, 'source must reject lone surrogate');
  expectStatus(() => engine.evaluate('1', malformed), JsBayStatus.InvalidArgument, 'filename must reject lone surrogate');
  expectStatus(() => engine.evaluate('1', 'unicode-cache.js', malformed, 'v1'), JsBayStatus.InvalidArgument, 'cache directory must reject lone surrogate');
  expectStatus(() => engine.evaluate('1', 'unicode-cache.js', '/tmp/jsbay-normalization/facade-cache', malformed), JsBayStatus.InvalidArgument, 'cache version must reject lone surrogate');
  expectStatus(() => engine.newString(malformed), JsBayStatus.InvalidArgument, 'newString must reject lone surrogate');
  expectStatus(() => engine.newJson(malformed), JsBayStatus.InvalidArgument, 'newJson must reject lone surrogate');
  expectStatus(() => engine.newError(malformed), JsBayStatus.InvalidArgument, 'newError must reject lone surrogate');
  expectStatus(() => engine.bind(malformed, () => engine.undefined()), JsBayStatus.InvalidArgument, 'bind name must reject lone surrogate');
  const object = engine.newObject();
  const one = engine.newNumber(1);
  try {
    expectStatus(() => object.get(malformed), JsBayStatus.InvalidArgument, 'get key must reject lone surrogate');
    expectStatus(() => object.set(malformed, one), JsBayStatus.InvalidArgument, 'set key must reject lone surrogate');
  } finally {
    object.close(); one.close();
  }

  let borrowed: Value | undefined;
  const borrowedBinding = engine.bind('borrowedClose', (_this: Value, args: Value[]): Value => {
    borrowed = args[0];
    expectStatus(() => borrowed!.close(), JsBayStatus.InvalidArgument, 'borrowed close must be invalid during callback');

    return engine.newNumber(1);
  });
  try {
    const value = engine.evaluate('borrowedClose(2)', 'borrowed-close.js');
    value.close();
  } finally {
    borrowedBinding.close();
  }
  expectStatus(() => borrowed!.toNumber(), JsBayStatus.StaleValue, 'borrowed value must be stale after callback');
  expectStatus(() => borrowed!.close(), JsBayStatus.StaleValue, 'expired borrowed value close must be stale');
  const idempotent = engine.newNumber(3);
  idempotent.close();
  idempotent.close();

  const duplicateId = 1103;
  const original = Engine.create(duplicateId);
  try {
    expectStatus(() => Engine.create(duplicateId), JsBayStatus.InvalidArgument, 'duplicate live instance ID');
    const answer = original.evaluate('40 + 2', 'duplicate-id.js');
    try {
      expect(answer.toNumber() === 42, 'original engine survives duplicate ID rejection');
    } finally {
      answer.close();
    }
  } finally {
    original.close();
  }
  const rebuilt = Engine.create(duplicateId);
  try {
    const answer = rebuilt.evaluate('40 + 2', 'recreated-id.js');
    try {
      expect(answer.toNumber() === 42, 'destroyed instance ID can be recreated');
    } finally {
      answer.close();
    }
  } finally {
    rebuilt.close();
  }

  const other = Engine.create(1102);
  let transient: Value | undefined;
  try {
    const inner = other.bind('inner', (_this: Value, _args: Value[]): Value => {
      transient = engine.newNumber(99);

      return other.newNumber(1);
    });
    const outer = engine.bind('outer', (_this: Value, _args: Value[]): Value => {
      const nested = other.evaluate('inner()', 'nested.js');
      try {
        expect(nested.toNumber() === 1, 'nested engine callback');
      } finally {
        nested.close();
      }

      return engine.newNumber(1);
    });
    try {
      const result = engine.evaluate('outer()', 'outer.js');
      try {
        expect(result.toNumber() === 1, 'outer callback');
      } finally {
        result.close();
      }
    } finally {
      outer.close(); inner.close();
    }
    let stale = false;
    try {
 transient!.toNumber();
    } catch (_) {
      stale = true;
    }
    expect(stale, 'cross-engine nested callback temporary must be scope-closed');
  } finally {
    other.close();
  }
  checkObjectOperations(engine);
  console.log('harmony facade consumer: PASS');
} finally {
  engine.close();
}

async function checkAutomaticLoop(): Promise<void> {
  const automatic = Engine.create(1110);
  let callbacks = 0;
  try {
    await new Promise<void>((resolve, reject) => {
      const watchdog = setTimeout(() => reject(new Error('facade automatic loop did not execute')), 5000);
      const binding = automatic.bind('automaticDone', (): Value => {
        callbacks += 1;
        clearTimeout(watchdog);
        resolve();

        return automatic.undefined();
      });
      binding.close();
      automatic.evaluate('setTimeout(() => queueMicrotask(automaticDone), 1)', 'facade-automatic-loop.js').close();
    });
    expect(callbacks === 1, 'facade automatically executes timer and microtask');
  } finally {
    automatic.close();
  }
  const closing = Engine.create(1110);
  const cancelled = closing.bind('cancelledTimer', (): Value => {
    callbacks += 1;

    return closing.undefined();
  });
  cancelled.close();
  closing.evaluate('setTimeout(cancelledTimer, 0)', 'facade-cancelled-timer.js').close();
  closing.close();
  await new Promise<void>((resolve) => {
    setTimeout(resolve, 0);
  });
  expect(callbacks === 1, 'facade close cancels pending timer before id reuse');
  const recovering = Engine.create(1111);
  try {
    const reenter = recovering.bind('rejectNestedLoop', (): Value => {
      expectStatus(() => recovering.runLoop(), JsBayStatus.InvalidArgument, 'nested loop rejects');

      return recovering.undefined();
    });
    reenter.close();
    await new Promise<void>((resolve, reject) => {
      const watchdog = setTimeout(() => reject(new Error('rejected nested loop lost automatic driving')), 5000);
      const done = recovering.bind('recoveredLoopDone', (): Value => {
        clearTimeout(watchdog);
        resolve();

        return recovering.undefined();
      });
      done.close();
      recovering.evaluate('rejectNestedLoop(); setTimeout(recoveredLoopDone, 1)', 'recovered-loop.js').close();
    });
  } finally {
    recovering.close();
  }
  console.log('harmony facade automatic loop: PASS');
}

checkAutomaticLoop().catch((cause: Error): never => {
  throw cause;
});
