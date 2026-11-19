//! Unit tests for simd_utf package.

const std = @import("std");
const simd_utf = @import("simd_utf");

test "simd_utf: isAscii detects pure ASCII across alignment boundaries" {
    try std.testing.expect(simd_utf.isAscii(""));
    try std.testing.expect(simd_utf.isAscii("hello world"));
    try std.testing.expect(simd_utf.isAscii("0123456789abcdef")); // exactly 16 bytes
    try std.testing.expect(simd_utf.isAscii("0123456789abcdefg")); // 17 bytes
    try std.testing.expect(!simd_utf.isAscii("hello 世界"));
    try std.testing.expect(!simd_utf.isAscii("0123456789abcde\x80"));
}

test "simd_utf: validateUtf8 accepts valid sequences and rejects invalid" {
    try std.testing.expect(simd_utf.validateUtf8(""));
    try std.testing.expect(simd_utf.validateUtf8("valid ascii string"));
    try std.testing.expect(simd_utf.validateUtf8("valid unicode: 你好，世界！🚀"));
    try std.testing.expect(!simd_utf.validateUtf8("\xFF\xFE invalid"));
    try std.testing.expect(!simd_utf.validateUtf8("half multi-byte: \xE4\xBD"));
}

test "simd_utf: transcodeUtf8ToUtf16 converts ASCII and multi-byte with SIMD" {
    const src = "The quick brown fox jumps over the lazy dog! 🚀 12345";
    var utf16_buf: [128]u16 = undefined;
    const written = try simd_utf.transcodeUtf8ToUtf16(&utf16_buf, src);
    try std.testing.expect(written > 0);

    // Verify first word
    try std.testing.expectEqual(@as(u16, 'T'), utf16_buf[0]);
    try std.testing.expectEqual(@as(u16, 'h'), utf16_buf[1]);
    try std.testing.expectEqual(@as(u16, 'e'), utf16_buf[2]);
}

test "simd_utf: transcode roundtrip UTF-8 -> UTF-16 -> UTF-8" {
    const original = "Sample test payload: 1234567890! Special chars: é, à, ü, 🦊, 🌟 and embedded null: \x00 end.";
    var utf16_buf: [256]u16 = undefined;
    const utf16_len = try simd_utf.transcodeUtf8ToUtf16(&utf16_buf, original);

    var utf8_buf: [256]u8 = undefined;
    const utf8_len = try simd_utf.transcodeUtf16ToUtf8(&utf8_buf, utf16_buf[0..utf16_len]);

    try std.testing.expectEqualStrings(original, utf8_buf[0..utf8_len]);
}

test "simd_utf: transcodeUtf16ToUtf8 replaces unpaired surrogates" {
    const unpaired = [_]u16{ 'a', 0xD800, 'b', 0xDC00, 'c' };
    var utf8_buf: [32]u8 = undefined;
    const utf8_len = try simd_utf.transcodeUtf16ToUtf8(&utf8_buf, &unpaired);
    const result = utf8_buf[0..utf8_len];
    try std.testing.expect(std.mem.indexOf(u8, result, "\xEF\xBF\xBD") != null);
}

test "simd_utf: transcodeUtf8ToUtf16 rejects undersized destination" {
    const src = "Short payload";
    var tiny_buf: [4]u16 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, simd_utf.transcodeUtf8ToUtf16(&tiny_buf, src));
}
