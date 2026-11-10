'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { resolve } = require('node:path');

async function within(promise, ms, label) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(label)), ms);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  const binary = process.argv[2];
  if (!binary) throw new Error('usage: debugger_driver.cjs <inspector-demo>');
  const child = spawn(resolve(binary), ['--port', '0'], { stdio: ['ignore', 'ignore', 'pipe'] });
  let output = '';
  let readyResolve;
  let readyReject;
  const ready = new Promise((resolveReady, rejectReady) => { readyResolve = resolveReady; readyReject = rejectReady; });
  child.once('error', readyReject);
  child.stderr.on('data', bytes => {
    output = (output + bytes.toString()).slice(-65536);
    if (process.env.JSBAY_DEBUGGER_TRACE === '1') process.stderr.write(bytes);
    const port = /inspector listening on ws:\/\/127\.0\.0\.1:(\d+)\//.exec(output)?.[1];
    if (port) readyResolve(port);
  });
  child.once('close', code => readyReject(new Error(`Inspector exited ${code}: ${output}`)));
  try {
    const port = await within(ready, 15000, 'Inspector did not start');
    const test = spawn(process.execPath, [resolve(__dirname, 'e2e.cjs'), '--host', '127.0.0.1', '--port', port, '--debugger-flow', ...process.argv.slice(3)], { stdio: 'inherit' });
    const [code, signal] = await once(test, 'close');
    assert.equal(signal, null);
    assert.equal(code, 0);
  } catch (error) {
    if (output) process.stderr.write(`Inspector stderr:\n${output}`);
    throw error;
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'close');
      child.kill('SIGTERM');
      try {
        await within(exited, 10000, 'Inspector did not stop');
      } catch (error) {
        child.kill('SIGKILL');
        await exited;
        throw error;
      }
    }
  }
}

main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
