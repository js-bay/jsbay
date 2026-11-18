import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

test('draft retries preserve assets and publication verifies every checksum', () => {
  const dir = mkdtempSync(join(tmpdir(), 'jsbay-release-test-'));
  try {
    const bin = join(dir, 'bin'), assets = join(dir, 'assets'), pkg = join(dir, 'package'), state = join(dir, 'state.json');
    for (const path of [bin, assets, pkg]) mkdirSync(path);
    symlinkSync(resolve('tests/ci/fixtures/fake-gh-release.mjs'), join(bin, 'gh'));
    writeFileSync(state, '{}');
    let checksums = '', manifest = '';
    for (const [backend, module] of [['quickjs', 'JsBayQuickJS'], ['quickjs_ng', 'JsBayQuickJSNG'], ['jsc', 'JsBayJavaScriptCore']]) {
      const name = `jsbay-1.2.3-apple-${backend}-${module}.xcframework.zip`, content = `archive ${module}`;
      const hash = createHash('sha256').update(content).digest('hex');
      writeFileSync(join(assets, name), content); checksums += `${hash}  ${name}\n`;
      manifest += `url: "https://github.com/example/jsbay/releases/download/v1.2.3/${name}", checksum: "${hash}"\n`;
    }
    writeFileSync(join(assets, 'SHA256SUMS'), checksums); writeFileSync(join(pkg, 'Package.swift'), manifest);
    const run = (operation, ...args) => spawnSync(process.execPath, ['scripts/github-release.mjs', operation, '1.2.3', 'jsbay-package-staging-123', assets, pkg, ...args], { encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, GITHUB_REPOSITORY: 'example/jsbay', FAKE_GH_STATE: state } });
    assert.equal(run('draft').status, 0); assert.equal(run('draft').status, 0);
    let data = JSON.parse(readFileSync(state)); assert.equal(data.release.assets.length, 4); assert.equal(data.release.draft, true);
    assert.equal(run('verify').stdout.trim(), String(data.release.id));
    assert.equal(JSON.parse(readFileSync(state)).release.draft, true);
    assert.notEqual(run('publish', String(data.release.id + 1)).status, 0);
    data.release.assets[0].digest = 'sha256:incorrect'; writeFileSync(state, JSON.stringify(data));
    assert.notEqual(run('verify').status, 0); assert.notEqual(run('publish').status, 0); assert.equal(JSON.parse(readFileSync(state)).release.draft, true);
    data.release.assets[0].digest = `sha256:${createHash('sha256').update(readFileSync(join(assets, data.release.assets[0].name))).digest('hex')}`; writeFileSync(state, JSON.stringify(data));
    assert.equal(run('publish', String(data.release.id)).status, 0); assert.equal(run('publish').status, 0); assert.notEqual(run('draft').status, 0); assert.notEqual(run('verify').status, 0);
    writeFileSync(join(pkg, 'Package.swift'), 'wrong'); assert.notEqual(run('publish').status, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
