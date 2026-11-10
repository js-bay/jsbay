# state_tcas sequence diagrams

Harness stories under `src/tests/state_tcas_*` record `Picture` / `Observation` steps and lock Mermaid (state + sequence) goldens beside this guide.

These diagrams are **contract illustrations** from fixed `exhaust.play` stories (Scheduler / Driver / ActiveEngine). They are not a full explore dump.

## Diagrams

| Story | Golden | Harness |
| --- | --- | --- |
| Scheduler: outer task → checkpoint drain | [scheduler-task-checkpoint.md](state-tcas-scheduler-task-checkpoint.md) | `state_tcas_js_event_loop_harness.zig` |
| Driver: arm timer → advance/fire | [driver-timer-fire.md](state-tcas-driver-timer-fire.md) | `state_tcas_js_event_loop_driver_harness.zig` |
| Engine: Promise microtask before `setTimeout(0)` (phases + `trace=mt` note) | [engine-microtask-before-timer.md](state-tcas-engine-microtask-before-timer.md) | `state_tcas_engine_harness.zig` |

Each golden embeds `stateDiagram-v2` (edges from observations) and `sequenceDiagram` (Host ⇄ Scheduler/Driver/Engine arrows).

## How they plug into docs

- This page is the index; goldens live under `docs/state-tcas-*.md`.
- Linked from [Documentation](readme.md) and [Testing](testing.md).
- Linux governance CI runs `zig build test-state-tcas` (Scheduler/Driver goldens + explore gates). Engine goldens byte-lock via `test-engine` (`all_tests.zig`); the dedicated `zig build test-state-tcas-engine` step also locks them locally (`setCwd` = package root). See [Testing](testing.md).

## Regenerate

From the jsbay package root:

```sh
touch .state_tcas-update-pictures
zig build test-state-tcas -Dbackend=quickjs_ng --summary all
zig build test-state-tcas-engine -Dbackend=quickjs_ng --summary all
rm -f .state_tcas-update-pictures
```

Optional filter:

```sh
zig build test-state-tcas -Dbackend=quickjs_ng -Dtest-filter="picture lock"
zig build test-state-tcas-engine -Dbackend=quickjs_ng -Dtest-filter="picture lock"
```

**Committed source of truth is `docs/state-tcas-*.md`.** Local debate scratch copies (if any) are not part of the package.
