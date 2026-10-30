# Contributing

Thanks for considering a patch. This document covers what you need to know to land code in `JS Bay`. If something is unclear, open an issue before doing significant work.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues through [SECURITY.md](SECURITY.md), not public issues.

Before you push, read [AGENTS.md](AGENTS.md) and run `zig build tool -- privacy`: the repository must not contain private product names, private network addresses or personal paths.

Comments explain current behavior, constraints, ownership, and reasons. Leave dates, machine details, implementation history, and review notes out of comments. Write one prose paragraph per physical line in comments, documentation, commit messages, PRs, issues, and work logs; let the reader's editor or platform wrap it. Preserve meaningful line breaks in lists, tables, code examples, stack traces, license notices, and tool directives. See [comment and prose rules](AGENTS.md#comments-and-prose).

## 1. Local development environment

### Zig version

`build.zig.zon` pins `minimum_zig_version` to **0.17.0**. CI installs that release with `mlugg/setup-zig@v2`.

Check yours:

```bash
zig version
```

### Event loop dependencies

JS Bay's event loop and wake primitive are implemented in Zig; the reusable loop primitives are in the separate `libs/zev` package. `libs/js_event_loop` coordinates JS task execution, microtask checkpoints and synchronous native waits above `zev`; engine values and runtime admission stay in the root adapters. Persistent bytecode artifact naming and storage are in `libs/bytecode_cache`; engine compilation, execution and exception ownership stay in the root package. Both QuickJS backends are supported on Linux; JSC requires Apple frameworks.

### Git pre-commit hook (Zig formatting)

CI runs `zig build test-fmt`. To block local commits the same way, enable the repo-owned hook once per clone:

```bash
git config core.hooksPath .githooks
```

The hook runs `zig build test-fmt` (full project paths, matching CI). Skip with `git commit --no-verify` only when you intentionally defer formatting.

### Quality checks (`make check` / pawl)

`make check` invokes **pawl** (see `pawl.yaml`): a task runner for hard quality gates such as SDK formatters and linters. Install `pawl` on your `PATH`, then run `make check` (optionally `CHECKS=…` to select dimensions) before pushing platform or style-sensitive changes.

### Build + test the backend you care about

```bash
zig build test -Dbackend=quickjs_ng         # all platforms
zig build test -Dbackend=quickjs            # QuickJS
zig build test -Dbackend=jsc                # macOS only
zig build test -Dbackend=quickjs_ng -Dstress-tests=true  # event-loop/timer stress tests
```

If your change touches code under `src/backend/jsc/`, `src/backend/jsc/remote_inspector.zig`, or anything that conditionally compiles on `backend.active_backend == .jsc`, you must run the JSC test job too.

## 2. Project layout

`src/` root has seven entry points: `root.zig`, `engine.zig`, `backend.zig`, `types.zig`, `c_api.zig`, `internal_tools.zig`, and `test262_host.zig`. Other root-package code belongs to a responsibility directory. See [source layout](docs/architecture.md#source-layout) for the complete rule.

### Adding a new submodule

Use the responsibility and package boundaries in [architecture](docs/architecture.md). Keep engine-specific code in its backend directory and preserve the existing public export names.

Tests for root engine modules go in `src/tests/<area>_tests.zig` and must be registered in `src/tests/all_tests.zig`. Package unit tests belong to that package and must be registered by its `src/tests.zig`; pure Inspector protocol, HTTP/WebSocket, and bytecode artifact-storage tests do not belong in the engine suite. Contracts that require a real Inspector host run through `src/tests/inspector_host_contract_tests.zig`; cache compile/run behavior and the disabled build switch remain root integration tests. Tests inside a generic factory are not collected automatically: expose test-only checks and call them from ordinary test declarations. Confirm a nonzero test count. The root test command runs the package suites too and forwards `-Dtest-filter` to them. Gate engine-specific integration tests by an explicit capability or backend tag.

## 3. TDD policy (required)

This project develops in test-first order. It is enforced for both new features and bug fixes.

- **New feature**: write the failing tests first, then implement until they pass. Do not commit implementation without the tests that justify it.
- **Bug fix**: write a test that reproduces the bug and fails on `main`, then fix the code so the test passes.
- **Tests should be authored by a different person/agent than the implementation.** Self-authored tests can miss the intended behavior. If you wrote both halves yourself, say so in the commit body so a reviewer can check that the tests constrain the requirement.
- If you modify a test you wrote earlier while implementing, explain why in the commit body.
- Tests must exercise behavior that matters. Reject tests that only restate the implementation, re-run mocks, or assert obvious identities. If you can't name the bug a test would catch, don't write it.

## 4. JSC backend: the `NULL_SENTINEL` rule

JSC has no compile-time JS-null constant — every real `JSValueRef` for JS `null` comes from `JSValueMakeNull(ctx)`, which requires a context. To preserve the JS-level distinction between `null` and `undefined` at the `ActiveEngine.Value` layer even when callers default-init a slot without a context, the JSC backend uses a sentinel pointer:

```zig
// src/backend/jsc/common.zig
pub const NULL_SENTINEL: jsc.JSValueRef = @ptrFromInt(0x1);
pub fn isSentinel(val: jsc.JSValueRef) bool { ... }
pub fn liftSentinel(ctx, val: jsc.JSValueRef) jsc.JSValueRef { ... }
```

**If you add a JSC entry point that accepts a `JSValueRef val` and forwards it to any raw `JSValueIs*` / `JSValueTo*` / `JSObject*` API, you must first either:**

- short-circuit on `common.isSentinel(val)` (return the trivial answer for JS null, or skip work that doesn't apply), or
- replace it with `common.liftSentinel(ctx, val)` before forwarding the raw pointer.

Skipping this will dereference `0x1` and crash. Look at `src/backend/jsc/value.zig` (`isUndefined`, `isNull`, `setPropertyStr`'s `liftSentinel` use) and `src/backend/jsc/datatypes.zig` (`jscIsDate` and friends, which all start with an `isSentinel` short-circuit) as the canonical patterns. There is a dedicated test file `src/tests/jsc_sentinel_tests.zig` that covers raw API entry points; if you add one, add a case there.

## 5. Commit conventions

Commits follow Conventional Commits with a scope. Examples:

```
feat(jsc): expose built-in WebKit Inspector for Safari attachment
refactor(value): split value.zig into per-responsibility submodules
fix(jsc): guard NULL_SENTINEL in raw JSC API call sites
docs: refresh README to match split codebase + new features
test(jsc): TDD sentinel coverage for raw API entries (failing)
ci: run the macos+jsc job too
```

Use `feat`, `fix`, `refactor`, `test`, `docs`, `ci`, `chore`. The scope is usually the backend (`jsc`, `quickjs`), the area (`value`, `inspector`, `native_handle`), or omitted for cross-cutting changes.

## 6. CI and acceptance

Pushing to `main` runs the build and test matrix:

- `ubuntu-latest` / QuickJS-NG and QuickJS
- `macos-latest` / QuickJS-NG and JSC
- `macos-latest` / inspector e2e

Each backend runs with Inspector enabled and disabled. Review the matrix result before a release.

If you touched `vendor/*.patch`, also run `bash tests/qjs-regression/run.sh` (and `--engine quickjs`); see [QuickJS upstream regressions](docs/testing.md#quickjs-upstream-regressions).

Before pushing, at minimum run `zig build test -Dbackend=quickjs_ng` locally. On macOS, also run `zig build test -Dbackend=jsc` if you touched anything backend-shared or JSC-specific. Fixing red CI is your responsibility, not the reviewer's.
