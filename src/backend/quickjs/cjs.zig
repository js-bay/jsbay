//! Backend-typed facade for shared cjs support.

const c = @import("c_api.zig");
const exception = @import("exception.zig");
const lifecycle = @import("lifecycle.zig");

const shared = @import("../quickjs_common/cjs.zig").create(c, exception, lifecycle);

pub const qjsCjsEvalToValue = shared.qjsCjsEvalToValue;
