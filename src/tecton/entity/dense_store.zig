const std = @import("std");

pub fn DenseStore(comptime EntityId: type, comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        sparse: []i32,
        dense_ids: []EntityId,
        dense_values: []T,
        len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const sparse = try allocator.alloc(i32, capacity);
            errdefer allocator.free(sparse);
            @memset(sparse, -1);
            const dense_ids = try allocator.alloc(EntityId, capacity);
            errdefer allocator.free(dense_ids);
            const dense_values = try allocator.alloc(T, capacity);
            return .{
                .allocator = allocator,
                .sparse = sparse,
                .dense_ids = dense_ids,
                .dense_values = dense_values,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.sparse);
            self.allocator.free(self.dense_ids);
            self.allocator.free(self.dense_values);
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
            if (id.index >= self.sparse.len or self.sparse[id.index] < 0) return false;
            return self.dense_ids[@intCast(self.sparse[id.index])].generation == id.generation;
        }
    };
}
