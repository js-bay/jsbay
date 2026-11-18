import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { closeSync, openSync, readFileSync, readdirSync, readSync, statSync } from 'node:fs';
import { basename, join } from 'node:path';

const [operation, version, target, directory, packageDir, expectedReleaseId] = process.argv.slice(2);
const repository = process.env.GITHUB_REPOSITORY;
if (!['draft', 'verify', 'publish'].includes(operation) || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version ?? '') || !/^jsbay-package-staging-[0-9]+$/.test(target ?? '') || !directory || !packageDir || !/^[\w.-]+\/[\w.-]+$/.test(repository ?? '') || (expectedReleaseId && !/^[1-9]\d*$/.test(expectedReleaseId))) throw new Error('invalid release arguments');
const tag = `v${version}`;
const endpoint = `repos/${repository}/releases`;
const api = (...args) => JSON.parse(execFileSync('gh', ['api', ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] }));
const assets = readdirSync(directory).filter(name => statSync(join(directory, name)).isFile()).sort();
if (!assets.length || !assets.includes('SHA256SUMS')) throw new Error('release assets or SHA256SUMS missing');
function sha256(path) {
  const file = openSync(path, 'r');
  const hash = createHash('sha256');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  try {
    for (let count; (count = readSync(file, buffer, 0, buffer.length, null)) > 0;) hash.update(buffer.subarray(0, count));
    return `sha256:${hash.digest('hex')}`;
  } finally { closeSync(file); }
}
const hashes = new Map(assets.map(name => [name, sha256(join(directory, name))]));
const manifest = readFileSync(join(directory, 'SHA256SUMS'), 'utf8');
for (const name of assets.filter(name => name !== 'SHA256SUMS')) {
  if (!manifest.split('\n').includes(`${hashes.get(name).slice(7)}  ${name}`)) throw new Error(`SHA256SUMS mismatch: ${name}`);
}
const swiftManifest = readFileSync(join(packageDir, 'Package.swift'), 'utf8');
for (const [backend, module] of [['quickjs', 'JsBayQuickJS'], ['quickjs_ng', 'JsBayQuickJSNG'], ['jsc', 'JsBayJavaScriptCore']]) {
  const name = `jsbay-${version}-apple-${backend}-${module}.xcframework.zip`;
  const checksum = hashes.get(name);
  const declaration = `url: "https://github.com/${repository}/releases/download/${tag}/${name}", checksum: "${checksum?.slice(7)}"`;
  if (!checksum || !swiftManifest.includes(declaration)) throw new Error(`Swift package checksum mismatch: ${name}`);
}
let releases = api('--paginate', '--slurp', `${endpoint}?per_page=100`).flat().filter(release => release.tag_name === tag);
if (releases.length > 1) throw new Error(`multiple releases for ${tag}`);
let release = releases[0];
if (!release && operation === 'draft') {
  release = api('--method', 'POST', endpoint, '-f', `tag_name=${tag}`, '-f', `target_commitish=${target}`, '-f', `name=JS Bay ${tag}`, '-f', 'body=Release assets and package metadata for JS Bay.', '-F', 'draft=true', '-F', `prerelease=${version.includes('-')}`);
}
if (!release) throw new Error(`release not found: ${tag}`);
if (expectedReleaseId && String(release.id) !== expectedReleaseId) throw new Error('release ID changed since verification');
if (release.target_commitish !== target) throw new Error('release target does not match this workflow run');
const remoteAssets = api('--paginate', '--slurp', `${endpoint}/${release.id}/assets?per_page=100`).flat();
for (const remote of remoteAssets) {
  if (!hashes.has(remote.name) || hashes.get(remote.name) !== remote.digest) throw new Error(`existing release asset differs: ${remote.name}`);
}
if (operation === 'draft') {
  if (!release.draft) throw new Error('release is already published');
  for (const name of assets) {
    if (remoteAssets.some(asset => asset.name === name)) continue;
    const url = `${release.upload_url.split('{')[0]}?name=${encodeURIComponent(basename(name))}`;
    api('--method', 'POST', '-H', 'Content-Type: application/octet-stream', url, '--input', join(directory, name));
  }
} else {
  if (remoteAssets.length !== assets.length) throw new Error('release assets are incomplete');
  if (operation === 'verify') {
    if (!release.draft) throw new Error('the original release is already published');
    console.log(release.id);
  }
  if (operation === 'publish' && release.draft) api('--method', 'PATCH', `${endpoint}/${release.id}`, '-F', 'draft=false');
}
