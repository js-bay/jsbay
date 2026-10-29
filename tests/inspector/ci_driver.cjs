// Runs the Inspector integration paths with a child process that is always cleaned up.
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { createWriteStream } = require('node:fs');
const { resolve } = require('node:path');

const [demo, idleHost] = process.argv.slice(2);
if (!demo || !idleHost) throw new Error('usage: node tests/inspector/ci_driver.cjs <inspector-demo> <idle-host>');

function run(command, args) {
  const child = spawn(command, args, { stdio: 'inherit' });
  return once(child, 'close').then(([code, signal]) => {
    assert.equal(signal, null, `${command} stopped by ${signal}`);
    assert.equal(code, 0, `${command} exited ${code}`);
  });
}

async function within(promise, ms, message) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), ms);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

async function stop(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'close');
  child.kill('SIGTERM');
  try {
    await within(exited, 8000, 'inspector demo did not stop');
  } catch (error) {
    child.kill('SIGKILL');
    await exited;
    throw error;
  }
}

async function runE2e() {
  const log = createWriteStream('inspector-demo.log');
  const child = spawn(resolve(demo), ['--port', '0'], { stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  let readyResolve;
  let readyReject;
  const ready = new Promise((resolveReady, rejectReady) => {
    readyResolve = resolveReady;
    readyReject = rejectReady;
  });
  child.once('error', readyReject);
  child.stderr.on('data', data => {
    const text = data.toString();
    stderr += text;
    log.write(text);
    const port = /inspector listening on ws:\/\/127\.0\.0\.1:(\d+)\//.exec(stderr)?.[1];
    if (port) readyResolve(port);
  });
  const exited = once(child, 'close').then(([code, signal]) => {
    throw new Error(`inspector demo exited before readiness: code=${code} signal=${signal}\n${stderr}`);
  });
  exited.catch(() => {});
  try {
    const port = await within(Promise.race([ready, exited]), 8000, `inspector demo did not become ready\n${stderr}`);
    await run(process.execPath, ['tests/inspector/e2e.cjs', '--port', String(port)]);
  } finally {
    await stop(child);
    await new Promise(resolveClose => log.end(resolveClose));
  }
}

async function main() {
  await runE2e();
  await run(process.execPath, ['tests/host_wake_consumer.mjs', resolve(idleHost)]);
  await run(process.execPath, ['tests/inspector/signal_stop_test.cjs', resolve(demo)]);
  console.log('PASS inspector CI driver');
}

main().catch(error => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
