//! Backend-typed facade for shared timers support.

const c = @import("c_api.zig");
const async_stack = @import("../../inspector/async_stack.zig");
const timers_mod = @import("../../runtime/timers.zig");

const shared = @import("../quickjs_common/timers.zig").create(c, async_stack, timers_mod);

pub const jsSetTimeout = shared.jsSetTimeout;
pub const jsSetInterval = shared.jsSetInterval;
pub const jsClearTimer = shared.jsClearTimer;
