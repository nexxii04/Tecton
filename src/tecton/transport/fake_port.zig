const std = @import("std");

const connection = @import("connection.zig");
const port_mod = @import("port.zig");
const SendPriority = @import("priority.zig").SendPriority;

/// A port with no transport behind it: records what the game sends, opens no sockets.
pub const TransportFake = struct {
    pub const Sent = struct {
        conn_id: u64,
        channel: port_mod.Channel,
        priority: SendPriority,
        bytes: []u8,
    };

    pub const Closed = struct {
        conn_id: u64,
        mode: port_mod.CloseMode,
    };

    allocator: std.mem.Allocator,
    sent: std.ArrayList(Sent) = .empty,
    closed: std.ArrayList(Closed) = .empty,
    payload_limit: usize = 1400,
    fail_next_send: ?port_mod.SendError = null,

    pub fn init(allocator: std.mem.Allocator) TransportFake {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TransportFake) void {
        for (self.sent.items) |entry| self.allocator.free(entry.bytes);
        self.sent.deinit(self.allocator);
        self.closed.deinit(self.allocator);
    }

    pub fn port(self: *TransportFake) port_mod.Port {
        return .{
            .ctx = self,
            .send = send,
            .close = close,
            .max_payload = maxPayload,
        };
    }

    pub fn sentTo(self: *const TransportFake, conn_id: u64) usize {
        var count: usize = 0;
        for (self.sent.items) |entry| {
            if (entry.conn_id == conn_id) count += 1;
        }
        return count;
    }

    pub fn lastSent(self: *const TransportFake) ?Sent {
        if (self.sent.items.len == 0) return null;
        return self.sent.items[self.sent.items.len - 1];
    }

    pub fn clear(self: *TransportFake) void {
        for (self.sent.items) |entry| self.allocator.free(entry.bytes);
        self.sent.clearRetainingCapacity();
        self.closed.clearRetainingCapacity();
    }

    fn send(ctx: *anyopaque, conn: *connection.Connection, bytes: []const u8, channel: port_mod.Channel, priority: SendPriority) port_mod.SendError!void {
        const self: *TransportFake = @ptrCast(@alignCast(ctx));
        if (self.fail_next_send) |err| {
            self.fail_next_send = null;
            return err;
        }
        if (!conn.isOpen()) return error.Closed;
        if (bytes.len > self.payload_limit) return error.PayloadTooLarge;
        const copy = self.allocator.dupe(u8, bytes) catch return error.Backpressure;
        self.sent.append(self.allocator, .{ .conn_id = conn.id, .channel = channel, .priority = priority, .bytes = copy }) catch {
            self.allocator.free(copy);
            return error.Backpressure;
        };
    }

    fn close(ctx: *anyopaque, conn: *connection.Connection, mode: port_mod.CloseMode) void {
        const self: *TransportFake = @ptrCast(@alignCast(ctx));
        self.closed.append(self.allocator, .{ .conn_id = conn.id, .mode = mode }) catch {};
    }

    fn maxPayload(ctx: *anyopaque, conn: *connection.Connection) usize {
        _ = conn;
        const self: *TransportFake = @ptrCast(@alignCast(ctx));
        return self.payload_limit;
    }
};

const testing = std.testing;

fn standaloneConnection(allocator: std.mem.Allocator, backend: *anyopaque) !*connection.Connection {
    const conn = try allocator.create(connection.Connection);
    conn.* = .{
        .id = 1,
        .backend = backend,
        .allocator = allocator,
        .refs = std.atomic.Value(u32).init(1),
        .state = std.atomic.Value(connection.State).init(.open),
    };
    return conn;
}

test "the fake port records every send against the connection id" {
    var backend: u128 = 0;
    const conn = try standaloneConnection(testing.allocator, &backend);
    defer conn.release();

    var fake = TransportFake.init(testing.allocator);
    defer fake.deinit();

    const port = fake.port();
    try port.sendBytes(conn, "one", .reliable, .normal);
    try port.sendBytes(conn, "two", .unreliable, .immediate);

    try testing.expectEqual(@as(usize, 2), fake.sentTo(conn.id));
    try testing.expectEqualStrings("two", fake.lastSent().?.bytes);
    try testing.expectEqual(SendPriority.immediate, fake.lastSent().?.priority);
    try testing.expectEqual(port_mod.Channel.unreliable, fake.lastSent().?.channel);
    try testing.expectEqual(@as(usize, 1400), port.maxPayload(conn));
}

test "a closed connection or a full payload is refused instead of recorded" {
    var backend: u128 = 0;
    const conn = try standaloneConnection(testing.allocator, &backend);
    defer conn.release();

    var fake = TransportFake.init(testing.allocator);
    defer fake.deinit();
    const port = fake.port();

    fake.payload_limit = 4;
    try testing.expectError(error.PayloadTooLarge, port.sendBytes(conn, "toolong", .reliable, .normal));

    port.closeConn(conn, .flush);
    try testing.expectEqual(@as(usize, 1), fake.closed.items.len);
    try testing.expectEqual(port_mod.CloseMode.flush, fake.closed.items[0].mode);

    conn.markClosed();
    try testing.expectError(error.Closed, port.sendBytes(conn, "one", .reliable, .normal));
}
