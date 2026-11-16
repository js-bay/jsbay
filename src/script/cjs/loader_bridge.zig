//! Adapt the existing public engine loader to the package's narrow loader. The temporary bridge/vtable and loader are borrowed only during require().
const commonjs = @import("commonjs");
const types = @import("../../types.zig");

pub const Bridge = struct {
    vtable: commonjs.LoaderVTable,
    host: *const types.ModuleLoader,

    pub fn init(host: *const types.ModuleLoader) Bridge {
        return .{ .host = host, .vtable = .{
            .resolve = if (host.vtable.resolve != null) resolve else null,
            .load = load,
            .free_resolved = if (host.vtable.free_resolved != null) release else null,
        } };
    }
    pub fn loader(self: *const Bridge) commonjs.Loader {
        return .{ .vtable = &self.vtable, .user_data = @ptrCast(@constCast(self.host)) };
    }
    fn hostLoader(opaque_ptr: ?*anyopaque) *const types.ModuleLoader {
        return @ptrCast(@alignCast(opaque_ptr.?));
    }
    fn resolve(opaque_ptr: ?*anyopaque, referrer: [*:0]const u8, specifier: [*:0]const u8) callconv(.c) ?[*:0]u8 {
        const host = hostLoader(opaque_ptr);
        return host.vtable.resolve.?(host.user_data, referrer, specifier);
    }
    fn load(opaque_ptr: ?*anyopaque, id: [*:0]const u8, out: *commonjs.LoadResult) callconv(.c) bool {
        const host = hostLoader(opaque_ptr);
        var result: types.ModuleLoadResult = undefined;
        if (!host.vtable.load(host.user_data, id, &result)) return false;
        out.* = .{ .source = result.source, .source_len = result.source_len };
        return true;
    }
    fn release(opaque_ptr: ?*anyopaque, resolved: [*:0]u8) callconv(.c) void {
        const host = hostLoader(opaque_ptr);
        host.vtable.free_resolved.?(host.user_data, resolved);
    }
};
