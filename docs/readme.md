# Documentation

Public declarations are in [the installed header](../include/jsbay.h). These guides cover behavior that signatures alone cannot describe.

- [Embedding](embedding.md): select a backend and use Zig, C, or an SDK.
- [Public API contract](api-contract.md): ownership, status, callbacks, and lifecycle.
- [Runtime limits](runtime-limits.md) and [synchronous native calls](native-sync.md).
- [Inspector](inspector.md): CDP setup, compatibility, and Safari inspection.
- [Architecture](architecture.md): package boundaries and source placement.
- [Testing](testing.md), [QuickJS upgrades](quickjs-upgrade.md), and [performance](performance.md).
- [Release](release.md).
- [Capability matrix](capability.md): Escargot/Hermes spike coverage vs QuickJS/JSC.
- [Production gaps](production-gaps.md) and [adversarial review](adversarial-review.md).
- [Host isolation](host-isolation.md), [upstream known issues](upstream-known-issues.md), and [Android box status](android-box-status.md).

Build files, manifests, generated protocol data, and scripts define inventories, versions, and exact commands. These documents record the contracts and operational limits around them.
