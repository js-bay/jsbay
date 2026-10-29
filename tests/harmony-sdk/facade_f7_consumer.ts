import { Engine, JsBayStatus, JsBayStatusError, Value } from './JsBay';

declare const process: { exit(code: number): never };

function expect(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(message);
  }
}

function main(): void {
  const first = Engine.create(1201);
  const second = Engine.create(1202);
  let transient: Value | undefined;
  try {
    const inner = second.bind('inner', (_this: Value, _args: Value[]): Value => {
      transient = first.newNumber(99);

      return second.newNumber(1);
    });
    const outer = first.bind('outer', (_this: Value, _args: Value[]): Value => {
      const nested = second.evaluate('inner()', 'f7-inner.js');
      try {
        expect(nested.toNumber() === 1, 'nested result');
      } finally {
        nested.close();
      }

      return first.newNumber(1);
    });
    try {
      const result = first.evaluate('outer()', 'f7-outer.js');
      try {
        expect(result.toNumber() === 1, 'outer result');
      } finally {
        result.close();
      }
    } finally {
      outer.close(); inner.close();
    }
    try {
    transient!.toNumber();
    throw new Error('cross-engine nested temporary remained live');
    } catch (cause) {
      expect(cause instanceof JsBayStatusError && (cause as JsBayStatusError).status === JsBayStatus.StaleValue, 'cross-engine nested temporary must be stale');
    }
    console.log('harmony F7 facade consumer: PASS');
  } finally {
    second.close();
    first.close();
  }
}

try {
  main(); process.exit(0);
} catch (cause) {
  console.error(cause); process.exit(1);
}
