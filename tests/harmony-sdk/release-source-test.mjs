import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { verifyHarmonyReleaseSource } from '../../scripts/verify-harmony-release-source.mjs';

const directory = mkdtempSync(join(tmpdir(), 'jsbay-harmony-release-source-'));
try {
  const version = '1.2.3-rc.1';
  const backend = 'quickjs_ng';
  const runId = '2458';
  const sourceSha = 'a'.repeat(40);
  const assetName = `jsbay-${version}-harmony-${backend}-arm64-v8a.har`;
  const artifactHar = join(directory, assetName);
  const publishedHar = join(directory, 'published.har');
  const artifactSums = join(directory, 'artifact.SHA256SUMS');
  const publishedSums = join(directory, 'published.SHA256SUMS');
  const harBytes = Buffer.from('original checked HAR');
  const sha = createHash('sha256').update(harBytes).digest('hex');
  writeFileSync(artifactHar, harBytes);
  writeFileSync(publishedHar, harBytes);
  writeFileSync(artifactSums, `${sha}  ${assetName}\n`);
  writeFileSync(publishedSums, readFileSync(artifactSums));

  const release = {
    tag_name: `v${version}`,
    draft: false,
    assets: [
      { name: assetName, state: 'uploaded', digest: `sha256:${sha}` },
      { name: 'SHA256SUMS', state: 'uploaded', digest: `sha256:${createHash('sha256').update(readFileSync(publishedSums)).digest('hex')}` },
    ],
  };
  const run = { id: Number(runId), path: '.github/workflows/release.yml', head_sha: sourceSha, status: 'in_progress' };
  const input = { version, backend, originalRunId: runId, sourceSha, run, release, artifactHar, publishedHar, artifactSums, publishedSums };
  assert.deepEqual(verifyHarmonyReleaseSource(input), { assetName, sha256: sha }, 'an active original Release run is valid when its asset is already uploaded');
  assert.throws(() => verifyHarmonyReleaseSource({ ...input, originalRunId: '2459' }), /original Release run/);
  assert.throws(() => verifyHarmonyReleaseSource({ ...input, run: { ...run, head_sha: 'b'.repeat(40) } }), /original Release run/);
  assert.throws(() => verifyHarmonyReleaseSource({ ...input, run: { ...run, path: '.github/workflows/other.yml' } }), /original Release run/);
  assert.throws(() => verifyHarmonyReleaseSource({ ...input, release: { ...release, assets: release.assets.slice(1) } }), /missing or duplicate Harmony HAR/);
  writeFileSync(publishedHar, 'replacement HAR');
  assert.throws(() => verifyHarmonyReleaseSource(input), /differs from the published Release asset/);
  writeFileSync(publishedHar, harBytes);
  writeFileSync(artifactSums, `0  ${assetName}\n`);
  assert.throws(() => verifyHarmonyReleaseSource(input), /SHA256SUMS/);
  writeFileSync(artifactSums, `${sha}  ${assetName}\n`);
  writeFileSync(publishedSums, 'replacement manifest\n');
  assert.throws(() => verifyHarmonyReleaseSource(input), /published SHA256SUMS/);
} finally {
  rmSync(directory, { recursive: true, force: true });
}

const publishWorkflow = readFileSync(new URL('../../.github/workflows/harmony-ohpm-publish.yml', import.meta.url), 'utf8');
const releaseWorkflow = readFileSync(new URL('../../.github/workflows/release.yml', import.meta.url), 'utf8');
assert.match(publishWorkflow, /release_run_id:[\s\S]*?required: true/);
assert.match(publishWorkflow, /release_artifact_id:[\s\S]*?required: true/);
assert.match(publishWorkflow, /actions: read/);
assert.match(publishWorkflow, /artifact-ids: \$\{\{ inputs\.release_artifact_id \}\}[\s\S]*?run-id: \$\{\{ inputs\.release_run_id \}\}[\s\S]*?merge-multiple: true/);
assert.match(publishWorkflow, /no Harmony HAR for \$BACKEND[\s\S]*?The GitHub Release remains published/);
assert.match(publishWorkflow, /Original Release artifact has no SHA256SUMS/);
assert.match(publishWorkflow, /verify-harmony-release-source\.mjs/);
assert.ok(publishWorkflow.indexOf('name: Validate original Release run ID') < publishWorkflow.indexOf('name: Download assets from the original Release run'));
assert.match(releaseWorkflow, /RELEASE_RUN_ID: \$\{\{ inputs\.recovery_run_id \|\| github\.run_id \}\}/);
assert.match(releaseWorkflow, /steps\.upload-final-assets\.outputs\.artifact-id/);
assert.match(releaseWorkflow, /needs: \[publish-release, prepare-swift-package-release-assets, verify-release-recovery\]/);
assert.match(releaseWorkflow, /RELEASE_ARTIFACT_ID: \$\{\{ inputs\.recovery_run_id != '' && needs\.verify-release-recovery\.outputs\.assets_id \|\| needs\.prepare-swift-package-release-assets\.outputs\.assets_id \}\}/);
assert.match(releaseWorkflow, /-f release_run_id="\$RELEASE_RUN_ID" -f release_artifact_id="\$RELEASE_ARTIFACT_ID"/);
