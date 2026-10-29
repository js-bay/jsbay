import { Engine, Value } from '@js-bay/harmony';

/* Device conformance case: the same native binding recursively calls itself. Each invocation must receive a distinct callback scope. */
export function recursiveCallbackConformance(): boolean {
  const engine = Engine.create(903);
  try {
    const binding = engine.bind('recurse', (_this: Value, args: Value[]): Value => {
      const remaining = args[0].toNumber();
      if (remaining === 0) {
        return engine.newNumber(1);
      }
      const global = engine.global();
      const functionValue = global.get('recurse');
      const next = engine.newNumber(remaining - 1);

      return functionValue.call(global, [next]);
    });
    try {
      const result = engine.evaluate('recurse(2)', 'recursive-callback.js');
      try {
        return result.toNumber() === 1;
      } finally {
        result.close();
      }
    } finally {
      binding.close();
    }
  } finally {
    engine.close();
  }
}
