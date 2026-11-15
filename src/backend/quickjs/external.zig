//! Backend-typed facade for shared external support.

const c = @import("c_api.zig");

const shared = @import("../quickjs_common/external.zig").create(c);

pub const QjsExternalFinalizer = shared.QjsExternalFinalizer;
pub const qjsNewExternal = shared.qjsNewExternal;
pub const qjsGetExternal = shared.qjsGetExternal;
pub const qjsIsExternal = shared.qjsIsExternal;
