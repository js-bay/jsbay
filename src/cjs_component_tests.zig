//! Engine-side compiled-artifact ownership tests. Generic CommonJS registry and loader tests run independently with `cd libs/commonjs && zig build test`.
comptime {
    _ = @import("script/cjs/compile_cache.zig");
}
