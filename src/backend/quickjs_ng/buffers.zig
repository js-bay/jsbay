//! Zero-copy buffer support.
//!
//! QuickJS-NG instantiation of the shared leaf in `src/backend/quickjs_common/buffers.zig`.
//! Public names stay on this path so existing imports keep working.

const impl = @import("../quickjs_common/buffers.zig").create(@import("c_api.zig"));

pub const QjsBufferFinalizer = impl.QjsBufferFinalizer;
pub const qjsNewArrayBufferFromBytes = impl.qjsNewArrayBufferFromBytes;
pub const qjsNewUint8ArrayFromBytes = impl.qjsNewUint8ArrayFromBytes;
pub const qjsGetBufferView = impl.qjsGetBufferView;
