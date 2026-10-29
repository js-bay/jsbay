import { readFile, writeFile, mkdir, mkdtemp, rm, realpath, rename } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, dirname, sep, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const options = { manifest: resolve(root, 'tests/test262/manifest.json'), backend: 'quickjs_ng' };
for (let i = 2; i < process.argv.length; i += 2) {
  const key = process.argv[i];
  if (!['--manifest', '--source-root', '--output', '--host', '--backend'].includes(key) || !process.argv[i + 1]) throw Error(`Invalid option ${key}`);
  options[key.slice(2)] = process.argv[i + 1];
}
const summary = { schema_version: 1, backend: options.backend, attempted: 0, passed: 0, failed: 0, timed_out: 0, unsupported: 0, results: [] };
let work;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const safePath = path => {
  if (typeof path !== 'string' || !path || isAbsolute(path) || path.includes('\\') || path.split('/').some(p => !p || p === '.' || p === '..')) throw Error(`Invalid source path: ${path}`);
  return path;
};
try {
  const capabilityProbe = spawnSync(options.host, ['--capabilities'], { timeout: 3000, encoding: 'utf8' });
  if (capabilityProbe.error || capabilityProbe.status !== 0) throw Error('Host capability probe failed');
  summary.capabilities = JSON.parse(capabilityProbe.stdout);
  if (typeof summary.capabilities.unhandledPromiseRejection !== 'boolean') throw Error('Invalid host capability response');
  if (!summary.capabilities.unhandledPromiseRejection) summary.capabilities.asyncLimitation = 'Unhandled Promise rejections cannot be observed; async results cover $DONE and explicit exceptions only.';
  const manifest = JSON.parse(await readFile(options.manifest, 'utf8'));
  if (manifest.schema_version !== 1 || !manifest.tests?.length || !manifest.files?.length) throw Error('Empty or invalid manifest');
  summary.revision = manifest.revision;
  const sourceRoot = options['source-root'] ? await realpath(options['source-root']) : resolve(process.env.JSBAY_TEST262_CACHE || resolve(tmpdir(), 'jsbay-test262-source'), manifest.revision);
  if (!options['source-root'] && !/^[a-f0-9]{40}$/.test(manifest.revision)) throw Error('A pinned revision is required for downloads');
  const sources = new Map();
  for (const entry of manifest.files) {
    const path = safePath(entry.path);
    if (!/^[a-f0-9]{64}$/.test(entry.sha256) || sources.has(path)) throw Error(`Invalid/duplicate digest entry: ${path}`);
    const destination = resolve(sourceRoot, path);
    let bytes;
    try {
      const actual = await realpath(destination);
      if (!actual.startsWith(sourceRoot + sep)) throw Error('Source symlink escapes root');
      bytes = await readFile(actual);
    } catch (error) {
      if (options['source-root'] || error.code !== 'ENOENT') throw error;
      const response = await fetch(`https://raw.githubusercontent.com/tc39/test262/${manifest.revision}/${path}`, { signal: AbortSignal.timeout(30000) });
      if (!response.ok) throw Error(`Download ${path}: ${response.status}`);
      bytes = Buffer.from(await response.arrayBuffer());
      if (digest(bytes) !== entry.sha256) throw Error(`Source digest mismatch: ${path}`);
      await mkdir(dirname(destination), { recursive: true });
      const temporary = `${destination}.${process.pid}.tmp`;
      await writeFile(temporary, bytes);
      await rename(temporary, destination);
    }
    if (digest(bytes) !== entry.sha256) throw Error(`Source digest mismatch: ${path}`);
    sources.set(path, bytes.toString('utf8'));
  }
  const source = path => {
    const text = sources.get(safePath(path));
    if (text === undefined) throw Error(`Missing manifest source: ${path}`);
    return text;
  };
  work = await mkdtemp(resolve(tmpdir(), 'jsbay-test262-cases-'));
  for (const test of manifest.tests) {
    if (!test.variants?.length || new Set(test.variants).size !== test.variants.length) throw Error(`Invalid variants: ${test.path}`);
    for (const variant of test.variants) {
      summary.attempted++;
      const result = { path: test.path, variant };
      if (!['strict', 'sloppy'].includes(variant) || (test.negative && !['runtime', 'parse'].includes(test.negative.phase))) {
        result.status = 'unsupported'; summary.unsupported++; summary.results.push(result); continue;
      }
      const includes = new Set(['sta.js', 'assert.js', ...(test.includes || [])]);
      const harness = [...includes].map(name => source(`harness/${safePath(name)}`)).join('\n');
      const harnessPath = resolve(work, 'harness.js');
      const testPath = resolve(work, 'test.js');
      await writeFile(harnessPath, harness);
      const phaseMarker = test.negative ? 'globalThis.__jsbayTest262Entered = true;\n' : '';
      await writeFile(testPath, `${variant === 'strict' ? '"use strict";\n' : ''}${phaseMarker}${source(test.path)}`);
      const child = spawnSync(options.host, [harnessPath, testPath, test.async ? 'async' : 'sync', test.negative?.type || '', test.negative?.phase || ''], { timeout: 3000, encoding: 'utf8', maxBuffer: 1024 * 1024 });
      if (child.error?.code === 'ETIMEDOUT') { result.status = 'timed_out'; summary.timed_out++; }
      else if (!child.error && child.status === 0) { result.status = 'passed'; summary.passed++; }
      else { result.status = 'failed'; summary.failed++; result.diagnostic = (child.stderr || child.error?.message || `Exit ${child.status}, signal ${child.signal}`).slice(0, 4096); }
      summary.results.push(result);
    }
  }
} catch (error) {
  summary.error = error.message;
  process.exitCode = 2;
} finally {
  if (work) await rm(work, { recursive: true, force: true });
  const json = `${JSON.stringify(summary, null, 2)}\n`;
  if (options.output) { await mkdir(dirname(resolve(options.output)), { recursive: true }); await writeFile(options.output, json); }
  process.stdout.write(json);
}
if (summary.failed || summary.timed_out || summary.unsupported || !summary.attempted) process.exitCode ||= 1;
