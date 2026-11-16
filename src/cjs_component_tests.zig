//! Engine-side compiled-artifact ownership tests. Generic CommonJS registry and loader tests now run independently with `cd libs/commonjs && zig build test`.
comptime {
    _ = @import("script/cjs/compile_cache.zig");
}
