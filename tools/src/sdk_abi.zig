//! Narrow source drift checks for the current Kotlin/C# native boundary. Numeric and host C layout authority is the public header, not copied numbers. This is not a language parser or an SDK runtime/foreign-target layout test: unsupported declaration shapes fail closed and require reviewing this gate.
const std = @import("std");
const c = @import("public_abi");
const Pair = [2][]const u8;
const status = [_]Pair{
    .{ "OK", "Ok" },                               .{ "EXCEPTION", "Exception" },
    .{ "INVALID_ARGUMENT", "InvalidArgument" },    .{ "WRONG_THREAD", "WrongThread" },
    .{ "INSTANCE_NOT_FOUND", "InstanceNotFound" }, .{ "STALE_VALUE", "StaleValue" },
    .{ "OUT_OF_MEMORY", "OutOfMemory" },           .{ "UNSUPPORTED", "Unsupported" },
    .{ "LOOP_FAILED", "LoopFailed" },
};
const kinds = [_]Pair{
    .{ "UNDEFINED", "Undefined" }, .{ "NULL", "Null" },         .{ "BOOL", "Bool" },
    .{ "NUMBER", "Number" },       .{ "STRING", "String" },     .{ "OBJECT", "Object" },
    .{ "ARRAY", "Array" },         .{ "FUNCTION", "Function" }, .{ "SYMBOL", "Symbol" },
    .{ "BIGINT", "BigInt" },
};
const submission = [_]Pair{ .{ "COMPLETED", "Completed" }, .{ "EXCEPTION", "Exception" }, .{ "CANCELLED", "Cancelled" } };
const shutdown = [_]Pair{ .{ "OPEN", "Open" }, .{ "CLOSING", "Closing" }, .{ "SEALED", "Sealed" }, .{ "DRAINED", "Drained" }, .{ "CANCELLED", "Cancelled" } };
const admission = [_]Pair{ .{ "FOREGROUND", "Foreground" }, .{ "BACKGROUND", "Background" } };

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}
fn body(source: []const u8, declaration: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, source, declaration) orelse return error.PolicyFailure;
    const first = std.mem.indexOfScalarPos(u8, source, at + declaration.len, '{') orelse return error.PolicyFailure;
    var depth: usize = 1;
    var end = first + 1;
    while (end < source.len) : (end += 1) switch (source[end]) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return source[first + 1 .. end];
        },
        else => {},
    };
    return error.PolicyFailure;
}

// Kotlin constructor arguments are native codes, NOT enum ordinals. Only ValueKind is ordinal-based (Value.kind indexes ValueKind.entries directly). The supported constructor/property/companion grammar is deliberately closed.
fn kotlinPrefix(source: []const u8) !void {
    var tokens = CsTokens{ .source = source, .kotlin = true };
    var token = try tokens.next();
    if (token != null and std.mem.eql(u8, token.?, "package")) {
        try tokens.sequence("io.jsbay");
        token = try tokens.next();
        if (token != null and std.mem.eql(u8, token.?, ";")) token = try tokens.next();
    }
    // Harmless top-level constant string decoys are allowed. Other declaration modifiers, annotations, imports and aliases require an explicit review.
    while (token) |first| {
        var modifier = first;
        if (std.mem.eql(u8, modifier, "private")) modifier = try tokens.next() orelse return error.PolicyFailure;
        if (!std.mem.eql(u8, modifier, "const")) return error.PolicyFailure;
        try tokens.expect("val");
        const name = try tokens.next() orelse return error.PolicyFailure;
        if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return error.PolicyFailure;
        try tokens.expect("=");
        try tokens.expect("\"literal\"");
        token = try tokens.next();
        if (token != null and std.mem.eql(u8, token.?, ";")) token = try tokens.next();
    }
}

fn kotlinBoundary(source: []const u8, at: usize) !void {
    var tokens = CsTokens{ .source = source, .kotlin = true };
    var braces: usize = 0;
    var parens: usize = 0;
    var brackets: usize = 0;
    var boundary: usize = 0;
    var found = false;
    while (try tokens.next()) |token| {
        // A file-local alias/import could change what the supposedly primitive Int constructor means, including when the alias follows the enum.
        if (std.mem.eql(u8, token, "typealias") or std.mem.eql(u8, token, "import")) return error.PolicyFailure;
        const offset = @intFromPtr(token.ptr) - @intFromPtr(source.ptr);
        if (offset == at) {
            if (braces != 0 or parens != 0 or brackets != 0) return error.PolicyFailure;
            try kotlinPrefix(source[boundary..at]);
            found = true;
        }
        if (std.mem.eql(u8, token, "{")) braces += 1;
        if (std.mem.eql(u8, token, "}")) {
            if (braces == 0) return error.PolicyFailure;
            braces -= 1;
            if (braces == 0 and parens == 0 and brackets == 0) boundary = tokens.cursor;
        }
        if (std.mem.eql(u8, token, "(")) parens += 1;
        if (std.mem.eql(u8, token, ")")) {
            if (parens == 0) return error.PolicyFailure;
            parens -= 1;
        }
        if (std.mem.eql(u8, token, "[")) brackets += 1;
        if (std.mem.eql(u8, token, "]")) {
            if (brackets == 0) return error.PolicyFailure;
            brackets -= 1;
        }
        // Do not let a semicolon hide an unsupported modifier/typealias prefix. Only complete prior top-level bodies establish a new boundary.
    }
    if (!found or braces != 0 or parens != 0 or brackets != 0) return error.PolicyFailure;
}

fn checkKotlinEnum(source: []const u8, at: usize, signature: []const u8, raw: []const u8, comptime declaration: []const u8, comptime members: []const Pair, comptime prefix: []const u8) !void {
    try kotlinBoundary(source, at);
    const ordinal_only = comptime std.mem.eql(u8, declaration, "enum class ValueKind");
    const property = comptime if (std.mem.eql(u8, declaration, "enum class Status")) "code" else "native";
    var header = CsTokens{ .source = signature, .kotlin = true };
    if (!ordinal_only) {
        try header.sequence("( val " ++ property ++ " : Int");
        const next = try header.next() orelse return error.PolicyFailure;
        if (std.mem.eql(u8, next, ",")) try header.expect(")") else if (!std.mem.eql(u8, next, ")")) return error.PolicyFailure;
    }
    if (try header.next() != null) return error.PolicyFailure;
    var tokens = CsTokens{ .source = raw, .kotlin = true };
    inline for (members, 0..) |member, index| {
        try tokens.expect(member[0]);
        var value: i64 = index;
        if (!ordinal_only) {
            try tokens.expect("(");
            const number = try tokens.next() orelse return error.PolicyFailure;
            for (number) |byte| if (!std.ascii.isDigit(byte)) return error.PolicyFailure;
            if (number.len > 1 and number[0] == '0') return error.PolicyFailure;
            value = std.fmt.parseInt(i32, number, 10) catch return error.PolicyFailure;
            try tokens.expect(")");
        }
        if (value != @field(c, prefix ++ member[0])) {
            std.debug.print("SDK ABI constant drift: {s}.{s}\n", .{ declaration, member[0] });
            return error.PolicyFailure;
        }
        if (index + 1 < members.len) try tokens.expect(",");
    }
    var next = try tokens.next() orelse return;
    if (std.mem.eql(u8, next, ",")) next = try tokens.next() orelse return;
    if (!std.mem.eql(u8, next, ";")) return error.PolicyFailure;
    if (try tokens.next() == null) return;
    if (ordinal_only) return error.PolicyFailure;
    // No init blocks, extra properties, entry subclasses, secondary constructors or arbitrary members can alter code/native or the conversion helpers.
    const tail = comptime if (std.mem.eql(u8, declaration, "enum class Status"))
        "companion object { fun of(code: Int) = entries.firstOrNull { it.code == code } ?: INVALID_ARGUMENT }"
    else if (std.mem.eql(u8, declaration, "enum class SubmissionStatus"))
        "companion object { fun of(value: Int): SubmissionStatus = entries.firstOrNull { it.native == value } ?: CANCELLED }"
    else if (std.mem.eql(u8, declaration, "enum class ShutdownPhase"))
        "companion object { fun of(value: Int): ShutdownPhase? = entries.firstOrNull { it.native == value } }"
    else if (std.mem.eql(u8, declaration, "enum class AdmissionClass"))
        "companion object { fun fromNative(value: Int): AdmissionClass? = entries.firstOrNull { it.native == value } }"
    else
        return error.PolicyFailure;
    // Rewind to just after the semicolon; the lookahead above only tested empty.
    var tail_tokens = CsTokens{ .source = raw[(std.mem.indexOfScalar(u8, raw, ';') orelse return error.PolicyFailure) + 1 ..], .kotlin = true };
    try tail_tokens.sequence(tail);
    if (try tail_tokens.next() != null) return error.PolicyFailure;
}

fn checkKotlinPackage(source: []const u8) !void {
    var tokens = CsTokens{ .source = source, .kotlin = true };
    try tokens.sequence("package io.jsbay");
    const next = try tokens.next() orelse return error.PolicyFailure;
    if (std.mem.eql(u8, next, ".")) return error.PolicyFailure;
}

fn checkEnum(allocator: std.mem.Allocator, input: []const u8, comptime declaration: []const u8, comptime members: []const Pair, comptime prefix: []const u8, comptime kotlin: bool) !void {
    // Lex the whole file before selecting a declaration. Decoy text in comments and literals must never qualify, and duplicate real declarations fail closed. Unsupported Unicode line terminators must not hide active code in a comment; ordinary Unicode prose inside comments/literals stays harmless.
    inline for (.{ "\xc2\x85", "\xe2\x80\xa8", "\xe2\x80\xa9" }) |newline| {
        if (std.mem.indexOf(u8, input, newline) != null) return error.PolicyFailure;
    }
    var clean_source: std.ArrayList(u8) = .empty;
    defer clean_source.deinit(allocator);
    try clean_source.append(allocator, ' ');
    var lexer = CsTokens{ .source = input, .kotlin = kotlin, .enum_mode = true };
    var conditional: usize = 0;
    while (try lexer.next()) |token| {
        if (std.mem.eql(u8, token, "#if JSBAY_TEST_HOOKS")) conditional += 1;
        if (std.mem.eql(u8, token, "#endif")) {
            if (conditional == 0) return error.PolicyFailure;
            conditional -= 1;
        }
        if (conditional != 0 and std.mem.eql(u8, token, "enum")) return error.PolicyFailure;
        try clean_source.appendSlice(allocator, if (token[0] == '"' or token[0] == '\'' or token[0] == '$') "\"literal\"" else token);
        try clean_source.append(allocator, ' ');
    }
    if (conditional != 0) return error.PolicyFailure;
    const source = clean_source.items;
    const needle = " " ++ declaration ++ " ";
    const selected = std.mem.indexOf(u8, source, needle) orelse return error.PolicyFailure;
    if (std.mem.indexOfPos(u8, source, selected + needle.len, needle) != null) return error.PolicyFailure;
    const at = selected + 1;
    const open = std.mem.indexOfScalarPos(u8, source, at + declaration.len, '{') orelse return error.PolicyFailure;
    const signature = trim(source[at + declaration.len .. open]);
    if (!kotlin and signature.len != 0 and !std.mem.eql(u8, signature, ": int")) return error.PolicyFailure;
    const raw = try body(source, declaration);
    if (kotlin) return checkKotlinEnum(source, at, signature, raw, declaration, members, prefix);
    // C# has language-defined implicit numbering; Kotlin constructor arguments were checked separately. C# member attributes may contain commas.
    const entries = raw;
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(allocator);
    var brackets: usize = 0;
    for (entries) |ch| {
        if (ch == '[') brackets += 1 else if (ch == ']') {
            if (brackets == 0) return error.PolicyFailure;
            brackets -= 1;
        } else if (brackets == 0) try clean.append(allocator, ch);
    }
    if (brackets != 0) return error.PolicyFailure;
    var tokens = std.mem.splitScalar(u8, clean.items, ',');
    var ordinal: i64 = 0;
    inline for (members) |member| {
        const entry = trim(tokens.next() orelse return error.PolicyFailure);
        const name = member[1];
        if (!std.mem.startsWith(u8, entry, name)) return error.PolicyFailure;
        const rest = trim(entry[name.len..]);
        if (rest.len != 0) {
            const number = if (rest[0] == '=') trim(rest[1..]) else return error.PolicyFailure;
            ordinal = std.fmt.parseInt(i64, number, 10) catch return error.PolicyFailure;
        }
        if (ordinal != @field(c, prefix ++ member[0])) {
            std.debug.print("SDK ABI constant drift: {s}.{s}\n", .{ declaration, name });
            return error.PolicyFailure;
        }
        ordinal += 1;
    }
    while (tokens.next()) |extra| if (trim(extra).len != 0) return error.PolicyFailure;
}

const FieldLayout = struct { size: usize, alignment: usize };
fn fieldLayout(name: []const u8) !FieldLayout {
    const names = .{ "IntPtr", "nuint", "uint", "int", "ulong", "byte", "Utf8" };
    const types = .{ usize, usize, u32, i32, u64, u8, c.jsbay_utf8_t };
    inline for (names, types) |n, T| if (std.mem.eql(u8, name, n)) return .{ .size = @sizeOf(T), .alignment = @min(8, @alignOf(T)) };
    return error.PolicyFailure;
}

// Tokenize supported Kotlin/C# declaration shapes while keeping comments and literals opaque. Enum mode permits narrowly recognized C# directives and simple interpolation; escaped identifiers and unsupported literal forms fail closed.
const CsTokens = struct {
    source: []const u8,
    cursor: usize = 0,
    kotlin: bool = false,
    enum_mode: bool = false,

    fn next(self: *CsTokens) error{PolicyFailure}!?[]const u8 {
        while (self.cursor < self.source.len) {
            const rest = self.source[self.cursor..];
            if (std.ascii.isWhitespace(rest[0])) {
                self.cursor += 1;
            } else if (std.mem.startsWith(u8, rest, "//")) {
                self.cursor += std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
            } else if (std.mem.startsWith(u8, rest, "/*")) {
                self.cursor += 2;
                var depth: usize = 1;
                while (depth != 0) {
                    if (self.cursor == self.source.len) return error.PolicyFailure;
                    const remaining = self.source[self.cursor..];
                    if (self.kotlin and std.mem.startsWith(u8, remaining, "/*")) {
                        depth += 1;
                        self.cursor += 2;
                    } else if (std.mem.startsWith(u8, remaining, "*/")) {
                        depth -= 1;
                        self.cursor += 2;
                    } else self.cursor += 1;
                }
            } else break;
        }
        if (self.cursor == self.source.len) return null;
        const start = self.cursor;
        var ch = self.source[start];
        if (self.enum_mode and !self.kotlin and ch == '#') {
            const end = start + (std.mem.indexOfAny(u8, self.source[start..], "\r\n") orelse self.source.len - start);
            const directive = trim(self.source[start..end]);
            if (!std.mem.eql(u8, directive, "#if JSBAY_TEST_HOOKS") and !std.mem.eql(u8, directive, "#endif")) return error.PolicyFailure;
            self.cursor = end;
            return directive;
        }
        var interpolated = false;
        if (self.enum_mode and !self.kotlin and std.mem.startsWith(u8, self.source[start..], "$\"")) {
            if (std.mem.startsWith(u8, self.source[start + 1 ..], "\"\"\"")) return error.PolicyFailure;
            self.cursor += 1;
            ch = '"';
            interpolated = true;
        }
        if (ch >= 128 or ch == '#' or (ch == '@' and !self.kotlin) or ch == '$' or ch == '`' or ch == '\\') return error.PolicyFailure;
        self.cursor += 1;
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            while (self.cursor < self.source.len and (std.ascii.isAlphanumeric(self.source[self.cursor]) or self.source[self.cursor] == '_')) self.cursor += 1;
        } else if (ch == '"' or ch == '\'') {
            if (std.mem.startsWith(u8, self.source[start..], "\"\"\"")) return error.PolicyFailure;
            while (self.cursor < self.source.len) {
                const byte = self.source[self.cursor];
                self.cursor += 1;
                // Kotlin expression interpolation has nested language syntax; unsupported here rather than misidentifying its quotes as code.
                if (self.kotlin and byte == '$' and self.cursor < self.source.len and self.source[self.cursor] == '{') return error.PolicyFailure;
                if (interpolated and byte == '{') {
                    // Only simple identifier/member interpolation is supported. Expressions containing nested quotes/braces fail closed.
                    while (self.cursor < self.source.len and self.source[self.cursor] != '}') : (self.cursor += 1) {
                        const b = self.source[self.cursor];
                        if (!std.ascii.isAlphanumeric(b) and b != '_' and b != '.' and b != ' ') return error.PolicyFailure;
                    }
                    if (self.cursor == self.source.len) return error.PolicyFailure;
                    self.cursor += 1;
                }
                if (byte == ch) return self.source[start..self.cursor];
                if (byte == '\n' or byte == '\r') return error.PolicyFailure;
                if (byte == '\\') {
                    if (self.cursor == self.source.len) return error.PolicyFailure;
                    self.cursor += 1;
                }
            }
            return error.PolicyFailure;
        }
        return self.source[start..self.cursor];
    }

    fn expect(self: *CsTokens, expected: []const u8) !void {
        if (!std.mem.eql(u8, try self.next() orelse return error.PolicyFailure, expected)) return error.PolicyFailure;
    }

    fn sequence(self: *CsTokens, expected: []const u8) !void {
        var tokens = CsTokens{ .source = expected };
        while (try tokens.next()) |token| try self.expect(token);
    }
};

fn checkStruct(tokens: *CsTokens, comptime name: []const u8, comptime T: type, comptime fields: []const Pair) !void {
    try tokens.sequence("[StructLayout(LayoutKind.Sequential)] internal");
    if (comptime std.mem.eql(u8, name, "Utf8")) try tokens.expect("readonly");
    try tokens.expect("struct");
    try tokens.expect(name);
    try tokens.expect("{");
    var offset: usize = 0;
    var max_alignment: usize = 1;
    inline for (fields) |field| {
        try tokens.expect("internal");
        var type_name = try tokens.next() orelse return error.PolicyFailure;
        if (std.mem.eql(u8, type_name, "readonly")) type_name = try tokens.next() orelse return error.PolicyFailure;
        try tokens.expect(field[0]);
        try tokens.expect(";");
        const layout = try fieldLayout(type_name);
        offset = std.mem.alignForward(usize, offset, layout.alignment);
        if (offset != @offsetOf(T, field[1]) or layout.size != @sizeOf(@FieldType(T, field[1]))) return error.PolicyFailure;
        offset += layout.size;
        max_alignment = @max(max_alignment, layout.alignment);
    }
    // Only the current constructor is supported. Consume its entire declaration and body, then require the struct to end: no hidden fields/auto-properties.
    if (comptime std.mem.eql(u8, name, "Utf8")) try tokens.sequence("internal Utf8(IntPtr data, nuint length) { Data = data; Length = length; }");
    try tokens.expect("}");
    if (std.mem.alignForward(usize, offset, max_alignment) != @sizeOf(T) or max_alignment != @alignOf(T)) return error.PolicyFailure;
}

fn checkLayout(source: []const u8, comptime name: []const u8, comptime T: type, comptime fields: []const Pair) !void {
    // C# also treats Unicode line separators as newlines. This deliberately ASCII-only subset must not hide declarations inside such comments.
    for (source) |byte| if (byte >= 128) return error.PolicyFailure;
    var tokens = CsTokens{ .source = source };
    var boundary: usize = 0;
    var found = false;
    while (try tokens.next()) |token| {
        if (std.mem.eql(u8, token, "struct")) {
            var lookahead = tokens;
            if (std.mem.eql(u8, try lookahead.next() orelse return error.PolicyFailure, name)) {
                if (found) return error.PolicyFailure; // partial/duplicate declarations are unsupported
                found = true;
                // Include all metadata/modifiers since the previous declaration boundary; an attribute in a comment or on another type cannot qualify.
                var declaration = CsTokens{ .source = source[boundary..] };
                try checkStruct(&declaration, name, T, fields);
            }
        }
        if (std.mem.eql(u8, token, ";") or std.mem.eql(u8, token, "{") or std.mem.eql(u8, token, "}")) boundary = tokens.cursor;
    }
    if (!found) return error.PolicyFailure;
}

fn checkNative(source: []const u8) !void {
    try checkLayout(source, "Utf8", c.jsbay_utf8_t, &.{ .{ "Data", "data" }, .{ "Length", "len" } });
    try checkLayout(source, "Bytes", c.jsbay_bytes_t, &.{ .{ "Data", "data" }, .{ "Length", "len" } });
    try checkLayout(source, "EvaluateOptions", c.jsbay_engine_evaluate_options_t, &.{ .{ "StructSize", "struct_size" }, .{ "CacheDirectory", "cache_dir" }, .{ "CacheVersion", "cache_version" }, .{ "CacheHit", "out_cache_hit" } });
    try checkLayout(source, "ShutdownStatusNative", c.jsbay_shutdown_status_t, &.{ .{ "Phase", "phase" }, .{ "RemainingMilliseconds", "remaining_ms" } });
    try checkLayout(source, "ResourceLimitsNative", c.jsbay_resource_limits_t, &.{ .{ "StructSize", "struct_size" }, .{ "MaxTimers", "max_timers" }, .{ "MaxTsfnHandles", "max_tsfn_handles" }, .{ "MaxPendingCalls", "max_pending_calls" }, .{ "MaxPendingBytes", "max_pending_bytes" }, .{ "MaxPendingTasks", "max_pending_tasks" } });
}

pub fn check(allocator: std.mem.Allocator, io: std.Io) !void {
    const kotlin_root = "sdk/android/jsbay/src/main/kotlin/io/jsbay/";
    const cs_root = "sdk/dotnet/JsBay/";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kstatus = try std.Io.Dir.cwd().readFileAlloc(io, kotlin_root ++ "Status.kt", a, .limited(1024 * 1024));
    const ksubmission = try std.Io.Dir.cwd().readFileAlloc(io, kotlin_root ++ "Submission.kt", a, .limited(1024 * 1024));
    const kadmission = try std.Io.Dir.cwd().readFileAlloc(io, kotlin_root ++ "AdmissionClass.kt", a, .limited(1024 * 1024));
    const csstatus = try std.Io.Dir.cwd().readFileAlloc(io, cs_root ++ "Status.cs", a, .limited(1024 * 1024));
    const csengine = try std.Io.Dir.cwd().readFileAlloc(io, cs_root ++ "Engine.cs", a, .limited(1024 * 1024));
    const native = try std.Io.Dir.cwd().readFileAlloc(io, cs_root ++ "Native.cs", a, .limited(1024 * 1024));
    try checkKotlinPackage(kstatus);
    try checkKotlinPackage(ksubmission);
    try checkKotlinPackage(kadmission);
    try checkEnum(a, kstatus, "enum class Status", &status, "JSBAY_", true);
    try checkEnum(a, kstatus, "enum class ValueKind", &kinds, "JSBAY_VALUE_", true);
    try checkEnum(a, ksubmission, "enum class SubmissionStatus", &submission, "JSBAY_SUBMISSION_", true);
    try checkEnum(a, ksubmission, "enum class ShutdownPhase", &shutdown, "JSBAY_SHUTDOWN_", true);
    try checkEnum(a, kadmission, "enum class AdmissionClass", &admission, "JSBAY_ADMISSION_", true);
    try checkEnum(a, csstatus, "enum Status", &status, "JSBAY_", false);
    try checkEnum(a, csstatus, "enum ValueKind", &kinds, "JSBAY_VALUE_", false);
    try checkEnum(a, csstatus, "enum SubmissionStatus", &submission, "JSBAY_SUBMISSION_", false);
    try checkEnum(a, csstatus, "enum ShutdownPhase", &shutdown, "JSBAY_SHUTDOWN_", false);
    try checkEnum(a, csengine, "enum AdmissionClass", &admission, "JSBAY_ADMISSION_", false);
    try checkNative(native);
}

test "SDK ABI: live Kotlin/C# constants and host sequential layouts match public header" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try check(std.testing.allocator, threaded.io());
}

test "SDK ABI: intentional explicit, implicit and extra enum drift is rejected" {
    const a = std.testing.allocator;
    const one = [_]Pair{.{ "OK", "Ok" }};
    try checkEnum(a, "enum class Status(val code: Int) { OK(0); }", "enum class Status", &one, "JSBAY_", true);
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum class Status(val code: Int) { OK(99); }", "enum class Status", &one, "JSBAY_", true));
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum Status { Ok = 99 }", "enum Status", &one, "JSBAY_", false));
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum Status { Other, Ok }", "enum Status", &one, "JSBAY_", false));
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum Status { Ok, Extra }", "enum Status", &one, "JSBAY_", false));
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum Status { Ok = UNKNOWN }", "enum Status", &one, "JSBAY_", false));
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum Status : byte { Ok }", "enum Status", &one, "JSBAY_", false));
}

test "SDK ABI: intentional field width, order and packing drift is rejected" {
    const fields = &[_]Pair{ .{ "Data", "data" }, .{ "Length", "len" } };
    const start = "[StructLayout(LayoutKind.Sequential)] internal struct Bytes { ";
    try checkLayout(start ++ "internal IntPtr Data; internal nuint Length; }", "Bytes", c.jsbay_bytes_t, fields);
    try std.testing.expectError(error.PolicyFailure, checkLayout(start ++ "internal uint Data; internal nuint Length; }", "Bytes", c.jsbay_bytes_t, fields));
    try std.testing.expectError(error.PolicyFailure, checkLayout(start ++ "internal nuint Length; internal IntPtr Data; }", "Bytes", c.jsbay_bytes_t, fields));
    try std.testing.expectError(error.PolicyFailure, checkLayout("[StructLayout(LayoutKind.Sequential, Pack = 1)] internal struct Bytes { internal IntPtr Data; internal nuint Length; }", "Bytes", c.jsbay_bytes_t, fields));
}

test "SDK ABI: live-source mutations are detected without changing SDK files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const kt = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), "sdk/android/jsbay/src/main/kotlin/io/jsbay/Status.kt", a, .limited(1024 * 1024));
    const changed_kt = try std.mem.replaceOwned(u8, a, kt, "LOOP_FAILED(8)", "LOOP_FAILED(99)");
    try std.testing.expect(!std.mem.eql(u8, kt, changed_kt));
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, changed_kt, "enum class Status", &status, "JSBAY_", true));
    const cs = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), "sdk/dotnet/JsBay/Status.cs", a, .limited(1024 * 1024));
    const changed_cs = try std.mem.replaceOwned(u8, a, cs, "BigInt,", "BigInt = 99,");
    try std.testing.expect(!std.mem.eql(u8, cs, changed_cs));
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, changed_cs, "enum ValueKind", &kinds, "JSBAY_VALUE_", false));
    const native = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), "sdk/dotnet/JsBay/Native.cs", a, .limited(1024 * 1024));
    const changed_native = try std.mem.replaceOwned(u8, a, native, "internal IntPtr Data; internal nuint Length;", "internal uint Data; internal nuint Length;");
    try std.testing.expect(!std.mem.eql(u8, native, changed_native));
    try std.testing.expectError(error.PolicyFailure, checkNative(changed_native));
}

test "SDK ABI: Utf8 constructor tail and declaration metadata fail closed" {
    const start = "[StructLayout(LayoutKind.Sequential)] internal readonly struct Utf8 { internal readonly IntPtr Data; internal readonly nuint Length; ";
    const constructor = "internal Utf8(IntPtr data, nuint length) { Data = data; Length = length; }";
    const fields = &[_]Pair{ .{ "Data", "data" }, .{ "Length", "len" } };
    try checkLayout(start ++ constructor ++ " }", "Utf8", c.jsbay_utf8_t, fields);
    const extras = .{
        "public readonly ulong Extra = 0;",
        "// comment\r public readonly ulong Extra = 0;",
        "// comment\xe2\x80\xa8 public readonly ulong Extra = 0;",
        "private readonly ulong Extra = 0;",
        "internal ulong Extra;",
        "public ulong Extra { get; } = 0;",
        "internal readonly ulong Extra;",
        "public event System.Action Extra;",
        "[field: MarshalAs(UnmanagedType.U8)] public ulong Extra { get; }",
    };
    inline for (extras) |extra| {
        try std.testing.expectError(error.PolicyFailure, checkLayout(start ++ constructor ++ extra ++ " }", "Utf8", c.jsbay_utf8_t, fields));
    }
    const declarations = .{
        "// [StructLayout(LayoutKind.Sequential)]\n internal readonly struct Utf8 { ",
        "[StructLayout(LayoutKind.Explicit)] // [StructLayout(LayoutKind.Sequential)]\n internal readonly struct Utf8 { ",
        "[StructLayout(LayoutKind.Sequential, Size = 64)] internal readonly struct Utf8 { ",
        "[StructLayout(LayoutKind.Sequential, Size = 64)] // [StructLayout(LayoutKind.Sequential)]\n internal readonly struct Utf8 { ",
        "[StructLayout(LayoutKind.Sequential, Pack = 1)] internal readonly struct Utf8 { ",
        "[StructLayout(LayoutKind.Explicit)] internal readonly struct Utf8 { ",
        "[Obsolete] [StructLayout(LayoutKind.Sequential)] internal readonly struct Utf8 { ",
        "[StructLayout(LayoutKind.Sequential)] internal readonly partial struct Utf8 { ",
        "[StructLayout(LayoutKind.Sequential)] internal readonly struct Utf8 : IFoo { ",
    };
    inline for (declarations) |declaration| {
        try std.testing.expectError(error.PolicyFailure, checkLayout(declaration ++ "internal readonly IntPtr Data; internal readonly nuint Length; " ++ constructor ++ " }", "Utf8", c.jsbay_utf8_t, fields));
    }
    try std.testing.expectError(error.PolicyFailure, checkLayout(start ++ constructor ++ " } internal readonly partial struct Utf8 { internal readonly ulong Extra; }", "Utf8", c.jsbay_utf8_t, fields));
    // A valid-looking commented declaration must not stand in for the real one.
    try std.testing.expectError(error.PolicyFailure, checkLayout("/* " ++ start ++ constructor ++ " } */", "Utf8", c.jsbay_utf8_t, fields));
}

test "SDK ABI: layout tokenization ignores comment and string decoys, not declarations" {
    const valid = "[StructLayout(LayoutKind.Sequential)] internal readonly struct Utf8 { internal /* field */ readonly IntPtr Data; internal readonly nuint Length; internal Utf8(IntPtr data, nuint length) { Data = data; Length = length; } }";
    const fields = &[_]Pair{ .{ "Data", "data" }, .{ "Length", "len" } };
    try checkLayout("/* struct Utf8 { } */ " ++ valid ++ " // struct Utf8\n", "Utf8", c.jsbay_utf8_t, fields);
    try checkLayout("const string Decoy = \"struct Utf8 { }\"; " ++ valid, "Utf8", c.jsbay_utf8_t, fields);
    try std.testing.expectError(error.PolicyFailure, checkLayout("const string Decoy = \"" ++ valid ++ "\";", "Utf8", c.jsbay_utf8_t, fields));
    try std.testing.expectError(error.PolicyFailure, checkLayout("#if false\n" ++ valid ++ "\n#endif", "Utf8", c.jsbay_utf8_t, fields));
    try std.testing.expectError(error.PolicyFailure, checkLayout(valid ++ " internal struct U\\u0074f8 { }", "Utf8", c.jsbay_utf8_t, fields));
    try std.testing.expectError(error.PolicyFailure, checkLayout(valid ++ " /* unterminated", "Utf8", c.jsbay_utf8_t, fields));
}

test "SDK ABI: enum comment and literal decoys cannot mask live drift in either language" {
    const a = std.testing.allocator;
    const one = [_]Pair{.{ "OK", "Ok" }};
    inline for (.{ true, false }) |kotlin| {
        const declaration = if (kotlin) "enum class Status" else "enum Status";
        const valid = if (kotlin) "enum class Status(val code: Int) { OK(0); }" else "enum Status { Ok = 0 }";
        const wrong = if (kotlin) "enum class Status(val code: Int) { OK(99); }" else "enum Status { Ok = 99 }";
        const literal_prefix = if (kotlin) "const val decoy = " else "const string decoy = ";
        inline for (.{ "/* " ++ valid ++ " */ ", "// " ++ valid ++ "\n", literal_prefix ++ "\"" ++ valid ++ "\"; " }) |decoy| {
            try checkEnum(a, decoy ++ valid, declaration, &one, "JSBAY_", kotlin);
            try std.testing.expectError(error.PolicyFailure, checkEnum(a, decoy ++ wrong, declaration, &one, "JSBAY_", kotlin));
            try std.testing.expectError(error.PolicyFailure, checkEnum(a, decoy, declaration, &one, "JSBAY_", kotlin));
        }
        try std.testing.expectError(error.PolicyFailure, checkEnum(a, valid ++ " " ++ valid, declaration, &one, "JSBAY_", kotlin));
        try std.testing.expectError(error.PolicyFailure, checkEnum(a, valid ++ " " ++ wrong, declaration, &one, "JSBAY_", kotlin));
        try checkEnum(a, if (kotlin) "enum /* harmless */ class Status(val code: Int) { OK(/* zero */ 0); }" else "enum /* harmless */ Status { Ok /* zero */ = 0 }", declaration, &one, "JSBAY_", kotlin);
    }
}

test "SDK ABI: enum lexer fails closed on unsupported literals, directives and escaped names" {
    const a = std.testing.allocator;
    const one = [_]Pair{.{ "OK", "Ok" }};
    const kt = "enum class Status(val code: Int) { OK(0); }";
    // Kotlin block comments nest; an inner terminator must not expose a decoy.
    try checkEnum(a, "/* outer /* inner */ enum class Status(val code: Int) { OK(99); } */ " ++ kt, "enum class Status", &one, "JSBAY_", true);
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "/* outer /* inner */ " ++ kt, "enum class Status", &one, "JSBAY_", true));
    inline for (.{ "val text = \"\"\"" ++ kt ++ "\"\"\"; ", "val text = \"${ call(\"enum class Status\") }\"; ", "enum class `Status` { OK(0); } ", "// unicode\xe2\x80\xa8" }) |prefix| {
        try std.testing.expectError(error.PolicyFailure, checkEnum(a, prefix ++ kt, "enum class Status", &one, "JSBAY_", true));
    }
    const cs = "enum Status { Ok = 0 }";
    inline for (.{ "var text = @\"" ++ cs ++ "\"; ", "var text = \"\"\"" ++ cs ++ "\"\"\"; ", "var text = $\"\"\"" ++ cs ++ "\"\"\"; ", "#if false\n" ++ cs ++ "\n#endif\n", "enum @Status { Ok = 0 } ", "// unicode\xe2\x80\xa8" }) |prefix| {
        try std.testing.expectError(error.PolicyFailure, checkEnum(a, prefix ++ cs, "enum Status", &one, "JSBAY_", false));
    }
    try checkEnum(a, "var text = $\"enum Status {name}\"; " ++ cs, "enum Status", &one, "JSBAY_", false);
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "#if JSBAY_TEST_HOOKS\n" ++ cs ++ "\n#endif", "enum Status", &one, "JSBAY_", false));
}

test "SDK ABI: Kotlin native-code constructors never borrow implicit ordinal numbering" {
    const a = std.testing.allocator;
    const one = [_]Pair{.{ "OK", "Ok" }};
    try checkEnum(a, "enum class Status(val code: Int,) { OK(0),; }", "enum class Status", &one, "JSBAY_", true);
    const declarations = .{
        "enum class Status(val code: Int = 99) { OK; }",
        "enum class Status(val code: Int = 0) { OK; }",
        "enum class Status(val code: Int = 99) { OK(0); }",
        "enum class Status(val code: Int) { OK; }",
        "enum class Status { OK; }",
        "enum class Status(val code: Long) { OK(0); }",
        "enum class Status(val code: kotlin.Int) { OK(0); }",
        "enum class Status(val code: Int?) { OK(0); }",
        "enum class Status(var code: Int) { OK(0); }",
        "enum class Status(code: Int) { OK(0); val code = 99 }",
        "enum class Status(val native: Int) { OK(0); }",
        "enum class Status(val code: Int, val other: Int = 99) { OK(0); }",
        "enum class Status private constructor(val code: Int) { OK(0); }",
        "enum class Status(val code: Int) : Other { OK(0); }",
    };
    inline for (declarations) |source| try std.testing.expectError(error.PolicyFailure, checkEnum(a, source, "enum class Status", &one, "JSBAY_", true));
    inline for (.{ "99", "0x0", "0b0", "00", "+0", "-0", "0L", "0U", "0_0", "0 + 0", "(0)", "code = 0", "ZERO" }) |number| {
        try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum class Status(val code: Int) { OK(" ++ number ++ "); }", "enum class Status", &one, "JSBAY_", true));
    }
}

test "SDK ABI: Kotlin enum headers and all body members are inside the closed subset" {
    const a = std.testing.allocator;
    const one = [_]Pair{.{ "OK", "Ok" }};
    const valid = "enum class Status(val code: Int) { OK(0); }";
    inline for (.{ "open ", "private ", "@Deprecated(\"old\") ", "class Holder { " }) |prefix| {
        try std.testing.expectError(error.PolicyFailure, checkEnum(a, prefix ++ valid ++ (if (comptime std.mem.startsWith(u8, prefix, "class")) " }" else ""), "enum class Status", &one, "JSBAY_", true));
    }
    inline for (.{ "init { error(\"changed\") }", "val other = 99", "constructor() : this(99)", "companion object { fun of(code: Int) = OK }" }) |member| {
        try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum class Status(val code: Int) { OK(0); " ++ member ++ " }", "enum class Status", &one, "JSBAY_", true));
    }
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum class Status(open val code: Int) { OK(0) { override val code get() = 99 }; }", "enum class Status", &one, "JSBAY_", true));
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum class Status(val code: Int) { OK(0) { override fun toString() = \"x\" }; }", "enum class Status", &one, "JSBAY_", true));
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, valid ++ " typealias Int = Long", "enum class Status", &one, "JSBAY_", true));
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "import kotlin.Long as Int; " ++ valid, "enum class Status", &one, "JSBAY_", true));
    try checkEnum(a, "package io.jsbay\nprivate const val decoy = \"enum class Status\"\n" ++ valid, "enum class Status", &one, "JSBAY_", true);
    try checkEnum(a, "enum /* type */ class Status(val /* property */ code: Int,) { OK(/* code */ 0); /* body */ }", "enum class Status", &one, "JSBAY_", true);
    try std.testing.expectError(error.PolicyFailure, checkKotlinPackage("package io.jsbay.other\n" ++ valid));
}

test "SDK ABI: only Kotlin ValueKind uses entries ordinals; Csharp implicit enum values remain supported" {
    const a = std.testing.allocator;
    const first_kind = [_]Pair{.{ "UNDEFINED", "Undefined" }};
    try checkEnum(a, "enum class ValueKind { UNDEFINED,; }", "enum class ValueKind", &first_kind, "JSBAY_VALUE_", true);
    inline for (.{ "enum class ValueKind(val code: Int = 99) { UNDEFINED }", "enum class ValueKind { UNDEFINED(0) }", "enum class ValueKind { UNDEFINED; val code = 99 }" }) |source| {
        try std.testing.expectError(error.PolicyFailure, checkEnum(a, source, "enum class ValueKind", &first_kind, "JSBAY_VALUE_", true));
    }
    const two = [_]Pair{ status[0], status[1] };
    try checkEnum(a, "enum Status { Ok, Exception }", "enum Status", &two, "JSBAY_", false);
    try checkEnum(a, "enum Status { Ok = 0, Exception }", "enum Status", &two, "JSBAY_", false);
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum Status { Ok = 99, Exception }", "enum Status", &two, "JSBAY_", false));
    const native_one = [_]Pair{.{ "COMPLETED", "Completed" }};
    try checkEnum(a, "enum class SubmissionStatus(val native: Int) { COMPLETED(0) }", "enum class SubmissionStatus", &native_one, "JSBAY_SUBMISSION_", true);
    try std.testing.expectError(error.PolicyFailure, checkEnum(a, "enum class SubmissionStatus(val native: Int = 99) { COMPLETED }", "enum class SubmissionStatus", &native_one, "JSBAY_SUBMISSION_", true));
}
