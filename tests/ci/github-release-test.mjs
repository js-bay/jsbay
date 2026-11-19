import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';

test('draft retries preserve assets and publication pins the verified Swift commit', () => {
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
    mkdirSync(join(pkg, 'Sources'));
    writeFileSync(join(pkg, 'Sources', 'Wrapper.swift'), 'public struct Wrapper {}\n');
    const legacyTarget = 'jsbay-package-staging-123';
    const source = join(dir, 'source'), remote = join(dir, 'remote.git');
    mkdirSync(source);
    const git = (...args) => execFileSync('git', args, { encoding: 'utf8', cwd: source });
    git('init', '--quiet', '--bare', remote);
    git('init', '--quiet');
    git('config', 'user.name', 'Release Test');
    git('config', 'user.email', 'release@example.invalid');
    writeFileSync(join(source, 'build.zig.zon'), '.{\n    .version = "1.2.3",\n}\n');
    git('add', 'build.zig.zon');
    git('commit', '--quiet', '-m', 'Release source');
    git('remote', 'add', 'origin', remote);
    const sourceSha = git('rev-parse', 'HEAD').trim();
    const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, GITHUB_REPOSITORY: 'example/jsbay', FAKE_GH_STATE: state };
    execFileSync('bash', [resolve('scripts/create-swift-package-tag.sh'), pkg, '1.2.3', sourceSha], {
      cwd: source, env: { ...env, JSBAY_PACKAGE_REF: `refs/heads/${legacyTarget}` }, stdio: 'pipe',
    });
    const packageSha = git('--git-dir', remote, 'rev-parse', `refs/heads/${legacyTarget}`).trim();
    const runStaged = operation => spawnSync('bash', [resolve('scripts/verify-staged-release.sh'), operation, '1.2.3', sourceSha, '123', assets, pkg], { encoding: 'utf8', cwd: source, env });
    const run = (operation, ...args) => spawnSync(process.execPath, ['scripts/github-release.mjs', operation, '1.2.3', packageSha, assets, pkg, ...args], { encoding: 'utf8', env });
    assert.equal(runStaged('draft').status, 0); assert.equal(runStaged('draft').status, 0);
    let data = JSON.parse(readFileSync(state)); assert.equal(data.release.assets.length, 4); assert.equal(data.release.draft, true);
    assert.equal(data.release.target_commitish, packageSha);
    const stagingRef = `refs/heads/${legacyTarget}`;
    const recreated = git('commit-tree', `${packageSha}^{tree}`, '-p', sourceSha, '-m', 'Recreated package commit').trim();
    git('push', '--quiet', `--force-with-lease=${stagingRef}:${packageSha}`, 'origin', `${recreated}:${stagingRef}`);
    assert.match(runStaged('publish').stderr, /release target does not match/);
    assert.equal(JSON.parse(readFileSync(state)).publication, undefined);
    git('push', '--quiet', `--force-with-lease=${stagingRef}:${recreated}`, 'origin', `${packageSha}:${stagingRef}`);
    assert.equal(run('verify').stdout.trim(), String(data.release.id));
    assert.equal(JSON.parse(readFileSync(state)).release.draft, true);
    assert.match(run('verify-published').stderr, /release is still a draft/);
    assert.notEqual(run('publish', String(data.release.id + 1)).status, 0);
    for (const target of [legacyTarget, 'b'.repeat(40)]) {
      data.release.target_commitish = target;
      writeFileSync(state, JSON.stringify(data));
      assert.match(run('verify').stderr, /release target does not match/);
      assert.match(run('publish', String(data.release.id)).stderr, /release target does not match/);
      const rejected = JSON.parse(readFileSync(state));
      assert.equal(rejected.release.draft, true);
      assert.equal(rejected.publication, undefined);
    }
    data.release.target_commitish = packageSha;
    data.release.assets[0].digest = 'sha256:incorrect'; writeFileSync(state, JSON.stringify(data));
    assert.notEqual(run('verify').status, 0); assert.notEqual(run('publish').status, 0); assert.equal(JSON.parse(readFileSync(state)).release.draft, true);
    data.release.assets[0].digest = `sha256:${createHash('sha256').update(readFileSync(join(assets, data.release.assets[0].name))).digest('hex')}`; writeFileSync(state, JSON.stringify(data));
    assert.equal(run('publish', String(data.release.id)).status, 0); assert.equal(run('publish').status, 0); assert.notEqual(run('draft').status, 0); assert.notEqual(run('verify').status, 0);
    data = JSON.parse(readFileSync(state));
    assert.deepEqual(data.publication, { tag_name: 'v1.2.3', target_commitish: packageSha });
    assert.equal(run('verify-published').status, 0);
    data.release.target_commitish = legacyTarget;
    const published = JSON.stringify(data);
    writeFileSync(state, published);
    assert.notEqual(run('verify-published').status, 0);
    assert.equal(run('verify-published', '', legacyTarget).status, 0);
    assert.equal(readFileSync(state, 'utf8'), published);
    writeFileSync(join(pkg, 'Package.swift'), 'wrong'); assert.notEqual(run('publish').status, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
