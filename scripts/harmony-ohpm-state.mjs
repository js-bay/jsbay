import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validHarmonyVersion } from './validate-harmony-version.mjs';

export const HARMONY_OHPM_STATE_MARKER = '<!-- harmony-ohpm-state:v1 -->';
export const HARMONY_OHPM_LABEL = 'harmony-ohpm-publication';
export const HARMONY_OHPM_STATUSES = Object.freeze([
  'submitting',
  'preflight-failed',
  'submitted',
  'submit-unknown',
  'public-verified',
  'install-verified',
  'install-failed',
  'device-verified',
  'device-failed',
  'timeout-unknown',
]);

const backends = new Set(['quickjs', 'quickjs_ng']);
const hex = (length) => new RegExp(`^[a-f0-9]{${length}}$`);
const runNumber = (value) => /^[1-9]\d*$/.test(String(value ?? ''));
const attemptId = (attempt) => `${attempt.run_id}:${attempt.run_attempt ?? '1'}`;

function parseAttemptId(value) {
  const match = /^(\d+):([1-9]\d*)$/.exec(value ?? '');
  if (!match) throw new Error('Attempt ID must use run_id:run_attempt format');
  return { runId: match[1], runAttempt: match[2] };
}

function validateState(state) {
  if (!state || state.schema !== 1 || !validHarmonyVersion(state.version) || !backends.has(state.backend) || !HARMONY_OHPM_STATUSES.includes(state.status)) {
    throw new Error('Invalid Harmony OHPM state');
  }
  if (state.release_tag !== `v${state.version}` || !/^\d+$/.test(state.release_id ?? '') || !hex(40).test(state.source_sha ?? '')) {
    throw new Error('Invalid Harmony OHPM release identity');
  }
  const expectedAsset = `jsbay-${state.version}-harmony-${state.backend}-arm64-v8a.har`;
  if (state.asset_name !== expectedAsset || !hex(64).test(state.sha256 ?? '') || !hex(128).test(state.sha512 ?? '')) {
    throw new Error('Invalid Harmony OHPM asset identity');
  }
  if (!Array.isArray(state.attempts) || !state.attempts.length || !Array.isArray(state.events) || !state.events.length) {
    throw new Error('Invalid Harmony OHPM history');
  }
  for (const attempt of state.attempts) {
    if (!/^\d+$/.test(attempt.run_id ?? '') || (attempt.run_attempt !== undefined && !runNumber(attempt.run_attempt)) || !Number.isFinite(Date.parse(attempt.started_at)) || !['submitting', 'preflight-failed', 'submitted', 'submit-unknown'].includes(attempt.outcome)) {
      throw new Error('Invalid Harmony OHPM attempt');
    }
  }
  for (const event of state.events) {
    if (!HARMONY_OHPM_STATUSES.includes(event.status) || !/^\d+$/.test(event.run_id ?? '') || (event.run_attempt !== undefined && !runNumber(event.run_attempt)) || !Number.isFinite(Date.parse(event.time))) {
      throw new Error('Invalid Harmony OHPM event');
    }
  }
  return state;
}

export function renderIssueTitle(state) {
  validateState(state);
  return `[harmony-ohpm] ${state.version} ${state.backend}`;
}

export function renderIssueState(state) {
  validateState(state);
  return `${HARMONY_OHPM_STATE_MARKER}\n\`\`\`json\n${JSON.stringify(state, null, 2)}\n\`\`\`\n`;
}

export function parseIssueState(body) {
  if (typeof body !== 'string' || body.split(HARMONY_OHPM_STATE_MARKER).length !== 2) {
    throw new Error('Issue must contain exactly one Harmony OHPM state marker');
  }
  const match = body.match(/<!-- harmony-ohpm-state:v1 -->\s*```json\s*([\s\S]*?)\s*```/);
  if (!match) throw new Error('Issue is missing the Harmony OHPM JSON state block');
  let state;
  try {
    state = JSON.parse(match[1]);
  } catch {
    throw new Error('Harmony OHPM issue state is not valid JSON');
  }
  return validateState(state);
}

export function createSubmissionState(identity, { runId, runAttempt = '1', time }) {
  if (!/^\d+$/.test(runId ?? '') || !runNumber(runAttempt)) throw new Error('Invalid GitHub Actions attempt identity');
  const state = {
    schema: 1,
    version: identity.version,
    backend: identity.backend,
    release_tag: identity.releaseTag,
    release_id: identity.releaseId,
    source_sha: identity.sourceSha,
    asset_name: identity.assetName,
    sha256: identity.sha256,
    sha512: identity.sha512,
    status: 'submitting',
    updated_at: time,
    attempts: [{ run_id: runId, run_attempt: String(runAttempt), started_at: time, finished_at: null, outcome: 'submitting', result: 'Submission is about to start.' }],
    events: [{ run_id: runId, run_attempt: String(runAttempt), time, status: 'submitting', result: 'Submission is about to start.' }],
  };
  return validateState(state);
}

export function stateFromIssue(issue) {
  if (!issue || typeof issue.title !== 'string') throw new Error('Invalid GitHub issue');
  const state = parseIssueState(issue.body);
  if (issue.title !== renderIssueTitle(state)) throw new Error('Harmony OHPM issue title does not match its state');
  return state;
}

export function assertIssueIdentity(issue, identity) {
  const state = stateFromIssue(issue);
  const expected = {
    version: identity.version,
    backend: identity.backend,
    release_tag: identity.releaseTag,
    release_id: identity.releaseId,
    source_sha: identity.sourceSha,
    asset_name: identity.assetName,
    sha256: identity.sha256,
    sha512: identity.sha512,
  };
  for (const [key, value] of Object.entries(expected)) {
    if (state[key] !== value) throw new Error(`Harmony OHPM issue ${key} does not match the verified release`);
  }
  return state;
}

export function classifyPublishOutcome(outcome, requestStarted) {
  if (outcome === 'success') return 'submitted';
  if (outcome === 'failure' || outcome === 'skipped') {
    return requestStarted === 'true' ? 'submit-unknown' : 'preflight-failed';
  }
  throw new Error(`Cannot classify OHPM publish outcome: ${outcome}`);
}

export function transitionIssueState(issue, nextStatus, { runId, runAttempt = '1', attemptId: providedAttemptId, time, result, confirmedAttemptId }) {
  const state = stateFromIssue(issue);
  const currentAttemptId = attemptId(state.attempts.at(-1));
  const operationAttemptId = providedAttemptId ?? `${runId}:${runAttempt}`;
  const operation = parseAttemptId(operationAttemptId);
  if (!HARMONY_OHPM_STATUSES.includes(nextStatus) || operation.runId !== String(runId ?? operation.runId) || !Number.isFinite(Date.parse(time)) || typeof result !== 'string' || !result.trim()) {
    throw new Error('Invalid Harmony OHPM state transition request');
  }
  const previous = state.status;
  let allowed = false;
  if (nextStatus === 'submitting') {
    const uncertain = ['submitting', 'submit-unknown', 'timeout-unknown'].includes(previous);
    if (uncertain && !confirmedAttemptId) {
      throw new Error('Retry requires manual confirmation that OHPM did not accept the previous request');
    }
    allowed = (uncertain && confirmedAttemptId === currentAttemptId && operationAttemptId !== currentAttemptId) || previous === 'preflight-failed';
    if (uncertain && confirmedAttemptId !== currentAttemptId) {
      throw new Error(`Confirmed attempt ID does not match the current uncertain attempt ${currentAttemptId}`);
    }
  } else if (nextStatus === 'submitted' || nextStatus === 'submit-unknown') {
    allowed = previous === 'submitting';
    if (allowed && operationAttemptId !== currentAttemptId) {
      throw new Error(`Attempt ${operationAttemptId} does not own the current attempt ${currentAttemptId}`);
    }
  } else if (nextStatus === 'preflight-failed') {
    allowed = previous === 'submitting' && operationAttemptId === currentAttemptId;
  } else if (nextStatus === 'public-verified') {
    allowed = ['submitting', 'submitted', 'submit-unknown', 'timeout-unknown'].includes(previous);
  } else if (nextStatus === 'install-verified' || nextStatus === 'install-failed') {
    allowed = ['public-verified', 'submitted', 'submit-unknown'].includes(previous);
  } else if (nextStatus === 'device-verified' || nextStatus === 'device-failed') {
    allowed = previous === 'install-verified';
  } else if (nextStatus === 'timeout-unknown') {
    allowed = ['submitting', 'submitted', 'submit-unknown'].includes(previous);
  }
  if (!allowed) throw new Error(`Invalid Harmony OHPM transition: ${previous} -> ${nextStatus}`);

  const safeResult = result.slice(0, 500);
  if (nextStatus === 'submitting') {
    if (previous === 'submitting') {
      const uncertainAttempt = state.attempts.at(-1);
      uncertainAttempt.finished_at = time;
      uncertainAttempt.outcome = 'submit-unknown';
      uncertainAttempt.result = 'The previous run ended before recording a response; a manual retry was authorized.';
    }
    const startResult = previous === 'preflight-failed'
      ? 'Automatically resuming after the prior OHPM publish step was confirmed skipped.'
      : 'Manual retry authorized after checking the OHPM console.';
    state.attempts.push({ run_id: operation.runId, run_attempt: operation.runAttempt, started_at: time, finished_at: null, outcome: 'submitting', result: startResult });
  } else if (nextStatus === 'submitted' || nextStatus === 'submit-unknown') {
    const attempt = state.attempts.at(-1);
    attempt.finished_at = time;
    attempt.outcome = nextStatus;
    attempt.result = safeResult;
  } else if (nextStatus === 'preflight-failed') {
    const attempt = state.attempts.at(-1);
    attempt.finished_at = time;
    attempt.outcome = nextStatus;
    attempt.result = safeResult;
  }
  state.status = nextStatus;
  state.updated_at = time;
  state.events.push({ run_id: operation.runId, run_attempt: operation.runAttempt, time, status: nextStatus, result: safeResult });
  return validateState(state);
}

async function main(args) {
  if (args[0] === 'create' && args.length === 2) {
    const input = JSON.parse(readFileSync(args[1], 'utf8'));
    process.stdout.write(renderIssueState(createSubmissionState(input.identity, input.attempt)));
    return;
  }
  if (args[0] === 'title' && args.length === 2) {
    const input = JSON.parse(readFileSync(args[1], 'utf8'));
    process.stdout.write(`${renderIssueTitle(createSubmissionState(input.identity, input.attempt))}\n`);
    return;
  }
  if (args[0] === 'validate-identity' && args.length === 3) {
    const issue = JSON.parse(readFileSync(args[1], 'utf8'));
    const input = JSON.parse(readFileSync(args[2], 'utf8'));
    assertIssueIdentity(issue, input.identity);
    process.stdout.write('Harmony OHPM issue identity matches the verified release.\n');
    return;
  }
  if (args[0] === 'transition' && args.length >= 6) {
    const issue = JSON.parse(readFileSync(args[1], 'utf8'));
    const [status, operationAttemptId, time, result, confirmationFlag, confirmedAttemptId] = args.slice(2);
    const operation = parseAttemptId(operationAttemptId);
    if (confirmationFlag !== undefined && confirmationFlag !== '--confirmed-attempt') throw new Error('Expected --confirmed-attempt <run-id:run-attempt>');
    const state = transitionIssueState(issue, status, { ...operation, attemptId: operationAttemptId, time, result, confirmedAttemptId });
    process.stdout.write(renderIssueState(state));
    return;
  }
  throw new Error('Usage: harmony-ohpm-state.mjs create <input.json> | transition <issue.json> <status> <run-id:run-attempt> <timestamp> <result> [--confirmed-attempt <run-id:run-attempt>]');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
