'use strict';

const assert = require('node:assert/strict');
const { execFileSync, spawn } = require('node:child_process');
const { once } = require('node:events');
const { resolve } = require('node:path');

const adb = process.env.ADB || 'adb';
const [libraries, dex] = process.argv.slice(2);
if (!libraries || !dex) throw new Error('usage: android_driver.cjs <jniLibs> <classes.dex>');
const remote = `/data/local/tmp/jsbay-inspector-${process.pid}`;
const run = (...args) => execFileSync(adb, args, { encoding: 'utf8' }).trim();

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
  const abi = run('shell', 'getprop', 'ro.product.cpu.abi');
  assert.ok(['arm64-v8a', 'x86_64'].includes(abi), `unsupported ABI: ${abi}`);
  let child;
  let forwarded;
  let output = '';
  try {
    run('shell', 'mkdir', remote);
    run('push', resolve(dex), resolve(libraries, abi, 'libjsbay.so'), resolve(libraries, abi, 'libjsbay_android.so'), `${remote}/`);
    child = spawn(adb, ['shell', '-T', `CLASSPATH=${remote}/classes.dex LD_LIBRARY_PATH=${remote} app_process / com.example.jsbay.inspector.InspectorMainKt`], { stdio: ['pipe', 'pipe', 'pipe'] });
    let readyResolve;
    let readyReject;
    const ready = new Promise((resolveReady, rejectReady) => { readyResolve = resolveReady; readyReject = rejectReady; });
    child.once('error', readyReject);
    child.stdout.on('data', bytes => {
      output += bytes.toString();
      const match = /^READY (\d+)\r?$/m.exec(output);
      if (match) readyResolve(match[1]);
    });
    child.stderr.on('data', bytes => { output += bytes.toString(); });
    child.once('close', code => readyReject(new Error(`Android inspector exited ${code}: ${output}`)));
    const port = await within(ready, 15000, 'Android SDK inspector did not start');
    forwarded = run('forward', 'tcp:0', `tcp:${port}`);
    assert.match(forwarded, /^\d+$/);
    const test = spawn(process.execPath, [resolve(__dirname, 'e2e.cjs'), '--host', '127.0.0.1', '--port', forwarded, '--debugger-flow'], { stdio: 'inherit' });
    const [code, signal] = await once(test, 'close');
    assert.equal(signal, null);
    assert.equal(code, 0);
  } finally {
    if (child && child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'close');
      child.stdin.end('\n');
      try {
        const [code] = await within(exited, 10000, 'Android SDK inspector did not stop');
        assert.equal(code, 0, output);
        assert.match(output, /CLEAN_EXIT/);
      } catch (error) {
        child.kill('SIGTERM');
        throw error;
      } finally {
        if (forwarded) run('forward', '--remove', `tcp:${forwarded}`);
        run('shell', 'rm', '-rf', remote);
      }
    } else {
      if (forwarded) run('forward', '--remove', `tcp:${forwarded}`);
      run('shell', 'rm', '-rf', remote);
    }
  }
  console.log('PASS Android SDK CDP debugger');
}

main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
