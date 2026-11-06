#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { appendFile } from 'node:fs/promises';
import http from 'node:http';

const mode = process.env.JSBAY_PROTOCOL_MODE ?? 'normal';
const proof = process.env.JSBAY_PROTOCOL_PROOF;
let measurements = 0;
let server;
let debugEnabled = false;
const sockets = new Set();
let input = '';
let closing = false;

async function record(event) {
  if (proof) await appendFile(proof, `${JSON.stringify({ event, pid: process.pid, ppid: process.ppid })}\n`);
}

function frame(text) {
  const payload = Buffer.from(text);
  if (payload.length >= 126) throw new Error('test frame is too large');
  return Buffer.concat([Buffer.from([0x81, payload.length]), payload]);
}

function accept(key) {
  return createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
}

function readFrames(socket, onMessage) {
  let pending = Buffer.alloc(0);
  socket.on('data', chunk => {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 2) {
      const opcode = pending[0] & 0x0f;
      const length = pending[1] & 0x7f;
      if (length === 126 || length === 127) throw new Error('unexpected extended test frame');
      const masked = (pending[1] & 0x80) !== 0;
      const frameLength = 2 + (masked ? 4 : 0) + length;
      if (pending.length < frameLength) return;
      const mask = masked ? pending.subarray(2, 6) : undefined;
      const payload = Buffer.from(pending.subarray(masked ? 6 : 2, frameLength));
      pending = pending.subarray(frameLength);
      if (mask) for (let index = 0; index < payload.length; index++) payload[index] ^= mask[index % 4];
      if (opcode === 1) onMessage(JSON.parse(payload.toString('utf8')));
    }
  });
}

server = http.createServer((request, response) => {
  if (request.url !== '/json/list') return response.writeHead(404).end();
  const address = server.address();
  response.setHeader('content-type', 'application/json');
  response.end(JSON.stringify([{ webSocketDebuggerUrl: `ws://127.0.0.1:${address.port}/debugger` }]));
});

server.on('upgrade', async (request, socket) => {
  sockets.add(socket);
  socket.once('close', () => sockets.delete(socket));
  socket.on('error', () => socket.destroy());
  await record('websocket-upgrade');
  if (mode === 'handshake-timeout') {
    await record('websocket-handshake-wait');
    return;
  }
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept(request.headers['sec-websocket-key'])}\r\n\r\n`);
  readFrames(socket, async message => {
    await record(`command:${message.method}`);
    if (mode === 'websocket-close') {
      await record('websocket-close');
      socket.end();
      return;
    }
    if (mode === 'invalid-json') {
      await record('invalid-json');
      socket.write(frame('{'));
      return;
    }
    if (message.method === 'Debugger.enable') {
      debugEnabled = true;
      socket.write(frame(JSON.stringify({ id: message.id, result: {} })));
      return;
    }
    if (message.method === 'Debugger.setBreakpointByUrl') {
      const locations = mode === 'zero-locations' ? [] : [{ scriptId: '1', lineNumber: 8, columnNumber: 0 }];
      await record(locations.length === 0 ? 'zero-locations' : 'breakpoint');
      socket.write(frame(JSON.stringify({ id: message.id, result: { breakpointId: '1', locations } })));
    }
  });
});

await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const address = server.address();
await record('ready');
process.stdout.write(`READY ${address.port}\n`);
process.stdin.setEncoding('utf8');
async function closeConsumer(code) {
  if (closing) return;
  closing = true;
  for (const socket of sockets) socket.destroy();
  server.close(() => process.exit(code));
}

async function command(line) {
  if (line === 'MEASURE') {
    measurements++;
    await record(`measure:${measurements}`);
    if (mode === 'shell-hold' && debugEnabled) {
      await record('shell-hold');
      return;
    }
    process.stdout.write(mode === 'result-zero' ? 'RESULT 0 1 4995000 0\n' : 'RESULT 1 1 4995000 0\n');
  }
  if (line === 'QUIT') {
    await record('quit');
    await closeConsumer(mode === 'result-exit' ? 7 : 0);
  }
}

let commands = Promise.resolve();
process.stdin.on('data', chunk => {
  input += chunk;
  commands = commands.then(async () => {
    for (;;) {
      const end = input.indexOf('\n');
      if (end < 0) return;
      const line = input.slice(0, end).replace(/\r$/, '');
      input = input.slice(end + 1);
      await command(line);
    }
  });
});
process.stdin.once('end', () => {
  commands = commands.then(async () => {
    if (input) await command(input.replace(/\r$/, ''));
    await closeConsumer(0);
  });
});
