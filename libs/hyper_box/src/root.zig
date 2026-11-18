//! HyperBox: High-Performance Hardware-Sympathetic Value Engine.

pub const hyper_box64 = @import("hyper_box64.zig");
pub const split_box32 = @import("split_box32.zig");
pub const generational_slot_map = @import("generational_slot_map.zig");

pub const Value = hyper_box64.Value;
pub const SplitBox32 = split_box32.SplitBox32;
pub const HandlePayload = hyper_box64.HandlePayload;
pub const SsoBuffer = hyper_box64.SsoBuffer;
pub const GenerationalSlotMap = generational_slot_map.GenerationalSlotMap;

pub const TAG_BASE = hyper_box64.TAG_BASE;
pub const TAG_INT32 = hyper_box64.TAG_INT32;
pub const TAG_BOOL = hyper_box64.TAG_BOOL;
pub const TAG_SPECIAL = hyper_box64.TAG_SPECIAL;
pub const TAG_HANDLE = hyper_box64.TAG_HANDLE;
pub const TAG_HEAP_OBJ = hyper_box64.TAG_HEAP_OBJ;
pub const TAG_EXTENDED = hyper_box64.TAG_EXTENDED;
pub const TAG_SSO_BASE = hyper_box64.TAG_SSO_BASE;
pub const TAG_SSO_0_5 = hyper_box64.TAG_SSO_0_5;
pub const TAG_SSO_6 = hyper_box64.TAG_SSO_6;

pub const TAG_MASK = hyper_box64.TAG_MASK;
pub const PAYLOAD_MASK = hyper_box64.PAYLOAD_MASK;
pub const CANONICAL_NAN = hyper_box64.CANONICAL_NAN;
pub const NEGATIVE_ZERO = hyper_box64.NEGATIVE_ZERO;

pub const VAL_EMPTY = hyper_box64.VAL_EMPTY;
pub const VAL_UNDEFINED = hyper_box64.VAL_UNDEFINED;
pub const VAL_NULL = hyper_box64.VAL_NULL;
pub const VAL_TRUE = hyper_box64.VAL_TRUE;
pub const VAL_FALSE = hyper_box64.VAL_FALSE;
