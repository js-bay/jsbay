import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const install = resolve(repo, process.argv[2] || process.env.HERMES_INSTALL || 'vendor/hermes-install');
const outputDir = mkdtempSync(join(tmpdir(), 'hermes-inspector-outbound-'));
const executable = join(outputDir, 'hermes-inspector-outbound-contract');
const compiler = process.env.CXX || 'c++';
const linkerFlag = process.platform === 'darwin' ? '-Wl,-dead_strip' : '-Wl,--gc-sections';
const includeDir = join(install, 'include');
const libDir = join(install, 'lib');

try {
  const compiled = spawnSync(compiler, [
    '-std=c++17',
    '-pthread',
    '-ffunction-sections',
    '-fdata-sections',
    '-DHERMES_ENABLE_DEBUGGER=1',
    '-I', join(repo, 'src/backend/hermes'),
    '-I', includeDir,
    join(repo, 'tests/hermes-inspector-outbound-contract.cpp'),
    '-L', libDir,
    `-Wl,-rpath,${libDir}`,
    '-lhermesvm',
    '-ljsi',
    linkerFlag,
    '-o', executable,
  ], { encoding: 'utf8', timeout: 120000 });
  assert.equal(compiled.error, undefined, `C++ compiler did not start: ${compiled.error}`);
  assert.equal(compiled.status, 0, `Hermes outbound contract compilation failed:\n${compiled.stdout}\n${compiled.stderr}`);

  const ran = spawnSync(executable, [], { encoding: 'utf8', timeout: 10000 });
  assert.equal(ran.error, undefined, `Hermes outbound contract did not start: ${ran.error}`);
  assert.equal(ran.status, 0, `Hermes outbound contract failed with ${ran.status}:\n${ran.stdout}\n${ran.stderr}`);
} finally {
  rmSync(outputDir, { recursive: true, force: true });
}
