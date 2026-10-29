# bytecode_cache

Content-addressed storage for serialized bytecode. It does not import or run a
JavaScript engine: callers provide an I/O capability and decide how to compile
and execute cache payloads. Files are published through a unique sibling and
rename so readers do not observe a partial artifact.

`artifactPath` accepts only full, lowercase SHA-256 hex values for its source
and filename identities. Version and build fingerprint are separately limited
to safe filename components.
