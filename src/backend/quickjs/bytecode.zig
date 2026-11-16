//! Backend-typed facade for shared bytecode support.

const c = @import("c_api.zig");
const exception = @import("exception.zig");
const lifecycle = @import("lifecycle.zig");
const module_mod = @import("module.zig");

const shared = @import("../quickjs_common/bytecode.zig").create(c, exception, lifecycle, module_mod);

pub const QJS_WRITE_OBJ_BYTECODE = shared.QJS_WRITE_OBJ_BYTECODE;
pub const QJS_READ_OBJ_BYTECODE = shared.QJS_READ_OBJ_BYTECODE;
pub const QjsCompileResult = shared.QjsCompileResult;
pub const qjsCompileBytecode = shared.qjsCompileBytecode;
pub const qjsFreeBytecode = shared.qjsFreeBytecode;
pub const qjsRunBytecode = shared.qjsRunBytecode;
pub const BytecodeToFnResult = shared.BytecodeToFnResult;
pub const qjsRunBytecodeToFn = shared.qjsRunBytecodeToFn;
