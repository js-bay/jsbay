//! Backend-typed facade for shared jobs support.

const c = @import("c_api.zig");
const async_stack = @import("../../inspector/async_stack.zig");
const debug_probe = @import("../../tests/debug_cold_probe.zig");
const inspector_enabled = @import("build_options").inspector;

const shared = @import("../quickjs_common/jobs.zig").create(c, async_stack, debug_probe, inspector_enabled);

pub const install = shared.install;
pub const setAsyncStackDepth = shared.setAsyncStackDepth;
