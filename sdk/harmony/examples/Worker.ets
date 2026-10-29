import { Engine, JsException } from '@js-bay/harmony';

/* Call this from a dedicated ArkTS Worker per instance id. Never move the Engine to another Worker; the native bridge rejects off-owner calls with WrongThread. */
export function evaluateInWorker(instanceId: number, source: string): ArrayBuffer {
  const engine = Engine.create(instanceId);
  try {
    const nativeIdentity = engine.bind('nativeIdentity', (_this, args) => args[0]);
    try {
      const result = engine.evaluate(source, 'worker-input.js');
      try {
        return result.toUtf8();
      } finally {
        result.close();
      }
    } finally {
      nativeIdentity.close();
    }
  } catch (cause) {
    if (cause instanceof JsException) {
      try {
        return cause.value.toUtf8();
      } finally {
        cause.value.close();
      }
    }
    if (cause instanceof Error) {
      throw cause;
    }
    throw new Error(String(cause));
  } finally {
    engine.close();
  }
}
