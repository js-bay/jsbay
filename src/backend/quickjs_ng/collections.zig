//! Map / Set support for `value.zig`.
//!
//! QuickJS-NG instantiation of the shared leaf in `src/backend/quickjs_common/collections.zig`. Public names stay on this path so existing imports keep working.

const impl = @import("../quickjs_common/collections.zig").create(@import("c_api.zig"), @import("exception.zig"));

pub const qjsIsMap = impl.qjsIsMap;
pub const qjsIsSet = impl.qjsIsSet;
pub const qjsMapSetToJson = impl.qjsMapSetToJson;
pub const qjsNewMapFromJson = impl.qjsNewMapFromJson;
pub const qjsNewSetFromJson = impl.qjsNewSetFromJson;
pub const QjsMapForEachFn = impl.QjsMapForEachFn;
pub const QjsSetForEachFn = impl.QjsSetForEachFn;
pub const qjsMapForEach = impl.qjsMapForEach;
pub const qjsSetForEach = impl.qjsSetForEach;
pub const qjsMapSize = impl.qjsMapSize;
pub const qjsSetSize = impl.qjsSetSize;
pub const qjsNewMap = impl.qjsNewMap;
pub const qjsNewSet = impl.qjsNewSet;
pub const qjsMapSet = impl.qjsMapSet;
pub const qjsSetAdd = impl.qjsSetAdd;
