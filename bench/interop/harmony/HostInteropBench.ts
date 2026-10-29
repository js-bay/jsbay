import { Engine, Value } from './JsBay';

declare const process: { hrtime: { bigint(): bigint } };

const warmup = 100;
const iterations = 1000;
const payloadBytes = 4096;

function elapsed(operation: () => void, count: number = iterations): bigint {
  for (let index = 0; index < warmup; index += 1) operation();
  const start = process.hrtime.bigint();
  for (let index = 0; index < count; index += 1) operation();
  return process.hrtime.bigint() - start;
}
const expectedJSON = new Uint8Array([123, 34, 116, 101, 120, 116, 34, 58, 34, 112, 117, 98, 108, 105, 99, 32, 105, 110, 116, 101, 114, 111, 112, 34, 44, 34, 99, 111, 117, 110, 116, 34, 58, 52, 50, 125]);
function sameBytes(actual: Uint8Array, expected: Uint8Array): boolean {
  if (actual.byteLength !== expected.byteLength) return false;
  for (let index = 0; index < expected.byteLength; index += 1) if (actual[index] !== expected[index]) return false;
  return true;
}
function expectNumber(engine: Engine, source: string): void {
  const value = engine.evaluate(source, 'interop.js');
  try {
    if (value.toNumber() !== 42) throw new Error('unexpected benchmark result');
  } finally { value.close(); }
}

const engine = Engine.create(1700001);
try {
  const binding = engine.bind('benchCallback', (_self: Value, _args: Value[]): Value => engine.newNumber(42));
  try {
    const evalTime = elapsed(() => expectNumber(engine, 'var n=0; for(var i=0;i<64;i++)n+=i; 42'));
    const callbackTime = elapsed(() => expectNumber(engine, 'benchCallback()'));
    const textTime = elapsed(() => {
      const value = engine.evaluate("({text:'public interop',count:42})", 'text-json.js');
      try { if (!sameBytes(new Uint8Array(value.toJson()), expectedJSON)) throw new Error('unexpected JSON'); }
      finally { value.close(); }
    });
    const input = new Uint8Array(payloadBytes);
    input.fill(7);
    const bufferTime = elapsed(() => {
      const value = engine.newArrayBuffer(input);
      try {
        const copy = new Uint8Array(value.copyBuffer());
        if (!sameBytes(copy, input)) throw new Error('buffer mismatch');
      } finally { value.close(); }
    });
    const lifeTime = elapsed(() => {
      const life = Engine.create(1800000 + Math.floor(Number(process.hrtime.bigint() % 100000n)));
      try { expectNumber(life, '42'); } finally { life.close(); }
    }, 100);
    console.log(`${evalTime} ${callbackTime} ${textTime} ${bufferTime} ${lifeTime}`);
  } finally { binding.close(); }
} finally { engine.close(); }
