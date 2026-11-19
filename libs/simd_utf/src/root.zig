//! SIMD-Accelerated Unicode Transcoding and Validation.
//!
//! Provides high-throughput UTF-8 and UTF-16 transcoding utilizing hardware vector registers (@Vector(16, u8)) on ARM NEON and x86 architectures.

const std = @import("std");

pub const VEC_SIZE: usize = 16;
const ascii_mask: @Vector(VEC_SIZE, u8) = @splat(0x80);

/// Check whether a UTF-8 slice consists entirely of 7-bit ASCII code points.
pub fn isAscii(src: []const u8) bool {
    var i: usize = 0;
    while (i + VEC_SIZE <= src.len) : (i += VEC_SIZE) {
        const chunk: @Vector(VEC_SIZE, u8) = src[i..][0..VEC_SIZE].*;
        if (!@reduce(.And, chunk < ascii_mask)) return false;
    }
    while (i < src.len) : (i += 1) {
        if (src[i] >= 0x80) return false;
    }
    return true;
}

/// Validate whether a byte slice contains valid UTF-8 sequences.
pub fn validateUtf8(src: []const u8) bool {
    var i: usize = 0;
    while (i + VEC_SIZE <= src.len) {
        const chunk: @Vector(VEC_SIZE, u8) = src[i..][0..VEC_SIZE].*;
        if (@reduce(.And, chunk < ascii_mask)) {
            i += VEC_SIZE;
            continue;
        }
        break;
    }
    return std.unicode.utf8ValidateSlice(src[i..]);
}

/// Transcode UTF-8 bytes to native UTF-16 code units with SIMD vector acceleration.
///
/// Uses 16-byte vector extensions on ASCII-heavy runs, dropping into scalar sequence decoding for multi-byte code points. Returns the count of UTF-16 code units written.
pub fn transcodeUtf8ToUtf16(dst: []u16, src: []const u8) !usize {
    var i: usize = 0;
    var out_i: usize = 0;

    while (i + VEC_SIZE <= src.len and out_i + VEC_SIZE <= dst.len) {
        const chunk: @Vector(VEC_SIZE, u8) = src[i..][0..VEC_SIZE].*;
        const all_ascii = @reduce(.And, chunk < ascii_mask);
        if (all_ascii) {
            const widened: @Vector(VEC_SIZE, u16) = chunk;
            dst[out_i..][0..VEC_SIZE].* = widened;
            i += VEC_SIZE;
            out_i += VEC_SIZE;
        } else {
            const seq_len = try std.unicode.utf8ByteSequenceLength(src[i]);
            if (i + seq_len > src.len) return error.Utf8InvalidStartByte;
            const written = try std.unicode.utf8ToUtf16Le(dst[out_i..], src[i .. i + seq_len]);
            i += seq_len;
            out_i += written;
        }
    }
    if (i < src.len) {
        const rem = try std.unicode.utf8ToUtf16Le(dst[out_i..], src[i..]);
        out_i += rem;
    }
    return out_i;
}

/// Transcode native UTF-16 code units to UTF-8 bytes with SIMD vector acceleration.
///
/// Returns the number of UTF-8 bytes written into dst. Unpaired surrogates are replaced with U+FFFD.
pub fn transcodeUtf16ToUtf8(dst: []u8, src: []const u16) !usize {
    var i: usize = 0;
    var out_i: usize = 0;
    const VEC_U16: usize = 8;
    const ascii_mask_u16: @Vector(VEC_U16, u16) = @splat(0x80);

    while (i + VEC_U16 <= src.len and out_i + VEC_U16 <= dst.len) {
        const chunk: @Vector(VEC_U16, u16) = src[i..][0..VEC_U16].*;
        const all_ascii = @reduce(.And, chunk < ascii_mask_u16);
        if (all_ascii) {
            const narrowed: @Vector(VEC_U16, u8) = @truncate(chunk);
            dst[out_i..][0..VEC_U16].* = narrowed;
            i += VEC_U16;
            out_i += VEC_U16;
        } else {
            const unit = src[i];
            var scalar: u21 = unit;
            if (unit >= 0xD800 and unit <= 0xDBFF) {
                if (i + 1 < src.len and src[i + 1] >= 0xDC00 and src[i + 1] <= 0xDFFF) {
                    scalar = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (@as(u21, src[i + 1]) - 0xDC00);
                    i += 1;
                } else scalar = std.unicode.replacement_character;
            } else if (unit >= 0xDC00 and unit <= 0xDFFF) scalar = std.unicode.replacement_character;

            var encoded: [4]u8 = undefined;
            const written = try std.unicode.utf8Encode(scalar, &encoded);
            if (out_i + written > dst.len) return error.NoSpaceLeft;
            @memcpy(dst[out_i .. out_i + written], encoded[0..written]);
            out_i += written;
            i += 1;
        }
    }
    while (i < src.len) {
        const unit = src[i];
        var scalar: u21 = unit;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (i + 1 < src.len and src[i + 1] >= 0xDC00 and src[i + 1] <= 0xDFFF) {
                scalar = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (@as(u21, src[i + 1]) - 0xDC00);
                i += 1;
            } else scalar = std.unicode.replacement_character;
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) scalar = std.unicode.replacement_character;

        var encoded: [4]u8 = undefined;
        const written = try std.unicode.utf8Encode(scalar, &encoded);
        if (out_i + written > dst.len) return error.NoSpaceLeft;
        @memcpy(dst[out_i .. out_i + written], encoded[0..written]);
        out_i += written;
        i += 1;
    }
    return out_i;
}
