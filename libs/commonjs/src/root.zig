//! Engine-independent CommonJS canonical IDs, loading transactions and instance cache. The embedding host supplies execution, references and serialization.
const loader = @import("loader.zig");
const registry = @import("registry.zig");
pub const Loader = loader.Loader;
pub const LoaderVTable = loader.LoaderVTable;
pub const LoadResult = loader.LoadResult;
pub const ResolvedId = loader.ResolvedId;
pub const resolveSpecifier = loader.resolveSpecifier;
pub const loadSource = loader.loadSource;
pub const dirnameOf = loader.dirnameOf;
pub const Registry = registry.Registry;
pub const ExecutionError = registry.ExecutionError;
pub const RequireError = registry.RequireError;
