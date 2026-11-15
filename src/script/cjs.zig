//! CommonJS public facade. Internal components separate instance caching, loader ownership, wrapper invocation and compiled bytes. The adapter owns native callbacks, engine admission and teardown timing.
const adapter = @import("cjs/adapter.zig");

pub const install = adapter.install;
pub const evalAsCjs = adapter.evalAsCjs;
pub const clearCache = adapter.clearCache;
pub const uninstall = adapter.uninstall;
pub const CjsCacheResult = adapter.CjsCacheResult;
pub const compileCommonJS = adapter.compileCommonJS;
pub const runCommonJS = adapter.runCommonJS;
pub const evalCachedCjs = adapter.evalCachedCjs;
