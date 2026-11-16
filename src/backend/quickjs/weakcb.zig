//! Backend-typed facade for shared weakcb support.

const c = @import("c_api.zig");
const native_handle_mod = @import("../../value/native_handle.zig");

const shared = @import("../quickjs_common/weakcb.zig").create(c, native_handle_mod);

pub const QjsWeakFinalizeCallback = shared.QjsWeakFinalizeCallback;
pub const nextWeakFinalizerKeyForTesting = shared.nextWeakFinalizerKeyForTesting;
pub const qjsWeakAttachFinalizer = shared.qjsWeakAttachFinalizer;
