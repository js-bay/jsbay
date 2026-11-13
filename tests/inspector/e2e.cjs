#!/usr/bin/env node
// End-to-end test driver for a Chrome DevTools Protocol (CDP) inspector. Vanilla Node.js >= 18. Built-in modules only.

'use strict';

const net = require('net');
const http = require('http');
const crypto = require('crypto');
const process = require('process');

// -----------------------------
// Arg parsing
// -----------------------------
function parseArgs(argv) {
  const opts = { host: 'localhost', port: 9229, timeoutMs: 5000, debuggerFlow: false, typedConsole: false, lineBreakpoints: false, nativeDebugger: false, skipSteps: new Set() };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--host') opts.host = argv[++i];
    else if (a === '--port') opts.port = parseInt(argv[++i], 10);
    else if (a === '--timeout-ms') opts.timeoutMs = parseInt(argv[++i], 10);
    else if (a === '--debugger-flow') opts.debuggerFlow = true;
    else if (a === '--typed-console') opts.typedConsole = true;
    else if (a === '--line-breakpoints') opts.lineBreakpoints = true;
    else if (a === '--native-debugger') opts.nativeDebugger = true;
    else if (a === '--skip-step') opts.skipSteps.add(argv[++i]);
    else if (a === '--help' || a === '-h') {
      process.stdout.write(
        'Usage: node tests/inspector/e2e.cjs [--host localhost] [--port 9229] [--timeout-ms 5000] [--debugger-flow] [--typed-console] [--line-breakpoints] [--native-debugger] [--skip-step <id>]\n'
      );
      process.exit(0);
    } else {
      process.stderr.write(`unknown arg: ${a}\n`);
      process.exit(2);
    }
  }
  if (!Number.isFinite(opts.port) || opts.port <= 0 || opts.port > 65535) {
    process.stderr.write('invalid --port\n');
    process.exit(2);
  }
  if (!Number.isFinite(opts.timeoutMs) || opts.timeoutMs <= 0) {
    process.stderr.write('invalid --timeout-ms\n');
    process.exit(2);
  }
  return opts;
}

// -----------------------------
// Logging helpers
// -----------------------------
function ok(msg) {
  process.stdout.write(`[ok] ${msg}\n`);
}
function fail(msg) {
  process.stdout.write(`[fail] ${msg}\n`);
}
function describeErr(err) {
  if (!err) return 'unknown error';
  if (err.message && err.message.length > 0) {
    return err.code && !err.message.includes(err.code)
      ? `${err.code}: ${err.message}`
      : err.message;
  }
  if (err.code) return String(err.code);
  return String(err);
}

// -----------------------------
// Failure class with short code
// -----------------------------
class E2EError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// -----------------------------
// Promise timeout helper
// -----------------------------
function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      reject(new E2EError(`timeout-${label}`, `timed out after ${ms}ms waiting for ${label}`));
    }, ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

// -----------------------------
// HTTP GET helper
// -----------------------------
function httpGet(host, port, path, timeoutMs) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host, port, path, method: 'GET', timeout: timeoutMs },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          resolve({
            statusCode: res.statusCode,
            headers: res.headers,
            body: Buffer.concat(chunks).toString('utf8'),
          });
        });
        res.on('error', reject);
      }
    );
    req.on('error', reject);
    req.on('timeout', () => {
      req.destroy(new E2EError('http-timeout', `HTTP ${path} timed out after ${timeoutMs}ms`));
    });
    req.end();
  });
}

// -----------------------------
// WebSocket client (minimal RFC 6455)
// -----------------------------
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function computeAccept(keyB64) {
  return crypto
    .createHash('sha1')
    .update(keyB64 + WS_GUID)
    .digest('base64');
}

class WSClient {
  constructor(socket) {
    this.socket = socket;
    this.buf = Buffer.alloc(0);
    this.textQueue = [];
    this.closeQueue = [];
    this.textWaiters = [];
    this.closeWaiters = [];
    this.closed = false;
    this.error = null;

    socket.on('data', (chunk) => this._onData(chunk));
    socket.on('close', () => {
      this.closed = true;
      this._flushWaitersOnClose();
    });
    socket.on('error', (err) => {
      this.error = err;
      this.closed = true;
      this._flushWaitersOnClose();
    });
  }

  _flushWaitersOnClose() {
    // Deliver closes to any close waiters
    while (this.closeWaiters.length > 0) {
      const w = this.closeWaiters.shift();
      if (this.closeQueue.length > 0) {
        w.resolve(this.closeQueue.shift());
      } else {
        w.resolve({ code: null, reason: '', serverClosed: true });
      }
    }
    // Fail pending text waiters
    while (this.textWaiters.length > 0) {
      const w = this.textWaiters.shift();
      w.reject(
        this.error ||
          new E2EError('ws-closed', 'WebSocket closed while waiting for message')
      );
    }
  }

  _onData(chunk) {
    this.buf = Buffer.concat([this.buf, chunk]);
    // Parse as many frames as possible
    while (true) {
      const parsed = this._tryParseFrame();
      if (!parsed) break;
      if (parsed.opcode === 0x1) {
        // text
        const text = parsed.payload.toString('utf8');
        if (this.textWaiters.length > 0) {
          this.textWaiters.shift().resolve(text);
        } else {
          this.textQueue.push(text);
        }
      } else if (parsed.opcode === 0x8) {
        // close
        let code = null;
        let reason = '';
        if (parsed.payload.length >= 2) {
          code = parsed.payload.readUInt16BE(0);
          reason = parsed.payload.slice(2).toString('utf8');
        }
        const closeInfo = { code, reason, serverClosed: false };
        if (this.closeWaiters.length > 0) {
          this.closeWaiters.shift().resolve(closeInfo);
        } else {
          this.closeQueue.push(closeInfo);
        }
      } else if (parsed.opcode === 0x9) {
        // ping -> send pong
        this._sendFrame(0xa, parsed.payload);
      } else if (parsed.opcode === 0xa) {
        // pong, ignore
      } else {
        // Unsupported opcode (binary, continuations) — ignore for this script
      }
    }
  }

  _tryParseFrame() {
    if (this.buf.length < 2) return null;
    const b0 = this.buf[0];
    const b1 = this.buf[1];
    const fin = (b0 & 0x80) !== 0;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let payloadLen = b1 & 0x7f;
    let offset = 2;

    if (payloadLen === 126) {
      if (this.buf.length < offset + 2) return null;
      payloadLen = this.buf.readUInt16BE(offset);
      offset += 2;
    } else if (payloadLen === 127) {
      if (this.buf.length < offset + 8) return null;
      const hi = this.buf.readUInt32BE(offset);
      const lo = this.buf.readUInt32BE(offset + 4);
      // JS number limits — refuse >2^53 (not going to happen here)
      payloadLen = hi * 0x100000000 + lo;
      offset += 8;
    }

    let maskKey = null;
    if (masked) {
      if (this.buf.length < offset + 4) return null;
      maskKey = this.buf.slice(offset, offset + 4);
      offset += 4;
    }

    if (this.buf.length < offset + payloadLen) return null;

    let payload = this.buf.slice(offset, offset + payloadLen);
    if (masked && maskKey) {
      const unmasked = Buffer.allocUnsafe(payload.length);
      for (let i = 0; i < payload.length; i++) {
        unmasked[i] = payload[i] ^ maskKey[i & 3];
      }
      payload = unmasked;
    }

    this.buf = this.buf.slice(offset + payloadLen);
    return { fin, opcode, payload };
  }

  _sendFrame(opcode, payload) {
    const payloadLen = payload.length;
    let header;
    if (payloadLen < 126) {
      header = Buffer.alloc(2);
      header[0] = 0x80 | (opcode & 0x0f); // FIN + opcode
      header[1] = 0x80 | payloadLen; // MASK + len
    } else if (payloadLen < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | (opcode & 0x0f);
      header[1] = 0x80 | 126;
      header.writeUInt16BE(payloadLen, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | (opcode & 0x0f);
      header[1] = 0x80 | 127;
      // high 32 bits = 0 for realistic sizes
      header.writeUInt32BE(0, 2);
      header.writeUInt32BE(payloadLen, 6);
    }
    const maskKey = crypto.randomBytes(4);
    const masked = Buffer.allocUnsafe(payloadLen);
    for (let i = 0; i < payloadLen; i++) {
      masked[i] = payload[i] ^ maskKey[i & 3];
    }
    this.socket.write(Buffer.concat([header, maskKey, masked]));
  }

  sendText(str) {
    this._sendFrame(0x1, Buffer.from(str, 'utf8'));
  }

  sendClose(code = 1000, reason = '') {
    const reasonBuf = Buffer.from(reason, 'utf8');
    const payload = Buffer.alloc(2 + reasonBuf.length);
    payload.writeUInt16BE(code, 0);
    reasonBuf.copy(payload, 2);
    this._sendFrame(0x8, payload);
  }

  // Wait for next text frame
  nextText(timeoutMs) {
    const p = new Promise((resolve, reject) => {
      if (this.textQueue.length > 0) {
        resolve(this.textQueue.shift());
        return;
      }
      if (this.closed) {
        reject(
          this.error || new E2EError('ws-closed', 'WebSocket closed; no message available')
        );
        return;
      }
      this.textWaiters.push({ resolve, reject });
    });
    return withTimeout(p, timeoutMs, 'ws-text');
  }

  // Wait for close (server->client close frame or TCP close)
  nextClose(timeoutMs) {
    const p = new Promise((resolve) => {
      if (this.closeQueue.length > 0) {
        resolve(this.closeQueue.shift());
        return;
      }
      if (this.closed) {
        resolve({ code: null, reason: '', serverClosed: true });
        return;
      }
      this.closeWaiters.push({ resolve });
    });
    return withTimeout(p, timeoutMs, 'ws-close');
  }
}

// -----------------------------
// WebSocket handshake over raw socket
// -----------------------------
function wsHandshake(host, port, path, timeoutMs) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host, port });
    let settled = false;
    let buf = Buffer.alloc(0);

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(
        new E2EError(
          'ws-handshake-timeout',
          `WebSocket handshake timed out after ${timeoutMs}ms`
        )
      );
    }, timeoutMs);

    const key = crypto.randomBytes(16).toString('base64');
    const expectedAccept = computeAccept(key);

    const onError = (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      reject(err);
    };

    const onClose = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new E2EError('ws-handshake-closed', 'socket closed during handshake'));
    };

    const onData = (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      const headerEnd = buf.indexOf('\r\n\r\n');
      if (headerEnd === -1) return; // need more
      const headerBytes = buf.slice(0, headerEnd);
      const remaining = buf.slice(headerEnd + 4);

      socket.removeListener('data', onData);
      socket.removeListener('error', onError);
      socket.removeListener('close', onClose);

      const headerText = headerBytes.toString('utf8');
      const lines = headerText.split('\r\n');
      const statusLine = lines.shift() || '';
      const m = /^HTTP\/\d\.\d\s+(\d+)\s*(.*)$/.exec(statusLine);
      if (!m) {
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        reject(
          new E2EError(
            'ws-bad-status-line',
            `bad status line: ${JSON.stringify(statusLine)}`
          )
        );
        return;
      }
      const status = parseInt(m[1], 10);
      const headers = {};
      for (const line of lines) {
        const idx = line.indexOf(':');
        if (idx === -1) continue;
        const k = line.slice(0, idx).trim().toLowerCase();
        const v = line.slice(idx + 1).trim();
        headers[k] = v;
      }

      if (status !== 101) {
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        reject(
          new E2EError(
            'ws-bad-status',
            `expected 101, got ${status} (${statusLine.trim()})`
          )
        );
        return;
      }
      const accept = headers['sec-websocket-accept'];
      if (!accept) {
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        reject(new E2EError('ws-no-accept', 'missing Sec-WebSocket-Accept header'));
        return;
      }
      if (accept !== expectedAccept) {
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        reject(
          new E2EError(
            'ws-bad-accept',
            `Accept mismatch: got ${JSON.stringify(accept)}, expected ${JSON.stringify(
              expectedAccept
            )}`
          )
        );
        return;
      }

      settled = true;
      clearTimeout(timer);
      const client = new WSClient(socket);
      // Any bytes after the handshake belong to WS frames.
      if (remaining.length > 0) {
        client._onData(remaining);
      }
      resolve({ client, socket });
    };

    socket.once('connect', () => {
      const req =
        `GET ${path} HTTP/1.1\r\n` +
        `Host: ${host}:${port}\r\n` +
        `Upgrade: websocket\r\n` +
        `Connection: Upgrade\r\n` +
        `Sec-WebSocket-Key: ${key}\r\n` +
        `Sec-WebSocket-Version: 13\r\n` +
        `\r\n`;
      socket.write(req);
    });
    socket.on('data', onData);
    socket.on('error', onError);
    socket.on('close', onClose);
  });
}

// -----------------------------
// Correlated CDP send + matched-id reply waiter
// -----------------------------
function makeDispatcher(client) {
  const pendingReplies = new Map(); // id -> {resolve,reject}
  const bufferedReplies = new Map();
  const eventWaiters = []; // list of {predicate,resolve,reject}
  const bufferedEvents = [];
  let running = true;

  (async () => {
    while (running) {
      let raw;
      try {
        // No outer timeout here — step-level timeout wraps waits.
        raw = await new Promise((resolve, reject) => {
          if (client.textQueue.length > 0) {
            resolve(client.textQueue.shift());
            return;
          }
          if (client.closed) {
            reject(
              client.error ||
                new E2EError('ws-closed', 'WebSocket closed (dispatcher)')
            );
            return;
          }
          client.textWaiters.push({ resolve, reject });
        });
      } catch (err) {
        // Flush pending with error
        for (const p of pendingReplies.values()) p.reject(err);
        pendingReplies.clear();
        for (const w of eventWaiters) w.reject(err);
        eventWaiters.length = 0;
        return;
      }

      let msg;
      try {
        msg = JSON.parse(raw);
      } catch (e) {
        // Non-JSON text frame — ignore
        continue;
      }

      if (typeof msg.id === 'number') {
        if (pendingReplies.has(msg.id)) {
          const p = pendingReplies.get(msg.id);
          pendingReplies.delete(msg.id);
          p.resolve(msg);
        } else {
          bufferedReplies.set(msg.id, msg);
        }
      } else if (typeof msg.method === 'string') {
        // Event — deliver to first matching waiter or buffer
        let matched = false;
        for (let i = 0; i < eventWaiters.length; i++) {
          if (eventWaiters[i].predicate(msg)) {
            const w = eventWaiters.splice(i, 1)[0];
            w.resolve(msg);
            matched = true;
            break;
          }
        }
        if (!matched) bufferedEvents.push(msg);
      } else {
        // Unknown shape — drop
      }
    }
  })();

  function stop() {
    running = false;
  }

  function sendCommand(id, method, params) {
    const payload = JSON.stringify({ id, method, params: params || {} });
    client.sendText(payload);
  }

  function awaitReply(id, timeoutMs, label) {
    if (bufferedReplies.has(id)) {
      const reply = bufferedReplies.get(id);
      bufferedReplies.delete(id);
      return Promise.resolve(reply);
    }
    const p = new Promise((resolve, reject) => {
      pendingReplies.set(id, { resolve, reject });
    });
    return withTimeout(p, timeoutMs, label || `reply-${id}`);
  }

  function awaitEvent(predicate, timeoutMs, label) {
    // Check buffered first
    for (let i = 0; i < bufferedEvents.length; i++) {
      if (predicate(bufferedEvents[i])) {
        const msg = bufferedEvents.splice(i, 1)[0];
        return Promise.resolve(msg);
      }
    }
    const p = new Promise((resolve, reject) => {
      eventWaiters.push({ predicate, resolve, reject });
    });
    return withTimeout(p, timeoutMs, label || 'event');
  }

  return { sendCommand, awaitReply, awaitEvent, stop };
}

// -----------------------------
// Main
// -----------------------------
async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const { host, port, timeoutMs } = opts;

  let firstFailure = null;

  // Step 1: GET /json/version
  try {
    const t0 = Date.now();
    const res = await withTimeout(
      httpGet(host, port, '/json/version', timeoutMs),
      timeoutMs,
      'http-version'
    );
    const dt = Date.now() - t0;
    if (res.statusCode !== 200) {
      throw new E2EError(
        'version-status',
        `GET /json/version: expected 200, got ${res.statusCode}`
      );
    }
    const ctype = (res.headers['content-type'] || '').toLowerCase();
    if (!ctype.includes('json')) {
      throw new E2EError(
        'version-content-type',
        `GET /json/version: content-type missing "json", got ${JSON.stringify(
          res.headers['content-type']
        )}`
      );
    }
    let parsed;
    try {
      parsed = JSON.parse(res.body);
    } catch (e) {
      throw new E2EError('version-bad-json', `GET /json/version: invalid JSON: ${e.message}`);
    }
    if (typeof parsed.Browser !== 'string') {
      throw new E2EError(
        'version-browser',
        `GET /json/version: missing string "Browser"`
      );
    }
    if (typeof parsed['Protocol-Version'] !== 'string') {
      throw new E2EError(
        'version-proto',
        `GET /json/version: missing string "Protocol-Version"`
      );
    }
    ok(`GET /json/version (${dt}ms)`);
  } catch (err) {
    fail(`GET /json/version: ${describeErr(err)}`);
    firstFailure = firstFailure || err.code || 'version';
    process.stdout.write(`E2E FAIL: ${firstFailure}\n`);
    process.exit(1);
  }

  // Step 2: GET /json/list
  let targetId;
  let wsPath;
  try {
    const t0 = Date.now();
    const res = await withTimeout(
      httpGet(host, port, '/json/list', timeoutMs),
      timeoutMs,
      'http-list'
    );
    const dt = Date.now() - t0;
    if (res.statusCode !== 200) {
      throw new E2EError(
        'list-status',
        `GET /json/list: expected 200, got ${res.statusCode}`
      );
    }
    let arr;
    try {
      arr = JSON.parse(res.body);
    } catch (e) {
      throw new E2EError('list-bad-json', `GET /json/list: invalid JSON: ${e.message}`);
    }
    if (!Array.isArray(arr) || arr.length === 0) {
      throw new E2EError('list-empty', `GET /json/list: expected non-empty array`);
    }
    const t = arr[0];
    for (const field of ['id', 'title', 'type', 'url']) {
      if (typeof t[field] !== 'string') {
        throw new E2EError(
          `list-field-${field}`,
          `GET /json/list: first target missing string field "${field}"`
        );
      }
    }
    const wsUrl = t.webSocketDebuggerUrl;
    if (typeof wsUrl !== 'string' || !/^ws:\/\//.test(wsUrl)) {
      throw new E2EError(
        'list-wsurl',
        `GET /json/list: missing/invalid webSocketDebuggerUrl: ${JSON.stringify(wsUrl)}`
      );
    }
    // Parse ws://host:port/<id>
    const m = /^ws:\/\/([^\/]+)(\/.*)$/.exec(wsUrl);
    if (!m) {
      throw new E2EError(
        'list-wsurl-parse',
        `GET /json/list: unparseable webSocketDebuggerUrl: ${wsUrl}`
      );
    }
    wsPath = m[2];
    targetId = wsPath.replace(/^\//, '');
    if (!targetId) {
      throw new E2EError(
        'list-wsurl-id',
        `GET /json/list: could not extract target id from ${wsUrl}`
      );
    }
    ok(`GET /json/list (${dt}ms) target id=${targetId}`);
  } catch (err) {
    fail(`GET /json/list: ${describeErr(err)}`);
    firstFailure = firstFailure || err.code || 'list';
    process.stdout.write(`E2E FAIL: ${firstFailure}\n`);
    process.exit(1);
  }

  // Step 3: WebSocket upgrade
  let client;
  let socket;
  try {
    const t0 = Date.now();
    const r = await wsHandshake(host, port, wsPath, timeoutMs);
    client = r.client;
    socket = r.socket;
    const dt = Date.now() - t0;
    ok(`WebSocket upgrade accepted (${dt}ms)`);
  } catch (err) {
    fail(`WebSocket upgrade: ${describeErr(err)}`);
    firstFailure = firstFailure || err.code || 'ws-upgrade';
    process.stdout.write(`E2E FAIL: ${firstFailure}\n`);
    process.exit(1);
  }

  const disp = makeDispatcher(client);

  // Helper to run steps consistently
  async function runStep(label, fn, failCode) {
    if (failCode && opts.skipSteps.has(failCode)) {
      process.stdout.write(`[skip] ${label}\n`);
      return;
    }
    try {
      await fn();
    } catch (err) {
      fail(`${label}: ${describeErr(err)}`);
      const code = err.code || failCode || label;
      firstFailure = firstFailure || code;
      try {
        disp.stop();
        client.sendClose(1000, 'e2e-abort');
      } catch (_) {
        // ignore
      }
      try {
        socket.destroy();
      } catch (_) {
        // ignore
      }
      process.stdout.write(`E2E FAIL: ${firstFailure}\n`);
      process.exit(1);
    }
  }

  if (opts.debuggerFlow) {
    if (opts.typedConsole) {
      await runStep('native Runtime context and console values', async () => {
        const context = disp.awaitEvent(message => message.method === 'Runtime.executionContextCreated', timeoutMs, 'native-runtime-context');
        disp.sendCommand(20, 'Runtime.enable', {});
        const enabled = await disp.awaitReply(20, timeoutMs, 'native-runtime-enable');
        if (enabled.error || typeof (await context).params?.context?.id !== 'number') {
          throw new E2EError('native-runtime-enable', JSON.stringify(enabled));
        }
        const event = disp.awaitEvent(message => message.method === 'Runtime.consoleAPICalled' && message.params?.args?.[0]?.value === 42, timeoutMs, 'native-console-values');
        disp.sendCommand(21, 'Runtime.evaluate', { expression: 'console.log(42, {answer:42}, "console-Ω")' });
        const result = await disp.awaitReply(21, timeoutMs, 'native-console-evaluate');
        if (result.error) throw new E2EError('native-console-evaluate', JSON.stringify(result));
        const args = (await event).params.args;
        if (args[0].type !== 'number' || args[1]?.type !== 'object' || typeof args[1].objectId !== 'string' || args[2]?.value !== 'console-Ω') {
          throw new E2EError('native-console-values', JSON.stringify(args));
        }
        disp.sendCommand(22, 'Runtime.getProperties', { objectId: args[1].objectId, ownProperties: true });
        const properties = await disp.awaitReply(22, timeoutMs, 'native-console-properties');
        if (properties.error || !properties.result?.result?.some(property => property.name === 'answer' && property.value?.value === 42)) {
          throw new E2EError('native-console-properties', JSON.stringify(properties));
        }
        const emptyLog = disp.awaitEvent(message => message.method === 'Runtime.consoleAPICalled' && message.params?.type === 'log' && Array.isArray(message.params?.args) && message.params.args.length === 0, timeoutMs, 'native-empty-log');
        disp.sendCommand(23, 'Runtime.evaluate', { expression: 'console.log()' });
        const emptyLogReply = await disp.awaitReply(23, timeoutMs, 'native-empty-log-evaluate');
        if (emptyLogReply.error) throw new E2EError('native-empty-log-evaluate', JSON.stringify(emptyLogReply));
        await emptyLog;
        const emptyWarning = disp.awaitEvent(message => message.method === 'Runtime.consoleAPICalled' && message.params?.type === 'warning' && Array.isArray(message.params?.args) && message.params.args.length === 0, timeoutMs, 'native-empty-warning');
        disp.sendCommand(24, 'Runtime.evaluate', { expression: 'console.warn()' });
        const emptyWarningReply = await disp.awaitReply(24, timeoutMs, 'native-empty-warning-evaluate');
        if (emptyWarningReply.error) throw new E2EError('native-empty-warning-evaluate', JSON.stringify(emptyWarningReply));
        await emptyWarning;
        ok('native Runtime context and typed console object handles');
      }, 'native-runtime');
    }
    await runStep(
      'Debugger.enable',
      async () => {
        disp.sendCommand(1, 'Debugger.enable', {});
        const reply = await disp.awaitReply(1, timeoutMs, 'debugger-enable');
        if (reply.error || typeof (reply.result && reply.result.debuggerId) !== 'string') {
          throw new E2EError('debugger-enable', `Debugger.enable failed: ${JSON.stringify(reply)}`);
        }
        ok('Debugger.enable');
      },
      'debugger-enable'
    );

    if (!opts.nativeDebugger && !opts.lineBreakpoints) {
      await runStep(
        'exception pause preserves the application exception across debugger evaluation',
        async () => {
          const source = [
            'const __cdpExceptionSentinel = { kind: "application-sentinel" };',
            'try {',
            '  throw __cdpExceptionSentinel;',
            '} catch (caught) {',
            '  globalThis.__cdpExceptionSentinelPreserved = caught === __cdpExceptionSentinel;',
            '}',
            '//# sourceURL=cdp-pending-exception.js',
          ].join('\n');
          let paused = false;
          try {
            disp.sendCommand(170, 'Debugger.setPauseOnExceptions', { state: 'all' });
            const configured = await disp.awaitReply(170, timeoutMs, 'pending-exception-configure');
            if (configured.error) throw new E2EError('pending-exception-configure', JSON.stringify(configured));
            const pauseEvent = disp.awaitEvent(message => message.method === 'Debugger.paused' && message.params?.reason === 'exception', timeoutMs, 'pending-exception-pause');
            disp.sendCommand(171, 'Runtime.evaluate', { expression: source });
            const pause = await pauseEvent;
            paused = true;
            const frame = pause.params?.callFrames?.[0];
            if (!frame?.callFrameId) throw new E2EError('pending-exception-frame', JSON.stringify(pause));
            disp.sendCommand(172, 'Debugger.evaluateOnCallFrame', { callFrameId: frame.callFrameId, expression: '(() => { throw new Error("debug-evaluation-error"); })()' });
            const debugEvaluation = await disp.awaitReply(172, timeoutMs, 'pending-exception-debug-evaluation');
            if (debugEvaluation.error || !debugEvaluation.result?.exceptionDetails) {
              throw new E2EError('pending-exception-debug-evaluation', JSON.stringify(debugEvaluation));
            }
            const resumed = disp.awaitEvent(message => message.method === 'Debugger.resumed', timeoutMs, 'pending-exception-resume');
            disp.sendCommand(173, 'Debugger.resume', {});
            const resume = await disp.awaitReply(173, timeoutMs, 'pending-exception-resume-reply');
            if (resume.error) throw new E2EError('pending-exception-resume-reply', JSON.stringify(resume));
            await resumed;
            paused = false;
            const application = await disp.awaitReply(171, timeoutMs, 'pending-exception-application');
            if (application.error || application.result?.exceptionDetails) throw new E2EError('pending-exception-application', JSON.stringify(application));
            disp.sendCommand(174, 'Runtime.evaluate', { expression: 'globalThis.__cdpExceptionSentinelPreserved' });
            const preserved = await disp.awaitReply(174, timeoutMs, 'pending-exception-preserved');
            if (preserved.error || preserved.result?.result?.value !== true) throw new E2EError('pending-exception-preserved', JSON.stringify(preserved));
            ok('exception pause preserves application exception identity after debugger evaluation');
          } finally {
            if (paused) {
              try {
                disp.sendCommand(175, 'Debugger.resume', {});
                await disp.awaitReply(175, timeoutMs, 'pending-exception-cleanup-resume');
              } catch (_) {
              }
            }
            try {
              disp.sendCommand(176, 'Debugger.setPauseOnExceptions', { state: 'none' });
              await disp.awaitReply(176, timeoutMs, 'pending-exception-cleanup-policy');
            } catch (_) {
            }
            try {
              disp.sendCommand(177, 'Runtime.evaluate', { expression: 'delete globalThis.__cdpExceptionSentinelPreserved' });
              await disp.awaitReply(177, timeoutMs, 'pending-exception-cleanup-global');
            } catch (_) {
            }
          }
        },
        'pending-exception'
      );
    }

    await runStep(
      'breakpoint, paused frame evaluation, and stepping',
      async () => {
        const sourceUrl = 'cdp-debugger-e2e.js';
        const source = [
          'function __cdpDebuggerE2e(value) {',
          '  const local = value + 1;',
          '  const result = local + 1;',
          '  return result;',
          '}',
          '__cdpDebuggerE2e(40)',
          '//# sourceURL=cdp-debugger-e2e.js',
        ].join('\n');
        disp.sendCommand(2, 'Debugger.setBreakpointByUrl', {
          url: sourceUrl,
          lineNumber: 2,
        });
        const breakpoint = await disp.awaitReply(2, timeoutMs, 'set-breakpoint');
        if (breakpoint.error || !breakpoint.result || typeof breakpoint.result.breakpointId !== 'string') {
          throw new E2EError('set-breakpoint', `setBreakpointByUrl failed: ${JSON.stringify(breakpoint)}`);
        }

        const paused = disp.awaitEvent(
          (message) => message.method === 'Debugger.paused',
          timeoutMs,
          'paused'
        );
        disp.sendCommand(3, 'Runtime.evaluate', {
          expression: source,
        });
        const pause = await paused;
        const frame = pause.params && pause.params.callFrames && pause.params.callFrames[0];
        if (!frame || typeof frame.callFrameId !== 'string') {
          throw new E2EError('paused-frame', `Debugger.paused had no call frame: ${JSON.stringify(pause)}`);
        }
        if (!frame.location || frame.location.lineNumber !== 2 || frame.url !== sourceUrl) {
          throw new E2EError('paused-location', `expected ${sourceUrl}:3, got ${JSON.stringify(frame)}`);
        }
        disp.sendCommand(8, 'Debugger.getScriptSource', { scriptId: frame.location.scriptId });
        const script = await disp.awaitReply(8, timeoutMs, 'paused-script-source');
        if (script.error || script.result?.scriptSource !== source) {
          throw new E2EError('script-source', `paused script source mismatch: ${JSON.stringify(script)}`);
        }

        disp.sendCommand(4, 'Debugger.evaluateOnCallFrame', {
          callFrameId: frame.callFrameId,
          expression: 'local',
        });
        const evaluated = await disp.awaitReply(4, timeoutMs, 'evaluate-on-call-frame');
        const value = evaluated.result && evaluated.result.result && evaluated.result.result.value;
        if (value !== 41) {
          throw new E2EError('frame-evaluation', `expected local=41, got ${JSON.stringify(evaluated)}`);
        }

        const stepped = disp.awaitEvent(
          (message) => message.method === 'Debugger.paused',
          timeoutMs,
          'step-over-paused'
        );
        disp.sendCommand(5, 'Debugger.stepOver', {});
        const stepReply = await disp.awaitReply(5, timeoutMs, 'step-over-reply');
        if (stepReply.error) throw new E2EError('step-over', `Debugger.stepOver failed: ${JSON.stringify(stepReply)}`);
        const stepPause = await stepped;
        const nextFrame = stepPause.params?.callFrames?.[0];
        const nextLocation = nextFrame?.location;
        const advanced = nextLocation?.scriptId === frame.location.scriptId &&
          (nextLocation.lineNumber > frame.location.lineNumber ||
            (nextLocation.lineNumber === frame.location.lineNumber && nextLocation.columnNumber > frame.location.columnNumber));
        if (!advanced) {
          throw new E2EError('step-location', `step did not advance from ${JSON.stringify(frame.location)}: ${JSON.stringify(nextFrame)}`);
        }

        const resumed = disp.awaitEvent(
          (message) => message.method === 'Debugger.resumed',
          timeoutMs,
          'resumed'
        );
        disp.sendCommand(6, 'Debugger.resume', {});
        const resumeReply = await disp.awaitReply(6, timeoutMs, 'resume-reply');
        if (resumeReply.error) throw new E2EError('resume', `Debugger.resume failed: ${JSON.stringify(resumeReply)}`);
        await resumed;
        const result = await disp.awaitReply(3, timeoutMs, 'evaluate-after-resume');
        if (result.error || result.result?.result?.value !== 42) {
          throw new E2EError('resumed-result', `expected resumed result=42, got ${JSON.stringify(result)}`);
        }
        ok('breakpoint, paused frame evaluation, and stepping');
      },
      'debugger-execution'
    );

    await runStep(
      'source identity survives repeated URLs and nested evaluation',
      async () => {
        const url = 'cdp-source-identity.js';
        const sources = [1, 2].map(value => `globalThis.__cdpSourceIdentity = ${value};\n//# sourceURL=${url}`);
        const ids = [];
        for (let index = 0; index < sources.length; ++index) {
          const parsed = disp.awaitEvent(message => message.method === 'Debugger.scriptParsed' && message.params?.url === url, timeoutMs, 'source-identity-parsed');
          disp.sendCommand(10 + index, 'Runtime.evaluate', { expression: sources[index] });
          const reply = await disp.awaitReply(10 + index, timeoutMs, 'source-identity-evaluate');
          if (reply.error) throw new E2EError('source-identity-evaluate', JSON.stringify(reply));
          ids.push((await parsed).params.scriptId);
        }
        if (ids[0] === ids[1]) throw new E2EError('source-identity-id', 'recompiled scripts reused a source identity');
        for (let index = 0; index < ids.length; ++index) {
          // Escaped method spelling and whitespace exercise JSON decoding at the native bridge boundary.
          client.sendText(`{ "id": ${12 + index}, "method": "Debugger.\\u0067etScriptSource", "params": { "scriptId": ${JSON.stringify(ids[index])} } }`);
          const reply = await disp.awaitReply(12 + index, timeoutMs, 'source-identity-read');
          if (reply.error || reply.result?.scriptSource !== sources[index]) {
            throw new E2EError('source-identity-read', `source snapshot changed: ${JSON.stringify(reply)}`);
          }
        }

        const inner = 'globalThis.__cdpNestedSource = 42;\n//# sourceURL=cdp-nested-source.js';
        const nested = disp.awaitEvent(message => message.method === 'Debugger.scriptParsed' && message.params?.url === 'cdp-nested-source.js', timeoutMs, 'nested-script-parsed');
        disp.sendCommand(14, 'Runtime.evaluate', { expression: 'eval("globalThis.__cdpNestedSource = 42;\\n//# sourceURL=cdp-nested-source.js");\n//# sourceURL=cdp-source-parent.js' });
        const evaluated = await disp.awaitReply(14, timeoutMs, 'nested-source-evaluate');
        if (evaluated.error) throw new E2EError('nested-source-evaluate', JSON.stringify(evaluated));
        disp.sendCommand(15, 'Debugger.getScriptSource', { scriptId: (await nested).params.scriptId });
        const reply = await disp.awaitReply(15, timeoutMs, 'nested-source-read');
        if (!reply.error && reply.result?.scriptSource !== inner) {
          throw new E2EError('nested-source-read', `nested script was attributed to another source: ${JSON.stringify(reply)}`);
        }
        disp.sendCommand(16, 'Debugger.getScriptSource', { scriptId: 'unknown-script' });
        const unknown = await disp.awaitReply(16, timeoutMs, 'unknown-source');
        if (!unknown.error) throw new E2EError('unknown-source', `unknown script returned a source: ${JSON.stringify(unknown)}`);
        ok('source identities, repeated URLs, and nested evaluation');
      },
      'source-identity'
    );

    await runStep(
      'cross-call stepping and line-granular breakpoint resolution',
      async () => {
        const sourceUrl = 'cdp-cross-call-step.js';
        const source = [
          'function __cdpNested(value) {',
          '  return value + 1;',
          '}',
          'function __cdpCaller(value) {',
          '  const outer = value;',
          '  {',
          '    const block = outer;',
          '    const result = __cdpNested(block);',
          '    return result;',
          '  }',
          '}',
          '({ receiver: 99, caller: __cdpCaller }).caller(41)',
          '//# sourceURL=cdp-cross-call-step.js',
        ].join('\n');
        disp.sendCommand(31, 'Debugger.setBreakpointByUrl', {
          url: sourceUrl,
          lineNumber: 7,
          columnNumber: opts.lineBreakpoints ? 20 : 0,
        });
        const breakpoint = await disp.awaitReply(31, timeoutMs, 'cross-call-breakpoint');
        if (breakpoint.error || typeof breakpoint.result?.breakpointId !== 'string') {
          throw new E2EError('cross-call-breakpoint', JSON.stringify(breakpoint));
        }
        const paused = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'cross-call-pause');
        disp.sendCommand(32, 'Runtime.evaluate', { expression: source });
        const pause = await paused;
        const frame = pause.params?.callFrames?.[0];
        if (frame?.functionName !== '__cdpCaller' || frame?.location?.lineNumber !== 7) {
          throw new E2EError('cross-call-location', JSON.stringify(frame));
        }
        disp.sendCommand(33, 'Debugger.evaluateOnCallFrame', { callFrameId: frame.callFrameId, expression: 'outer' });
        const outer = await disp.awaitReply(33, timeoutMs, 'cross-call-local');
        if (outer.result?.result?.value !== 41) throw new E2EError('cross-call-local', JSON.stringify(outer));
        const localScope = frame.scopeChain?.find(scope => scope.type === 'local');
        if (!localScope?.object?.objectId) throw new E2EError('cross-call-local-scope', JSON.stringify(frame.scopeChain));
        disp.sendCommand(36, 'Runtime.getProperties', { objectId: localScope.object.objectId, ownProperties: true });
        const scopeProperties = await disp.awaitReply(36, timeoutMs, 'cross-call-local-properties');
        const scopeNames = new Set((scopeProperties.result?.result || []).map(property => property.name));
        if (!scopeNames.has('outer') || !scopeNames.has('block')) {
          throw new E2EError('cross-call-local-properties', JSON.stringify(scopeProperties));
        }
        disp.sendCommand(37, 'Debugger.evaluateOnCallFrame', { callFrameId: frame.callFrameId, expression: 'this.receiver' });
        const receiver = await disp.awaitReply(37, timeoutMs, 'cross-call-this');
        if (receiver.result?.result?.value !== 99) throw new E2EError('cross-call-this', JSON.stringify(receiver));
        if (!frame.this?.objectId) throw new E2EError('cross-call-this-object', JSON.stringify(frame));
        disp.sendCommand(38, 'Runtime.getProperties', { objectId: frame.this.objectId, ownProperties: true });
        const receiverProperties = await disp.awaitReply(38, timeoutMs, 'cross-call-this-properties');
        const receiverProperty = (receiverProperties.result?.result || []).find(property => property.name === 'receiver');
        if (receiverProperty?.value?.value !== 99) {
          throw new E2EError('cross-call-this-properties', JSON.stringify(receiverProperties));
        }
        const stepped = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'cross-call-step-over');
        disp.sendCommand(34, 'Debugger.stepOver', {});
        const stepReply = await disp.awaitReply(34, timeoutMs, 'cross-call-step-over-reply');
        if (stepReply.error) throw new E2EError('cross-call-step-over-reply', JSON.stringify(stepReply));
        const step = await stepped;
        const next = step.params?.callFrames?.[0];
        if (next?.functionName !== '__cdpCaller' || next?.location?.lineNumber !== 8) {
          throw new E2EError('cross-call-step-over-location', JSON.stringify(next));
        }
        const resumed = disp.awaitEvent(message => message.method === 'Debugger.resumed', timeoutMs, 'cross-call-resume');
        disp.sendCommand(35, 'Debugger.resume', {});
        const resumeReply = await disp.awaitReply(35, timeoutMs, 'cross-call-resume-reply');
        if (resumeReply.error) throw new E2EError('cross-call-resume-reply', JSON.stringify(resumeReply));
        await resumed;
        const result = await disp.awaitReply(32, timeoutMs, 'cross-call-result');
        if (result.error || result.result?.result?.value !== 42) throw new E2EError('cross-call-result', JSON.stringify(result));
        ok('cross-call stepping and line-granular breakpoint resolution');
      },
      'cross-call-step'
    );

    if (!opts.lineBreakpoints) {
      await runStep(
        opts.nativeDebugger ? 'same-line native breakpoints remain active across resume' : 'same-line breakpoint wins over line-granular stepOver',
        async () => {
          const sourceUrl = 'cdp-same-line-step.js';
          const source = [
            'function __cdpSameLineStep() {',
            '  globalThis.__cdpSameLineA = true; globalThis.__cdpSameLineB = true;',
            '}',
            '__cdpSameLineStep()',
            '//# sourceURL=cdp-same-line-step.js',
          ].join('\n');
          const initialColumn = source.split('\n')[1].indexOf('globalThis.__cdpSameLineA');
          const breakpointColumn = source.split('\n')[1].indexOf('globalThis.__cdpSameLineB');
          if (breakpointColumn < 0) throw new E2EError('same-line-source', 'missing second statement');
          disp.sendCommand(40, 'Debugger.setBreakpointByUrl', {
            url: sourceUrl,
            lineNumber: 1,
            columnNumber: initialColumn,
          });
          const breakpoint = await disp.awaitReply(40, timeoutMs, 'same-line-breakpoint');
          if (breakpoint.error || typeof breakpoint.result?.breakpointId !== 'string') {
            throw new E2EError('same-line-breakpoint', JSON.stringify(breakpoint));
          }
          const initial = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'same-line-initial-pause');
          disp.sendCommand(45, 'Runtime.evaluate', { expression: source });
          const initialPause = await initial;
          if (initialPause.params?.reason !== 'other' || initialPause.params?.callFrames?.[0]?.functionName !== '__cdpSameLineStep') {
            throw new E2EError('same-line-initial-pause', JSON.stringify(initialPause));
          }
          disp.sendCommand(41, 'Debugger.setBreakpointByUrl', { url: sourceUrl, lineNumber: 1, columnNumber: breakpointColumn });
          const secondBreakpoint = await disp.awaitReply(41, timeoutMs, 'same-line-second-breakpoint');
          if (secondBreakpoint.error) throw new E2EError('same-line-second-breakpoint', JSON.stringify(secondBreakpoint));
          disp.sendCommand(46, 'Debugger.removeBreakpoint', { breakpointId: breakpoint.result.breakpointId });
          const removed = await disp.awaitReply(46, timeoutMs, 'same-line-remove-initial');
          if (removed.error) throw new E2EError('same-line-remove-initial', JSON.stringify(removed));
          const stepped = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'same-line-breakpoint-pause');
          disp.sendCommand(42, opts.nativeDebugger ? 'Debugger.resume' : 'Debugger.stepOver', {});
          const stepReply = await disp.awaitReply(42, timeoutMs, 'same-line-step-over');
          if (stepReply.error) throw new E2EError('same-line-step-over', JSON.stringify(stepReply));
          const pause = await stepped;
          if (pause.params?.reason !== 'other' || pause.params?.callFrames?.[0]?.location?.columnNumber !== breakpointColumn) {
            throw new E2EError('same-line-breakpoint-pause', JSON.stringify(pause));
          }
          const frame = pause.params.callFrames[0];
          disp.sendCommand(43, 'Debugger.evaluateOnCallFrame', { callFrameId: frame.callFrameId, expression: 'globalThis.__cdpSameLineA === true && typeof globalThis.__cdpSameLineB === "undefined"' });
          const values = await disp.awaitReply(43, timeoutMs, 'same-line-side-effects');
          if (values.error || values.result?.result?.value !== true) {
            throw new E2EError('same-line-side-effects', JSON.stringify(values));
          }
          const resumed = disp.awaitEvent(message => message.method === 'Debugger.resumed', timeoutMs, 'same-line-resume');
          disp.sendCommand(44, 'Debugger.resume', {});
          const resume = await disp.awaitReply(44, timeoutMs, 'same-line-resume-reply');
          if (resume.error) throw new E2EError('same-line-resume-reply', JSON.stringify(resume));
          await resumed;
          const result = await disp.awaitReply(45, timeoutMs, 'same-line-result');
          if (result.error) throw new E2EError('same-line-result', JSON.stringify(result));
          ok(opts.nativeDebugger ? 'same-line native breakpoint pauses before its statement executes' : 'same-line breakpoint has priority over line-granular stepOver');
        },
        'same-line-step'
      );
    }

    await runStep(
      'stepOut visits every immediate recursive and ordinary caller',
      async () => {
        const recursiveUrl = 'cdp-recursive-step-out.js';
        const recursive = [
          'function __cdpRecursiveStepOut(n) {',
          '  if (n === 0) { debugger; return n; }',
          '  return __cdpRecursiveStepOut(n - 1);',
          '}',
          '__cdpRecursiveStepOut(2)',
          '//# sourceURL=cdp-recursive-step-out.js',
        ].join('\n');
        const initial = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'recursive-initial-pause');
        disp.sendCommand(50, 'Runtime.evaluate', { expression: recursive });
        let pause = await initial;
        for (const expectedN of [1, 2]) {
          const current = pause.params?.callFrames?.[0];
          if (current?.functionName !== '__cdpRecursiveStepOut') throw new E2EError('recursive-current-frame', JSON.stringify(current));
          const next = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, `recursive-step-out-${expectedN}`);
          disp.sendCommand(51 + expectedN, 'Debugger.stepOut', {});
          const reply = await disp.awaitReply(51 + expectedN, timeoutMs, `recursive-step-out-reply-${expectedN}`);
          if (reply.error) throw new E2EError('recursive-step-out-reply', JSON.stringify(reply));
          pause = await next;
          const frame = pause.params?.callFrames?.[0];
          if (frame?.functionName !== '__cdpRecursiveStepOut') throw new E2EError('recursive-step-out-frame', JSON.stringify(frame));
          disp.sendCommand(60 + expectedN, 'Debugger.evaluateOnCallFrame', { callFrameId: frame.callFrameId, expression: 'n' });
          const n = await disp.awaitReply(60 + expectedN, timeoutMs, `recursive-n-${expectedN}`);
          if (n.result?.result?.value !== expectedN) throw new E2EError('recursive-step-out-n', JSON.stringify(n));
        }
        const evaluation = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'recursive-step-out-eval');
        disp.sendCommand(54, 'Debugger.stepOut', {});
        const finalReply = await disp.awaitReply(54, timeoutMs, 'recursive-step-out-eval-reply');
        if (finalReply.error) throw new E2EError('recursive-step-out-eval-reply', JSON.stringify(finalReply));
        const finalPause = await evaluation;
        const finalFrame = finalPause.params?.callFrames?.[0];
        if (!finalFrame || !['', '<eval>', 'global'].includes(finalFrame.functionName) || finalFrame.url !== recursiveUrl || finalFrame.location?.lineNumber !== 4) {
          throw new E2EError('recursive-step-out-eval-frame', JSON.stringify(finalPause));
        }
        const resumed = disp.awaitEvent(message => message.method === 'Debugger.resumed', timeoutMs, 'recursive-resume');
        disp.sendCommand(55, 'Debugger.resume', {});
        const resume = await disp.awaitReply(55, timeoutMs, 'recursive-resume-reply');
        if (resume.error) throw new E2EError('recursive-resume-reply', JSON.stringify(resume));
        await resumed;
        const recursiveResult = await disp.awaitReply(50, timeoutMs, 'recursive-result');
        if (recursiveResult.error || recursiveResult.result?.result?.value !== 0) throw new E2EError('recursive-result', JSON.stringify(recursiveResult));

        const direct = [
          'function __cdpDirectLeaf() { debugger; return 1; }',
          'function __cdpDirectCaller() { return __cdpDirectLeaf(); }',
          '__cdpDirectCaller()',
          '//# sourceURL=cdp-direct-step-out.js',
        ].join('\n');
        const directInitial = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'direct-initial-pause');
        disp.sendCommand(70, 'Runtime.evaluate', { expression: direct });
        await directInitial;
        const directOut = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'direct-step-out');
        disp.sendCommand(71, 'Debugger.stepOut', {});
        const directReply = await disp.awaitReply(71, timeoutMs, 'direct-step-out-reply');
        if (directReply.error) throw new E2EError('direct-step-out-reply', JSON.stringify(directReply));
        const directPause = await directOut;
        if (directPause.params?.callFrames?.[0]?.functionName !== '__cdpDirectCaller') throw new E2EError('direct-step-out-frame', JSON.stringify(directPause));
        const directResumed = disp.awaitEvent(message => message.method === 'Debugger.resumed', timeoutMs, 'direct-resume');
        disp.sendCommand(72, 'Debugger.resume', {});
        const directResume = await disp.awaitReply(72, timeoutMs, 'direct-resume-reply');
        if (directResume.error) throw new E2EError('direct-resume-reply', JSON.stringify(directResume));
        await directResumed;
        const directResult = await disp.awaitReply(70, timeoutMs, 'direct-result');
        if (directResult.error || directResult.result?.result?.value !== 1) throw new E2EError('direct-result', JSON.stringify(directResult));
        ok('stepOut visits immediate recursive and ordinary callers');
      },
      'step-out-callers'
    );

    if (opts.nativeDebugger) {
      await runStep(
        'a user return breakpoint survives recursive stepOut restoration',
        async () => {
          const sourceUrl = 'cdp-hermes-return-breakpoint.js';
          const source = [
            'globalThis.__cdpArmRecursiveDebugger = true;',
            'function __cdpRecursiveReturnBreakpoint(n) {',
            '  if (n === 0) { if (globalThis.__cdpArmRecursiveDebugger) debugger; return n; }',
            '  return __cdpRecursiveReturnBreakpoint(n - 1);',
            '}',
            '__cdpRecursiveReturnBreakpoint(2)',
            '//# sourceURL=cdp-hermes-return-breakpoint.js',
          ].join('\n');
          const initial = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'return-breakpoint-initial');
          disp.sendCommand(140, 'Runtime.evaluate', { expression: source });
          const initialPause = await initial;
          if (initialPause.params?.callFrames?.[0]?.functionName !== '__cdpRecursiveReturnBreakpoint') {
            throw new E2EError('return-breakpoint-initial-frame', JSON.stringify(initialPause));
          }
          disp.sendCommand(141, 'Debugger.setBreakpointByUrl', { url: sourceUrl, lineNumber: 3 });
          const breakpoint = await disp.awaitReply(141, timeoutMs, 'return-breakpoint-set');
          if (breakpoint.error || typeof breakpoint.result?.breakpointId !== 'string') {
            throw new E2EError('return-breakpoint-set', JSON.stringify(breakpoint));
          }
          disp.sendCommand(142, 'Debugger.evaluateOnCallFrame', { callFrameId: initialPause.params.callFrames[0].callFrameId, expression: 'globalThis.__cdpArmRecursiveDebugger = false' });
          const disarm = await disp.awaitReply(142, timeoutMs, 'return-breakpoint-disarm');
          if (disarm.error) throw new E2EError('return-breakpoint-disarm', JSON.stringify(disarm));
          let pause = initialPause;
          for (const expectedN of [1, 2]) {
            const next = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, `return-breakpoint-step-out-${expectedN}`);
            disp.sendCommand(143 + expectedN, 'Debugger.stepOut', {});
            const reply = await disp.awaitReply(143 + expectedN, timeoutMs, `return-breakpoint-step-out-reply-${expectedN}`);
            if (reply.error) throw new E2EError('return-breakpoint-step-out-reply', JSON.stringify(reply));
            pause = await next;
            const frame = pause.params?.callFrames?.[0];
            if (frame?.functionName !== '__cdpRecursiveReturnBreakpoint' || frame?.url !== sourceUrl) {
              throw new E2EError('return-breakpoint-step-out-frame', JSON.stringify(pause));
            }
            disp.sendCommand(150 + expectedN, 'Debugger.evaluateOnCallFrame', { callFrameId: frame.callFrameId, expression: 'n' });
            const n = await disp.awaitReply(150 + expectedN, timeoutMs, `return-breakpoint-n-${expectedN}`);
            if (n.result?.result?.value !== expectedN) throw new E2EError('return-breakpoint-step-out-n', JSON.stringify(n));
          }
          const resumed = disp.awaitEvent(message => message.method === 'Debugger.resumed', timeoutMs, 'return-breakpoint-first-resume');
          disp.sendCommand(160, 'Debugger.resume', {});
          const resume = await disp.awaitReply(160, timeoutMs, 'return-breakpoint-first-resume-reply');
          if (resume.error) throw new E2EError('return-breakpoint-first-resume-reply', JSON.stringify(resume));
          await resumed;
          const firstResult = await disp.awaitReply(140, timeoutMs, 'return-breakpoint-first-result');
          if (firstResult.error || firstResult.result?.result?.value !== 0) throw new E2EError('return-breakpoint-first-result', JSON.stringify(firstResult));

          const again = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'return-breakpoint-user-hit');
          disp.sendCommand(161, 'Runtime.evaluate', { expression: '__cdpRecursiveReturnBreakpoint(1)' });
          const userPause = await again;
          const userFrame = userPause.params?.callFrames?.[0];
          if (userPause.params?.reason !== 'other' || userFrame?.functionName !== '__cdpRecursiveReturnBreakpoint' || userFrame?.url !== sourceUrl) {
            throw new E2EError('return-breakpoint-user-frame', JSON.stringify(userPause));
          }
          disp.sendCommand(162, 'Debugger.evaluateOnCallFrame', { callFrameId: userFrame.callFrameId, expression: 'n' });
          const userN = await disp.awaitReply(162, timeoutMs, 'return-breakpoint-user-n');
          if (userN.result?.result?.value !== 1) throw new E2EError('return-breakpoint-user-n', JSON.stringify(userN));
          const userResumed = disp.awaitEvent(message => message.method === 'Debugger.resumed', timeoutMs, 'return-breakpoint-user-resume');
          disp.sendCommand(163, 'Debugger.resume', {});
          const userResume = await disp.awaitReply(163, timeoutMs, 'return-breakpoint-user-resume-reply');
          if (userResume.error) throw new E2EError('return-breakpoint-user-resume-reply', JSON.stringify(userResume));
          await userResumed;
          const secondResult = await disp.awaitReply(161, timeoutMs, 'return-breakpoint-second-result');
          if (secondResult.error || secondResult.result?.result?.value !== 0) throw new E2EError('return-breakpoint-second-result', JSON.stringify(secondResult));
          disp.sendCommand(164, 'Debugger.removeBreakpoint', { breakpointId: breakpoint.result.breakpointId });
          const removed = await disp.awaitReply(164, timeoutMs, 'return-breakpoint-remove');
          if (removed.error) throw new E2EError('return-breakpoint-remove', JSON.stringify(removed));
          ok('a user return breakpoint remains active after recursive stepOut');
        },
        'hermes-return-breakpoint'
      );
    }

    await runStep(
      'stepOut from a native callback resumes the native call before its caller',
      async () => {
        const source = [
          'globalThis.__cdpForEachCount = 0;',
          'function __cdpForEachCallback(value) { if (globalThis.__cdpForEachCount === 0) debugger; globalThis.__cdpForEachCount += value; }',
          'function __cdpForEachParent() { [1, 1].forEach(__cdpForEachCallback);',
          '  const afterNativeCall = globalThis.__cdpForEachCount;',
          '  return afterNativeCall;',
          '}',
          '__cdpForEachParent()',
          '//# sourceURL=cdp-native-callback-step-out.js',
        ].join('\n');
        const initial = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'native-callback-initial-pause');
        disp.sendCommand(90, 'Runtime.evaluate', { expression: source });
        const firstPause = await initial;
        if (firstPause.params?.callFrames?.[0]?.functionName !== '__cdpForEachCallback') throw new E2EError('native-callback-initial-frame', JSON.stringify(firstPause));
        const stepped = disp.awaitEvent(message => message.method === 'Debugger.paused', timeoutMs, 'native-callback-step-out');
        disp.sendCommand(91, 'Debugger.stepOut', {});
        const stepReply = await disp.awaitReply(91, timeoutMs, 'native-callback-step-out-reply');
        if (stepReply.error) throw new E2EError('native-callback-step-out-reply', JSON.stringify(stepReply));
        const pause = await stepped;
        const frame = pause.params?.callFrames?.[0];
        if (frame?.functionName !== '__cdpForEachParent' || frame?.url !== 'cdp-native-callback-step-out.js' || ![2, 3].includes(frame?.location?.lineNumber)) throw new E2EError('native-callback-step-out-frame', JSON.stringify(pause));
        disp.sendCommand(92, 'Debugger.evaluateOnCallFrame', { callFrameId: frame.callFrameId, expression: 'globalThis.__cdpForEachCount' });
        const count = await disp.awaitReply(92, timeoutMs, 'native-callback-side-effects');
        if (count.result?.result?.value !== 2) throw new E2EError('native-callback-side-effects', JSON.stringify(count));
        const resumed = disp.awaitEvent(message => message.method === 'Debugger.resumed', timeoutMs, 'native-callback-resume');
        disp.sendCommand(93, 'Debugger.resume', {});
        const resumeReply = await disp.awaitReply(93, timeoutMs, 'native-callback-resume-reply');
        if (resumeReply.error) throw new E2EError('native-callback-resume-reply', JSON.stringify(resumeReply));
        await resumed;
        const result = await disp.awaitReply(90, timeoutMs, 'native-callback-result');
        if (result.error || result.result?.result?.value !== 2) throw new E2EError('native-callback-result', JSON.stringify(result));
        ok('stepOut leaves a native callback at the first shallower JS location');
      },
      'native-callback-step-out'
    );

    if (opts.typedConsole) {
      await runStep('native Runtime re-enable and source limit', async () => {
        disp.sendCommand(30, 'Runtime.disable', {});
        const disabled = await disp.awaitReply(30, timeoutMs, 'native-runtime-disable');
        if (disabled.error) throw new E2EError('native-runtime-disable', JSON.stringify(disabled));
        const context = disp.awaitEvent(message => message.method === 'Runtime.executionContextCreated', timeoutMs, 'native-runtime-reenabled');
        disp.sendCommand(31, 'Runtime.enable', {});
        const enabled = await disp.awaitReply(31, timeoutMs, 'native-runtime-reenable');
        if (enabled.error) throw new E2EError('native-runtime-reenable', JSON.stringify(enabled));
        await context;

        const parsed = disp.awaitEvent(message => message.method === 'Debugger.scriptParsed' && message.params?.url === 'cdp-large-native-source.js', timeoutMs, 'large-native-script');
        disp.sendCommand(32, 'Runtime.evaluate', { expression: `globalThis.__cdpLargeSource = 42;\n/*${'x'.repeat(96 * 1024)}*/\n//# sourceURL=cdp-large-native-source.js` });
        const evaluated = await disp.awaitReply(32, timeoutMs, 'large-native-evaluate');
        if (evaluated.error || evaluated.result?.result?.value !== 42) {
          throw new E2EError('large-native-evaluate', JSON.stringify(evaluated));
        }
        disp.sendCommand(33, 'Debugger.getScriptSource', { scriptId: (await parsed).params.scriptId });
        const source = await disp.awaitReply(33, timeoutMs, 'large-native-source-limit');
        if (!source.error) throw new E2EError('large-native-source-limit', 'Oversized source did not return an explicit error');
        disp.sendCommand(34, 'Runtime.evaluate', { expression: '6 * 7' });
        const afterLimit = await disp.awaitReply(34, timeoutMs, 'native-after-source-limit');
        if (afterLimit.error || afterLimit.result?.result?.value !== 42) {
          throw new E2EError('native-after-source-limit', JSON.stringify(afterLimit));
        }
        ok('native Runtime re-enable and explicit source limit error');
      }, 'native-runtime-limits');
    }

    await runStep(
      'reconnect after debugger session close',
      async () => {
        client.sendClose(1000, 'debugger-flow-reconnect');
        await client.nextClose(Math.min(1000, timeoutMs));
        disp.stop();
        socket.destroy();

        const next = await wsHandshake(host, port, wsPath, timeoutMs);
        const nextDisp = makeDispatcher(next.client);
        nextDisp.sendCommand(7, 'Runtime.evaluate', { expression: '6 * 7' });
        const reply = await nextDisp.awaitReply(7, timeoutMs, 'reconnect-evaluate');
        const value = reply.result && reply.result.result && reply.result.result.value;
        nextDisp.stop();
        next.client.sendClose(1000, 'debugger-flow-done');
        next.socket.destroy();
        if (reply.error || value !== 42) {
          throw new E2EError('reconnect-evaluate', `reconnect evaluation failed: ${JSON.stringify(reply)}`);
        }
        ok('reconnect after debugger session close');
      },
      'debugger-reconnect'
    );

    process.stdout.write('E2E PASS\n');
    return;
  }

  // Step 4: Runtime.enable
  let execContextId = null;
  await runStep(
    'Runtime.enable',
    async () => {
      disp.sendCommand(1, 'Runtime.enable', {});
      const [reply, event] = await Promise.all([
        disp.awaitReply(1, timeoutMs, 'runtime-enable-reply'),
        disp.awaitEvent(
          (m) => m.method === 'Runtime.executionContextCreated',
          timeoutMs,
          'execution-context-created'
        ),
      ]);
      if (reply.error) {
        throw new E2EError(
          'runtime-enable-error',
          `Runtime.enable returned error: ${JSON.stringify(reply.error)}`
        );
      }
      if (!reply.result || typeof reply.result !== 'object') {
        throw new E2EError(
          'runtime-enable-result',
          `Runtime.enable reply missing result object`
        );
      }
      if (!event.params || !event.params.context || event.params.context.id == null) {
        throw new E2EError(
          'exec-ctx-id',
          `executionContextCreated missing params.context.id`
        );
      }
      execContextId = event.params.context.id;
      ok(
        `Runtime.enable reply + executionContextCreated (ctxId=${JSON.stringify(
          execContextId
        )})`
      );
    },
    'runtime-enable'
  );

  // Step 5: Runtime.evaluate 1+2
  await runStep(
    'Runtime.evaluate 1+2',
    async () => {
      disp.sendCommand(2, 'Runtime.evaluate', { expression: '1 + 2' });
      const reply = await disp.awaitReply(2, timeoutMs, 'evaluate-1+2');
      if (reply.error) {
        throw new E2EError(
          'evaluate-1+2-error',
          `Runtime.evaluate 1+2 returned error: ${JSON.stringify(reply.error)}`
        );
      }
      const inner = reply.result && reply.result.result;
      if (!inner || typeof inner !== 'object') {
        throw new E2EError(
          'evaluate-1+2-missing',
          `Runtime.evaluate 1+2 reply missing result.result`
        );
      }
      const t = inner.type;
      if (!['number', 'object', 'string'].includes(t)) {
        throw new E2EError(
          'evaluate-1+2-type',
          `Runtime.evaluate 1+2: unexpected type ${JSON.stringify(t)}`
        );
      }
      if (t === 'number') {
        if (inner.value !== 3) {
          throw new E2EError(
            'evaluate-1+2-wrong-number',
            `Runtime.evaluate 1+2: expected number=3, got ${JSON.stringify(inner.value)}`
          );
        }
        ok(`Runtime.evaluate 1+2 = 3`);
      } else if (t === 'object') {
        const desc = String(inner.description);
        if (desc !== '3') {
          throw new E2EError(
            'evaluate-1+2-wrong-type',
            `Runtime.evaluate 1+2: expected number=3, got object desc=${JSON.stringify(
              desc
            )}`
          );
        }
        ok(`Runtime.evaluate 1+2 = object desc="3"`);
      } else {
        // string fallback
        if (String(inner.value) !== '3') {
          throw new E2EError(
            'evaluate-1+2-wrong-string',
            `Runtime.evaluate 1+2: expected string "3", got ${JSON.stringify(inner.value)}`
          );
        }
        ok(`Runtime.evaluate 1+2 = string "3"`);
      }
    },
    'evaluate-1+2'
  );

  // Step 6: Runtime.evaluate console.log marker
  await runStep(
    'console.log marker',
    async () => {
      disp.sendCommand(3, 'Runtime.evaluate', {
        expression: 'console.log("e2e-marker-" + Date.now())',
      });
      const reply = await disp.awaitReply(3, timeoutMs, 'evaluate-console');
      if (reply.error) {
        throw new E2EError(
          'evaluate-console-error',
          `console.log evaluate returned error: ${JSON.stringify(reply.error)}`
        );
      }
      // Now wait for the consoleAPICalled event
      const evt = await disp.awaitEvent(
        (m) => {
          if (m.method !== 'Runtime.consoleAPICalled') return false;
          const args = m.params && m.params.args;
          if (!Array.isArray(args) || args.length === 0) return false;
          const a0 = args[0];
          const v = a0.value != null ? String(a0.value) : '';
          const d = a0.description != null ? String(a0.description) : '';
          return v.includes('e2e-marker-') || d.includes('e2e-marker-');
        },
        timeoutMs,
        'console-marker-event'
      );
      const a0 = evt.params.args[0];
      const shown = a0.value != null ? String(a0.value) : String(a0.description);
      ok(`console.log event arrived with marker value=${JSON.stringify(shown)}`);
    },
    'console-log-marker'
  );

  // Step 7: Runtime.evaluate throw new Error("boom-e2e")
  await runStep(
    'exception boom-e2e',
    async () => {
      disp.sendCommand(4, 'Runtime.evaluate', {
        expression: 'throw new Error("boom-e2e")',
      });
      const reply = await disp.awaitReply(4, timeoutMs, 'evaluate-throw');
      // CDP typically returns reply with result.exceptionDetails populated (not reply.error)
      const detail = reply.result && reply.result.exceptionDetails;
      if (!detail) {
        throw new E2EError(
          'exception-missing',
          `throw: reply missing result.exceptionDetails: ${JSON.stringify(reply)}`
        );
      }
      const text = typeof detail.text === 'string' ? detail.text : '';
      const exDesc =
        detail.exception && typeof detail.exception.description === 'string'
          ? detail.exception.description
          : '';
      if (!text.includes('boom-e2e') && !exDesc.includes('boom-e2e')) {
        throw new E2EError(
          'exception-no-match',
          `throw: neither exceptionDetails.text nor exception.description contained "boom-e2e"; text=${JSON.stringify(
            text
          )} exDesc=${JSON.stringify(exDesc)}`
        );
      }
      ok(`exception e2e captured`);
    },
    'exception-capture'
  );

  // Step 8: Debugger.enable
  await runStep(
    'Debugger.enable',
    async () => {
      disp.sendCommand(5, 'Debugger.enable', {});
      const reply = await disp.awaitReply(5, timeoutMs, 'debugger-enable');
      if (reply.error) {
        throw new E2EError(
          'debugger-enable-error',
          `Debugger.enable returned error: ${JSON.stringify(reply.error)}`
        );
      }
      const dbgId = reply.result && reply.result.debuggerId;
      if (typeof dbgId !== 'string' || dbgId.length === 0) {
        throw new E2EError(
          'debugger-id-missing',
          `Debugger.enable reply missing non-empty debuggerId: ${JSON.stringify(reply.result)}`
        );
      }
      ok(`Debugger.enable debuggerId=${JSON.stringify(dbgId)}`);
    },
    'debugger-enable'
  );

  // Helper: pull numeric value out of a Runtime.evaluate result regardless of whether the inspector formatted it as a number or an object description.
  function extractNumber(inner) {
    if (!inner) return NaN;
    if (inner.type === 'number' && typeof inner.value === 'number') return inner.value;
    if (typeof inner.value === 'string') {
      const n = Number(inner.value);
      return Number.isFinite(n) ? n : NaN;
    }
    if (typeof inner.description === 'string') {
      const n = Number(inner.description);
      return Number.isFinite(n) ? n : NaN;
    }
    return NaN;
  }

  // Step 10: REPL state persists across evaluates.
  await runStep(
    'stateful REPL',
    async () => {
      disp.sendCommand(6, 'Runtime.evaluate', {
        expression: 'globalThis.__e2e_counter = 0',
      });
      await disp.awaitReply(6, timeoutMs, 'repl-init');
      disp.sendCommand(7, 'Runtime.evaluate', {
        expression: '++globalThis.__e2e_counter',
      });
      const r1 = await disp.awaitReply(7, timeoutMs, 'repl-1');
      disp.sendCommand(8, 'Runtime.evaluate', {
        expression: '++globalThis.__e2e_counter',
      });
      const r2 = await disp.awaitReply(8, timeoutMs, 'repl-2');
      const v1 = extractNumber(r1.result && r1.result.result);
      const v2 = extractNumber(r2.result && r2.result.result);
      if (v1 !== 1 || v2 !== 2) {
        throw new E2EError(
          'repl-state',
          `expected counter 1 then 2, got ${v1} then ${v2}`
        );
      }
      ok(`stateful REPL: __e2e_counter 0 → 1 → 2`);
    },
    'stateful-repl'
  );

  // Step 11: all five console.* levels map to the right CDP type.
  await runStep(
    'console levels route correctly',
    async () => {
      const marker = `lvl${Date.now()}`;
      disp.sendCommand(9, 'Runtime.evaluate', {
        expression:
          `console.log("LG_${marker}");` +
          `console.info("IN_${marker}");` +
          `console.warn("WN_${marker}");` +
          `console.error("ER_${marker}")`,
      });
      await disp.awaitReply(9, timeoutMs, 'levels-eval');
      const got = { log: null, info: null, warning: null, error: null };
      const deadline = Date.now() + timeoutMs;
      while (
        Object.values(got).some((v) => v === null) &&
        Date.now() < deadline
      ) {
        const remaining = Math.max(100, deadline - Date.now());
        let evt;
        try {
          evt = await disp.awaitEvent(
            (m) => {
              if (m.method !== 'Runtime.consoleAPICalled') return false;
              const a0 = m.params && m.params.args && m.params.args[0];
              if (!a0) return false;
              const s = String(a0.value != null ? a0.value : a0.description);
              return s.includes(marker);
            },
            remaining,
            'level-event'
          );
        } catch (_) {
          break;
        }
        const a0 = evt.params.args[0];
        const s = String(a0.value != null ? a0.value : a0.description);
        const t = evt.params.type;
        if (s.startsWith(`LG_`)) got.log = t;
        else if (s.startsWith(`IN_`)) got.info = t;
        else if (s.startsWith(`WN_`)) got.warning = t;
        else if (s.startsWith(`ER_`)) got.error = t;
      }
      // Our backend folds console.log and console.debug into the same level (LogLevel.debug) — the inspector maps that back to CDP "log", so the expectation below uses CDP canonical types.
      if (
        got.log !== 'log' ||
        got.info !== 'info' ||
        got.warning !== 'warning' ||
        got.error !== 'error'
      ) {
        throw new E2EError(
          'levels-mismatch',
          `expected log/info/warning/error, got ${JSON.stringify(got)}`
        );
      }
      ok(
        `console levels: log=${got.log} info=${got.info} warn=${got.warning} error=${got.error}`
      );
    },
    'console-levels'
  );

  // Step 12: non-ASCII UTF-8 roundtrips through evaluate + console.
  await runStep(
    'non-ASCII UTF-8 roundtrip',
    async () => {
      const marker = `nonASCII-${Date.now()}-🚀`;
      disp.sendCommand(10, 'Runtime.evaluate', {
        expression: `console.log(${JSON.stringify(marker)})`,
      });
      await disp.awaitReply(10, timeoutMs, 'utf8-eval');
      const evt = await disp.awaitEvent(
        (m) => {
          if (m.method !== 'Runtime.consoleAPICalled') return false;
          const a0 = m.params && m.params.args && m.params.args[0];
          if (!a0) return false;
          const s = String(a0.value != null ? a0.value : a0.description);
          return s.includes('nonASCII-') && s.includes('🚀');
        },
        timeoutMs,
        'utf8-event'
      );
      ok(`non-ASCII UTF-8 roundtrip: ${evt.params.args[0].value || evt.params.args[0].description}`);
    },
    'utf8-roundtrip'
  );

  // Step 13: 100KB console message — exercises 64-bit extended length frame encoding on the server → client direction.
  await runStep(
    'large console payload',
    async () => {
      const size = 100000;
      disp.sendCommand(11, 'Runtime.evaluate', {
        expression: `console.log("X".repeat(${size}))`,
      });
      await disp.awaitReply(11, timeoutMs, 'large-eval');
      const evt = await disp.awaitEvent(
        (m) => {
          if (m.method !== 'Runtime.consoleAPICalled') return false;
          const a0 = m.params && m.params.args && m.params.args[0];
          if (!a0) return false;
          const s = String(a0.value != null ? a0.value : a0.description);
          return s.length >= size && s.startsWith('XXX');
        },
        timeoutMs,
        'large-event'
      );
      const a0 = evt.params.args[0];
      const s = String(a0.value != null ? a0.value : a0.description);
      ok(`large console payload: ${s.length} bytes delivered`);
    },
    'large-payload'
  );

  // Step 14: syntax error in evaluate surfaces via exceptionDetails (not a thrown Error object, not a protocol-level error).
  await runStep(
    'syntax error via exceptionDetails',
    async () => {
      disp.sendCommand(12, 'Runtime.evaluate', { expression: '1 +' });
      const reply = await disp.awaitReply(12, timeoutMs, 'syntax-eval');
      if (reply.error) {
        throw new E2EError(
          'syntax-proto-error',
          `expected exceptionDetails in result, got protocol error: ${JSON.stringify(reply.error)}`
        );
      }
      const detail = reply.result && reply.result.exceptionDetails;
      if (!detail) {
        throw new E2EError(
          'syntax-no-detail',
          `expected result.exceptionDetails, got ${JSON.stringify(reply.result)}`
        );
      }
      ok(`syntax error captured (exception description available)`);
    },
    'syntax-error'
  );

  // Step 15: unknown CDP method → JSON-RPC method-not-found (code -32601).
  await runStep(
    'unknown method → -32601',
    async () => {
      disp.sendCommand(13, 'Foo.nonexistentMethod', {});
      const reply = await disp.awaitReply(13, timeoutMs, 'unknown-method');
      if (!reply.error || reply.error.code !== -32601) {
        throw new E2EError(
          'unknown-method-code',
          `expected error code -32601 (Method not found), got ${JSON.stringify(reply.error)}`
        );
      }
      ok(`unknown CDP method rejected with code ${reply.error.code}`);
    },
    'unknown-method'
  );

  // Step 16: a second concurrent WebSocket session to the same target works independently — proves multi-client support and per-session isolation.
  await runStep(
    'second concurrent session',
    async () => {
      const r2 = await wsHandshake(host, port, wsPath, timeoutMs);
      const client2 = r2.client;
      const socket2 = r2.socket;
      const disp2 = makeDispatcher(client2);
      try {
        disp2.sendCommand(100, 'Runtime.enable', {});
        const r = await disp2.awaitReply(100, timeoutMs, 'session2-enable');
        if (r.error) {
          throw new E2EError(
            'session2-enable-err',
            `session 2 Runtime.enable error: ${JSON.stringify(r.error)}`
          );
        }
        disp2.sendCommand(101, 'Runtime.evaluate', { expression: '40 + 2' });
        const reply = await disp2.awaitReply(101, timeoutMs, 'session2-eval');
        const inner = reply.result && reply.result.result;
        const val = extractNumber(inner);
        if (val !== 42) {
          throw new E2EError(
            'session2-wrong-val',
            `session 2 evaluate expected 42, got ${val}`
          );
        }
        client2.sendClose(1000, 'session2-done');
      } finally {
        disp2.stop();
        try {
          socket2.destroy();
        } catch (_) {
          // ignore
        }
      }
      ok(`second concurrent session works independently (40+2=42)`);
    },
    'second-session'
  );

  // Step 17: heartbeat observation — the inspector-demo target installs a `setInterval(..., 1000)` that emits `heartbeat <iso-date>` via console.log. A successful tick proves timer callbacks flow through the tap on the live session.
  await runStep(
    'heartbeat observed via setInterval',
    async () => {
      const waitMs = Math.min(2000, timeoutMs);
      const evt = await disp.awaitEvent(
        (m) => {
          if (m.method !== 'Runtime.consoleAPICalled') return false;
          const a0 = m.params && m.params.args && m.params.args[0];
          if (!a0) return false;
          const s = String(a0.value != null ? a0.value : a0.description);
          return s.startsWith('heartbeat ');
        },
        waitMs,
        'heartbeat'
      );
      const a0 = evt.params.args[0];
      const s = String(a0.value != null ? a0.value : a0.description);
      ok(`heartbeat observed: ${s}`);
    },
    'heartbeat'
  );

  // Step 20: Runtime.evaluate on an object returns an objectId + className. Request IDs from here on start at 20 to stay clear of previous steps.
  let probeObjectId = null;
  await runStep(
    'evaluate object → objectId roundtrip',
    async () => {
      disp.sendCommand(20, 'Runtime.evaluate', {
        expression: '({a: 1, b: "hello"})',
      });
      const reply = await disp.awaitReply(20, timeoutMs, 'evaluate-object');
      if (reply.error) {
        throw new E2EError(
          'evaluate-object-error',
          `Runtime.evaluate object returned error: ${JSON.stringify(reply.error)}`
        );
      }
      const inner = reply.result && reply.result.result;
      if (!inner || typeof inner !== 'object') {
        throw new E2EError(
          'evaluate-object-shape',
          `evaluate object reply missing result.result: ${JSON.stringify(reply)}`
        );
      }
      if (inner.type !== 'object') {
        throw new E2EError(
          'evaluate-object-type',
          `evaluate object expected type=object, got ${JSON.stringify(inner.type)}`
        );
      }
      if (inner.className !== 'Object') {
        throw new E2EError(
          'evaluate-object-class',
          `evaluate object expected className=Object, got ${JSON.stringify(inner.className)}`
        );
      }
      if (typeof inner.objectId !== 'string' || inner.objectId.length === 0) {
        throw new E2EError(
          'evaluate-object-id',
          `evaluate object missing string objectId: ${JSON.stringify(inner)}`
        );
      }
      probeObjectId = inner.objectId;
      ok(
        `evaluate object → objectId=${JSON.stringify(
          probeObjectId
        )} className=${JSON.stringify(inner.className)}`
      );
    },
    'evaluate-object'
  );

  // Step 21: Runtime.getProperties expands the object.
  await runStep(
    'Runtime.getProperties expands object',
    async () => {
      disp.sendCommand(21, 'Runtime.getProperties', {
        objectId: probeObjectId,
      });
      const reply = await disp.awaitReply(21, timeoutMs, 'get-properties');
      if (reply.error) {
        throw new E2EError(
          'get-properties-error',
          `Runtime.getProperties returned error: ${JSON.stringify(reply.error)}`
        );
      }
      const props = reply.result && reply.result.result;
      if (!Array.isArray(props)) {
        throw new E2EError(
          'get-properties-shape',
          `getProperties reply missing result.result array: ${JSON.stringify(reply)}`
        );
      }
      const byName = {};
      for (const p of props) byName[p.name] = p;
      if (!byName.a || !byName.b) {
        throw new E2EError(
          'get-properties-missing',
          `expected properties a,b, got names ${JSON.stringify(Object.keys(byName))}`
        );
      }
      if (byName.a.value.type !== 'number' || byName.a.value.value !== 1) {
        throw new E2EError(
          'get-properties-a',
          `expected a=number(1), got ${JSON.stringify(byName.a.value)}`
        );
      }
      if (byName.b.value.type !== 'string' || byName.b.value.value !== 'hello') {
        throw new E2EError(
          'get-properties-b',
          `expected b=string("hello"), got ${JSON.stringify(byName.b.value)}`
        );
      }
      ok(
        `getProperties returned a=number(1) b=string("hello") (${props.length} prop(s))`
      );
    },
    'get-properties'
  );

  // Step 22: Runtime.callFunctionOn with the returned objectId as `this`.
  await runStep(
    'Runtime.callFunctionOn binds this to objectId',
    async () => {
      disp.sendCommand(22, 'Runtime.callFunctionOn', {
        objectId: probeObjectId,
        functionDeclaration: 'function(){ return this.a + 10; }',
      });
      const reply = await disp.awaitReply(22, timeoutMs, 'call-function-on');
      if (reply.error) {
        throw new E2EError(
          'call-function-on-error',
          `callFunctionOn returned error: ${JSON.stringify(reply.error)}`
        );
      }
      const inner = reply.result && reply.result.result;
      if (!inner || inner.type !== 'number' || inner.value !== 11) {
        throw new E2EError(
          'call-function-on-result',
          `callFunctionOn expected 11, got ${JSON.stringify(inner)}`
        );
      }
      ok(`callFunctionOn(this.a + 10) = 11`);
    },
    'call-function-on'
  );

  // Step 23: Runtime.releaseObject invalidates the objectId.
  await runStep(
    'Runtime.releaseObject invalidates the handle',
    async () => {
      disp.sendCommand(23, 'Runtime.releaseObject', { objectId: probeObjectId });
      const relReply = await disp.awaitReply(23, timeoutMs, 'release-object');
      if (relReply.error) {
        throw new E2EError(
          'release-object-error',
          `releaseObject returned error: ${JSON.stringify(relReply.error)}`
        );
      }
      // After release, getProperties on the same id must return
      // -32000 "Could not find object with given id".
      disp.sendCommand(24, 'Runtime.getProperties', { objectId: probeObjectId });
      const gpReply = await disp.awaitReply(24, timeoutMs, 'get-properties-after-release');
      if (!gpReply.error || gpReply.error.code !== -32000) {
        throw new E2EError(
          'release-object-still-live',
          `getProperties after release expected code=-32000, got ${JSON.stringify(
            gpReply
          )}`
        );
      }
      ok(`releaseObject cleared ${probeObjectId} (subsequent getProperties → -32000)`);
    },
    'release-object'
  );

  // Step 18: Clean close
  await runStep(
    'close handshake',
    async () => {
      client.sendClose(1000, 'e2e-done');
      // Expect either a close frame back OR TCP close within 1s
      const closeTimeout = Math.min(1000, timeoutMs);
      try {
        const info = await client.nextClose(closeTimeout);
        if (info.serverClosed) {
          ok(`close handshake clean (server closed TCP)`);
        } else {
          ok(`close handshake clean (close frame code=${info.code})`);
        }
      } catch (err) {
        throw new E2EError(
          'close-timeout',
          `no close frame or TCP close within ${closeTimeout}ms`
        );
      }
    },
    'close-handshake'
  );

  disp.stop();
  try {
    socket.destroy();
  } catch (_) {
    // ignore
  }

  process.stdout.write(`E2E PASS\n`);
  process.exit(0);
}

main().catch((err) => {
  // Unhandled — shouldn't normally reach here
  const code = (err && err.code) || 'unhandled';
  fail(`unhandled: ${describeErr(err)}`);
  process.stdout.write(`E2E FAIL: ${code}\n`);
  process.exit(1);
});
