//! WebKit Inspector Relay client.
//!
//! The relay sends length-prefixed binary plists: a four-byte big-endian payload length followed by
//! a plist dictionary with `messageName` and `userInfo`. Protocol JSON travels inside the `data`
//! value under `WIRSocketDataKey`. This client only owns the transport, discovery, and attach
//! handshake; CDP translation lives above it.

const std = @import("std");
const plist = @import("plist.zig");
const zev = @import("zev");

const Allocator = std.mem.Allocator;

pub const Error = error{
    ConnectFailed,
    SocketFailed,
    WriteFailed,
    ReadFailed,
    FrameTooLarge,
    Closed,
    DiscoveryTimeout,
    DiscoveryFailed,
} || plist.Error || std.Thread.SpawnError;

const max_frame_bytes: usize = 32 * 1024 * 1024;

/// Enables frame dumps on stderr for transport diagnosis.
pub var trace_enabled = false;

const sockaddr_un = extern struct {
    len: u8 = 0,
    family: u8 = 0,
    path: [104]u8 = @splat(0),
};

pub const Message = struct {
    /// Owned by `arena`.
    name: []const u8,
    info: plist.Value,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Message, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

pub const Target = struct {
    application: []u8,
    application_name: []u8,
    page: i64,
    title: []u8,

    pub fn deinit(self: *Target, allocator: Allocator) void {
        allocator.free(self.application);
        allocator.free(self.application_name);
        allocator.free(self.title);
    }
};

pub const Client = struct {
    allocator: Allocator,
    fd: std.posix.fd_t,
    connection_id: []u8,
    /// Relay sender registered by `_rpc_forwardSocketSetup`. The target addresses replies to it.
    sender_id: []u8,
    send_mutex: zev.Mutex = .{},
    queue_mutex: zev.Mutex = .{},
    queue_changed: zev.Condition = .init,
    queue: std.ArrayListUnmanaged(Message) = .empty,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reader: ?std.Thread = null,

    pub fn connect(allocator: Allocator, io: std.Io, path: []const u8) Error!*Client {
        if (path.len == 0 or path.len >= 104) return error.ConnectFailed;
        const raw = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        if (raw < 0) return error.SocketFailed;
        const fd: std.posix.fd_t = @intCast(raw);
        errdefer _ = std.posix.system.close(fd);

        var address = sockaddr_un{};
        address.len = @intCast(@sizeOf(sockaddr_un));
        address.family = @intCast(std.posix.AF.UNIX);
        @memcpy(address.path[0..path.len], path);
        if (std.posix.system.connect(fd, @ptrCast(&address), @sizeOf(sockaddr_un)) < 0) return error.ConnectFailed;

        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .fd = fd,
            .connection_id = try uuid4(io, allocator),
            .sender_id = try uuid4(io, allocator),
        };
        errdefer allocator.free(self.sender_id);
        errdefer allocator.free(self.connection_id);
        self.reader = std.Thread.spawn(.{}, readerMain, .{self}) catch |err| {
            allocator.free(self.connection_id);
            allocator.destroy(self);
            return err;
        };
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.close();
        if (self.reader) |thread| thread.join();
        self.reader = null;
        self.drain();
        self.queue.deinit(self.allocator);
        self.queue_changed.deinit();
        self.queue_mutex.deinit();
        self.send_mutex.deinit();
        self.allocator.free(self.sender_id);
        self.allocator.free(self.connection_id);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn close(self: *Client) void {
        if (self.closed.swap(true, .acq_rel)) return;
        _ = std.posix.system.shutdown(self.fd, std.posix.SHUT.RDWR);
        self.queue_mutex.lock();
        self.queue_changed.broadcast();
        self.queue_mutex.unlock();
    }

    /// Sends one relay message. The value is copied into the frame before this returns.
    pub fn send(self: *Client, selector: []const u8, info: plist.Value) Error!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const envelope = plist.Value{ .dict = &.{
            .{ .key = "__selector", .value = .{ .string = selector } },
            .{ .key = "__argument", .value = info },
        } };
        const bytes = try plist.encode(allocator, envelope);
        if (bytes.len > max_frame_bytes) return error.FrameTooLarge;
        traceFrame("send", selector, bytes);

        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        const frame = try allocator.alloc(u8, bytes.len + 4);
        std.mem.writeInt(u32, frame[0..4], @intCast(bytes.len), .big);
        @memcpy(frame[4..], bytes);
        try self.writeAll(frame);
    }

    /// Waits for the next relay message. A null result means the deadline expired or the client closed.
    pub fn next(self: *Client, timeout_ms: ?u64) Error!?Message {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        while (self.queue.items.len == 0) {
            if (self.closed.load(.acquire)) return null;
            const result = self.queue_changed.waitTimeout(&self.queue_mutex, timeout_ms);
            if (result == .timed_out) return null;
        }
        return self.queue.orderedRemove(0);
    }

    /// Returns true once the relay socket closed or the owner shut the client down.
    pub fn isClosed(self: *Client) bool {
        return self.closed.load(.acquire);
    }

    pub fn sendSocketData(self: *Client, target: *const Target, json: []const u8) Error!void {
        try self.sendData(target, self.sender_id, json);
    }

    pub fn sendData(self: *Client, target: *const Target, sender_id: []const u8, json: []const u8) Error!void {
        try self.send("_rpc_forwardSocketData:", .{ .dict = &.{
            .{ .key = "WIRSocketDataKey", .value = .{ .data = json } },
            .{ .key = "WIRConnectionIdentifierKey", .value = .{ .string = self.connection_id } },
            .{ .key = "WIRSenderKey", .value = .{ .string = sender_id } },
            .{ .key = "WIRApplicationIdentifierKey", .value = .{ .string = target.application } },
            .{ .key = "WIRPageIdentifierKey", .value = .{ .integer = target.page } },
        } });
    }

    pub fn sendDidClose(self: *Client, target: *const Target) Error!void {
        try self.sendDidCloseFor(target, self.sender_id);
    }

    pub fn sendDidCloseFor(self: *Client, target: *const Target, sender_id: []const u8) Error!void {
        try self.send("_rpc_forwardDidClose:", .{ .dict = &.{
            .{ .key = "WIRConnectionIdentifierKey", .value = .{ .string = self.connection_id } },
            .{ .key = "WIRApplicationIdentifierKey", .value = .{ .string = target.application } },
            .{ .key = "WIRPageIdentifierKey", .value = .{ .integer = target.page } },
            .{ .key = "WIRSenderKey", .value = .{ .string = sender_id } },
        } });
    }

    fn writeAll(self: *Client, bytes: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const written = std.c.send(self.fd, bytes[offset..].ptr, bytes.len - offset, std.posix.MSG.NOSIGNAL);
            if (written < 0) {
                return switch (std.posix.errno(written)) {
                    .INTR => continue,
                    else => error.WriteFailed,
                };
            }
            if (written == 0) return error.WriteFailed;
            offset += @intCast(written);
        }
    }

    fn readerMain(self: *Client) void {
        while (!self.closed.load(.acquire)) {
            const payload = self.readFrame() catch |err| {
                if (!self.closed.load(.acquire)) {
                    std.log.warn("inspector relay read failed: {s}", .{@errorName(err)});
                }
                self.close();
                return;
            };
            defer self.allocator.free(payload);
            self.enqueue(payload) catch |err| {
                std.log.warn("inspector relay frame rejected: {s}", .{@errorName(err)});
            };
        }
    }

    fn enqueue(self: *Client, payload: []const u8) !void {
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        arena.* = .init(self.allocator);
        errdefer arena.deinit();

        const root = plist.parse(arena.allocator(), payload) catch return error.InvalidPlist;
        const name = switch (root.get("__selector") orelse return error.InvalidPlist) {
            .string => |text| text,
            else => return error.InvalidPlist,
        };
        const info = root.get("__argument") orelse plist.Value{ .dict = &.{} };

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (self.closed.load(.acquire)) return error.Closed;
        try self.queue.append(self.allocator, .{ .name = name, .info = info, .arena = arena });
        self.queue_changed.signal();
    }

    fn readFrame(self: *Client) ![]u8 {
        var header: [4]u8 = undefined;
        try self.readExact(&header);
        const length = std.mem.readInt(u32, &header, .big);
        if (length > max_frame_bytes) return error.FrameTooLarge;
        const payload = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(payload);
        try self.readExact(payload);
        traceFrame("recv", "", payload);
        return payload;
    }

    fn readExact(self: *Client, buffer: []u8) !void {
        var offset: usize = 0;
        while (offset < buffer.len) {
            const count = std.posix.read(self.fd, buffer[offset..]) catch |err| return switch (err) {
                error.WouldBlock => error.WouldBlock,
                else => error.ReadFailed,
            };
            if (count == 0) return error.Closed;
            offset += count;
        }
    }

    fn drain(self: *Client) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        for (self.queue.items) |*message| message.deinit(self.allocator);
        self.queue.clearRetainingCapacity();
    }
};

fn traceFrame(direction: []const u8, label: []const u8, bytes: []const u8) void {
    if (!trace_enabled) return;
    const limit = @min(bytes.len, 48);
    std.debug.print("[trace] {s} {s} {d} bytes ", .{ direction, label, bytes.len });
    for (bytes[0..limit]) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}

pub fn uuid4(io: std.Io, allocator: Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],  bytes[1],  bytes[2],  bytes[3],
        bytes[4],  bytes[5],  bytes[6],  bytes[7],
        bytes[8],  bytes[9],  bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    });
}

const ApplicationCandidate = struct { id: []u8, name: []u8 };

/// Runs the relay handshake and attaches to one JavaScript target.
///
/// Several processes can register the same application name, for example after a previous demo has
/// not exited. Candidates are tried newest PID first and only an application that reports a
/// JavaScript target is selected.
pub fn attach(client: *Client, application_name: ?[]const u8, target_name: ?[]const u8, timeout_ms: u64) Error!Target {
    try client.send("_rpc_reportIdentifier:", .{ .dict = &.{
        .{ .key = "WIRConnectionIdentifierKey", .value = .{ .string = client.connection_id } },
    } });
    try client.send("_rpc_getConnectedApplications:", .{ .dict = &.{
        .{ .key = "WIRConnectionIdentifierKey", .value = .{ .string = client.connection_id } },
    } });

    const deadline = zev.monotonicMilliseconds() + timeout_ms;
    const Candidate = ApplicationCandidate;
    var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
    defer {
        for (candidates.items) |candidate| {
            client.allocator.free(candidate.id);
            client.allocator.free(candidate.name);
        }
        candidates.deinit(client.allocator);
    }

    while (candidates.items.len == 0) {
        var message = (try client.next(remaining(deadline))) orelse return error.DiscoveryTimeout;
        defer message.deinit(client.allocator);
        try collectApplications(client.allocator, &candidates, message.info, application_name);
    }
    std.sort.pdq(Candidate, candidates.items, {}, struct {
        fn newerFirst(_: void, a: Candidate, b: Candidate) bool {
            return processId(a.id) > processId(b.id);
        }
    }.newerFirst);

    for (candidates.items) |candidate| {
        try client.send("_rpc_forwardGetListing:", .{ .dict = &.{
            .{ .key = "WIRConnectionIdentifierKey", .value = .{ .string = client.connection_id } },
            .{ .key = "WIRApplicationIdentifierKey", .value = .{ .string = candidate.id } },
        } });
        const candidate_deadline = @min(deadline, zev.monotonicMilliseconds() + 1500);
        const found = (try waitForPage(client, candidate.id, target_name, candidate_deadline)) orelse continue;
        errdefer client.allocator.free(found.title);
        try client.send("_rpc_forwardSocketSetup:", .{ .dict = &.{
            .{ .key = "WIRApplicationIdentifierKey", .value = .{ .string = candidate.id } },
            .{ .key = "WIRConnectionIdentifierKey", .value = .{ .string = client.connection_id } },
            .{ .key = "WIRSenderKey", .value = .{ .string = client.sender_id } },
            .{ .key = "WIRPageIdentifierKey", .value = .{ .integer = found.page } },
            .{ .key = "WIRMessageDataTypeChunkSupportedKey", .value = .{ .integer = 0 } },
        } });
        return .{
            .application = try client.allocator.dupe(u8, candidate.id),
            .application_name = try client.allocator.dupe(u8, candidate.name),
            .page = found.page,
            .title = found.title,
        };
    }
    return error.DiscoveryFailed;
}

fn collectApplications(allocator: Allocator, candidates: *std.ArrayListUnmanaged(ApplicationCandidate), info: plist.Value, wanted: ?[]const u8) Error!void {
    const dictionary = info.get("WIRApplicationDictionaryKey") orelse return;
    const entries = switch (dictionary) {
        .dict => |items| items,
        else => return,
    };
    for (entries) |entry| {
        const name = entry.value.getString("WIRApplicationNameKey") orelse continue;
        if (wanted) |match| {
            if (!std.mem.eql(u8, name, match)) continue;
        }
        const id = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(id);
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        try candidates.append(allocator, .{ .id = id, .name = name_copy });
    }
}

fn waitForPage(client: *Client, application: []const u8, target_name: ?[]const u8, deadline: u64) Error!?struct { page: i64, title: []u8 } {
    while (true) {
        var message = (try client.next(remaining(deadline))) orelse return null;
        defer message.deinit(client.allocator);
        if (findPage(message.info, application, target_name)) |found| {
            return .{ .page = found.page, .title = try client.allocator.dupe(u8, found.title) };
        }
    }
}

fn processId(identifier: []const u8) u64 {
    if (!std.mem.startsWith(u8, identifier, "PID:")) return 0;
    return std.fmt.parseInt(u64, identifier[4..], 10) catch 0;
}

fn remaining(deadline: u64) ?u64 {
    const now = zev.monotonicMilliseconds();
    if (now >= deadline) return 1;
    return deadline - now;
}

const Application = struct { id: []const u8, name: []const u8 };
const Page = struct { page: i64, title: []const u8 };

fn findApplication(info: plist.Value, wanted: ?[]const u8) ?Application {
    if (info.get("WIRApplicationDictionaryKey")) |dictionary| {
        switch (dictionary) {
            .dict => |entries| for (entries) |entry| {
                const name = entry.value.getString("WIRApplicationNameKey") orelse continue;
                if (wanted == null or std.mem.eql(u8, name, wanted.?)) return .{ .id = entry.key, .name = name };
            },
            else => {},
        }
    }
    if (info.getString("WIRApplicationIdentifierKey")) |id| {
        const name = info.getString("WIRApplicationNameKey") orelse return null;
        if (wanted == null or std.mem.eql(u8, name, wanted.?)) return .{ .id = id, .name = name };
    }
    return null;
}

fn findPage(info: plist.Value, application: []const u8, wanted: ?[]const u8) ?Page {
    const listing = info.get("WIRListingKey") orelse return null;
    if (info.getString("WIRApplicationIdentifierKey")) |listed| {
        if (!std.mem.eql(u8, listed, application)) return null;
    }
    switch (listing) {
        .dict => |entries| for (entries) |entry| {
            const title = entry.value.getString("WIRTitleKey") orelse "";
            const kind = entry.value.getString("WIRTypeKey") orelse "";
            if (!std.mem.eql(u8, kind, "WIRTypeJavaScript")) continue;
            if (wanted != null and !std.mem.eql(u8, title, wanted.?)) continue;
            const page = std.fmt.parseInt(i64, entry.key, 10) catch continue;
            return .{ .page = page, .title = title };
        },
        else => {},
    }
    return null;
}

test "uuid4 has the expected shape" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const id = try uuid4(threaded.io(), std.testing.allocator);
    defer std.testing.allocator.free(id);
    try std.testing.expectEqual(@as(usize, 36), id.len);
    try std.testing.expectEqual(@as(u8, '-'), id[8]);
    try std.testing.expectEqual(@as(u8, '-'), id[13]);
    try std.testing.expectEqual(@as(u8, '-'), id[18]);
    try std.testing.expectEqual(@as(u8, '-'), id[23]);
    try std.testing.expectEqual(@as(u8, '4'), id[14]);
}
