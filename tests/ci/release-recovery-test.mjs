import { strict as assert } from 'node:assert';
import { execFile, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { access, mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { promisify } from 'node:util';
import { verifyRecoveryRun } from '../../scripts/verify-release-recovery.mjs';

const repository = 'example/jsbay';
const sha = 'a'.repeat(40);
const digest = `sha256:${'b'.repeat(64)}`;
const run = {
  id: 123, name: 'Release', event: 'workflow_dispatch', status: 'completed', path: '.github/workflows/release.yml',
  head_sha: sha, repository: { id: 42, full_name: repository }, head_repository: { id: 42, full_name: repository },
};
const jobs = ['quickjs', 'quickjs_ng'].map((backend, index) => ({
  id: index + 1, name: `Publish Android package (${backend})`, run_id: 123, run_attempt: 1, status: 'completed', conclusion: 'success',
}));
const artifacts = ['jsbay-npm-packages-1', 'jsbay-swift-package', 'jsbay-final-release-assets'].map((name, index) => ({
  id: index + 10, name, digest, expired: false, workflow_run: { id: 123, repository_id: 42, head_repository_id: 42, head_sha: sha },
}));
const input = { repository, runId: '123', artifactIds: '10,11,12', run, jobs, artifacts };
const execute = promisify(execFile);

test('recovery selects only the explicit artifacts from the original release run', () => {
  const result = verifyRecoveryRun(input);
  assert.equal(result.source_sha, sha);
  assert.equal(result.npm_id, '10');
  assert.equal(result.swift_id, '11');
  assert.equal(result.assets_id, '12');
  assert.equal(result.npm_digest, digest);
  assert.throws(() => verifyRecoveryRun({ ...input, artifactIds: '10,12,11' }), /Swift package artifact/);
  assert.throws(() => verifyRecoveryRun({ ...input, artifacts: artifacts.slice(1) }), /npm.*artifact/);
  const wrongOrigin = [{ ...artifacts[0], workflow_run: { ...artifacts[0].workflow_run, id: 321 } }, ...artifacts.slice(1)];
  assert.throws(() => verifyRecoveryRun({ ...input, artifacts: wrongOrigin }), /npm.*artifact/);
  assert.throws(() => verifyRecoveryRun({ ...input, run: { ...run, path: '.github/workflows/ci.yml' } }), /original release run/);
});

test('recovery stops when either Android package failed or the original run remains active', () => {
  assert.throws(() => verifyRecoveryRun({ ...input, run: { ...run, status: 'in_progress' } }), /original release run/);
  assert.throws(() => verifyRecoveryRun({ ...input, jobs: jobs.slice(0, 1) }), /quickjs_ng/);
  const newestJob = { ...jobs[0], id: 3, run_attempt: 2, conclusion: 'failure' };
  assert.throws(() => verifyRecoveryRun({ ...input, jobs: [...jobs, newestJob] }), /quickjs/);
});

test('recovery downloads the requested artifact ID and rejects changed ZIP bytes', async () => {
  const work = await mkdtemp(join(tmpdir(), 'jsbay-recovery-test-'));
  const requests = [];
  await writeFile(join(work, 'record'), 'original artifact');
  execFileSync('zip', ['-q', 'original.zip', 'record'], { cwd: work });
  const bytes = await readFile(join(work, 'original.zip'));
  const hash = `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
  const server = createServer((request, response) => {
    requests.push([request.url, request.headers.authorization]);
    if (request.url === '/repos/example/jsbay/actions/artifacts/10/zip') {
      response.writeHead(302, { Location: `${origin}/blob` }).end();
    } else if (request.url === '/blob') {
      response.writeHead(200).end(bytes);
    } else {
      response.writeHead(404).end();
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  const env = { ...process.env, GITHUB_API_URL: origin, GITHUB_REPOSITORY: repository, GH_TOKEN: 'fixture-token' };
  const download = (id, checksum, path) => execute(process.execPath, ['scripts/verify-release-recovery.mjs', 'download', id, checksum, path], { env });
  try {
    const output = join(work, 'output');
    await download('10', hash, output);
    assert.equal(await readFile(join(output, 'record'), 'utf8'), 'original artifact');
    assert.deepEqual(requests, [['/repos/example/jsbay/actions/artifacts/10/zip', 'Bearer fixture-token'], ['/blob', undefined]]);
    const wrong = join(work, 'wrong');
    await assert.rejects(download('10', digest, wrong), /different digest/);
    await assert.rejects(access(wrong), { code: 'ENOENT' });
    await assert.rejects(download('11', hash, wrong), /HTTP 404/);
  } finally {
    await new Promise(resolve => server.close(resolve));
    await rm(work, { recursive: true, force: true });
  }
});

test('npm publication preflight checks every platform and main tarball before writing', async () => {
  const work = await mkdtemp(join(tmpdir(), 'jsbay-recovery-npm-test-'));
  const version = '1.2.3-rc.1';
  const names = ['main/jsbay-jsc', 'main/jsbay-quickjs', 'main/jsbay-quickjsng',
    'platform/jsbay-jscmacosarm64', 'platform/jsbay-jscmacosx64',
    'platform/jsbay-quickjslinuxarm64', 'platform/jsbay-quickjslinuxx64', 'platform/jsbay-quickjsmacosarm64', 'platform/jsbay-quickjsmacosx64',
    'platform/jsbay-quickjsnglinuxarm64', 'platform/jsbay-quickjsnglinuxx64', 'platform/jsbay-quickjsngmacosarm64', 'platform/jsbay-quickjsngmacosx64'];
  const preflight = (commit, operation) => execute(process.execPath, ['scripts/publish-npm-release.mjs', work, version, commit, operation], {
    env: { ...process.env, NODE_AUTH_TOKEN: 'fixture-token' },
  });
  try {
    for (const type of ['main', 'platform']) await mkdir(join(work, type));
    const checksums = [];
    for (const name of names) {
      const archive = `${name}-${version}.tgz`;
      await writeFile(join(work, archive), archive);
      checksums.push(`${createHash('sha512').update(archive).digest('hex')}  ${archive}`);
    }
    await writeFile(join(work, 'SHA512SUMS'), `${checksums.join('\n')}\n`);
    await writeFile(join(work, 'VERSION'), `${version}\n`);
    await writeFile(join(work, 'COMMIT'), `${sha}\n`);
    await preflight(sha, 'verify');
    await assert.rejects(preflight('c'.repeat(40), 'verify'), /source SHA/);
    await writeFile(join(work, `main/jsbay-quickjsng-${version}.tgz`), 'mismatched bytes');
    await assert.rejects(preflight(sha, 'publish'), /checksum mismatch: main\/jsbay-quickjsng/);
  } finally {
    await rm(work, { recursive: true, force: true });
  }
});
