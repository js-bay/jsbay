# Release

The release workflow is [`.github/workflows/release.yml`](../.github/workflows/release.yml). It is the authority for the asset set and build commands.

Before tagging, run the normal CI workflow on the release commit. Then dispatch the release workflow once with the intended `build.zig.zon` version. A dispatch run produces artifacts for inspection; only a `v*` tag creates a GitHub release.

Inspect the uploaded artifacts before tagging:

- checksums cover every uploaded asset;
- desktop archives contain headers, a static library, version, commit, backend, license, and notices;
- Apple archives are usable Swift package directories and pass their consumer probe;
- Android archives contain the expected AAR or Maven repository contents;
- the source archive passes `zig build tool -- privacy` and contains no Git metadata.

The tag version must match `build.zig.zon`. Platform packages depend on their platform SDKs; use the workflow instead of recreating its commands locally. The workflow can omit Apple or Android for a dispatch run, but a tagged release requires the configured release jobs to succeed.
