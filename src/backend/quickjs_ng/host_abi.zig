//! Backend-typed facade for shared host_abi support.

const c = @import("c_api.zig");
const instance_map = @import("../../runtime/instance_map.zig");
const host_value = @import("../../abi/host_value.zig");

const shared = @import("../quickjs_common/host_abi.zig").create(c, instance_map, host_value);

pub const install = shared.install;
pub const releaseInstance = shared.releaseInstance;
