import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const root = resolve(process.argv[2] ?? '.');
const temporary = await mkdtemp(join(tmpdir(), 'jsbay-debugger-cleanup-failure.'));
const proof = join(temporary, 'consumer-pid');
const driver = join(root, 'bench', 'debugger_benchmark_driver.mjs');
const consumer = join(root, 'tests', 'debugger_benchmark_cleanup_consumer.sh');
let child;
let closed = false;
let closedPromise;

function delay(milliseconds) {
  return new Promise(resolve => { const timer = setTimeout(resolve, milliseconds); timer.unref(); });
}

async function stop() {
  if (!child?.pid) return;
  try { process.kill(-child.pid, 'SIGTERM'); } catch (_) {}
  if (!closed && !await Promise.race([closedPromise, delay(500)])) {
    try { process.kill(-child.pid, 'SIGKILL'); } catch (_) {}
  }
}

try {
  child = spawn(process.execPath, [driver, '--bin', consumer, '--out', join(temporary, 'report.json'), '--samples', '1', '--timeout-ms', '300'], { detached: true, env: { ...process.env, JSBAY_DEBUGGER_CLEANUP_PROOF: proof, JSBAY_DEBUGGER_SOURCE_SHA: '0'.repeat(64), JSBAY_DEBUGGER_ENGINE_SOURCE_SHA: '1'.repeat(64), JSBAY_DEBUGGER_DRIVER_SHA: '2'.repeat(64), JSBAY_DEBUGGER_TOOLCHAIN: 'test-toolchain', JSBAY_DEBUGGER_CC_VERSION: 'test-cc', JSBAY_DEBUGGER_SOURCE_COMMIT: 'null', JSBAY_DEBUGGER_SOURCE_DIRTY: 'false' }, stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { stderr += chunk; });
  closedPromise = new Promise(resolve => child.once('close', (code, signal) => { closed = true; resolve({ code, signal }); }));
  const status = await Promise.race([closedPromise, delay(2000).then(() => undefined)]);
  if (!status) throw new Error('driver did not exit after RESULT timeout');
  await readFile(proof, 'utf8');
  if (status.code === 0) throw new Error('hanging consumer unexpectedly succeeded');
  if (!stderr.includes('timed out waiting for /^RESULT /')) throw new Error(`primary RESULT timeout missing: ${stderr}`);
  if (!stderr.includes('consumer exited') || !stderr.includes('after timeout')) throw new Error(`cleanup failure missing: ${stderr}`);
} finally {
  await stop();
  await rm(temporary, { recursive: true, force: true });
}
