//! Date / BigInt support (see ../value.zig).
//!
//! QuickJS-NG instantiation of the shared leaf in `src/backend/quickjs_common/datetime.zig`. Public names stay on this path so existing imports keep working.

const impl = @import("../quickjs_common/datetime.zig").create(@import("c_api.zig"));

pub const qjsIsDate = impl.qjsIsDate;
pub const qjsToDateMs = impl.qjsToDateMs;
pub const qjsNewDate = impl.qjsNewDate;
pub const qjsIsBigInt = impl.qjsIsBigInt;
pub const qjsToBigIntI64 = impl.qjsToBigIntI64;
pub const qjsToBigIntU64 = impl.qjsToBigIntU64;
pub const qjsNewBigIntI64 = impl.qjsNewBigIntI64;
pub const qjsNewBigIntU64 = impl.qjsNewBigIntU64;
