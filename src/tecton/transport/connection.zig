const std = @import("std");

const events_mod = @import("events.zig");

/// `closed` is terminal. Leaving `open` happens once, through a CAS, so teardown runs once.
pub const State = enum(u8) { open, closing, closed };

pub const Connection = struct {
    /// Stable session identity. It is never a pointer: the object can outlive the transport handle.
    id: u64,
    /// Transport-private handle. Only the port that created this connection may interpret it.
    backend: *anyopaque,
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(u32),
    state: std.atomic.Value(State),

    pub fn retain(self: *Connection) void {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0);
    }

    pub fn release(self: *Connection) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous == 1) self.allocator.destroy(self);
    }

    pub fn isOpen(self: *const Connection) bool {
        return self.state.load(.acquire) == .open;
    }

    /// Returns true for the single caller that gets to tear the connection down.
    pub fn beginClose(self: *Connection) bool {
        return self.state.cmpxchgStrong(.open, .closing, .acq_rel, .acquire) == null;
    }

    pub fn markClosed(self: *Connection) void {
        self.state.store(.closed, .release);
    }
};

/// Owns every live connection by id and emits one `opened`/`closed` event per session.
pub const ConnectionRegistry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    events: *events_mod.Queue,
    mutex: std.Io.Mutex = .init,
    next_id: u64 = 0,
    by_id: std.AutoHashMap(u64, *Connection),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, event_queue: *events_mod.Queue) ConnectionRegistry {
        return .{
            .allocator = allocator,
            .io = io,
            .events = event_queue,
            .by_id = std.AutoHashMap(u64, *Connection).init(allocator),
        };
    }

    /// Releases whatever the transport never closed; callers must have drained in-flight work first.
    pub fn deinit(self: *ConnectionRegistry) void {
        self.mutex.lock(self.io) catch {
            self.by_id.deinit();
            return;
        };
        var it = self.by_id.valueIterator();
        while (it.next()) |entry| {
            const conn = entry.*;
            conn.markClosed();
            conn.release();
        }
        self.by_id.clearRetainingCapacity();
        self.mutex.unlock(self.io);
        self.by_id.deinit();
    }

    pub fn create(self: *ConnectionRegistry, backend: *anyopaque) !*Connection {
        const conn = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(conn);

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;

        conn.* = .{
            .id = self.next_id,
            .backend = backend,
            .allocator = self.allocator,
            .refs = std.atomic.Value(u32).init(1),
            .state = std.atomic.Value(State).init(.open),
        };
        try self.by_id.put(conn.id, conn);
        self.events.push(.{ .opened = conn.id });
        return conn;
    }

    pub fn get(self: *ConnectionRegistry, id: u64) ?*Connection {
        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);
        return self.by_id.get(id);
    }

    pub fn count(self: *ConnectionRegistry) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.by_id.count();
    }

    /// Drops the transport reference and emits `closed` exactly once, for whichever caller closes first.
    pub fn closeAndRelease(self: *ConnectionRegistry, conn: *Connection) void {
        if (!conn.beginClose()) return;
        conn.markClosed();

        self.mutex.lock(self.io) catch {
            self.events.push(.{ .closed = conn.id });
            conn.release();
            return;
        };
        _ = self.by_id.remove(conn.id);
        self.mutex.unlock(self.io);

        self.events.push(.{ .closed = conn.id });
        conn.release();
    }
};

const testing = std.testing;

test "ids are unique, monotonic and never zero" {
    var queue = events_mod.Queue.init(testing.io, testing.allocator);
    defer queue.deinit();

    var registry = ConnectionRegistry.init(testing.allocator, testing.io, &queue);
    defer registry.deinit();

    var backends: [3]u128 = .{ 0, 0, 0 };
    var ids: [3]u64 = undefined;
    for (&backends, 0..) |*backend, index| {
        const conn = try registry.create(backend);
        ids[index] = conn.id;
        try testing.expect(conn.id != 0);
        try testing.expect(conn.isOpen());
        try testing.expectEqual(conn, registry.get(conn.id).?);
    }

    try testing.expect(ids[0] < ids[1]);
    try testing.expect(ids[1] < ids[2]);
    try testing.expectEqual(@as(usize, 3), registry.count());
}

test "closing emits one event, removes the mapping and drops the transport reference" {
    var queue = events_mod.Queue.init(testing.io, testing.allocator);
    defer queue.deinit();

    var registry = ConnectionRegistry.init(testing.allocator, testing.io, &queue);
    defer registry.deinit();

    var backend: u128 = 0;
    const conn = try registry.create(&backend);
    conn.retain();

    registry.closeAndRelease(conn);
    registry.closeAndRelease(conn);

    try testing.expect(!conn.isOpen());
    try testing.expectEqual(@as(?*Connection, null), registry.get(conn.id));
    try testing.expectEqual(@as(?*Connection, null), registry.get(conn.id + 100));
    try testing.expectEqual(@as(usize, 0), registry.count());

    var drained: std.ArrayList(events_mod.Event) = .empty;
    defer drained.deinit(testing.allocator);
    queue.drain(&drained);
    try testing.expectEqual(@as(usize, 2), drained.items.len);
    try testing.expectEqual(conn.id, drained.items[0].opened);
    try testing.expectEqual(conn.id, drained.items[1].closed);

    // The player reference keeps the object alive until it is released.
    conn.release();
}

test "the registry frees connections the transport never closed" {
    var queue = events_mod.Queue.init(testing.io, testing.allocator);
    defer queue.deinit();

    var registry = ConnectionRegistry.init(testing.allocator, testing.io, &queue);
    var backends: [2]u128 = .{ 0, 0 };
    for (&backends) |*backend| _ = try registry.create(backend);
    try testing.expectEqual(@as(usize, 2), registry.count());
    registry.deinit();
}

test "retain and release balance out" {
    var queue = events_mod.Queue.init(testing.io, testing.allocator);
    defer queue.deinit();

    var registry = ConnectionRegistry.init(testing.allocator, testing.io, &queue);
    var backend: u128 = 0;
    const conn = try registry.create(&backend);

    conn.retain();
    conn.retain();
    try testing.expectEqual(@as(u32, 3), conn.refs.load(.acquire));
    conn.release();
    conn.release();
    try testing.expectEqual(@as(u32, 1), conn.refs.load(.acquire));

    // Drops the last reference and frees the object.
    registry.closeAndRelease(conn);
    try testing.expectEqual(@as(usize, 0), registry.by_id.count());
    registry.deinit();
}
