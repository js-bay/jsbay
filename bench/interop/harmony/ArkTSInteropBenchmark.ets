import { Engine, Value } from './JsBay';

/** Device-facing entry point. Invoke this from the application's Engine owner Worker; it returns measurements rather than printing host benchmark JSON. */
export interface ArkTSInteropMeasurement {
  readonly evalComputeNs: bigint;
  readonly hostCallbackNs: bigint;
  readonly textJsonNs: bigint;
  readonly bufferCopyNs: bigint;
  readonly lifecycleNs: bigint;
}

function elapsed(nowNanoseconds: () => bigint, operation: () => void, count: number = 1000): bigint {
  for (let index = 0; index < 100; index += 1) operation();
  const start = nowNanoseconds();
  for (let index = 0; index < count; index += 1) operation();
  return nowNanoseconds() - start;
}
const expectedJSON = new Uint8Array([123, 34, 116, 101, 120, 116, 34, 58, 34, 112, 117, 98, 108, 105, 99, 32, 105, 110, 116, 101, 114, 111, 112, 34, 44, 34, 99, 111, 117, 110, 116, 34, 58, 52, 50, 125]);
function sameBytes(actual: Uint8Array, expected: Uint8Array): boolean {
  if (actual.byteLength !== expected.byteLength) return false;
  for (let index = 0; index < expected.byteLength; index += 1) if (actual[index] !== expected[index]) return false;
  return true;
}
function number(engine: Engine, source: string): void {
  const value = engine.evaluate(source, 'interop.js');
  try {
    if (value.toNumber() !== 42) throw new Error('unexpected benchmark result');
  } finally { value.close(); }
}

/** Runs the public Harmony facade only. Pass a monotonic native clock such as CLOCK_MONOTONIC exposed by the host application; Date.now() is deliberately not accepted because it cannot support nanosecond benchmark reporting. */
export function runArkTSInteropBenchmark(nowNanoseconds: () => bigint): ArkTSInteropMeasurement {
  const engine = Engine.create(1900001);
  try {
    const callback = engine.bind('benchCallback', (_self: Value, _args: Value[]): Value => engine.newNumber(42));
    try {
      const evalComputeNs = elapsed(nowNanoseconds, () => number(engine, 'var n=0; for(var i=0;i<64;i++)n+=i; 42'));
      const hostCallbackNs = elapsed(nowNanoseconds, () => number(engine, 'benchCallback()'));
      const textJsonNs = elapsed(nowNanoseconds, () => {
        const value = engine.evaluate("({text:'public interop',count:42})", 'text-json.js');
        try { if (!sameBytes(new Uint8Array(value.toJson()), expectedJSON)) throw new Error('unexpected JSON'); }
        finally { value.close(); }
      });
      const input = new Uint8Array(4096);
      input.fill(7);
      const bufferCopyNs = elapsed(nowNanoseconds, () => {
        const value = engine.newArrayBuffer(input);
        try { if (!sameBytes(new Uint8Array(value.copyBuffer()), input)) throw new Error('buffer mismatch'); }
        finally { value.close(); }
      });
      const lifecycleNs = elapsed(nowNanoseconds, () => {
        const life = Engine.create(1950000 + Math.floor(Math.random() * 10000));
        try { number(life, '42'); } finally { life.close(); }
      }, 100);
      return { evalComputeNs, hostCallbackNs, textJsonNs, bufferCopyNs, lifecycleNs };
    } finally { callback.close(); }
  } finally { engine.close(); }
}
