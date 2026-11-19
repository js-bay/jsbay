import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { stateFromIssue } from './harmony-ohpm-state.mjs';
import { validHarmonyVersion } from './validate-harmony-version.mjs';

export function selectTrackingIssues(issues, slot = Math.floor(Date.now() / 7200000)) {
  const candidates = new Map();
  for (const issue of issues) {
    if (!Number.isSafeInteger(issue.number) || issue.number <= 0) continue;
    let state;
    try { state = stateFromIssue(issue); } catch { continue; }
    if (!['submitting', 'submitted', 'submit-unknown'].includes(state.status)) continue;
    const key = `${state.version}:${state.backend}`;
    if (candidates.has(key)) candidates.set(key, null);
    else candidates.set(key, { issue: issue.number, version: state.version, backend: state.backend });
  }
  const selected = [...candidates.values()].filter(Boolean);
  if (selected.length <= 256) return selected;
  const start = (slot * 256) % selected.length;
  return Array.from({ length: 256 }, (_, i) => selected[(start + i) % selected.length]);
}

export function untrackedReleasePackages(releases, issues, now = Date.now()) {
  const tracked = new Set();
  for (const issue of issues) {
    try {
      const state = stateFromIssue(issue);
      tracked.add(`${state.release_id}:${state.version}:${state.backend}`);
    } catch { /* Other issues are not publication records. */ }
  }
  const missing = [];
  for (const release of releases) {
    const version = typeof release.tag_name === 'string' && release.tag_name.startsWith('v') ? release.tag_name.slice(1) : '';
    const published = Date.parse(release.published_at);
    if (release.draft || !validHarmonyVersion(version) || !Number.isFinite(published) || now - published < 86400000 || !Array.isArray(release.assets)) continue;
    const backends = ['quickjs', 'quickjs_ng'];
    if (!backends.some(backend => release.assets.some(asset => asset.name === `jsbay-${version}-harmony-${backend}-arm64-v8a.har`))) continue;
    for (const backend of backends) {
      if (!tracked.has(`${release.id}:${version}:${backend}`)) missing.push(`${version} ${backend}`);
    }
  }
  return missing;
}

export function registryIntegrity(status, body, version) {
  if (!validHarmonyVersion(version)) throw new Error('Invalid package version');
  if (status === 404) return null;
  if (status !== 200) throw new Error(`OHPM returned HTTP ${status}`);
  let registry;
  try { registry = JSON.parse(body); } catch { throw new Error('Invalid OHPM JSON'); }
  if (!registry || typeof registry !== 'object' || Array.isArray(registry) || (registry.versions != null && (typeof registry.versions !== 'object' || Array.isArray(registry.versions)))) throw new Error('Invalid OHPM metadata');
  const entry = registry.versions?.[version];
  if (entry == null) return null;
  const integrity = entry?.dist?.integrity;
  if (typeof integrity !== 'string' || !integrity.startsWith('sha512-')) throw new Error('Invalid OHPM integrity');
  return integrity;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === 'probe') {
    const result = registryIntegrity(Number(process.argv[3]), readFileSync(process.argv[5], 'utf8'), process.argv[4]);
    process.stdout.write(result ?? 'not-public');
  } else if (process.argv[2] === 'reconcile') {
    const input = JSON.parse(readFileSync(0, 'utf8'));
    const missing = untrackedReleasePackages(input.releases, input.issues);
    for (const item of missing) console.error(`::error::No OHPM submission record for ${item}`);
    if (missing.length) process.exitCode = 1;
  } else {
    const input = JSON.parse(readFileSync(0, 'utf8'));
    process.stdout.write(JSON.stringify({ include: selectTrackingIssues(input) }));
  }
}
