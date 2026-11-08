import { spawn } from 'node:child_process';
import { access, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const root = resolve(process.argv[2] ?? '.');
const temporary = await mkdtemp(join(tmpdir(), 'jsbay-debugger-http-failure.'));
const report = join(temporary, 'report.json');
const responseProof = join(temporary, 'response-proof');
const exitProof = join(temporary, 'exit-proof');
const driver = join(root, 'bench', 'debugger_benchmark_driver.mjs');
const consumer = join(root, 'tests', 'debugger_benchmark_truncated_http_consumer.mjs');
let child;
let closed = false;
let closedPromise;

function delay(milliseconds) {
  return new Promise(resolve => {
    const timer = setTimeout(resolve, milliseconds);
    timer.unref();
  });
}

async function stopOwnedProcesses(closedPromise) {
  if (!child?.pid) return;
  try { process.kill(-child.pid, 'SIGTERM'); } catch (_) {}
  if (closed) return;
  if (await Promise.race([closedPromise, delay(500)])) return;
  try { process.kill(-child.pid, 'SIGKILL'); } catch (_) {}
  await Promise.race([closedPromise, delay(500)]);
}

try {
  child = spawn(process.execPath, [driver, '--bin', consumer, '--out', report, '--samples', '1', '--timeout-ms', '1000'], {
    detached: true,
    env: { ...process.env, JSBAY_TRUNCATED_HTTP_RESPONSE_PROOF: responseProof, JSBAY_TRUNCATED_HTTP_EXIT_PROOF: exitProof, JSBAY_DEBUGGER_SOURCE_SHA: '0'.repeat(64), JSBAY_DEBUGGER_ENGINE_SOURCE_SHA: '1'.repeat(64), JSBAY_DEBUGGER_DRIVER_SHA: '2'.repeat(64), JSBAY_DEBUGGER_TOOLCHAIN: 'test-toolchain', JSBAY_DEBUGGER_CC_VERSION: 'test-cc', JSBAY_DEBUGGER_SOURCE_COMMIT: 'null', JSBAY_DEBUGGER_SOURCE_DIRTY: 'false' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { stderr += chunk; });
  closedPromise = new Promise(resolve => child.once('close', (code, signal) => {
    closed = true;
    resolve({ code, signal });
  }));
  const deadline = delay(5000).then(() => undefined);
  const status = await Promise.race([closedPromise, deadline]);
  if (!status) {
    await stopOwnedProcesses(closedPromise);
    throw new Error('driver did not exit after the truncated HTTP response');
  }
  await access(responseProof).catch(error => { throw new Error(`truncated response was not sent: ${stderr || error.message}`); });
  await access(exitProof);
  const responsePid = (await readFile(responseProof, 'utf8')).trim();
  const exitedPids = (await readFile(exitProof, 'utf8')).trim().split('\n');
  if (!exitedPids.includes(responsePid)) throw new Error('consumer that sent the truncated response did not exit');
  await access(report).then(() => { throw new Error('truncated HTTP response published a report'); }, error => {
    if (error.code !== 'ENOENT') throw error;
  });
  if (status.code === 0) throw new Error('truncated HTTP response unexpectedly succeeded');
  if (!stderr.includes('truncated')) throw new Error(`truncated response was not diagnosed: ${stderr}`);
} finally {
  if (child) await stopOwnedProcesses(closedPromise);
  await rm(temporary, { recursive: true, force: true });
}
