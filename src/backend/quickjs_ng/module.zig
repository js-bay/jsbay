//! Backend-typed facade for shared module support.

const c = @import("c_api.zig");
const exception = @import("exception.zig");
const lifecycle = @import("lifecycle.zig");

const shared = @import("../quickjs_common/module.zig").create(c, exception, lifecycle);

pub const QJS_EVAL_TYPE_MODULE = shared.QJS_EVAL_TYPE_MODULE;
pub const QJS_EVAL_FLAG_COMPILE_ONLY = shared.QJS_EVAL_FLAG_COMPILE_ONLY;
pub const installModuleLoader = shared.installModuleLoader;
pub const evalAsModule = shared.evalAsModule;
pub const importModuleBySpecifier = shared.importModuleBySpecifier;
