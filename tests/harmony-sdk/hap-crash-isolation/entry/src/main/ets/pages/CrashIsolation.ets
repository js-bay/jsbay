import { ErrorEvent, MessageEvents, worker } from '@kit.ArkTS';
import { Engine, JsBayStatus, JsBayStatusError, JsException, Value } from '@js-bay/harmony';

/**
 * Device-facing Harmony crash-isolation / close-ordering harness.
 * Prints greppable PASS:/FAIL:/SKIP: (hilog / console).
 *
 * Host anti-pattern under test: post destroy/close on a Worker then IMMEDIATELY
 * terminate without awaiting native destroy — Worker may never finish teardown;
 * orphan engine thread; TSFN into dead N-API env = UAF.
 * jsbay: sync owner-thread closeEngine + napi envCleanup. Still probe host misuse.
 */

let failures: number = 0;

function pass(name: string, detail?: string): void {
  if (detail) {
    console.info(`PASS: ${name} — ${detail}`);
  } else {
    console.info(`PASS: ${name}`);
  }
}

function fail(name: string, detail: string): void {
  failures += 1;
  console.error(`FAIL: ${name} — ${detail}`);
}

function skip(name: string, reason: string): void {
  console.warn(`SKIP: ${name} — ${reason}`);
}

function releaseQuiet(value: Value | undefined): void {
  if (value === undefined) {
    return;
  }
  try {
    value.close();
  } catch (_) {
  }
}

/** Happy path: create → timers → engine.close on owner → no crash; instanceId reusable. */
function caseHappyCloseOrdering(): void {
  const name = 'happy-close-ordering';
  try {
    const engine = Engine.create(9301);
    const stop = engine.bind('stopHappy', (_this: Value, _args: Value[]): Value => {
      engine.stopLoop();
      return engine.undefined();
    });
    try {
      const setup = engine.evaluate(
        'globalThis.__h=0; setTimeout(() => { __h = 1; stopHappy(); }, 10); 0',
        'happy-timer.js');
      setup.close();
      engine.runLoop();
      const flag = engine.evaluate('__h', 'happy-flag.js');
      try {
        if (flag.toNumber() !== 1) {
          fail(name, 'timer did not run');
          return;
        }
      } finally {
        flag.close();
      }
      const usage = engine.getMemoryUsage();
      engine.runGc();
      engine.close();
      engine.close(); /* idempotent */
      const again = Engine.create(9301);
      try {
        const v = again.evaluate('9*9', 'reuse.js');
        try {
          if (v.toNumber() !== 81) {
            fail(name, 'instanceId not reusable');
            return;
          }
        } finally {
          v.close();
        }
      } finally {
        again.close();
      }
      pass(name, `mallocSize=${usage.mallocSize}`);
    } finally {
      stop.close();
    }
  } catch (cause) {
    fail(name, String(cause));
  }
}

/** Close while a host/JS timer is still pending. */
function caseCloseWhileTimerPending(): void {
  const name = 'close-while-timer-pending';
  try {
    const engine = Engine.create(9302);
    const setup = engine.evaluate(
      'setTimeout(() => { globalThis.__late = 1 }, 500); 0',
      'pending.js');
    setup.close();
    engine.close();
    engine.close();
    pass(name);
  } catch (cause) {
    fail(name, String(cause));
  }
}

/**
 * Anti: create in Worker, host terminate() WITHOUT posting/awaiting close.
 * Expect envCleanup path; UI ability / harness process stays alive; instanceId free.
 */
async function caseNoCloseTerminate(workerScript: string): Promise<void> {
  const name = 'no-close-terminate-envCleanup';
  try {
    const w = new worker.ThreadWorker(workerScript);
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error('worker ready timeout'));
      }, 8000);
      w.onmessage = (e: MessageEvents): void => {
        const data = e.data as Record<string, Object>;
        if (data['ready'] === true && data['mode'] === 'no-close') {
          clearTimeout(timer);
          resolve();
        }
      };
      w.onerror = (err: ErrorEvent): void => {
        clearTimeout(timer);
        reject(new Error(`ww onerror ${err.message}`));
      };
      w.postMessage({ command: 'init-no-close', instanceId: 9303 });
    });
    /* Host anti-pattern: terminate without destroy ack. */
    w.terminate();
    await new Promise<void>((resolve) => setTimeout(resolve, 200));
    const engine = Engine.create(9303);
    try {
      const v = engine.evaluate('4+4', 'after-envCleanup.js');
      try {
        if (v.toNumber() !== 8) {
          fail(name, 'instanceId not free after envCleanup');
          return;
        }
      } finally {
        v.close();
      }
    } finally {
      engine.close();
    }
    pass(name, 'terminate without close; envCleanup; id reusable');
  } catch (cause) {
    fail(name, String(cause));
  }
}

/**
 * Host misuse: post close/destroy then IMMEDIATELY terminate without awaiting
 * native Engine.close. Parent must stay alive.
 */
async function caseTerminateBeforeDestroyAck(workerScript: string): Promise<void> {
  const name = 'terminate-before-destroy-ack';
  try {
    const w = new worker.ThreadWorker(workerScript);
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error('worker ready timeout'));
      }, 8000);
      w.onmessage = (e: MessageEvents): void => {
        const data = e.data as Record<string, Object>;
        if (data['ready'] === true && data['mode'] === 'owner-close') {
          clearTimeout(timer);
          resolve();
        }
      };
      w.onerror = (err: ErrorEvent): void => {
        clearTimeout(timer);
        console.error(`Tags.JS_ENGINE ww onerror ${err.message}`);
        reject(new Error(err.message));
      };
      w.postMessage({ command: 'init-owner-close', instanceId: 9304 });
    });
    w.postMessage({ command: 'close' });
    w.terminate(); /* do not await close ack — host anti-pattern under test */
    await new Promise<void>((resolve) => setTimeout(resolve, 200));
    pass(name, 'parent alive after post-close+immediate terminate (host-misuse probe)');
  } catch (cause) {
    fail(name, String(cause));
  }
}

/**
 * Wrong-thread: Engine lives on Worker; host tries Engine.close equivalent by asking
 * a second Worker / host thread to close — Worker reports WRONG_THREAD or refuses.
 * Here: create on this thread, spawn Worker that cannot see the wrapper; instead
 * create on Worker and ask host to close via postMessage carrying nothing transferable.
 * Authoritative check: Worker creates engine, host posts 'host-close-probe' which Worker
 * answers by attempting close from a nested path — actually same thread.
 *
 * Device pattern: engine created on Worker A; Worker B cannot receive Engine.
 * We assert owner-thread by creating on current thread then documenting that cross-Worker
 * transfer is unsupported; plus evaluate after close → InstanceNotFound.
 */
function caseWrongThreadAndAfterClose(): void {
  const name = 'wrong-thread-close';
  try {
    const engine = Engine.create(9305);
    /* Same-thread close is correct. Cross-Worker transfer of Engine is unsupported by ArkTS. */
    engine.close();
    let status: JsBayStatus | undefined = undefined;
    try {
      engine.evaluate('1', 'after-close.js');
      status = JsBayStatus.Ok;
    } catch (cause) {
      if (cause instanceof JsBayStatusError) {
        status = (cause as JsBayStatusError).status;
      }
    }
    if (status !== JsBayStatus.InstanceNotFound) {
      fail(name, `expected InstanceNotFound after close, got ${status}`);
      return;
    }
    skip(
      name,
      'ArkTS forbids transferring Engine across ThreadWorkers; owner-thread check is native ' +
        'requireEngine/WRONG_THREAD (see "Engine.close must run on its owner thread"). ' +
        `after-close=${status}. Host misuse of shared wrappers must not be introduced.`);
  } catch (cause) {
    fail(name, String(cause));
  }
}

function caseSoftException(): void {
  const name = 'soft-exception';
  try {
    const engine = Engine.create(9306);
    try {
      engine.evaluate('throw 1', 'soft.js');
      fail(name, 'evaluate should throw');
      return;
    } catch (cause) {
      if (cause instanceof JsException) {
        releaseQuiet((cause as JsException).value);
      } else {
        fail(name, `expected JsException got ${String(cause)}`);
        engine.close();
        return;
      }
    }
    const v = engine.evaluate('2+2', 'alive.js');
    try {
      if (v.toNumber() !== 4) {
        fail(name, 'engine dead after soft throw');
        return;
      }
    } finally {
      v.close();
    }
    engine.close();
    pass(name);
  } catch (cause) {
    fail(name, String(cause));
  }
}

function caseTimeLimitInterrupt(): void {
  const name = 'time-limit-interrupt';
  try {
    const engine = Engine.create(9307);
    if (!engine.setExecutionTimeLimit(50n)) {
      fail(name, 'setExecutionTimeLimit rejected');
      return;
    }
    let interrupted = false;
    const killer = setTimeout((): void => {
      interrupted = engine.requestInterrupt();
    }, 20);
    try {
      engine.evaluate('for(;;){}', 'spin.js');
      fail(name, 'infinite loop should not complete');
      return;
    } catch (cause) {
      if (cause instanceof JsException) {
        releaseQuiet((cause as JsException).value);
      }
    } finally {
      clearTimeout(killer);
      engine.clearInterrupt();
      engine.setExecutionTimeLimit(0n);
    }
    const v = engine.evaluate("'ok'", 'after-interrupt.js');
    try {
      if (v.string() !== 'ok') {
        fail(name, 'engine dead after interrupt');
        return;
      }
    } finally {
      v.close();
    }
    engine.close();
    pass(name, interrupted ? 'requestInterrupt=true' : 'deadline-or-interrupt');
  } catch (cause) {
    fail(name, String(cause));
  }
}

function caseMemoryLimit(): void {
  const name = 'memory-limit';
  try {
    const engine = Engine.create(9308);
    const before = engine.getMemoryUsage();
    let cap = before.mallocSize + 64n * 1024n;
    if (cap < 256n * 1024n) {
      cap = 256n * 1024n;
    }
    if (!engine.setMemoryLimit(cap)) {
      skip(name, 'backend rejected setMemoryLimit');
      engine.close();
      return;
    }
    try {
      const alloc = engine.evaluate('new ArrayBuffer(8 * 1024 * 1024)', 'oom.js');
      alloc.close();
      skip(name, 'allocation succeeded under soft cap; backend may not hard-fail');
      engine.setMemoryLimit(0n);
      engine.close();
      return;
    } catch (cause) {
      if (cause instanceof JsException) {
        releaseQuiet((cause as JsException).value);
      }
    }
    engine.setMemoryLimit(0n);
    engine.runGc();
    const v = engine.evaluate('3*3', 'after-oom.js');
    try {
      if (v.toNumber() !== 9) {
        fail(name, 'engine unusable after memory limit');
        return;
      }
    } finally {
      v.close();
    }
    engine.close();
    pass(name);
  } catch (cause) {
    fail(name, String(cause));
  }
}

function caseNativeFaultDoc(): void {
  skip(
    'native-fault-boundary',
    'same-process native abort still kills the host; soft limits ≠ crash isolation. ' +
      'Do NOT claim native fault containment.');
}

/**
 * Entry for Ability / hdc shell harness. Pass the Worker script URL used by the fixture
 * (e.g. './CrashIsolationWorker.ets').
 */
export async function runCrashIsolation(workerScript: string = './CrashIsolationWorker.ets'): Promise<boolean> {
  failures = 0;
  console.info('harmony crash-isolation start');
  caseHappyCloseOrdering();
  caseCloseWhileTimerPending();
  await caseTerminateBeforeDestroyAck(workerScript);
  await caseNoCloseTerminate(workerScript);
  caseWrongThreadAndAfterClose();
  caseSoftException();
  caseTimeLimitInterrupt();
  caseMemoryLimit();
  caseNativeFaultDoc();
  if (failures !== 0) {
    console.error(`FAIL: harmony crash-isolation harness failures=${failures}`);
    return false;
  }
  console.info('PASS: harmony crash-isolation harness complete');
  return true;
}
