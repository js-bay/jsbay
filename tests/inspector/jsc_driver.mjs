import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { Socket } from 'node:net';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const decoder = new TextDecoder();
const encoder = new TextEncoder();

export function argument(message) { return message?.__argument && typeof message.__argument === 'object' ? message.__argument : {}; }
export function apps(message) {
  const value = argument(message);
  if (value.WIRApplicationDictionaryKey && typeof value.WIRApplicationDictionaryKey === 'object') return Object.entries(value.WIRApplicationDictionaryKey).filter(([, metadata]) => metadata && typeof metadata === 'object');
  return typeof value.WIRApplicationIdentifierKey === 'string' && typeof value.WIRApplicationNameKey === 'string' ? [[value.WIRApplicationIdentifierKey, value]] : [];
}
export function page(message, name) {
  const listing = argument(message).WIRListingKey;
  if (!listing || typeof listing !== 'object') return null;
  for (const [identifier, metadata] of Object.entries(listing)) if (metadata?.WIRTitleKey === name && metadata.WIRTypeKey === 'WIRTypeJavaScript') return [Number(identifier), metadata];
  return null;
}
export function listingPage(message, application, target) { return argument(message).WIRApplicationIdentifierKey === application ? page(message, target) : null; }
export function listingHasConnection(message, application, target, connection) { return listingPage(message, application, target)?.[1].WIRConnectionIdentifierKey === connection; }
export function listingIsDetached(message, application, target) { const selected = listingPage(message, application, target); return !!selected && !selected[1].WIRConnectionIdentifierKey; }
export function protocolMessages(value) {
  const out = [], pending = [value];
  while (pending.length) {
    const value = pending.pop();
    if (Array.isArray(value)) pending.push(...value);
    else if (value && typeof value === 'object' && !Buffer.isBuffer(value)) { if (Number.isInteger(value.id) || typeof value.method === 'string') out.push(value); pending.push(...Object.values(value)); }
    else if (Buffer.isBuffer(value) || typeof value === 'string') { try { pending.push(JSON.parse(Buffer.isBuffer(value) ? decoder.decode(value) : value)); } catch {} }
  }
  return out;
}
export function shouldTerminateDemo(normalExit, processState) { return !normalExit && processState === 'owned'; }
export function ownedCommand(command, binary) { return command === binary || command.startsWith(`${binary} `); }

function deadlineError() { throw new Error('Web Inspector deadline expired'); }
function escapeXml(value) { return String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;'); }
function plistValue(value) {
  if (Buffer.isBuffer(value)) return `<data>${value.toString('base64')}</data>`;
  if (Array.isArray(value)) return `<array>${value.map(plistValue).join('')}</array>`;
  if (value && typeof value === 'object') return `<dict>${Object.entries(value).map(([key, item]) => `<key>${escapeXml(key)}</key>${plistValue(item)}`).join('')}</dict>`;
  if (typeof value === 'boolean') return value ? '<true/>' : '<false/>';
  if (Number.isInteger(value)) return `<integer>${value}</integer>`;
  return `<string>${escapeXml(value ?? '')}</string>`;
}
function tokenizeXml(xml) { return xml.match(/<[^>]+>|[^<]+/g) ?? []; }
function unescapeXml(value) { return value.replaceAll('&quot;', '"').replaceAll('&gt;', '>').replaceAll('&lt;', '<').replaceAll('&amp;', '&'); }
function parsePlist(xml) {
  const tokens = tokenizeXml(xml).filter(token => !/^<\?/.test(token) && !/^<!/.test(token)); let index = 0;
  const skipWhitespace = () => {
    while (typeof tokens[index] === 'string' && tokens[index].trim() === '') index++;
  };
  const value = () => {
    skipWhitespace();
    const open = tokens[index++];
    if (open === '<true/>' || open === '<true />') return true;
    if (open === '<false/>' || open === '<false />') return false;
    const empty = /^<(string|integer|data|array|dict)\s*\/>$/.exec(open)?.[1];
    if (empty === 'string') return '';
    if (empty === 'integer') return 0;
    if (empty === 'data') return Buffer.alloc(0);
    if (empty === 'array') return [];
    if (empty === 'dict') return {};
    const type = /^<(string|integer|data|array|dict)>$/.exec(open)?.[1]; if (!type) throw new Error(`unsupported plist token ${open}`);
    if (type === 'array') {
      const items = [];
      skipWhitespace();
      while (tokens[index] !== '</array>') {
        items.push(value());
        skipWhitespace();
      }
      index++;
      return items;
    }
    if (type === 'dict') {
      const result = {};
      skipWhitespace();
      while (tokens[index] !== '</dict>') {
        const keyOpen = tokens[index++];
        if (keyOpen !== '<key>') throw new Error('plist dictionary key expected');
        const key = unescapeXml(tokens[index++] ?? '');
        if (tokens[index++] !== '</key>') throw new Error('invalid plist key');
        result[key] = value();
        skipWhitespace();
      }
      index++;
      return result;
    }
    const closing = `</${type}>`;
    const text = tokens[index] === closing ? '' : tokens[index++] ?? '';
    if (tokens[index++] !== closing) throw new Error(`invalid plist ${type}`);
    return type === 'integer' ? Number(text) : type === 'data' ? Buffer.from(text.trim(), 'base64') : unescapeXml(text);
  };
  while (tokens[index] !== '<plist version="1.0">' && tokens[index] !== '<plist>') index++;
  index++; return value();
}
function plist(value, binary) {
  const dir = mkdtempSync(join(tmpdir(), 'jsbay-wir-')); const input=join(dir, 'input.plist'); const output=join(dir, 'output.plist');
  try { writeFileSync(input, `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0">${plistValue(value)}</plist>`); execFileSync('plutil', ['-convert', binary ? 'binary1' : 'xml1', '-o', output, input], { stdio: 'pipe' }); return Buffer.from(requireBuffer(output)); } finally { rmSync(dir, { recursive: true, force: true }); }
}
function requireBuffer(path) { return readFileSync(path); }
export function encodePlist(value) { return plist(value, true); }
export function decodePlist(bytes) { const dir=mkdtempSync(join(tmpdir(), 'jsbay-wir-')); const input=join(dir, 'input.plist'); const output=join(dir, 'output.plist'); try { writeFileSync(input, bytes); execFileSync('plutil', ['-convert', 'xml1', '-o', output, input], { stdio: 'pipe' }); return parsePlist(decoder.decode(requireBuffer(output))); } finally { rmSync(dir,{recursive:true,force:true}); } }

export class Wire {
  constructor(path, deadline) {
    this.deadline = deadline;
    this.socket = new Socket();
    this.pending = Buffer.alloc(0);
    this.frames = [];
    this.waiters = [];
    this.error = null;
    this.connected = new Promise((resolve, reject) => {
      this.socket.once('connect', resolve);
      this.socket.once('error', reject);
    });
    this.socket.on('data', data => this.#data(data));
    this.socket.on('error', error => { this.error = error; this.#wake(); });
    this.socket.on('close', () => {
      this.error ??= new Error('webinspectord closed the socket');
      this.#wake();
    });
    this.socket.connect(path);
  }

  remaining() {
    const left = this.deadline - performance.now();
    if (left <= 0) deadlineError();
    return left;
  }

  async ready() { await within(this.connected, this.remaining(), 'Web Inspector connect'); }

  #data(data) {
    this.pending = Buffer.concat([this.pending, data]);
    while (this.pending.length >= 4) {
      const length = this.pending.readUInt32BE();
      if (this.pending.length < 4 + length) break;
      try {
        this.frames.push(decodePlist(this.pending.subarray(4, 4 + length)));
      } catch (error) {
        this.error = error;
        this.socket.destroy();
        this.#wake();
        return;
      }
      this.pending = this.pending.subarray(4 + length);
    }
    this.#wake();
  }

  #wake() { for (const wake of this.waiters.splice(0)) wake(); }

  async receive() {
    while (!this.frames.length) {
      if (this.error) throw this.error;
      await within(new Promise(resolve => this.waiters.push(resolve)), this.remaining(), 'Web Inspector receive');
    }
    return this.frames.shift();
  }

  send(selector, payload) {
    this.remaining();
    const body = encodePlist({ __selector: selector, __argument: payload });
    const header = Buffer.alloc(4);
    header.writeUInt32BE(body.length);
    this.socket.write(Buffer.concat([header, body]));
  }

  close() { this.socket.destroy(); }
}
export function within(promise, milliseconds, label) {
  let timer;
  const timed = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds); });
  return Promise.race([promise, timed]).finally(() => clearTimeout(timer));
}

export class Client {
  constructor(wire, connection, application, pageId, sender) {
    Object.assign(this, { wire, connection, application, pageId, sender });
    this.nextId = 1;
    this.pending = [];
  }

  async receiveMatching(predicate, label) {
    for (let index = 0; index < this.pending.length; index++) {
      if (predicate(this.pending[index])) return this.pending.splice(index, 1)[0];
    }
    const selectors = [];
    for (;;) {
      const item = await this.wire.receive();
      selectors.push(String(item.__selector ?? ''));
      if (predicate(item)) return item;
      this.pending.push(item);
      if (performance.now() >= this.wire.deadline) throw new Error(`timeout waiting for ${label}; selectors=${selectors.slice(-8)}`);
    }
  }

  async request(method, params = {}, wait = true) {
    const id = this.nextId++;
    this.wire.send('_rpc_forwardSocketData:', {
      WIRSocketDataKey: Buffer.from(JSON.stringify({ id, method, params })),
      WIRConnectionIdentifierKey: this.connection,
      WIRSenderKey: this.sender,
      WIRApplicationIdentifierKey: this.application,
      WIRPageIdentifierKey: this.pageId,
    });
    if (!wait) return id;
    const item = await this.receiveMatching(message => protocolMessages(argument(message)).some(protocol => protocol.id === id), method);
    const answer = protocolMessages(argument(item)).filter(protocol => protocol.id === id).at(-1);
    if (answer.error) throw new Error(`${method}: ${JSON.stringify(answer.error)}`);
    return answer;
  }

  closeInspector() {
    this.wire.send('_rpc_forwardDidClose:', {
      WIRConnectionIdentifierKey: this.connection,
      WIRApplicationIdentifierKey: this.application,
      WIRPageIdentifierKey: this.pageId,
      WIRSenderKey: this.sender,
    });
  }
}
export class DiscoveryMonitor {
  constructor(client, targetName) {
    this.client = client;
    this.targetName = targetName;
  }
  static async connect(path, applicationName, targetName, deadline) {
    const wire = new Wire(path, deadline);
    try {
      await wire.ready();
      const connection = randomUUID();
      wire.send('_rpc_reportIdentifier:', { WIRConnectionIdentifierKey: connection });
      wire.send('_rpc_getConnectedApplications:', { WIRConnectionIdentifierKey: connection });
      const client = new Client(wire, connection, '', 0, randomUUID());
      const message = await client.receiveMatching(message => apps(message).some(([, metadata]) => metadata.WIRApplicationNameKey === applicationName), `monitor application ${applicationName}`);
      client.application = apps(message).find(([, metadata]) => metadata.WIRApplicationNameKey === applicationName)[0];
      const monitor = new DiscoveryMonitor(client, targetName);
      monitor.requestListing();
      await client.receiveMatching(message => monitor.hasTarget(message), 'initial monitor listing');
      return monitor;
    } catch (error) {
      wire.close();
      throw error;
    }
  }
  hasTarget(message) { return !!listingPage(message, this.client.application, this.targetName); }

  requestListing() {
    this.client.wire.send('_rpc_forwardGetListing:', {
      WIRConnectionIdentifierKey: this.client.connection,
      WIRApplicationIdentifierKey: this.client.application,
    });
  }

  async detach(inspectorClient) {
    this.client.pending = [];
    this.requestListing();
    await this.client.receiveMatching(message => listingHasConnection(message, this.client.application, this.targetName, inspectorClient.connection), 'monitor attached target connection');
    console.log('[ok] monitor sees active target connection');
    this.client.pending = [];
    inspectorClient.closeInspector();
    this.requestListing();
    await this.client.receiveMatching(message => listingIsDetached(message, this.client.application, this.targetName), 'monitor detached target connection');
    console.log('[ok] monitor sees detached target connection');
  }

  close() { this.client.wire.close(); }
}
export async function connect(path, applicationName, targetName, deadline) {
  const wire = new Wire(path, deadline);
  try {
    await wire.ready();
    const connection = randomUUID();
    const sender = randomUUID();
    wire.send('_rpc_reportIdentifier:', { WIRConnectionIdentifierKey: connection });
    wire.send('_rpc_getConnectedApplications:', { WIRConnectionIdentifierKey: connection });
    const bootstrap = new Client(wire, connection, '', 0, sender);
    const message = await bootstrap.receiveMatching(message => apps(message).some(([, metadata]) => metadata.WIRApplicationNameKey === applicationName), `target application ${applicationName}`);
    const application = apps(message).find(([, metadata]) => metadata.WIRApplicationNameKey === applicationName)[0];
    wire.send('_rpc_forwardGetListing:', { WIRConnectionIdentifierKey: connection, WIRApplicationIdentifierKey: application });
    const listing = await bootstrap.receiveMatching(message => listingPage(message, application, targetName), 'JavaScript context');
    const selected = listingPage(listing, application, targetName);
    if (!selected) throw new Error(`target ${targetName} was not discovered`);
    wire.send('_rpc_forwardSocketSetup:', { WIRApplicationIdentifierKey: application, WIRConnectionIdentifierKey: connection, WIRSenderKey: sender, WIRPageIdentifierKey: selected[0], WIRMessageDataTypeChunkSupportedKey: 0 });
    return new Client(wire, connection, application, selected[0], sender);
  } catch (error) {
    wire.close();
    throw error;
  }
}
function resultValue(answer){return answer?.result?.result?.value;}

export class SimulatorProcess {
  constructor(simulator, binary, deadline, hooks = {}) {
    this.simulator = simulator;
    this.binary = realpathSync(binary);
    this.deadline = deadline;
    this.output = [];
    this.demoPid = null;
    this.wrapper = null;
    this.runCommand = hooks.command ?? (async args => execFileSync('xcrun', ['simctl', 'spawn', ...args], {
      encoding: 'utf8',
      timeout: Math.max(100, Math.floor(this.deadline - performance.now())),
    }));
    this.spawn = hooks.spawn ?? spawn;
    this.readState = hooks.state ?? (async pid => {
      const result = spawnSync('ps', ['-p', String(pid), '-o', 'state=', '-o', 'command='], { encoding: 'utf8' });
      if (result.status !== 0 || !result.stdout.trim()) return 'gone';
      const fields = /^(\S+)\s+(.+)$/.exec(result.stdout.trim());
      if (!fields) return 'different';
      const [, state, command] = fields;
      if (state.startsWith('Z')) return 'gone';
      return ownedCommand(command, this.binary) ? 'owned' : 'different';
    });
    this.signal = hooks.signal ?? process.kill;
  }

  static async create(simulator, binary, deadline, hooks) {
    const host = new SimulatorProcess(simulator, binary, deadline, hooks);
    try {
      await host.start();
      return host;
    } catch (error) {
      await host.abortStartup();
      throw error;
    }
  }

  async state() { return this.demoPid === null ? 'gone' : this.readState(this.demoPid); }

  normal() { return this.wrapper?.exitCode === 0 && this.output.join('').includes('CLEAN_EXIT'); }

  wrapperExited() {
    return this.wrapper?.exitCode !== null && this.wrapper?.exitCode !== undefined || this.wrapper?.signalCode !== null && this.wrapper?.signalCode !== undefined;
  }

  watchOutput() {
    let buffered = '';
    const consume = data => {
      buffered += data;
      for (;;) {
        const end = buffered.indexOf('\n');
        if (end < 0) break;
        const line = buffered.slice(0, end + 1);
        buffered = buffered.slice(end + 1);
        this.output.push(line);
        const started = /^STARTED ([1-9][0-9]*)\n?$/.exec(line);
        const ready = /^READY ([1-9][0-9]*)\n?$/.exec(line);
        if (started) this.demoPid = Number(started[1]);
        if (ready && this.demoPid === Number(ready[1])) this.ready?.();
      }
    };
    this.wrapper.stdout.on('data', consume);
    this.wrapper.stderr.on('data', consume);
  }

  async start() {
    await this.runCommand([this.simulator, 'launchctl', 'kickstart', 'user/foreground/com.apple.webinspectord']);
    this.wrapper = this.spawn('xcrun', ['simctl', 'spawn', this.simulator, this.binary], { stdio: ['ignore', 'pipe', 'pipe'] });
    this.watchOutput();
    await within(new Promise((resolve, reject) => {
      this.ready = resolve;
      this.wrapper.once('error', reject);
      this.wrapper.once('exit', () => reject(new Error(`JSC simulator demo exited before READY: ${this.output.join('')}`)));
    }), this.deadline - performance.now(), 'JSC simulator demo READY');
    if ((await this.state()) !== 'owned') throw new Error('STARTED process identifier did not name the requested demo binary');
    const socketPath = (await this.runCommand([this.simulator, 'launchctl', 'getenv', 'RWI_LISTEN_SOCKET'])).trim();
    if (!socketPath) throw new Error('the selected simulator did not expose a Web Inspector socket');
    this.socketPath = socketPath;
  }

  async waitWrapper(milliseconds) {
    if (this.wrapperExited()) return true;
    return within(new Promise(resolve => this.wrapper.once('exit', () => resolve(true))), milliseconds, 'JSC simulator demo exit').catch(() => false);
  }

  async abortStartup() {
    if (!this.wrapper || this.wrapperExited()) return;
    if (this.demoPid !== null && await this.state() === 'owned') this.signal(this.demoPid, 'SIGTERM');
    else this.wrapper.kill('SIGTERM');
    if (!await this.waitWrapper(5000)) this.wrapper.kill('SIGKILL');
    await this.waitWrapper(5000);
  }

  async stop() {
    if (this.normal()) return;
    if (this.wrapperExited()) throw new Error(`JSC simulator demo exited without CLEAN_EXIT: ${this.output.join('')}`);
    const state = await this.state();
    if (state === 'gone') {
      await this.waitWrapper(1000);
      if (!this.normal()) throw new Error(`JSC simulator demo exited without CLEAN_EXIT: ${this.output.join('')}`);
      return;
    }
    if (!shouldTerminateDemo(this.normal(), state)) throw new Error('JSC simulator demo process identity changed before cleanup');
    this.signal(this.demoPid, 'SIGTERM');
    if (!await this.waitWrapper(15000)) {
      if (shouldTerminateDemo(this.normal(), await this.state())) this.signal(this.demoPid, 'SIGKILL');
      await this.waitWrapper(5000);
    }
    if (!this.normal()) throw new Error(`JSC simulator demo did not report CLEAN_EXIT: ${this.output.join('')}`);
  }

  async close() { await this.stop(); }
}

export async function exercise(socketPath, applicationName, targetName, deadline) {
  let client;
  let reconnect;
  let monitor;
  try {
    monitor = await DiscoveryMonitor.connect(socketPath, applicationName, targetName, deadline);
    client = await connect(socketPath, applicationName, targetName, deadline);
    console.log('[ok] discover');
    await client.request('Runtime.enable');
    console.log('[ok] Runtime.enable');
    await client.request('Debugger.enable');
    assert.equal(resultValue(await client.request('Runtime.evaluate', { expression: '40 + 2', returnByValue: true })), 42);
    const source = 'function __jsbayWirProbe(){\n const marker=40+2;\n const stepped=marker+1;\n return stepped;\n}\n//# sourceURL=jsbay-wir-probe.js';
    await client.request('Runtime.evaluate', { expression: source, returnByValue: true });
    await client.request('Debugger.setBreakpointsActive', { active: true });
    const breakpoint = await client.request('Debugger.setBreakpointByUrl', { lineNumber: 2, url: 'jsbay-wir-probe.js' });
    const breakpointId = breakpoint.result?.breakpointId;
    const scripts = new Set((breakpoint.result?.locations ?? []).filter(location => location.lineNumber === 2).map(location => location.scriptId));
    if (!breakpointId || !scripts.size) throw new Error('breakpoint was not resolved');
    console.log('[ok] breakpoint');
    await client.request('Runtime.evaluate', { expression: '__jsbayWirProbe()', returnByValue: true, doNotPauseOnExceptionsAndMuteConsole: false }, false);
    const paused = await client.receiveMatching(message => protocolMessages(argument(message)).some(item => item.method === 'Debugger.paused'), 'breakpoint pause');
    const event = protocolMessages(argument(paused)).filter(item => item.method === 'Debugger.paused').at(-1);
    const top = event.params?.callFrames?.[0];
    const location = top?.location;
    if (event.params?.reason !== 'Breakpoint' || event.params?.data?.breakpointId !== breakpointId || !top || location.lineNumber !== 2 || !scripts.has(location.scriptId)) throw new Error('pause did not identify the configured breakpoint');
    assert.equal(resultValue(await client.request('Debugger.evaluateOnCallFrame', { callFrameId: top.callFrameId, expression: 'marker', returnByValue: true })), 42);
    console.log('[ok] frame-evaluate');
    await client.request('Debugger.stepOver');
    const stepped = await client.receiveMatching(message => protocolMessages(argument(message)).some(item => item.method === 'Debugger.paused'), 'step pause');
    const stepEvent = protocolMessages(argument(stepped)).filter(item => item.method === 'Debugger.paused').at(-1);
    const steppedLocation = stepEvent.params?.callFrames?.[0]?.location;
    if (steppedLocation?.scriptId !== location.scriptId || steppedLocation?.lineNumber !== 3) throw new Error('step did not advance within the probe function');
    await client.request('Debugger.resume');
    await client.request('Debugger.removeBreakpoint', { breakpointId });
    assert.equal(resultValue(await client.request('Runtime.evaluate', { expression: '__jsbayWirProbe()', returnByValue: true })), 43);
    console.log('[ok] step-resume43');
    await monitor.detach(client);
    client.wire.close();
    client = null;
    reconnect = await connect(socketPath, applicationName, targetName, deadline);
    await reconnect.request('Runtime.enable');
    assert.equal(resultValue(await reconnect.request('Runtime.evaluate', { expression: '6 * 7', returnByValue: true })), 42);
    console.log('[ok] reconnect42');
    await monitor.detach(reconnect);
    reconnect.wire.close();
    reconnect = null;
    console.log('PASS JSC iOS Simulator Web Inspector debugger flow');
  } finally {
    const active = reconnect ?? client;
    if (active) {
      try { await active.request('Debugger.resume'); } catch {}
      try {
        if (monitor) await monitor.detach(active);
        else active.closeInspector();
      } finally {
        active.wire.close();
      }
    }
    monitor?.close();
  }
}
function options(argv) {
  const out = { targetName: 'js-bay-demo', timeout: 20 };
  for (let index = 0; index < argv.length; index += 2) {
    const raw = argv[index];
    const key = raw?.replace(/^--([a-z])/, (_, first) => first).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    if (!key || argv[index + 1] === undefined) throw new Error('invalid arguments');
    out[key] = argv[index + 1];
  }
  return out;
}

async function main() {
  const args = options(process.argv.slice(2));
  if (Boolean(args.simulator) !== Boolean(args.binary) || Boolean(args.socket) === Boolean(args.simulator)) throw new Error('supply --socket or --simulator with --binary');
  if (!args.applicationName) throw new Error('--application-name is required');
  const deadline = performance.now() + Number(args.timeout) * 1000;
  let processHost;
  let failure;
  try {
    if (args.simulator) {
      processHost = await SimulatorProcess.create(args.simulator, args.binary, deadline);
      await exercise(processHost.socketPath, args.applicationName, args.targetName, deadline);
    } else {
      await exercise(args.socket, args.applicationName, args.targetName, deadline);
    }
  } catch (error) {
    failure = error;
  }
  try {
    if (processHost) {
      await processHost.close();
      console.log('[ok] simulator CLEAN_EXIT');
    }
  } catch (error) {
    failure ??= error;
  }
  if (failure) throw failure;
}

if (process.argv[1] && pathToFileURL(realpathSync(process.argv[1])).href === import.meta.url) main().catch(error => {
  console.error(`FAIL ${error.message}`);
  process.exitCode = 1;
});
