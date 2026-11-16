//! Backend-typed facade for shared symbol support.

const c = @import("c_api.zig");

const shared = @import("../quickjs_common/symbol.zig").create(c);

pub const make = shared.make;
