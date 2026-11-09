import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import http from 'node:http';

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, values) => index % 2 === 0 ? [...pairs, [value.slice(2), values[index + 1]]] : pairs, []));
const executable = args.bin;
const output = args.out;
const samples = Number(args.samples ?? 5);
const timeoutMs = Number(args['timeout-ms'] ?? 10000);
if (!executable || !output || !Number.isInteger(samples) || samples < 1 || samples % 2 === 0 || !Number.isSafeInteger(timeoutMs) || timeoutMs < 10) process.exit(64);
const sha256 = /^[a-f0-9]{64}$/;
const commit = /^[a-f0-9]{40}$/;
function metadataError(message) {
  process.stderr.write(`Invalid debugger benchmark metadata: ${message}\n`);
  process.exit(64);
}
function requiredSha(name) {
  const value = process.env[name];
  if (!sha256.test(value ?? '')) metadataError(`${name} must be a SHA-256 hash`);
  return value;
}
function requiredText(name) {
  const value = process.env[name];
  if (!value) metadataError(`${name} is required`);
  return value;
}
function nullableCommit(name) {
  const value = process.env[name];
  if (value === 'null') return null;
  if (!commit.test(value ?? '')) metadataError(`${name} must be null or a commit hash`);
  return value;
}
function nullableBoolean(name) {
  const value = process.env[name];
  if (value === 'null') return null;
  if (value === 'true') return true;
  if (value === 'false') return false;
  metadataError(`${name} must be true, false, or null`);
}
const metadata = {
  benchmark_source_sha256: requiredSha('JSBAY_DEBUGGER_SOURCE_SHA'),
  engine_source_sha256: requiredSha('JSBAY_DEBUGGER_ENGINE_SOURCE_SHA'),
  driver_sha256: requiredSha('JSBAY_DEBUGGER_DRIVER_SHA'),
  toolchain: requiredText('JSBAY_DEBUGGER_TOOLCHAIN'),
  cc_version: requiredText('JSBAY_DEBUGGER_CC_VERSION'),
  source_commit: nullableCommit('JSBAY_DEBUGGER_SOURCE_COMMIT'),
  source_dirty: nullableBoolean('JSBAY_DEBUGGER_SOURCE_DIRTY'),
};
let activeProcess;

function median(values) {
  const ordered = [...values].sort((a, b) => a - b);
  return ordered[Math.floor(ordered.length / 2)];
}

function delay(ms) {
  return new Promise(resolve => { const timer = setTimeout(resolve, ms); timer.unref(); });
}

function start() {
  const child = spawn(executable, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  let text = '';
  let stderr = '';
  let childError;
  let closed;
  let resolveClosed;
  const closedPromise = new Promise(resolve => { resolveClosed = resolve; });
  const lines = [];
  const waiters = [];
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    text += chunk;
    for (;;) {
      const end = text.indexOf('\n');
      if (end < 0) break;
      const line = text.slice(0, end);
      text = text.slice(end + 1);
      lines.push(line);
      for (const waiter of waiters.splice(0)) waiter();
    }
  });
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.stdin.on('error', error => {
    if (error.code !== 'EPIPE') {
      childError = error;
      for (const waiter of waiters.splice(0)) waiter();
    }
  });
  child.once('error', error => {
    childError = error;
    if (!closed) {
      closed = { code: null, signal: 'spawn-error' };
      resolveClosed(closed);
    }
    for (const waiter of waiters.splice(0)) waiter();
  });
  child.once('close', (code, signal) => {
    closed = { code, signal };
    resolveClosed(closed);
    for (const waiter of waiters.splice(0)) waiter();
  });
  const next = async (pattern, timeout = 10000) => {
    const deadline = Date.now() + timeout;
    for (;;) {
      const index = lines.findIndex(line => pattern.test(line));
      if (index >= 0) return lines.splice(index, 1)[0];
      if (childError) throw childError;
      if (closed) throw new Error(`consumer exited before ${pattern}: ${closed.code ?? closed.signal}: ${stderr}`);
      if (Date.now() >= deadline) throw new Error(`timed out waiting for ${pattern}`);
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`timed out waiting for ${pattern}`)), deadline - Date.now());
        timer.unref();
        waiters.push(() => { clearTimeout(timer); resolve(); });
      });
    }
  };
  const write = text => {
    if (childError) throw childError;
    if (closed) throw new Error(`consumer already exited: ${closed.code ?? closed.signal}: ${stderr}`);
    if (!child.stdin.write(text)) child.stdin.once('drain', () => {});
  };
  return { child, next, write, stderr: () => stderr, closed: closedPromise, status: () => closed };
}

async function terminate(process, name) {
  let forced = false;
  if (!process.status()) {
    try { process.write('QUIT\n'); process.child.stdin.end(); } catch (_) {}
    const graceful = await Promise.race([process.closed, delay(timeoutMs)]);
    if (!graceful) {
      forced = true;
      process.child.kill('SIGTERM');
      const terminated = await Promise.race([process.closed, delay(timeoutMs)]);
      if (!terminated) process.child.kill('SIGKILL');
    }
  }
  const status = await process.closed;
  if (forced || status.code !== 0) throw new Error(`${name} consumer exited ${status.code ?? status.signal}${forced ? ' after timeout' : ''}: ${process.stderr()}`);
}

function withTimeout(promise, label) {
  return Promise.race([promise, new Promise((_, reject) => { const timer = setTimeout(() => reject(new Error(`${label} timed out`)), timeoutMs); timer.unref(); })]);
}

async function cdp(port) {
  const targets = await new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) {
        request.destroy();
        reject(error);
      } else resolve(value);
    };
    const request = http.get({ hostname: '127.0.0.1', port, path: '/json/list' }, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { body += chunk; });
      response.once('end', () => {
        try { finish(null, JSON.parse(body)); }
        catch (error) { finish(new Error(`invalid CDP target JSON: ${error.message}`)); }
      });
      response.once('error', error => finish(error));
      response.once('aborted', () => finish(new Error('CDP target discovery response was truncated')));
      response.once('close', () => {
        if (!response.complete) finish(new Error('CDP target discovery response was truncated'));
      });
    });
    const timer = setTimeout(() => finish(new Error('CDP target discovery timed out')), timeoutMs);
    timer.unref();
    request.once('error', error => finish(error));
  });
  if (!Array.isArray(targets) || targets.length !== 1) throw new Error('expected one inspector target');
  const socket = new WebSocket(targets[0].webSocketDebuggerUrl);
  try {
    await withTimeout(new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = () => reject(new Error('WebSocket connection failed')); }), 'WebSocket connection');
  } catch (error) { socket.close(); throw error; }
  let sequence = 0;
  const pending = new Map();
  const rejectPending = error => {
    for (const { reject, timer } of pending.values()) { clearTimeout(timer); reject(error); }
    pending.clear();
  };
  socket.onmessage = event => {
    let message;
    try { message = JSON.parse(event.data); } catch (error) { rejectPending(new Error(`invalid CDP JSON: ${error.message}`)); socket.close(); return; }
    const waiter = pending.get(message.id);
    if (waiter) { pending.delete(message.id); waiter.resolve(message); }
  };
  socket.onerror = () => rejectPending(new Error('WebSocket error'));
  socket.onclose = () => rejectPending(new Error('WebSocket closed'));
  const command = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP ${method} timed out`)); }, timeoutMs);
    timer.unref();
    pending.set(id, { resolve: message => { clearTimeout(timer); if (message.error) reject(new Error(`${method}: ${message.error.message}`)); else resolve(message.result); }, reject, timer });
    try { socket.send(JSON.stringify({ id, method, params })); } catch (error) { pending.delete(id); clearTimeout(timer); reject(error); }
  });
  return { command, close: () => { rejectPending(new Error('WebSocket closed')); socket.close(); } };
}

async function measureSample(name) {
  const process = start();
  activeProcess = process;
  let client;
  let result;
  let primaryError;
  try {
    const ready = await process.next(/^READY (\d+)$/, timeoutMs);
    const port = Number(ready.split(' ')[1]);
    let resolved_locations = 0;
    if (name !== 'cold') {
      client = await cdp(port);
      await client.command('Debugger.enable');
      if (name !== 'enabled') {
        const result = await client.command('Debugger.setBreakpointByUrl', {
          lineNumber: name === 'unmatched' ? 8 : 4,
          columnNumber: 0,
          url: 'debugger-benchmark.js',
          ...(name === 'conditional' ? { condition: 'globalThis.__debugConditionHits=(globalThis.__debugConditionHits||0)+1,false' } : {}),
        });
        resolved_locations = result.locations.length;
        if (resolved_locations === 0) throw new Error(`${name} breakpoint had no resolved locations`);
      }
    }
    process.write('MEASURE\n');
    const resultParts = (await process.next(/^RESULT /, timeoutMs)).split(' ');
    if (resultParts.length !== 5 || resultParts[1] !== '1' || Number(resultParts[3]) !== 4995000) throw new Error(`${name} workload validation failed`);
    const elapsed_ns = Number(resultParts[2]);
    const condition_hits = Number(resultParts[4]);
    if (!Number.isSafeInteger(elapsed_ns) || elapsed_ns <= 0 || !Number.isSafeInteger(condition_hits) || condition_hits < 0) throw new Error(`${name} emitted invalid measurement values`);
    if (name === 'conditional' && condition_hits !== 12000) throw new Error(`condition breakpoint executed ${condition_hits} times`);
    if (name !== 'conditional' && condition_hits !== 0) throw new Error(`${name} condition counter was ${condition_hits}`);
    result = { elapsed_ns, resolved_locations, condition_hits };
  } catch (error) {
    primaryError = error;
  } finally {
    let cleanupError;
    try {
      client?.close();
      await terminate(process, name);
    } catch (error) {
      cleanupError = error;
    } finally {
      if (activeProcess === process) activeProcess = undefined;
    }
    if (primaryError && cleanupError) throw new AggregateError([primaryError, cleanupError], 'Debugger sample failed and cleanup failed');
    if (primaryError) throw primaryError;
    if (cleanupError) throw cleanupError;
  }
  return result;
}

for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
  void (async () => {
    try { if (activeProcess) await terminate(activeProcess, signal); }
    finally { process.exit(128); }
  })();
});

const byName = new Map(['cold', 'enabled', 'unmatched', 'conditional'].map(name => [name, { name, samples_ns: [], resolved_locations: 0, condition_hits: 0, breakpoint_count: name === 'cold' || name === 'enabled' ? 0 : 1 }]));
for (let sample = 0; sample < samples; sample++) for (const name of byName.keys()) {
  const result = await measureSample(name);
  const state = byName.get(name);
  state.samples_ns.push(result.elapsed_ns);
  state.resolved_locations = result.resolved_locations;
  state.condition_hits += result.condition_hits;
}
const states = [...byName.values()];
for (const state of states) state.median_ns = median(state.samples_ns);
const cold = states[0].median_ns;
for (const state of states) state.relative_to_cold = state.median_ns / cold;
const binary = await readFile(executable);
await writeFile(output, JSON.stringify({ schema_version: 1, backend: 'quickjs_ng', optimize: 'ReleaseFast', workload_calls: 10, inner_loop_iterations: 1000, warmup_calls: 2, samples_per_state: samples, sample_order: ['cold', 'enabled', 'unmatched', 'conditional'], host: { platform: process.platform, arch: process.arch, node: process.version }, artifact: { sha256: createHash('sha256').update(binary).digest('hex'), bytes: binary.length }, states, ...metadata }, null, 2) + '\n');
