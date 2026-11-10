import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { createServer } from 'node:net';
import { chmodSync, cpSync, mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { apps, decodePlist, encodePlist, listingHasConnection, listingIsDetached, ownedCommand, protocolMessages, shouldTerminateDemo, SimulatorProcess, Wire, within } from './jsc_driver.mjs';

test('direct invocation rejects missing arguments instead of silently succeeding', () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('./jsc_driver.mjs', import.meta.url))], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /supply --socket or --simulator with --binary/);
});

test('symlink invocation rejects missing arguments instead of silently succeeding', () => {
  const directory = mkdtempSync(join(tmpdir(), 'jsbay-wir-entry-'));
  try {
    const entry = join(directory, 'driver.mjs');
    symlinkSync(fileURLToPath(new URL('./jsc_driver.mjs', import.meta.url)), entry);
    const result = spawnSync(process.execPath, [entry], { encoding: 'utf8' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /supply --socket or --simulator with --binary/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('application list', () => { const metadata={WIRApplicationNameKey:'jsc-safari-demo'}; assert.deepEqual(apps({__argument:{WIRApplicationDictionaryKey:{'PID:123':metadata}}}), [['PID:123',metadata]]); });
test('application connected after initial list', () => { const metadata={WIRApplicationIdentifierKey:'PID:123',WIRApplicationNameKey:'jsc-safari-demo'}; assert.deepEqual(apps({__argument:{WIRApplicationDictionaryKey:{}}}),[]); assert.deepEqual(apps({__selector:'_rpc_applicationConnected:',__argument:metadata}),[['PID:123',metadata]]); });
test('detached listing does not match an active connection', () => { const message={__argument:{WIRApplicationIdentifierKey:'PID:123',WIRListingKey:{1:{WIRTitleKey:'js-bay-demo',WIRTypeKey:'WIRTypeJavaScript'}}}}; assert.equal(listingHasConnection(message,'PID:123','js-bay-demo','connection-1'),false);assert.equal(listingIsDetached(message,'PID:123','js-bay-demo'),true); });
test('embedded protocol JSON is discovered', () => { assert.deepEqual(protocolMessages({outer:Buffer.from('{"id":1,"result":{}}')}),[{id:1,result:{}}]); });
test('binary plist preserves data values', () => { const input={__selector:'_rpc_forwardSocketData:',__argument:{WIRSocketDataKey:Buffer.from('{"id":1}'),WIRPageIdentifierKey:1}}; assert.deepEqual(decodePlist(encodePlist(input)),input); });
test('binary plist preserves empty values', () => {
  const input = { apps: {}, list: [], empty: '', space: ' ', data: Buffer.alloc(0) };
  assert.deepEqual(decodePlist(encodePlist(input)), input);
});
test('clean wrapper exit does not signal a reused process identifier', () => { assert.equal(shouldTerminateDemo(true, 'different'), false); assert.equal(shouldTerminateDemo(false, 'different'), false); assert.equal(shouldTerminateDemo(false, 'owned'), true); });
test('process identity retains an executable path containing spaces', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'jsbay inspector path '));
  const binary = join(directory, 'node with spaces');
  cpSync(process.execPath, binary);
  chmodSync(binary, 0o755);
  const child = spawn(binary, ['-e', 'setTimeout(() => {}, 30000)']);
  try {
    await new Promise(resolve => child.once('spawn', resolve));
    const host = new SimulatorProcess('test-simulator', binary, performance.now() + 100);
    host.demoPid = child.pid;
    assert.equal(await host.state(), 'owned');
    assert.equal(ownedCommand(`${binary} -e test`, host.binary), true);
  } finally {
    child.kill('SIGKILL');
    await new Promise(resolve => child.once('exit', resolve));
    rmSync(directory, { recursive: true, force: true });
  }
});

class FakeChild extends EventEmitter {
  constructor() {
    super();
    this.stdout = new PassThrough();
    this.stderr = new PassThrough();
    this.exitCode = null;
  }

  kill() {
    this.exitCode = 0;
    this.emit('exit', 0);
  }
}

function fakeHooks(child, state = 'owned') {
  return {
    command: async args => args.at(-1) === 'RWI_LISTEN_SOCKET' ? '/tmp/inspector.sock\n' : '',
    spawn: () => child,
    state: async () => state,
    signal: () => {
      child.exitCode = 0;
      child.emit('exit', 0);
    },
  };
}

test('simulator startup awaits the socket environment query', async () => {
  const child = new FakeChild();
  const deadline = performance.now() + 200;
  const promise = SimulatorProcess.create('test-simulator', process.execPath, deadline, fakeHooks(child));
  child.stdout.write(`STARTED ${process.pid}\nREADY ${process.pid}\n`);
  const host = await promise;
  assert.equal(host.socketPath, '/tmp/inspector.sock');
  host.output.push('CLEAN_EXIT\n');
  child.exitCode = 0;
  await host.close();
});

test('simulator stop rejects an early non-clean exit', async () => {
  const child = new FakeChild();
  child.exitCode = 1;
  const host = new SimulatorProcess('test-simulator', process.execPath, performance.now() + 100, fakeHooks(child, 'gone'));
  host.wrapper = child;
  host.demoPid = process.pid;
  await assert.rejects(host.stop(), /without CLEAN_EXIT/);
});

test('a non-clean exited wrapper never signals a reused process identifier', async () => {
  const child = new FakeChild();
  child.exitCode = 1;
  let signals = 0;
  const hooks = fakeHooks(child, 'owned');
  hooks.signal = () => { signals++; };
  const host = new SimulatorProcess('test-simulator', process.execPath, performance.now() + 100, hooks);
  host.wrapper = child;
  host.demoPid = process.pid;
  await assert.rejects(host.stop(), /without CLEAN_EXIT/);
  assert.equal(signals, 0);
});

test('startup timeout cleans an owned process after STARTED without READY', async () => {
  const child = new FakeChild();
  const hooks = fakeHooks(child);
  let signals = 0;
  hooks.signal = () => { signals++; child.exitCode = 0; child.emit('exit', 0); };
  const promise = SimulatorProcess.create('test-simulator', process.execPath, performance.now() + 25, hooks);
  child.stdout.write(`STARTED ${process.pid}\n`);
  await assert.rejects(promise, /READY timed out/);
  assert.equal(signals, 1);
});

test('startup wrapper errors reject and clean up', async () => {
  const child = new FakeChild();
  const promise = SimulatorProcess.create('test-simulator', process.execPath, performance.now() + 100, fakeHooks(child));
  await new Promise(resolve => setImmediate(resolve));
  child.emit('error', new Error('spawn failed'));
  await assert.rejects(promise, /spawn failed/);
  assert.equal(child.exitCode, 0);
});

test('wire receives fragmented plist frames and closes cleanly', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'jsbay-wir-test-'));
  const path = join(directory, 'wire.sock');
  const server = createServer(socket => {
    const body = encodePlist({ __selector: '_rpc_probe:', __argument: { value: 42 } });
    const frame = Buffer.alloc(4 + body.length);
    frame.writeUInt32BE(body.length);
    body.copy(frame, 4);
    socket.write(frame.subarray(0, 3));
    socket.write(frame.subarray(3));
  });
  await new Promise(resolve => server.listen(path, resolve));
  const wire = new Wire(path, performance.now() + 500);
  try {
    await wire.ready();
    assert.deepEqual(await wire.receive(), { __selector: '_rpc_probe:', __argument: { value: 42 } });
  } finally {
    wire.close();
    await new Promise(resolve => server.close(resolve));
    rmSync(directory, { recursive: true, force: true });
  }
});

test('wire reports malformed plist through receive', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'jsbay-wir-test-'));
  const path = join(directory, 'wire.sock');
  const server = createServer(socket => {
    const body = Buffer.from('not a plist');
    const frame = Buffer.alloc(4 + body.length);
    frame.writeUInt32BE(body.length);
    body.copy(frame, 4);
    socket.write(frame);
  });
  await new Promise(resolve => server.listen(path, resolve));
  const wire = new Wire(path, performance.now() + 500);
  try {
    await wire.ready();
    await assert.rejects(wire.receive(), /plist|unsupported/);
  } finally {
    wire.close();
    await new Promise(resolve => server.close(resolve));
    rmSync(directory, { recursive: true, force: true });
  }
});

test('resolved deadline waits clear their timers', async () => {
  assert.equal(await within(Promise.resolve(42), 1000, 'unit wait'), 42);
});
