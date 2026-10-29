import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';

const child = spawn(process.argv[2], [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = [];
const readers = createInterface({ input: child.stdout });
let resolveReady;
const ready = new Promise(resolve => { resolveReady = resolve; });
readers.on('line', line => {
  console.log(line);
  lines.push(line);
  if (line.startsWith('READY ')) resolveReady(Number(line.slice(6)));
});
const timeout = setTimeout(() => {
  console.error('idle wake consumer timed out');
  child.kill('SIGKILL');
  process.exitCode = 1;
}, 5000);
let socket;
try {
  const exit = once(child, 'close');
  const port = await Promise.race([ready, exit.then(() => { throw new Error('consumer exited before ready'); })]);
  const [target] = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await once(socket, 'open');
  const reply = once(socket, 'message');
  socket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: '6 * 7', returnByValue: true } }));
  const [event] = await reply;
  const message = JSON.parse(String(event.data));
  assert.equal(message.id, 1);
  assert.equal(message.result.result.value, 42);
  socket.close();
  child.stdin.write('quit\n');
  const [code] = await exit;
  assert.equal(code, 0);
  assert.ok(lines.includes('LOOP_RUNNING'));
  assert.ok(lines.includes('CLEAN_EXIT'));
  console.log('PASS idle CDP work wakes the owner without timers or polling');
} catch (error) {
  console.error(error);
  socket?.close();
  child.kill('SIGKILL');
  process.exitCode = 1;
} finally {
  clearTimeout(timeout);
}
