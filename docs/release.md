# Release

The release workflow is [`.github/workflows/release.yml`](../.github/workflows/release.yml). It is the authority for the asset set and build commands.

Run the normal CI workflow on the source commit, then dispatch Release from that commit with its `build.zig.zon` version. Leave **Publish a complete release** disabled to build and inspect artifacts only. Enable it to publish; this requires both Apple and Android builds, `NPM_TOKEN`, and a version tag that does not already exist. CI creates the version tag only after every build and consumer check succeeds. The tag points to a generated commit containing the root Swift package manifest and wrapper sources; engine binaries remain release assets. The build commit SHA is recorded in artifacts and passed to npm publishing separately from the generated tag commit.

Inspect the uploaded artifacts before tagging:

- checksums cover every uploaded asset;
- desktop archives contain headers, a static library, version, commit, backend, license, and notices;
- Apple XCFramework archives pass the single-package Swift and Objective-C consumer probe; the generated manifest records each archive checksum;
- Android archives contain the expected AAR or Maven repository contents;
- the source archive passes `zig build tool -- privacy` and contains no Git metadata.
- the Zig package archive has `build.zig.zon` at its root and passes the external consumer probe for `quickjs` and `quickjs_ng`.

The release includes `jsbay-<version>-source.tar.gz` for source browsing and `jsbay-<version>-zig.tar.gz` for Zig package dependencies. The Zig archive keeps `build.zig.zon` at its root so Zig can load the package build script. Before release, create it with `bash tests/ci/pack-zig-source.sh <source-archive> <zig-package-archive>` and validate it with `bash tests/ci/release-zig-consumer.sh <zig-package-archive>`. The consumer probe serves the archive locally, installs it with `zig fetch --save`, then builds and runs independent consumers with both supported QuickJS backends. It requires Zig 0.17.0, Node.js, and curl.

For a release tagged `v0.1.0`, a downstream project can install the package with `zig fetch --save=jsbay https://github.com/js-bay/jsbay/releases/download/v0.1.0/jsbay-0.1.0-zig.tar.gz`. Its `build.zig` can select a backend and link the package with the same helper used by the repository's consumer:

```zig
const jsbay_build = @import("jsbay");
const backend = b.option(Backend, "backend", "JS Bay backend") orelse .quickjs_ng;
const sysroot = b.option([]const u8, "apple-sysroot", "Apple SDK path for cross compilation");
const jsbay = if (sysroot) |sdk| b.dependency("jsbay", .{
    .target = target,
    .optimize = optimize,
    .backend = backend,
    .@"apple-sysroot" = sdk,
    .@"apple-package" = true,
}) else b.dependency("jsbay", .{
    .target = target,
    .optimize = optimize,
    .backend = backend,
});
jsbay_build.linkConsumer(exe, jsbay);
```

`linkConsumer` connects the public `jsbay` module and library and forwards framework paths, library paths, and the Zig standard-library directory needed by cross-compiled consumers. The release probe runs native host builds for `quickjs` and `quickjs_ng`; Apple and iOS cross-compilation are not covered by that probe.

The release version must match `build.zig.zon`. Platform packages depend on their platform SDKs; use the workflow instead of recreating its commands locally. Build-only runs can omit Apple or Android; publication requires both tiers to succeed. The CI workflow never moves an existing tag. Version `0.1.0` already has tag `v0.1.0`, so that version cannot be published again.

For publication, configure the `release` GitHub environment with approved deployment branches, required reviewers, and an environment-scoped `NPM_TOKEN` with permission to publish the `@jsbay` npm packages. Limit the token to that environment rather than repository or organization secrets. The workflow uses the repository's `GITHUB_TOKEN` with `contents: write` to stage the package commit in a run-specific branch and upload verified assets to a draft GitHub Release. After Android and npm publication succeed, CI publishes the release and its version tag. The staging branch is retained so a retry can verify the same package commit. Retry the failed jobs in the same workflow run; an existing asset is reused only when its checksum matches. Android and npm publication upload multiple packages and cannot be atomic, so an interrupted deployment can leave a partial version; inspect the registry before retrying.
