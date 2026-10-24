const std = @import("std");
const EntityId = @import("entity_id.zig").EntityId;

pub fn DenseStore(comptime T: type) type {
    return struct {
        const Self = @This();

        sparse: []i32,
        dense_ids: []EntityId,
        dense_values: []T,
        len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (capacity > std.math.maxInt(i32)) return error.CapacityExceeded;
            const sparse = try allocator.alloc(i32, capacity);
            errdefer allocator.free(sparse);
            @memset(sparse, -1);
            const dense_ids = try allocator.alloc(EntityId, capacity);
            errdefer allocator.free(dense_ids);
            const dense_values = try allocator.alloc(T, capacity);
            return .{
                .sparse = sparse,
                .dense_ids = dense_ids,
                .dense_values = dense_values,
            };
        }

        pub fn reserve(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            if (capacity <= self.sparse.len) return;
            if (capacity > std.math.maxInt(i32)) return error.CapacityExceeded;
            var replacement = try Self.init(allocator, capacity);
            @memcpy(replacement.sparse[0..self.sparse.len], self.sparse);
            @memcpy(replacement.dense_ids[0..self.len], self.dense_ids[0..self.len]);
            @memcpy(replacement.dense_values[0..self.len], self.dense_values[0..self.len]);
            replacement.len = self.len;
            self.deinit(allocator);
            self.* = replacement;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.sparse);
            allocator.free(self.dense_ids);
            allocator.free(self.dense_values);
        }

        pub fn add(self: *Self, id: EntityId, value: T) !void {
            const index = id.index;
            if (index >= self.sparse.len) return error.InvalidEntity;
            if (self.sparse[index] >= 0) {
                const dense_index: usize = @intCast(self.sparse[index]);
                if (self.dense_ids[dense_index].generation != id.generation) return error.InvalidEntity;
                self.dense_values[dense_index] = value;
                return;
            }
            if (self.len == self.dense_ids.len) return error.CapacityExceeded;
            self.sparse[index] = @intCast(self.len);
            self.dense_ids[self.len] = id;
            self.dense_values[self.len] = value;
            self.len += 1;
        }

        pub fn remove(self: *Self, id: EntityId) void {
            if (id.index >= self.sparse.len) return;
            const dense_index = self.sparse[id.index];
            if (dense_index < 0) return;
            const removed_index: usize = @intCast(dense_index);
            if (self.dense_ids[removed_index].generation != id.generation) return;
            const last = self.len - 1;
            if (removed_index != last) {
                const moved_id = self.dense_ids[last];
                self.dense_ids[removed_index] = moved_id;
                self.dense_values[removed_index] = self.dense_values[last];
                self.sparse[moved_id.index] = dense_index;
            }
            self.sparse[id.index] = -1;
            self.len = last;
        }

        pub fn get(self: *Self, id: EntityId) ?*T {
            if (id.index >= self.sparse.len) return null;
            const dense_index = self.sparse[id.index];
            if (dense_index < 0) return null;
            const resolved_index: usize = @intCast(dense_index);
            if (self.dense_ids[resolved_index].generation != id.generation) return null;
            return &self.dense_values[resolved_index];
        }

        pub fn contains(self: *const Self, id: EntityId) bool {
            if (id.index >= self.sparse.len) return false;
            if (self.sparse[id.index] < 0) return false;
            const dense_index: usize = @intCast(self.sparse[id.index]);
            return self.dense_ids[dense_index].generation == id.generation;
        }

        pub fn fillRatio(self: *const Self) f32 {
            if (self.dense_values.len == 0) return 1;
            return @as(f32, @floatFromInt(self.len)) / @as(f32, @floatFromInt(self.dense_values.len));
        }
    };
}

test "dense store add get remove round trips with generation validation" {
    const allocator = std.testing.allocator;
    var store = try DenseStore(u32).init(allocator, 4);
    defer store.deinit(allocator);

    const id = EntityId{ .index = 1, .generation = 5, .kind = .mob };
    try store.add(id, 42);
    try std.testing.expect(store.contains(id));
    try std.testing.expectEqual(@as(u32, 42), store.get(id).?.*);
    try std.testing.expect(!store.contains(.{ .index = 1, .generation = 6, .kind = .mob }));

    store.remove(id);
    try std.testing.expect(!store.contains(id));
    try std.testing.expect(store.get(id) == null);
    try std.testing.expectEqual(@as(usize, 0), store.len);
}

test "dense store swap remove keeps remaining entities addressable" {
    const allocator = std.testing.allocator;
    var store = try DenseStore(u64).init(allocator, 4);
    defer store.deinit(allocator);

    const first = EntityId{ .index = 0, .generation = 1, .kind = .item };
    const second = EntityId{ .index = 1, .generation = 1, .kind = .item };
    try store.add(first, 10);
    try store.add(second, 20);
    store.remove(first);
    try std.testing.expectEqual(@as(u64, 20), store.get(second).?.*);
    try std.testing.expectEqual(@as(usize, 1), store.len);
}

test "dense store reserve preserves sparse mappings" {
    const allocator = std.testing.allocator;
    var store = try DenseStore(u64).init(allocator, 2);
    defer store.deinit(allocator);

    const id = EntityId{ .index = 1, .generation = 7, .kind = .item };
    try store.add(id, 42);
    try store.reserve(allocator, 8);
    try std.testing.expectEqual(@as(u64, 42), store.get(id).?.*);
    try store.add(.{ .index = 7, .generation = 3, .kind = .item }, 99);
    store.remove(id);
    try std.testing.expectEqual(@as(u64, 99), store.get(.{ .index = 7, .generation = 3, .kind = .item }).?.*);
}
