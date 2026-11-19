import assert from 'node:assert/strict';
import { createSubmissionState, renderIssueState, renderIssueTitle } from '../../scripts/harmony-ohpm-state.mjs';
import { selectTrackingIssues, untrackedReleasePackages, registryIntegrity } from '../../scripts/harmony-ohpm-monitor.mjs';

function issue(number, version, backend, status) {
  const state = createSubmissionState({ version, backend, releaseTag: `v${version}`, releaseId: '12', sourceSha: 'a'.repeat(40), assetName: `jsbay-${version}-harmony-${backend}-arm64-v8a.har`, sha256: 'b'.repeat(64), sha512: 'c'.repeat(128) }, { runId: '1', time: '2026-01-01T00:00:00Z' });
  state.status = status;
  return { number, title: renderIssueTitle(state), body: renderIssueState(state) };
}
const input = [
  issue(1, '1.0.0', 'quickjs', 'submitted'),
  issue(2, '1.0.1', 'quickjs_ng', 'submit-unknown'),
  issue(3, '1.0.2', 'quickjs', 'submitting'),
  { number: 6, body: '<!-- harmony-ohpm-state:v1 -->\n```json\nnot-json\n```' },
  { number: 7, body: '<!-- harmony-ohpm-state:v1 -->\n```json\nnull\n```' },
];
assert.deepEqual(selectTrackingIssues(input), [
  { issue: 1, version: '1.0.0', backend: 'quickjs' },
  { issue: 2, version: '1.0.1', backend: 'quickjs_ng' },
  { issue: 3, version: '1.0.2', backend: 'quickjs' },
]);
assert.deepEqual(selectTrackingIssues([...input, issue(8, '1.0.0', 'quickjs', 'submitted')]), [
  { issue: 2, version: '1.0.1', backend: 'quickjs_ng' },
  { issue: 3, version: '1.0.2', backend: 'quickjs' },
]);
const many = Array.from({ length: 300 }, (_, i) => issue(i + 10, `1.0.${i}`, 'quickjs', 'submitted'));
const first = selectTrackingIssues(many, 0);
const second = selectTrackingIssues(many, 1);
assert.equal(first.length, 256);
assert.equal(new Set([...first, ...second].map(x => x.issue)).size, 300);

const releases = [{ id: 12, tag_name: 'v1.0.0', draft: false, published_at: '2026-01-01T00:00:00Z', assets: [
  { name: 'jsbay-1.0.0-harmony-quickjs-arm64-v8a.har' },
  { name: 'jsbay-1.0.0-harmony-quickjs_ng-arm64-v8a.har' },
] }];
assert.deepEqual(untrackedReleasePackages(releases, [input[0]], Date.parse('2026-01-03T00:00:00Z')), ['1.0.0 quickjs_ng']);
assert.deepEqual(untrackedReleasePackages(releases, [input[0]], Date.parse('2026-01-01T01:00:00Z')), []);
assert.equal(registryIntegrity(404, '', '1.0.0'), null);
assert.equal(registryIntegrity(200, '{}', '1.0.0'), null);
assert.equal(registryIntegrity(200, '{"versions":{"1.0.0":{"dist":{"integrity":"sha512-abc"}}}}', '1.0.0'), 'sha512-abc');
assert.throws(() => registryIntegrity(500, '{}', '1.0.0'), /HTTP/);
assert.throws(() => registryIntegrity(200, 'not-json', '1.0.0'), /JSON/);
assert.throws(() => registryIntegrity(200, '{"versions":{"1.0.0":{}}}', '1.0.0'), /integrity/);
