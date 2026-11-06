import { spawn } from 'node:child_process';
import http from 'node:http';

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, values) => index % 2 === 0 ? [...pairs, [value.slice(2), values[index + 1]]] : pairs, []));
if (!args.bin) process.exit(64);

function within(promise, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out`)), 10000);
    timer.unref();
    promise.then(value => { clearTimeout(timer); resolve(value); }, error => { clearTimeout(timer); reject(error); });
  });
}

function start() {
  const child = spawn(args.bin, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  let buffered = '';
  let stderr = '';
  let closed;
  let resolveClosed;
  const closedPromise = new Promise(resolve => { resolveClosed = resolve; });
  const lines = [];
  const waiters = [];
  let markers = 0;
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    buffered += chunk;
    for (;;) {
      const end = buffered.indexOf('\n');
      if (end < 0) break;
      const line = buffered.slice(0, end);
      buffered = buffered.slice(end + 1);
      if (line === 'JSBAY_DEBUG_EVAL_HELPER_COMPILED') markers++;
      lines.push(line);
      for (const waiter of waiters.splice(0)) waiter();
    }
  });
  child.stdin.on('error', () => {});
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.once('error', error => { closed = { code: null, signal: error.message }; resolveClosed(closed); for (const waiter of waiters.splice(0)) waiter(); });
  child.once('close', (code, signal) => { closed = { code, signal }; resolveClosed(closed); for (const waiter of waiters.splice(0)) waiter(); });
  const next = async pattern => {
    const deadline = Date.now() + 10000;
    for (;;) {
      const index = lines.findIndex(line => pattern.test(line));
      if (index >= 0) return lines.splice(index, 1)[0];
      if (closed) throw new Error(`consumer exited ${closed.code ?? closed.signal}: ${stderr}`);
      if (Date.now() >= deadline) throw new Error(`timed out waiting for ${pattern}`);
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`timed out waiting for ${pattern}`)), deadline - Date.now());
        timer.unref();
        waiters.push(() => { clearTimeout(timer); resolve(); });
      });
    }
  };
  return { child, next, write: text => child.stdin.write(text), markers: () => markers, stderr: () => stderr, closed: () => closed, closedPromise };
}

async function cdp(port) {
  const targets = await within(new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error); else resolve(value);
    };
    const request = http.get({ hostname: '127.0.0.1', port, path: '/json/list' }, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { body += chunk; });
      response.once('end', () => {
        try { finish(null, JSON.parse(body)); } catch (error) { finish(error); }
      });
      response.once('error', finish);
      response.once('aborted', () => finish(new Error('CDP discovery response was truncated')));
      response.once('close', () => { if (!response.complete) finish(new Error('CDP discovery response was truncated')); });
    });
    const timer = setTimeout(() => { request.destroy(); finish(new Error('CDP discovery timed out')); }, 10000);
    timer.unref();
    request.once('error', finish);
  }), 'CDP discovery');
  if (!Array.isArray(targets) || targets.length !== 1) throw new Error('expected one CDP target');
  const socket = new WebSocket(targets[0].webSocketDebuggerUrl);
  await within(new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; }), 'WebSocket connection');
  let sequence = 0;
  const pending = new Map();
  const pauses = [];
  const pauseWaiters = [];
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Debugger.paused') {
      pauses.push(message.params);
      for (const waiter of pauseWaiters.splice(0)) waiter();
      return;
    }
    const waiter = pending.get(message.id);
    if (waiter) { pending.delete(message.id); waiter(message); }
  };
  const command = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 10000);
    timer.unref();
    pending.set(id, message => { clearTimeout(timer); if (message.error) reject(new Error(`${method}: ${message.error.message}`)); else resolve(message.result); });
    socket.send(JSON.stringify({ id, method, params }));
  });
  const paused = async () => {
    if (pauses.length) return pauses.shift();
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Debugger.paused timed out')), 10000);
      timer.unref();
      pauseWaiters.push(() => { clearTimeout(timer); resolve(); });
    });
    return pauses.shift();
  };
  return { command, paused, close: () => socket.close() };
}

function number(result, expected, label) {
  if (result.exceptionDetails || result.result?.value !== expected) throw new Error(`${label}: expected ${expected}, received ${JSON.stringify(result)}`);
}

async function evaluate_frame(client, local, closure, thisValue, realm) {
  const pause = await client.paused();
  const callFrameId = pause.callFrames?.[0]?.callFrameId;
  if (typeof callFrameId !== 'string') throw new Error('paused event omitted a call frame');
  number(await client.command('Debugger.evaluateOnCallFrame', { callFrameId, expression: 'local', returnByValue: true }), local, 'local scope');
  number(await client.command('Debugger.evaluateOnCallFrame', { callFrameId, expression: 'outerClosure', returnByValue: true }), closure, 'closure scope');
  number(await client.command('Debugger.evaluateOnCallFrame', { callFrameId, expression: 'this.value', returnByValue: true }), thisValue, 'this scope');
  number(await client.command('Debugger.evaluateOnCallFrame', { callFrameId, expression: 'globalThis.contractRealm', returnByValue: true }), realm, 'realm scope');
  const syntax = await client.command('Debugger.evaluateOnCallFrame', { callFrameId, expression: '(', returnByValue: true });
  if (!syntax.exceptionDetails) throw new Error('invalid debugger expression did not throw');
  number(await client.command('Debugger.evaluateOnCallFrame', { callFrameId, expression: 'local', returnByValue: true }), local, 'local scope after exception');
  await client.command('Debugger.resume');
}

async function run(process, client, expected, local, closure, thisValue) {
  process.write('RUN\n');
  await evaluate_frame(client, local, closure, thisValue, expected - local - closure - thisValue);
  const result = await process.next(/^RESULT /);
  if (Number(result.slice(7)) !== expected) throw new Error(`run result: expected ${expected}`);
}

async function enable_frame_breakpoint(client) {
  const breakpoint = await client.command('Debugger.setBreakpointByUrl', { url: 'debug-eval-contract.js', lineNumber: 8, columnNumber: 0 });
  if (!breakpoint.locations?.length) throw new Error('frame breakpoint did not resolve');
}

const childProcess = start();
let client;
try {
  let ready = await childProcess.next(/^READY /);
  client = await cdp(Number(ready.slice(6)));
  await client.command('Debugger.enable');
  await enable_frame_breakpoint(client);
  await run(childProcess, client, 211, 1, 10, 100);
  childProcess.write('GC\n');
  await childProcess.next(/^GC$/);
  await run(childProcess, client, 322, 2, 20, 200);
  if (childProcess.markers() !== 1) throw new Error(`helper compiled ${childProcess.markers()} times before reset`);
  client.close();
  childProcess.write('RESET\n');
  ready = await childProcess.next(/^READY /);
  client = await cdp(Number(ready.slice(6)));
  await client.command('Debugger.enable');
  await enable_frame_breakpoint(client);
  await run(childProcess, client, 311, 1, 10, 100);
  if (childProcess.markers() !== 2) throw new Error(`helper compiled ${childProcess.markers()} times across engines`);
  client.close();
  childProcess.write('QUIT\n');
  const closed = await within(childProcess.closedPromise, 'consumer exit');
  if (closed.code !== 0) throw new Error(`consumer did not exit cleanly: ${childProcess.stderr()}`);
  console.log(`PASS debugger eval cache: realm=100 GC=ok reset-realm=200 helper-compiles=${childProcess.markers()}`);
} catch (error) {
  client?.close();
  if (!childProcess.closed()) {
    childProcess.child.kill('SIGTERM');
    try {
      await within(childProcess.closedPromise, 'consumer cleanup');
    } catch (cleanupError) {
      childProcess.child.kill('SIGKILL');
      await childProcess.closedPromise;
      throw new AggregateError([error, cleanupError], 'cache contract and consumer cleanup failed');
    }
  }
  throw error;
}
