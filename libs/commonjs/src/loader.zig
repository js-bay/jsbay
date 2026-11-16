//! Narrow loader contract and ownership boundary. No VM headers or engine imports.
const std = @import("std");

/// Borrowed source bytes, valid after load returns until the caller copies them.
pub const LoadResult = extern struct { source: [*]const u8, source_len: usize };
pub const LoaderVTable = extern struct {
    /// Optional canonicalization; null result means identity. Inputs are borrowed NUL-terminated strings. Non-null output is copied before free_resolved.
    resolve: ?*const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) ?[*:0]u8 = null,
    load: *const fn (?*anyopaque, [*:0]const u8, *LoadResult) callconv(.c) bool,
    /// Null means the host retains ownership (for example static output).
    free_resolved: ?*const fn (?*anyopaque, [*:0]u8) callconv(.c) void = null,
};
/// Borrowed only for the synchronous require transaction, never retained.
pub const Loader = extern struct { vtable: *const LoaderVTable, user_data: ?*anyopaque = null };

pub const ResolvedId = struct {
    /// Canonical id borrows the specifier on identity fallback; otherwise it is owned by the explicit allocator through buf.
    id: []const u8,
    allocator: std.mem.Allocator,
    buf: ?[]u8 = null, // owned by allocator when non-null

    pub fn deinit(self: ResolvedId) void {
        if (self.buf) |b| self.allocator.free(b);
    }
};

pub fn resolveSpecifier(
    allocator: std.mem.Allocator,
    loader: *const Loader,
    specifier: []const u8,
    referrer: []const u8,
) !ResolvedId {
    const resolve = loader.vtable.resolve orelse {
        return .{ .id = specifier, .allocator = allocator, .buf = null };
    };

    const ref_z = try allocator.dupeSentinel(u8, referrer, 0);
    defer allocator.free(ref_z);
    const spec_z = try allocator.dupeSentinel(u8, specifier, 0);
    defer allocator.free(spec_z);

    const user_out = resolve(loader.user_data, ref_z.ptr, spec_z.ptr);
    if (user_out == null) {
        return .{ .id = specifier, .allocator = allocator, .buf = null };
    }
    const out_slice = std.mem.span(user_out.?);
    // Copy before releasing the callback output. Copy failure still releases that output.
    const buf = allocator.dupe(u8, out_slice) catch |err| {
        if (loader.vtable.free_resolved) |fr| fr(loader.user_data, user_out.?);
        return err;
    };
    if (loader.vtable.free_resolved) |fr| fr(loader.user_data, user_out.?);
    return .{ .id = buf, .allocator = allocator, .buf = buf };
}

pub fn loadSource(allocator: std.mem.Allocator, loader: *const Loader, canonical_id: []const u8) std.mem.Allocator.Error!?[]u8 {
    const id_z = try allocator.dupeSentinel(u8, canonical_id, 0);
    defer allocator.free(id_z);

    var out: LoadResult = .{ .source = undefined, .source_len = 0 };
    if (!loader.vtable.load(loader.user_data, id_z.ptr, &out)) return null;

    // Source is host-owned across the callback return; the returned copy belongs to allocator.
    const src = try allocator.alloc(u8, out.source_len);
    if (out.source_len > 0) {
        @memcpy(src, out.source[0..out.source_len]);
    }
    return src;
}

pub fn dirnameOf(path: []const u8) []const u8 {
    // Use the last '/' or '\\' as the separator. On "no separator found", Node returns ".", so mirror that.
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        const c = path[i - 1];
        if (c == '/' or c == '\\') {
            if (i == 1) return path[0..1]; // preserve root "/"
            return path[0 .. i - 1];
        }
    }
    return ".";
}

const Probe = struct {
    releases: usize = 0,
    resolves: usize = 0,
    identity: bool = false,

    fn resolve(opaque_ptr: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) ?[*:0]u8 {
        const self: *Probe = @ptrCast(@alignCast(opaque_ptr.?));
        self.resolves += 1;
        return if (self.identity) null else @constCast("resolved");
    }

    fn release(opaque_ptr: ?*anyopaque, _: [*:0]u8) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(opaque_ptr.?));
        self.releases += 1;
    }

    fn load(_: ?*anyopaque, _: [*:0]const u8, out: *LoadResult) callconv(.c) bool {
        out.* = .{ .source = "bytes", .source_len = 5 };
        return true;
    }
    const vtable = LoaderVTable{ .resolve = resolve, .free_resolved = release, .load = load };
};

test "cjs loader: identity borrows, resolved IDs and loaded source own independent copies" {
    const allocator = std.testing.allocator;
    var probe = Probe{ .identity = true };
    const loader = Loader{ .vtable = &Probe.vtable, .user_data = &probe };
    const spec = "specifier";
    const identity = try resolveSpecifier(allocator, &loader, spec, "<cjs>");
    defer identity.deinit();
    try std.testing.expect(identity.buf == null);
    try std.testing.expectEqual(@intFromPtr(spec.ptr), @intFromPtr(identity.id.ptr));
    probe.identity = false;
    const resolved = try resolveSpecifier(allocator, &loader, spec, "<cjs>");
    defer resolved.deinit();
    try std.testing.expect(resolved.buf != null);
    try std.testing.expectEqualStrings("resolved", resolved.id);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
    const source = (try loadSource(allocator, &loader, resolved.id)) orelse return error.MissingSource;
    defer allocator.free(source);
    source[0] = 'B';
    try std.testing.expectEqualStrings("Bytes", source);
    try std.testing.expectEqualStrings("resolved", resolved.id);
}

test "cjs loader: failed resolved copy still releases callback output" {
    var probe = Probe{};
    const loader = Loader{ .vtable = &Probe.vtable, .user_data = &probe };
    // The referrer and specifier sentinel copies succeed; the resolved-ID copy fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    try std.testing.expectError(error.OutOfMemory, resolveSpecifier(failing.allocator(), &loader, "specifier", "<cjs>"));
    try std.testing.expectEqual(@as(usize, 1), probe.resolves);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
}

test "cjs loader: absent resolver and borrowed host output need no release callback" {
    const vtable = LoaderVTable{ .load = Probe.load };
    const loader = Loader{ .vtable = &vtable };
    const resolved = try resolveSpecifier(std.testing.allocator, &loader, "static", "<cjs>");
    defer resolved.deinit();
    try std.testing.expect(resolved.buf == null);
    try std.testing.expectEqualStrings("static", resolved.id);
    var probe = Probe{};
    const borrowed_vtable = LoaderVTable{ .resolve = Probe.resolve, .load = Probe.load };
    const borrowed_loader = Loader{ .vtable = &borrowed_vtable, .user_data = &probe };
    const copied = try resolveSpecifier(std.testing.allocator, &borrowed_loader, "static", "<cjs>");
    defer copied.deinit();
    try std.testing.expect(copied.buf != null);
    try std.testing.expectEqualStrings("resolved", copied.id);
    try std.testing.expectEqual(@as(usize, 0), probe.releases);
    try std.testing.expectEqualStrings("/", dirnameOf("/a.js"));
    try std.testing.expectEqualStrings("a", dirnameOf("a/b.js"));
    try std.testing.expectEqualStrings(".", dirnameOf("a.js"));
}
