import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { downloadSource } from './test262/download.mjs';

async function withServer(handler, run) {
  const server = createServer(handler);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try { await run(`http://127.0.0.1:${server.address().port}/source.js`); }
  finally {
    server.closeAllConnections();
    await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  }
}

test('pinned-source download retries a transient HTTP error and preserves exact bytes', async () => {
  let requests = 0;
  const bytes = Buffer.from([0, 255, 10, 13, 128]);
  await withServer((_request, response) => {
    requests++;
    response.writeHead(requests === 1 ? 503 : 200);
    response.end(requests === 1 ? 'unavailable' : bytes);
  }, async url => assert.deepEqual(await downloadSource(url), bytes));
  assert.equal(requests, 2);
});

test('pinned-source download retries a dropped transport connection', async () => {
  let requests = 0;
  await withServer((request, response) => {
    if (++requests === 1) request.socket.destroy();
    else response.end('recovered');
  }, async url => assert.equal((await downloadSource(url)).toString(), 'recovered'));
  assert.equal(requests, 2);
});

test('permanent HTTP errors are not retried or converted to empty success', async () => {
  let requests = 0;
  await withServer((_request, response) => {
    requests++;
    response.writeHead(404);
    response.end('missing');
  }, async url => assert.rejects(downloadSource(url), /HTTP 404/));
  assert.equal(requests, 1);
});

test('transient HTTP errors stop after three attempts with actionable diagnostics', async () => {
  let requests = 0;
  await withServer((_request, response) => {
    requests++;
    response.writeHead(503);
    response.end('unavailable');
  }, async url => assert.rejects(downloadSource(url), /failed after 3 attempts: HTTP 503/));
  assert.equal(requests, 3);
});

test('persistent network failures stop after three attempts', async () => {
  let requests = 0;
  await withServer(request => { requests++; request.socket.destroy(); },
    async url => assert.rejects(downloadSource(url), /failed after 3 attempts: UND_ERR_SOCKET/));
  assert.equal(requests, 3);
});
