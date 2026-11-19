import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const prepare = resolve('scripts/prepare-harmony-ohpm.mjs');
const root = mkdtempSync(join(tmpdir(), 'jsbay-ohpm-test-'));
try {
  mkdirSync(join(root, 'sdk/harmony'), { recursive: true });
  mkdirSync(join(root, 'tests/harmony-sdk/fixture'), { recursive: true });
  writeFileSync(join(root, 'LICENSE'), 'MIT test license\n');
  writeFileSync(join(root, 'sdk/harmony/oh-package.json5'), JSON.stringify({ name: '@js-bay/harmony', version: '0.1.0', dependencies: { 'libjsbay_harmony.so': 'file:./src/main/cpp/types/libjsbay_harmony' } }));
  writeFileSync(join(root, 'tests/harmony-sdk/fixture/build-profile.json5'), JSON.stringify({ app: { buildModeSet: [{ name: 'debug', buildOption: { strictMode: { useNormalizedOHMUrl: true } } }] } }));
  for (const [backend, expected] of [['quickjs', '@jsbay/quickjs'], ['quickjs_ng', '@jsbay/quickjs_ng']]) {
    execFileSync(process.execPath, [prepare, root, backend, '0.1.1-rc.1']);
    const metadata = JSON.parse(readFileSync(join(root, 'sdk/harmony/oh-package.json5'), 'utf8'));
    assert.equal(metadata.name, expected);
    assert.equal(metadata.version, '0.1.1-rc.1');
    assert.match(readFileSync(join(root, 'sdk/harmony/README.md'), 'utf8'), new RegExp(`ohpm install ${expected}@0\\.1\\.1-rc\\.1`));
    assert.match(readFileSync(join(root, 'sdk/harmony/CHANGELOG.md'), 'utf8'), /0\.1\.1-rc\.1/);
    assert.ok(readFileSync(join(root, 'sdk/harmony/LICENSE'), 'utf8').length > 0);
    const profile = JSON.parse(readFileSync(join(root, 'tests/harmony-sdk/fixture/build-profile.json5'), 'utf8'));
    assert.equal(profile.app.buildModeSet.find((mode) => mode.name === 'release').buildOption.strictMode.useNormalizedOHMUrl, true);
  }
  assert.throws(() => execFileSync(process.execPath, [prepare, root, 'unknown', '0.1.1-rc.1'], { stdio: 'ignore' }));
  assert.throws(() => execFileSync(process.execPath, [prepare, root, 'quickjs', 'not-a-version'], { stdio: 'ignore' }));
} finally {
  rmSync(root, { recursive: true, force: true });
}
