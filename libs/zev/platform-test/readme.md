# Platform test runner

`zev-platform-test` is a host-native Zig executable. It records one result for each requested platform and does not invoke a shell adapter.

## Quick start

```sh
# from the zev package directory
zig build platform-test -- run --case zev_stress --platform macos
zig build platform-test -- run --case zev_stress --all
```

The runner reads cases from `platform-test/cases/`. It builds and executes on macOS, an iOS simulator, Android, HarmonyOS, and remote Linux or Windows hosts using the configured SDKs and device tools. Missing configuration is reported as `SKIP`; a configured build, transfer, execution, or marker failure is `FAIL`. A cross-build alone does not count as a runtime pass.

Copy [config.env.example](config.env.example) to `config.env`, or export its variables. Existing environment variables take precedence. The configuration file accepts literal `KEY=VALUE` assignments, optional `export`, comments, and single or double quotes; it does not execute shell commands or expand variables. `list` shows discovered cases, `platforms` shows supported targets, and `run --all` selects all cases and platforms.

## Contract

The `zev_stress` case requires `result=PASS`, the native mutex checks, and ordered contention output on one line. A failure marker wins even when pass markers are present. Its Zig source starts four producer threads for 1,000,000 signals, checks 100,000 zero-timeout waits, and runs 20,000 create/signal/wait lifecycles.

Adding another case requires a Zig runner implementation and its `case.json` together. Do not add a manifest-only case: the current runner must know how to execute it and how to record a truthful `PASS`, `FAIL`, or `SKIP` result.
