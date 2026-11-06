import { spawn } from 'node:child_process';
import { watch } from 'node:fs';
import { access, chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const root = resolve(process.argv[2] ?? '.');
const driver = join(root, 'bench', 'debugger_benchmark_driver.mjs');
const consumer = join(root, 'tests', 'debugger_benchmark_protocol_consumer.mjs');
const measure = join(root, 'bench', 'measure-debugger.sh');
const temporary = await mkdtemp(join(tmpdir(), 'jsbay-debugger-protocol.'));
const metadata = { JSBAY_DEBUGGER_SOURCE_SHA: '0'.repeat(64), JSBAY_DEBUGGER_ENGINE_SOURCE_SHA: '1'.repeat(64), JSBAY_DEBUGGER_DRIVER_SHA: '2'.repeat(64), JSBAY_DEBUGGER_TOOLCHAIN: 'test-toolchain', JSBAY_DEBUGGER_CC_VERSION: 'test-cc', JSBAY_DEBUGGER_SOURCE_COMMIT: 'null', JSBAY_DEBUGGER_SOURCE_DIRTY: 'false' };

function delay(milliseconds) { return new Promise(resolveDelay => { const timer = setTimeout(resolveDelay, milliseconds); timer.unref(); }); }
async function missing(path) { return access(path).then(() => false, error => error.code === 'ENOENT'); }
async function waitForEvent(path, event, timeout = 5000) {
  const contains = async () => (await readFile(path, 'utf8').catch(error => error.code === 'ENOENT' ? '' : Promise.reject(error))).split('\n').filter(Boolean).map(JSON.parse).find(entry => entry.event === event);
  const existing = await contains();
  if (existing) return existing;
  return new Promise((resolveEvent, reject) => {
    let settled = false;
    let watcher;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      watcher?.close();
      if (error) reject(error); else resolveEvent(result);
    };
    const check = () => { void contains().then(found => { if (found) finish(null, found); }, error => finish(error)); };
    const timer = setTimeout(() => finish(new Error(`timed out waiting for proof ${event}`)), timeout);
    watcher = watch(temporary, check);
    watcher.once('error', error => finish(error));
    check();
  });
}
function stderrOf(child) { let stderr = ''; child.stderr.setEncoding('utf8'); child.stderr.on('data', chunk => { stderr += chunk; }); return () => stderr; }
function closeOf(child) { return new Promise(resolveClose => child.once('close', (code, signal) => resolveClose({ code, signal }))); }
async function setupDiagnostic(directory, closed) {
  const status = await Promise.race([closed, delay(1).then(() => undefined)]);
  const log = async name => readFile(join(directory, 'work', `${name}.log`), 'utf8').catch(error => error.code === 'ENOENT' ? '<missing>' : error.message);
  const [build, link, measure] = await Promise.all(['build', 'link', 'measure'].map(log));
  return `child=${status ? `${status.code ?? status.signal}` : 'running'} build=${JSON.stringify(build)} link=${JSON.stringify(link)} measure=${JSON.stringify(measure)}`;
}
async function stopGroup(child, closed) {
  if (!child?.pid) return;
  try { process.kill(-child.pid, 'SIGTERM'); } catch (_) {}
  if (!await Promise.race([closed, delay(500)])) { try { process.kill(-child.pid, 'SIGKILL'); } catch (_) {} await Promise.race([closed, delay(500)]); }
}
async function protocolCase(name, mode, proofEvent, expectedError) {
  const directory = join(temporary, name);
  const proof = join(temporary, `${name}.proof`);
  const report = join(directory, 'report.json');
  const child = spawn(process.execPath, [driver, '--bin', consumer, '--out', report, '--samples', '1', '--timeout-ms', '1000'], { detached: true, env: { ...process.env, ...metadata, JSBAY_PROTOCOL_MODE: mode, JSBAY_PROTOCOL_PROOF: proof }, stdio: ['ignore', 'ignore', 'pipe'] });
  const stderr = stderrOf(child);
  const closed = closeOf(child);
  try {
    const [status, stage] = await Promise.all([Promise.race([closed, delay(5000).then(() => undefined)]), waitForEvent(proof, proofEvent)]);
    if (!status) throw new Error(`${name} did not finish: ${stderr()}`);
    if (status.code === 0) throw new Error(`${name} unexpectedly succeeded`);
    if (!expectedError.test(stderr())) throw new Error(`${name} missed expected error ${expectedError}: ${stderr()}`);
    if (!Number.isInteger(stage.pid) || stage.pid < 1) throw new Error(`${name} proof did not identify the consumer PID`);
    await assertGone(stage.pid, `${name} consumer`);
    if (!await missing(report)) throw new Error(`${name} published a report`);
    process.stdout.write(`PASS ${name} stage=${stage.event} pid=${stage.pid} exit=${status.code ?? status.signal}\n`);
  } finally { await stopGroup(child, closed); }
}
async function assertGone(pid, name) {
  try { process.kill(pid, 0); } catch (error) { if (error.code === 'ESRCH') return; throw error; }
  throw new Error(`${name} PID ${pid} survived Bash SIGTERM`);
}
async function signalCase() {
  const directory = join(temporary, 'signal-report');
  const proof = join(temporary, 'signal.proof');
  const zig = join(temporary, 'zig');
  const cc = join(temporary, 'cc');
  const bin = join(temporary, 'signal-bin');
  const shasum = join(bin, 'shasum');
  await mkdir(bin);
  await writeFile(zig, '#!/usr/bin/env bash\nif [ "$1" = version ]; then printf test-zig\\n; exit 0; fi\nwhile [ "$#" -gt 0 ]; do if [ "$1" = --prefix ]; then shift; prefix=$1; fi; shift; done\nmkdir -p "$prefix/lib"\n: >"$prefix/lib/libjsbay.a"\n');
  await writeFile(cc, '#!/usr/bin/env bash\nif [ "$1" = --version ]; then printf test-cc\\n; exit 0; fi\nwhile [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; output=$1; fi; shift; done\ncp "$JSBAY_PROTOCOL_CONSUMER" "$output"\nchmod +x "$output"\n');
  await writeFile(shasum, '#!/usr/bin/env bash\nif [ "$#" -gt 2 ]; then printf \'%064d  %s\\n\' 0 "$3"; else cat >/dev/null; printf \'%064d  -\\n\' 0; fi\n');
  await chmod(zig, 0o755); await chmod(cc, 0o755); await chmod(shasum, 0o755);
  const child = spawn('bash', [measure, directory, 'quickjs_ng'], { detached: true, env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, ZIG: zig, CC: cc, JSBAY_PROTOCOL_CONSUMER: consumer, JSBAY_PROTOCOL_MODE: 'shell-hold', JSBAY_PROTOCOL_PROOF: proof }, stdio: ['ignore', 'ignore', 'pipe'] });
  const stderr = stderrOf(child);
  const closed = closeOf(child);
  try {
    let stage;
    try { stage = await waitForEvent(proof, 'shell-hold', 15000); }
    catch (error) { throw new Error(`signal setup failed: ${await setupDiagnostic(directory, closed)} stderr=${stderr()} ${error.message}`); }
    if (!Number.isInteger(stage.pid) || !Number.isInteger(stage.ppid)) throw new Error('signal proof did not identify consumer and driver PIDs');
    process.kill(child.pid, 'SIGTERM');
    const status = await Promise.race([closed, delay(5000).then(() => undefined)]);
    if (!status) throw new Error(`measure shell did not exit after SIGTERM: ${stderr()}`);
    if (status.code !== 143) throw new Error(`measure shell exited ${status.code ?? status.signal}, expected 143`);
    await assertGone(stage.ppid, 'driver'); await assertGone(stage.pid, 'consumer');
    if (!await missing(join(directory, 'report.json'))) throw new Error('signal termination published a report');
    process.stdout.write(`PASS signal-cleanup stage=${stage.event} driver=${stage.ppid} consumer=${stage.pid} exit=${status.code}\n`);
  } finally { await stopGroup(child, closed); }
}
async function buildIntCase() {
  const directory = join(temporary, 'build-int-report');
  const proof = join(temporary, 'build-int.proof');
  const zig = join(temporary, 'zig-build-hold');
  await writeFile(zig, '#!/usr/bin/env bash\nprintf \'{"event":"build-hold","pid":%s,"ppid":%s}\\n\' "$$" "$PPID" >>"$JSBAY_BUILD_INT_PROOF"\nexec sleep 30\n');
  await chmod(zig, 0o755);
  const child = spawn('bash', [measure, directory, 'quickjs_ng'], { detached: true, env: { ...process.env, ZIG: zig, JSBAY_BUILD_INT_PROOF: proof }, stdio: ['ignore', 'ignore', 'pipe'] });
  const stderr = stderrOf(child);
  const closed = closeOf(child);
  try {
    const stage = await waitForEvent(proof, 'build-hold');
    if (!Number.isInteger(stage.pid) || stage.pid < 1) throw new Error('build INT proof did not identify the sleep PID');
    process.kill(child.pid, 'SIGINT');
    const status = await Promise.race([closed, delay(5000).then(() => undefined)]);
    if (!status) throw new Error(`measure shell did not exit after SIGINT: ${stderr()}`);
    if (status.code !== 130) throw new Error(`measure shell exited ${status.code ?? status.signal}, expected 130`);
    await assertGone(stage.pid, 'build sleep');
    if (!await missing(join(directory, 'report.json'))) throw new Error('build INT termination published a report');
    process.stdout.write(`PASS build-int-cleanup stage=${stage.event} sleep=${stage.pid} exit=${status.code}\n`);
  } finally { await stopGroup(child, closed); }
}
try {
  await protocolCase('handshake-timeout', 'handshake-timeout', 'websocket-handshake-wait', /WebSocket connection timed out/);
  await protocolCase('websocket-close', 'websocket-close', 'websocket-close', /WebSocket (closed|error)/);
  await protocolCase('invalid-json', 'invalid-json', 'invalid-json', /invalid CDP JSON/);
  await protocolCase('zero-locations', 'zero-locations', 'zero-locations', /unmatched breakpoint had no resolved locations/);
  await protocolCase('result-zero', 'result-zero', 'measure:1', /cold workload validation failed/);
  await protocolCase('result-exit', 'result-exit', 'quit', /cold consumer exited 7/);
  await signalCase();
  await buildIntCase();
} finally { await rm(temporary, { recursive: true, force: true }); }
