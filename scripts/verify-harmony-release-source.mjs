import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function manifestHas(manifest, digest, name) {
  return manifest.split('\n').filter(line => line === `${digest}  ${name}`).length === 1;
}

export function verifyHarmonyReleaseSource({ version, backend, originalRunId, sourceSha, run, release, artifactHar, publishedHar, artifactSums, publishedSums }) {
  if (!/^[1-9][0-9]*$/.test(String(originalRunId))) throw new Error('invalid original Release run ID');
  if (!/^[a-f0-9]{40}$/.test(sourceSha)) throw new Error('invalid source commit');
  if (String(run.id) !== String(originalRunId) || run.path !== '.github/workflows/release.yml' || run.head_sha !== sourceSha) throw new Error('original Release run does not match the source commit');
  if (release.tag_name !== `v${version}` || release.draft !== false) throw new Error('published Release identity mismatch');

  const assetName = `jsbay-${version}-harmony-${backend}-arm64-v8a.har`;
  const matchingAssets = release.assets.filter(asset => asset.name === assetName && asset.state === 'uploaded');
  if (matchingAssets.length !== 1) throw new Error('missing or duplicate Harmony HAR release asset');
  const publishedDigest = matchingAssets[0].digest;
  if (!/^sha256:[a-f0-9]{64}$/.test(publishedDigest)) throw new Error('GitHub Release HAR digest is unavailable');

  const artifactDigest = sha256(artifactHar);
  const downloadedDigest = sha256(publishedHar);
  if (artifactDigest !== downloadedDigest || artifactDigest !== publishedDigest.slice('sha256:'.length)) throw new Error('original run HAR differs from the published Release asset');

  const manifestAssets = release.assets.filter(asset => asset.name === 'SHA256SUMS' && asset.state === 'uploaded');
  if (manifestAssets.length !== 1 || !/^sha256:[a-f0-9]{64}$/.test(manifestAssets[0].digest)) throw new Error('missing or duplicate SHA256SUMS release asset');
  if (sha256(publishedSums) !== manifestAssets[0].digest.slice('sha256:'.length)) throw new Error('published SHA256SUMS differs from its Release digest');
  const artifactManifest = readFileSync(artifactSums, 'utf8');
  const publishedManifest = readFileSync(publishedSums, 'utf8');
  if (artifactManifest !== publishedManifest || !manifestHas(artifactManifest, artifactDigest, assetName)) throw new Error('original run HAR does not match the published SHA256SUMS manifest');
  return { assetName, sha256: artifactDigest };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [version, backend, originalRunId, sourceSha, runPath, releasePath, artifactHar, publishedHar, artifactSums, publishedSums] = process.argv.slice(2);
  if (!version || !backend || !originalRunId || !sourceSha || !runPath || !releasePath || !artifactHar || !publishedHar || !artifactSums || !publishedSums) throw new Error('usage: verify-harmony-release-source.mjs VERSION BACKEND ORIGINAL_RUN_ID SOURCE_SHA RUN_JSON RELEASE_JSON ARTIFACT_HAR PUBLISHED_HAR ARTIFACT_SUMS PUBLISHED_SUMS');
  const result = verifyHarmonyReleaseSource({ version, backend, originalRunId, sourceSha, run: JSON.parse(readFileSync(runPath, 'utf8')), release: JSON.parse(readFileSync(releasePath, 'utf8')), artifactHar, publishedHar, artifactSums, publishedSums });
  console.log(`Verified ${result.assetName} from original Release run ${originalRunId} (${result.sha256}).`);
}
