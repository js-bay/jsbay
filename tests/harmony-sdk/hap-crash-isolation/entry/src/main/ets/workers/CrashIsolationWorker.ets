import { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { Engine, Value } from '@js-bay/harmony';

/**
 * Worker half of CrashIsolation.ets.
 * Modes:
 *  - init-owner-close: create Engine, arm timers, wait for close then Engine.close()
 *  - init-no-close: create Engine + timers; never close — host terminate() → envCleanup
 *
 * Log keywords for hilog grepping: destroyEngine, Engine.close, Tags.JS_ENGINE, ww onerror
 */

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

let engine: Engine | undefined = undefined;
let stopBinding: Value | undefined = undefined;

function clearBindings(): void {
  if (stopBinding !== undefined) {
    try {
      stopBinding.close();
    } catch (_) {
    }
    stopBinding = undefined;
  }
}

workerPort.onmessage = (e: MessageEvents): void => {
  const data = e.data as Record<string, Object>;
  const command = data['command'] as string;
  try {
    if (command === 'init-owner-close') {
      const instanceId = data['instanceId'] as number;
      engine = Engine.create(instanceId);
      stopBinding = engine.bind('stopWorkerLoop', (_this: Value, _args: Value[]): Value => {
        engine!.stopLoop();
        return engine!.undefined();
      });
      const setup = engine.evaluate(
        'globalThis.__w=0; setTimeout(() => { __w = 1 }, 5); 0',
        'worker-timer.js');
      setup.close();
      console.info('Tags.JS_ENGINE worker owner-close ready');
      workerPort.postMessage({ ready: true, mode: 'owner-close' });
      return;
    }
    if (command === 'init-no-close') {
      const instanceId = data['instanceId'] as number;
      engine = Engine.create(instanceId);
      const setup = engine.evaluate(
        'globalThis.__spin=0; setInterval(() => { __spin++ }, 20); 0',
        'orphan-timer.js');
      setup.close();
      console.info('Tags.JS_ENGINE worker no-close ready (await envCleanup on terminate)');
      workerPort.postMessage({ ready: true, mode: 'no-close' });
      return;
    }
    if (command === 'close') {
      /* Ordered teardown: cancel loop → close values → engine.close → only then host terminate. */
      console.info('Tags.JS_ENGINE worker Engine.close begin');
      if (engine !== undefined) {
        try {
          engine.stopLoop();
        } catch (_) {
        }
        clearBindings();
        engine.close();
        engine = undefined;
        console.info('Tags.JS_ENGINE worker Engine.close done (destroyEngine sync)');
        workerPort.postMessage({ closed: true });
      }
      return;
    }
  } catch (cause) {
    console.error(`Tags.JS_ENGINE worker error ${String(cause)}`);
    workerPort.postMessage({ error: String(cause) });
  }
};

workerPort.onerror = (e: ErrorEvent): void => {
  console.error(`Tags.JS_ENGINE ww onerror ${e.message}`);
};

workerPort.onmessageerror = (_e: MessageEvents): void => {
  console.error('Tags.JS_ENGINE worker onmessageerror');
};
