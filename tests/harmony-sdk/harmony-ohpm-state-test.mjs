import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { assertIssueIdentity, classifyPublishOutcome, createSubmissionState, parseIssueState, renderIssueState, renderIssueTitle, transitionIssueState } from '../../scripts/harmony-ohpm-state.mjs';

assert.equal(classifyPublishOutcome('success', 'true'), 'submitted');
assert.equal(classifyPublishOutcome('failure', ''), 'preflight-failed');
assert.equal(classifyPublishOutcome('skipped', ''), 'preflight-failed');
assert.equal(classifyPublishOutcome('failure', 'true'), 'submit-unknown');
assert.equal(classifyPublishOutcome('skipped', 'true'), 'submit-unknown');
assert.throws(() => classifyPublishOutcome('cancelled', ''), /Cannot classify/);

const identity = {
  version: '1.2.3-rc.1',
  backend: 'quickjs_ng',
  releaseTag: 'v1.2.3-rc.1',
  releaseId: '123456',
  sourceSha: 'a'.repeat(40),
  assetName: 'jsbay-1.2.3-rc.1-harmony-quickjs_ng-arm64-v8a.har',
  sha256: 'b'.repeat(64),
  sha512: createHash('sha512').update('the verified HAR bytes').digest('hex'),
};
assert.match(identity.sha512, /^[a-f0-9]{128}$/);

const initial = createSubmissionState(identity, { runId: '77', runAttempt: '1', time: '2026-11-19T12:00:00.000Z' });
assert.equal(initial.status, 'submitting');
assert.equal(initial.attempts.length, 1);
const issue = { title: '[harmony-ohpm] 1.2.3-rc.1 quickjs_ng', body: renderIssueState(initial) };
assert.deepEqual(parseIssueState(issue.body), initial);
assert.equal(assertIssueIdentity(issue, { ...identity, releaseTag: identity.releaseTag, releaseId: identity.releaseId, sourceSha: identity.sourceSha, assetName: identity.assetName, sha256: identity.sha256, sha512: identity.sha512 }).status, 'submitting');
assert.throws(() => assertIssueIdentity(issue, { ...identity, sha256: 'd'.repeat(64) }), /does not match/);
assert.throws(() => parseIssueState(`${issue.body}\n${issue.body}`), /exactly one/);
assert.throws(() => parseIssueState('<!-- harmony-ohpm-state:v1 -->\n```json\n{}\n```'), /Invalid/);

assert.throws(() => transitionIssueState(issue, 'submitted', { runId: '78', runAttempt: '1', time: '2026-11-19T12:01:00.000Z', result: 'wrong run' }), /does not own the current attempt/);
assert.throws(() => transitionIssueState(issue, 'submitted', { runId: '77', runAttempt: '2', time: '2026-11-19T12:01:00.000Z', result: 'wrong rerun attempt' }), /does not own the current attempt/);
const submitted = transitionIssueState(issue, 'submitted', { runId: '77', runAttempt: '1', time: '2026-11-19T12:01:00.000Z', result: 'ohpm publish exited successfully' });
assert.equal(submitted.status, 'submitted');
assert.equal(submitted.attempts[0].result, 'ohpm publish exited successfully');
const verifiedIssue = { ...issue, body: renderIssueState(submitted) };
const verified = transitionIssueState(verifiedIssue, 'install-verified', { runId: '88', runAttempt: '1', time: '2026-11-20T12:00:00.000Z', result: 'registry integrity and consumer build passed' });
assert.equal(verified.status, 'install-verified');
assert.equal(verified.release_id, identity.releaseId);
assert.equal(verified.attempts.length, 1);
assert.throws(() => transitionIssueState({ ...issue, body: renderIssueState(initial) }, 'device-verified', { runId: '89', runAttempt: '1', time: '2026-11-20T12:01:00.000Z', result: 'device pass' }), /Invalid Harmony OHPM transition/);
assert.equal(transitionIssueState({ ...issue, body: renderIssueState(verified) }, 'device-verified', { runId: '89', runAttempt: '1', time: '2026-11-20T12:01:00.000Z', result: 'device pass' }).status, 'device-verified');

const unknown = transitionIssueState(issue, 'submit-unknown', { runId: '77', runAttempt: '1', time: '2026-11-19T12:02:00.000Z', result: 'publish request outcome is uncertain' });
assert.equal(unknown.attempts[0].result, 'publish request outcome is uncertain');
const preflightFailed = transitionIssueState(issue, 'preflight-failed', { runId: '77', runAttempt: '1', time: '2026-11-19T12:02:00.000Z', result: 'OHPM publish step was skipped before a request was sent.' });
assert.equal(preflightFailed.attempts[0].outcome, 'preflight-failed');
const resumed = transitionIssueState({ ...issue, body: renderIssueState(preflightFailed) }, 'submitting', { runId: '91', runAttempt: '1', time: '2026-11-21T12:00:00.000Z', result: 'Retry after confirmed preflight failure.' });
assert.equal(resumed.attempts.length, 2);
assert.equal(resumed.attempts[1].run_id, '91');
assert.equal(resumed.attempts[1].result, 'Automatically resuming after the prior OHPM publish step was confirmed skipped.');
assert.throws(() => transitionIssueState({ ...issue, body: renderIssueState(unknown) }, 'submitting', { runId: '91', runAttempt: '1', time: '2026-11-21T12:00:00.000Z', result: 'must confirm unknown attempt' }), /manual confirmation/);
assert.throws(() => transitionIssueState({ ...issue, body: renderIssueState(submitted) }, 'submitting', { runId: '90', runAttempt: '1', time: '2026-11-20T12:00:00.000Z', result: 'retry', confirmedAttemptId: '77:1' }), /Invalid Harmony OHPM transition/);
assert.throws(() => transitionIssueState({ ...issue, body: renderIssueState(unknown) }, 'submitting', { runId: '91', runAttempt: '1', time: '2026-11-21T12:00:00.000Z', result: 'manual retry', confirmedAttemptId: '77:2' }), /does not match the current uncertain attempt/);
const retried = transitionIssueState({ ...issue, body: renderIssueState(unknown) }, 'submitting', { runId: '91', runAttempt: '1', time: '2026-11-21T12:00:00.000Z', result: 'manual retry', confirmedAttemptId: '77:1' });
assert.equal(retried.attempts.length, 2);
assert.equal(retried.attempts[1].run_id, '91');
assert.equal(retried.attempts[1].run_attempt, '1');
assert.throws(() => transitionIssueState({ ...issue, body: renderIssueState(retried) }, 'submitting', { runId: '92', runAttempt: '1', time: '2026-11-22T12:00:00.000Z', result: 'stale queued retry', confirmedAttemptId: '77:1' }), /does not match the current uncertain attempt 91:1/);
assert.throws(() => transitionIssueState({ ...issue, body: renderIssueState(unknown) }, 'submitting', { runId: '91', runAttempt: '1', time: '2026-11-21T12:00:00.000Z', result: 'manual retry' }), /manual confirmation/);
assert.throws(() => transitionIssueState({ ...issue, title: '[harmony-ohpm] 9.9.9 quickjs_ng' }, 'submitted', { runId: '77', runAttempt: '1', time: '2026-11-19T12:01:00.000Z', result: 'ok' }), /title/);

const temp = mkdtempSync(join(tmpdir(), 'jsbay-ohpm-state-test-'));
try {
  const inputPath = join(temp, 'input.json');
  const issuePath = join(temp, 'issue.json');
  const identityInput = { identity, attempt: { runId: '77', runAttempt: '1', time: '2026-11-19T12:00:00.000Z' } };
  writeFileSync(inputPath, JSON.stringify(identityInput));
  const cliBody = execFileSync(process.execPath, [resolve('scripts/harmony-ohpm-state.mjs'), 'create', inputPath], { encoding: 'utf8' });
  assert.deepEqual(parseIssueState(cliBody), initial);
  writeFileSync(issuePath, JSON.stringify({ title: renderIssueTitle(initial), body: cliBody }));
  const transitionedBody = execFileSync(process.execPath, [resolve('scripts/harmony-ohpm-state.mjs'), 'transition', issuePath, 'submitted', '77:1', '2026-11-19T12:01:00.000Z', 'accepted'], { encoding: 'utf8' });
  assert.equal(parseIssueState(transitionedBody).status, 'submitted');
  const unknownIssue = { title: renderIssueTitle(initial), body: renderIssueState(unknown) };
  writeFileSync(issuePath, JSON.stringify(unknownIssue));
  assert.throws(() => execFileSync(process.execPath, [resolve('scripts/harmony-ohpm-state.mjs'), 'transition', issuePath, 'submitting', '91:1', '2026-11-21T12:00:00.000Z', 'retry', '--confirmed-attempt', '77:2'], { encoding: 'utf8', stdio: 'pipe' }));
  const retryBody = execFileSync(process.execPath, [resolve('scripts/harmony-ohpm-state.mjs'), 'transition', issuePath, 'submitting', '91:1', '2026-11-21T12:00:00.000Z', 'retry', '--confirmed-attempt', '77:1'], { encoding: 'utf8' });
  assert.equal(parseIssueState(retryBody).attempts[1].run_id, '91');
  writeFileSync(issuePath, JSON.stringify({ title: renderIssueTitle(initial), body: renderIssueState(preflightFailed) }));
  const preflightRetryBody = execFileSync(process.execPath, [resolve('scripts/harmony-ohpm-state.mjs'), 'transition', issuePath, 'submitting', '92:1', '2026-11-22T12:00:00.000Z', 'automatic retry after skipped publish'], { encoding: 'utf8' });
  assert.equal(parseIssueState(preflightRetryBody).attempts.at(-1).run_id, '92');
} finally {
  rmSync(temp, { recursive: true, force: true });
}
console.log('Harmony OHPM state tests passed.');
