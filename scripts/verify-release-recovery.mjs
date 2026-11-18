import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createReadStream, createWriteStream, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { pathToFileURL } from 'node:url';

const validId = value => /^[1-9]\d*$/.test(value ?? '');
const validSha = value => /^[a-f0-9]{40}$/.test(value ?? '');
const validDigest = value => /^sha256:[a-f0-9]{64}$/.test(value ?? '');

export function verifyRecoveryRun({ repository, runId, artifactIds, run, jobs, artifacts }) {
  const ids = artifactIds.split(',').map(id => id.trim());
  if (!validId(runId) || ids.length !== 3 || !ids.every(validId) || new Set(ids).size !== ids.length) throw new Error('expected one run ID and three distinct artifact IDs in npm, Swift package, release asset order');
  if (String(run.id) !== runId || run.name !== 'Release' || run.path?.split('@')[0] !== '.github/workflows/release.yml'
      || run.event !== 'workflow_dispatch' || run.status !== 'completed' || !validSha(run.head_sha)
      || run.repository?.full_name !== repository || run.head_repository?.id !== run.repository.id) {
    throw new Error('expected a completed original release run from this repository');
  }

  for (const backend of ['quickjs', 'quickjs_ng']) {
    const latest = jobs.filter(job => String(job.run_id) === runId && job.name === `Publish Android package (${backend})`)
      .sort((left, right) => right.run_attempt - left.run_attempt || right.id - left.id)[0];
    if (latest?.status !== 'completed' || latest.conclusion !== 'success') throw new Error(`the latest original Android publication for ${backend} did not succeed`);
  }

  const output = { source_sha: run.head_sha };
  for (const [index, key, label, expectedName] of [
    [0, 'npm', 'npm package', /^jsbay-npm-packages-[1-9]\d*$/],
    [1, 'swift', 'Swift package', /^jsbay-swift-package$/],
    [2, 'assets', 'release asset', /^jsbay-final-release-assets$/],
  ]) {
    const id = ids[index];
    const artifact = artifacts.find(item => String(item.id) === id);
    const origin = artifact?.workflow_run;
    if (!artifact || artifact.expired !== false || !expectedName.test(artifact.name) || !validDigest(artifact.digest)
        || String(origin?.id) !== runId || origin.repository_id !== run.repository.id
        || origin.head_repository_id !== run.head_repository.id || origin.head_sha !== run.head_sha) {
      throw new Error(`${label} artifact ${id} does not match the original release run`);
    }
    output[`${key}_id`] = id;
    output[`${key}_digest`] = artifact.digest;
  }
  return output;
}

async function downloadArtifact(repository, id, digest, output) {
  if (!validId(id) || !validDigest(digest) || !output) throw new Error('expected an artifact ID, SHA-256 digest and output path');
  const work = mkdtempSync(join(tmpdir(), 'jsbay-release-artifact-'));
  try {
    const archive = join(work, 'artifact.zip');
    const apiBase = process.env.GITHUB_API_URL ?? 'https://api.github.com';
    const token = process.env.GH_TOKEN;
    if (!token) throw new Error('GH_TOKEN is required to download the original artifact');
    const request = await fetch(`${apiBase}/repos/${repository}/actions/artifacts/${id}/zip`, {
      redirect: 'manual', headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json' },
    });
    const location = request.headers.get('location');
    if (request.status !== 302 || !location) throw new Error(`artifact ${id} download redirect failed (HTTP ${request.status})`);
    await request.body?.cancel();
    const response = await fetch(location);
    if (!response.ok || !response.body) throw new Error(`artifact ${id} download failed (HTTP ${response.status})`);
    await pipeline(Readable.fromWeb(response.body), createWriteStream(archive));
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(archive)) hash.update(chunk);
    if (`sha256:${hash.digest('hex')}` !== digest) throw new Error(`downloaded artifact ${id} has a different digest`);
    mkdirSync(output, { recursive: false });
    execFileSync('unzip', ['-q', archive, '-d', output], { stdio: 'inherit' });
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const repository = process.env.GITHUB_REPOSITORY;
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository ?? '')) throw new Error('GITHUB_REPOSITORY must name the release repository');
  const [operation, first, second, output] = process.argv.slice(2);
  if (operation === 'resolve' && validId(first) && second) {
    const endpoint = `repos/${repository}/actions/runs/${first}`;
    const api = (...args) => JSON.parse(execFileSync('gh', ['api', ...args], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 }));
    const run = api(endpoint);
    const jobs = api('--paginate', '--slurp', `${endpoint}/jobs?filter=all&per_page=100`).flatMap(page => page.jobs);
    const artifacts = api('--paginate', '--slurp', `${endpoint}/artifacts?per_page=100`).flatMap(page => page.artifacts);
    for (const [key, value] of Object.entries(verifyRecoveryRun({ repository, runId: first, artifactIds: second, run, jobs, artifacts }))) {
      console.log(`${key}=${value}`);
    }
  } else if (operation === 'download') {
    await downloadArtifact(repository, first, second, output);
  } else {
    throw new Error('usage: verify-release-recovery.mjs resolve <run-id> <npm-id,swift-id,assets-id> or download <artifact-id> <digest> <output-directory>');
  }
}
