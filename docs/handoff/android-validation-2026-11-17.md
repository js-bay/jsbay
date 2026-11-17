# Android validation handoff — 2026-11-17

Work stopped at the user's request, around 20:53 Asia/Shanghai (UTC+8), due to usage limits. Do not automatically resume work.

## Remote checkpoint

- Draft PR: https://github.com/js-bay/jsbay/pull/26 — keep Draft; not ready to merge.
- Branch: `research/android-validation-wip-20261117`.
- Base main: `14f9891deed1802af45ef676ac158cce74391b8b`.
- Last implementation commit: `2044b3d1557bb08e5cb4c5449eff088879598dd2`.
- Earlier checkpoints: `b836caa` (initial WIP), `b34fcb6` (owner-thread teardown), `b5b5721` (Android unit-test scripts). No force-push or history rewrite.

## Verified progress and evidence boundaries

- S1/S2 QuickJS-NG pin backports and earlier Linux evidence are retained. Linux results are not Android results.
- Android API35 x86_64 TCG: QJS and NG targeted 19/19 each passed before the latest teardown commits. Not full-suite sign-off.
- Hermes previously passed 720 with 47 skips, but that ELF predates shared inspector changes; it does not certify this head.
- Hermes object identity now uses the engine identity API with equality fallback, not raw handle bytes. Cycle/depth/DAG tests need current-head regression.
- QJS/NG pending-job deadline and inspector fixes have targeted evidence; current-head full suites remain outstanding.
- SDK QJS/NG build/AAR, Maven consumer, Java/Kotlin consumer, R8 and Inspector e2e passed with JNI built from the 20:06 source snapshot. Inspector READY default is again 15 seconds. This is not current-head JNI certification.
- QJS packaged release consumer passed. NG packaged release consumer was interrupted without an exit status; do not count it as passed.
- Escargot emutls/link problem and many CJS issues were addressed. The initial smoke passing did not imply native suite success.
- Commit 2044b3d fixes the round-3 teardown wait race: in-progress cleanup is published with the final lease decrement under the same lock, and completion is recorded only after JS cleanup returns.
- For 2044b3d, Escargot API35 x86_64 targeted teardown run: 5 passed, 0 failed/crashed/timed out, selected 5 of 785. Includes the new deterministic late-wait barrier test. ELF SHA256: e932ebb3f3a13999b7d0882e0838485cb37925c84df79709dfdf02e78cb9b564. Not a full lifecycle or suite certification.

## Remaining blockers / next steps (only after new authorization to resume)

1. Escargot cyclic CommonJS `throw undefined`, error observer, default async export and circular lexical behavior remain open. Do not silently skip or downgrade documented support.
2. Re-review the final teardown protocol; round 3 caught a real race in b34fcb6, repaired by 2044b3d. No final whole-PR approval is claimed.
3. Freeze source/vendor hashes, rebuild and run all four engines' native suites on API35. Repeat affected tests on API24. No ARM64 hardware coverage exists.
4. Rebuild current-head JNI and rerun affected SDK/Looper bounded-flush, R8, packaged consumers and Inspector tests. Do not reuse old JNI greens for new source.
5. Verify in-repository Android scripts reproduce the local builds, including Escargot emutls and state-tcas document deployment. See `scripts/android-unit-tests/` and `docs/android-unit-tests.md`.
6. Keep PR Draft until remaining failures and multi-round review are closed. Never remove assertions, add unsupported skips, or silently disable sanitizers to obtain green results.

## Local recovery material (not needed by repository consumers)

Research checkout is `/workspace/jsbay-research/sources/jsbay`. Full logs, source/ELF hashes, independent reviews, patches and STATUS files are under `/workspace/jsbay-research/validation/android/`, particularly `fixes/`, `fixes/independent-review/` and `fixes/sdk-parallel/`. Rebase backup: `rebase-20261117-175908/`; first Draft backup: `fixes/checkpoint-draft-20261117-2027/`.

Dirty vendor/hermes and vendor/escargot working trees were intentionally retained; official patch files are committed, not dirty gitlinks or generated prefixes. `vendor/icu-build/` is local generated material and must not be added. Original `/workspace/jsbay`, `/workspace/jsbay-main`, `/workspace/jsbay-upstream-main` worktrees were not modified. Do not reset/clean these trees or discard vendor state.

At stop: no background workers or native build/test commands were running. AVD 5554 may remain idle; do not touch another workflow's device 5560. Do not resume tests automatically.
