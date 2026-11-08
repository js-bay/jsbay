#!/usr/bin/env node
import { appendFileSync, writeFileSync } from 'node:fs';
import net from 'node:net';

const responseProof = process.env.JSBAY_TRUNCATED_HTTP_RESPONSE_PROOF;
const exitProof = process.env.JSBAY_TRUNCATED_HTTP_EXIT_PROOF;
let input = '';
let stopping = false;

const server = net.createServer(socket => {
  socket.once('data', () => {
    writeFileSync(responseProof, `${process.pid}\n`);
    socket.end('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\nConnection: close\r\n\r\n[');
  });
});

function stop() {
  if (stopping) return;
  stopping = true;
  server.close(() => process.exit(0));
  const timer = setTimeout(() => process.exit(0), 100);
  timer.unref();
}

process.on('exit', () => {
  if (exitProof) appendFileSync(exitProof, `${process.pid}\n`);
});
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  input += chunk;
  if (input.includes('MEASURE\n')) {
    input = input.replace('MEASURE\n', '');
    process.stdout.write('RESULT 1 1 4995000 0\n');
  }
  if (input.includes('QUIT\n')) stop();
});
process.stdin.on('end', stop);
server.listen(0, '127.0.0.1', () => {
  process.stdout.write(`READY ${server.address().port}\n`);
});
