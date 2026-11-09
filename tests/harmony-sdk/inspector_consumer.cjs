'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { resolve } = require('node:path');
const { isMainThread, parentPort, Worker } = require('node:worker_threads');

// The Worker runs the unmodified Harmony N-API bridge and core under a Node host.
if (!isMainThread) {
  const native = require(process.env.JSBAY_HARMONY_NODE);
  const engine = native.create(7132);
  let timer;
  native.attachLoop(engine, (delay, generation) => {
    clearTimeout(timer);
    timer = setTimeout(() => native.runLoopTask(engine, generation), delay);
  });
  const port = native.inspectorStart(engine, 0);
  assert.ok(port > 0);
  parentPort.on('message', () => {
    native.inspectorStop(engine);
    native.close(engine);
    clearTimeout(timer);
    parentPort.postMessage({ closed: true });
    parentPort.close();
  });
  parentPort.postMessage({ port });
} else {
  async function within(promise, ms) {
    let timer;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Harmony bridge worker timed out')), ms);
      })]);
    } finally {
      clearTimeout(timer);
    }
  }

  async function main() {
    const worker = new Worker(__filename);
    const exited = once(worker, 'exit');
    try {
      const [ready] = await within(once(worker, 'message'), 10000);
      assert.ok(ready.port > 0);
      const test = spawn(process.execPath, [resolve(__dirname, '../inspector/e2e.cjs'), '--host', '127.0.0.1', '--port', String(ready.port), '--debugger-flow'], { stdio: 'inherit' });
      const [code, signal] = await once(test, 'close');
      assert.equal(signal, null);
      assert.equal(code, 0);
    } finally {
      const closed = once(worker, 'message');
      worker.postMessage('close');
      try {
        const [message] = await within(closed, 10000);
        assert.equal(message.closed, true);
        const [code] = await within(exited, 10000);
        assert.equal(code, 0);
      } catch (error) {
        await worker.terminate();
        throw error;
      }
    }
    console.log('PASS Harmony N-API CDP debugger');
  }

  main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
}
