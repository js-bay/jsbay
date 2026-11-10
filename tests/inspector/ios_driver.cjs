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
  const [simulator, binary] = process.argv.slice(2);
  if (!simulator || !binary) throw new Error('usage: ios_driver.cjs <booted-simulator> <debug-owner-binary>');
  const child = spawn('xcrun', ['simctl', 'spawn', simulator, resolve(binary), '--port', '0'], { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '';
  let readyResolve;
  let readyReject;
  const ready = new Promise((resolveReady, rejectReady) => { readyResolve = resolveReady; readyReject = rejectReady; });
  const exited = once(child, 'close');
  child.once('error', readyReject);
  const collect = bytes => {
    output = (output + bytes.toString()).slice(-65536);
    const match = /^READY (\d+)\r?$/m.exec(output);
    if (match) readyResolve(match[1]);
  };
  child.stdout.on('data', collect);
  child.stderr.on('data', collect);
  child.once('close', code => readyReject(new Error(`Simulator inspector exited ${code}: ${output}`)));
  try {
    const port = await within(ready, 20000, 'Simulator inspector did not start');
    const test = spawn(process.execPath, [resolve(__dirname, 'e2e.cjs'), '--host', '127.0.0.1', '--port', port, '--debugger-flow'], { stdio: 'inherit' });
    const [code, signal] = await once(test, 'close');
    assert.equal(signal, null);
    assert.equal(code, 0);
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.stdin.end('\n');
    try {
      const [code, signal] = await within(exited, 15000, 'Simulator inspector did not stop');
      assert.equal(signal, null);
      assert.equal(code, 0, output);
      assert.match(output, /CLEAN_EXIT/);
    } catch (error) {
      child.kill('SIGKILL');
      await exited.catch(() => {});
      throw error;
    }
  }
  console.log('PASS iOS Simulator owner-thread CDP and CLEAN_EXIT');
}

main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
