# Updating QuickJS backends

QuickJS and QuickJS-NG are Git submodules under `vendor/`. Build preparation copies their sources to the Zig cache and applies the patches named by `build.zig`; do not edit a submodule worktree to carry a project patch.

Update one backend at a time:

1. Initialize the checked-out submodules with `git submodule update --init --recursive`.
2. Move the submodule gitlink to the intended upstream commit and update the corresponding patch files. Each patch must apply to a clean checkout of that commit.
3. Review upstream C API and source-list changes, then update the backend adapter or `build.zig` when required.
4. Run the backend tests and the upstream regression runner:

```sh
zig build test -Dbackend=quickjs --summary all
zig build test -Dbackend=quickjs_ng --summary all
bash tests/qjs-regression/run.sh --engine quickjs
bash tests/qjs-regression/run.sh --engine quickjs_ng
zig build test-tools
```

The bytecode cache fingerprint includes engine inputs, so an engine update invalidates existing cache entries. The source-export check also confirms that the release source package contains the pinned upstream sources without Git metadata.

See [QuickJS upstream regressions](testing.md#quickjs-upstream-regressions) for runner options and failure classification.
