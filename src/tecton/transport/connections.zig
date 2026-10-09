const std = @import("std");
const Raknet = @import("Raknet");
const queue = @import("queue.zig");

/// Generation number per connection; queued packets from a recycled RakNet pointer are dropped.
pub const ConnectionRegistry = struct {
    generations: std.AutoHashMap(usize, u64),
    counter: u64 = 0,
    mutex: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConnectionRegistry {
        return .{
            .generations = std.AutoHashMap(usize, u64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConnectionRegistry) void {
        self.generations.deinit();
    }

    pub fn register(self: *ConnectionRegistry, io: std.Io, connection: *Raknet.Connection) void {
        self.mutex.lock(io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.mutex.unlock(io);
        self.counter += 1;
        self.generations.put(@intFromPtr(connection), self.counter) catch {
            std.log.err("failed to register connection", .{});
        };
    }

    pub fn unregister(self: *ConnectionRegistry, io: std.Io, connection: *Raknet.Connection) void {
        self.mutex.lock(io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.mutex.unlock(io);
        _ = self.generations.remove(@intFromPtr(connection));
    }

    pub fn currentGeneration(self: *ConnectionRegistry, io: std.Io, connection: *Raknet.Connection) ?u64 {
        self.mutex.lock(io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return null;
        };
        defer self.mutex.unlock(io);
        return self.generations.get(@intFromPtr(connection));
    }

    pub fn isCurrent(self: *ConnectionRegistry, io: std.Io, connection: *Raknet.Connection, generation: u64) bool {
        const current = self.currentGeneration(io, connection) orelse return false;
        return current == generation;
    }

    pub fn markValidGenerations(self: *ConnectionRegistry, io: std.Io, entries: []queue.QueuedPacket) void {
        self.mutex.lock(io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            for (entries) |*entry| entry.valid = false;
            return;
        };
        defer self.mutex.unlock(io);
        for (entries) |*entry| {
            const generation = self.generations.get(@intFromPtr(entry.conn));
            entry.valid = generation != null and generation.? == entry.generation;
        }
    }
};

test "generation validation is per batch, not per packet" {
    const io = std.testing.io;
    var registry = ConnectionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var conn_storage: [2]u128 align(16) = .{ 0, 0 };
    const live: *Raknet.Connection = @ptrCast(&conn_storage[0]);
    const resigned: *Raknet.Connection = @ptrCast(&conn_storage[1]);

    registry.register(io, live);
    registry.register(io, resigned);
    const live_generation = registry.currentGeneration(io, live) orelse return error.TestUnexpectedResult;
    const resigned_generation = registry.currentGeneration(io, resigned) orelse return error.TestUnexpectedResult;
    registry.unregister(io, resigned);

    var entries = [_]queue.QueuedPacket{
        .{ .conn = live, .generation = live_generation, .payload = &.{} },
        .{ .conn = resigned, .generation = resigned_generation, .payload = &.{} },
        .{ .conn = live, .generation = live_generation -% 1, .payload = &.{} },
    };
    registry.markValidGenerations(io, &entries);

    try std.testing.expect(entries[0].valid);
    try std.testing.expect(!entries[1].valid);
    try std.testing.expect(!entries[2].valid);
}

test "connection registry validates generations across pointer reuse" {
    const registry_box = try std.testing.allocator.create(ConnectionRegistry);
    defer std.testing.allocator.destroy(registry_box);
    registry_box.* = ConnectionRegistry.init(std.testing.allocator);
    defer registry_box.deinit();

    var conn_storage: u128 align(16) = 0;
    const conn: *Raknet.Connection = @ptrCast(&conn_storage);

    registry_box.register(std.testing.io, conn);
    const first_gen = registry_box.currentGeneration(std.testing.io, conn) orelse return error.TestUnexpectedResult;
    try std.testing.expect(registry_box.isCurrent(std.testing.io, conn, first_gen));

    registry_box.unregister(std.testing.io, conn);
    try std.testing.expectEqual(@as(?u64, null), registry_box.currentGeneration(std.testing.io, conn));
    try std.testing.expect(!registry_box.isCurrent(std.testing.io, conn, first_gen));

    registry_box.register(std.testing.io, conn);
    const second_gen = registry_box.currentGeneration(std.testing.io, conn) orelse return error.TestUnexpectedResult;
    try std.testing.expect(second_gen != first_gen);
    try std.testing.expect(registry_box.isCurrent(std.testing.io, conn, second_gen));
    try std.testing.expect(!registry_box.isCurrent(std.testing.io, conn, first_gen));
}
