// The blocking demo must stop when signalled immediately after becoming ready.
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { test } = require('node:test');

const binary = process.argv[2];
if (!binary) throw new Error('usage: node signal_stop_test.cjs <inspector-demo>');

async function checkStop(signal) {
  const child = spawn(binary, ['--port', '0'], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  let stopped = false;
  let readyResolve;
  let readyReject;
  let timer;
  const ready = new Promise((resolve, reject) => {
    readyResolve = resolve;
    readyReject = reject;
  });
  // Drain both streams so output cannot keep the child from handling a signal.
  child.stdout.resume();
  child.stderr.on('data', (data) => {
    stderr += data.toString();
    if (stderr.includes('inspector listening')) readyResolve();
  });
  const exited = new Promise((resolve, reject) => {
    child.once('error', (error) => {
      stopped = true;
      readyReject(error);
      reject(error);
    });
    child.once('close', (code, exitSignal) => {
      stopped = true;
      readyReject(new Error(`Inspector exited before becoming ready: ${stderr}`));
      resolve({ code, signal: exitSignal });
    });
  });
  // Handle an early spawn failure while readiness is being awaited.
  exited.catch(() => {});
  try {
    const limit = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Inspector did not become ready: ${stderr}`)), 8000);
    });
    await Promise.race([ready, limit]);
    clearTimeout(timer);
    assert.ok(child.kill(signal), `Could not send ${signal}`);
    const exitLimit = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Inspector did not stop after ${signal}: ${stderr}`)), 8000);
    });
    const result = await Promise.race([exited, exitLimit]);
    assert.equal(result.code, 0, stderr);
    assert.equal(result.signal, null, stderr);
    assert.match(stderr, /shutting down/);
  } finally {
    clearTimeout(timer);
    if (!stopped) child.kill('SIGKILL');
    await exited.catch(() => {});
  }
}

test('Inspector stops cleanly on SIGINT', () => checkStop('SIGINT'));
test('Inspector stops cleanly on SIGTERM', () => checkStop('SIGTERM'));
