const std = @import("std");
const entity_id = @import("entity_id.zig");

const EntityId = entity_id.EntityId;

pub const EcsChunkIndex = struct {
    allocator: std.mem.Allocator,
    by_chunk: std.AutoHashMapUnmanaged(i64, std.ArrayListUnmanaged(EntityId)) = .empty,
    chunk_of: std.AutoHashMapUnmanaged(u64, i64) = .empty,

    pub fn init(allocator: std.mem.Allocator) EcsChunkIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EcsChunkIndex) void {
        var it = self.by_chunk.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.by_chunk.deinit(self.allocator);
        self.chunk_of.deinit(self.allocator);
    }

    pub fn add(self: *EcsChunkIndex, id: EntityId, hash: i64) !void {
        _ = self.remove(id);
        const gop = try self.by_chunk.getOrPut(self.allocator, hash);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        errdefer {
            if (gop.value_ptr.items.len == 0) {
                gop.value_ptr.deinit(self.allocator);
                _ = self.by_chunk.remove(hash);
            }
        }
        try gop.value_ptr.append(self.allocator, id);
        errdefer _ = gop.value_ptr.pop();
        try self.chunk_of.put(self.allocator, @bitCast(id), hash);
    }

    pub fn remove(self: *EcsChunkIndex, id: EntityId) bool {
        const removed = self.chunk_of.fetchRemove(@as(u64, @bitCast(id))) orelse return false;
        const list = self.by_chunk.getPtr(removed.value) orelse return true;
        for (list.items, 0..) |entry, i| {
            if (@as(u64, @bitCast(entry)) == @as(u64, @bitCast(id))) {
                _ = list.orderedRemove(i);
                break;
            }
        }
        if (list.items.len == 0) {
            list.deinit(self.allocator);
            _ = self.by_chunk.remove(removed.value);
        }
        return true;
    }

    pub fn update(self: *EcsChunkIndex, id: EntityId, hash: i64) !void {
        const current = self.chunk_of.get(@as(u64, @bitCast(id))) orelse {
            try self.add(id, hash);
            return;
        };
        if (current == hash) return;
        try self.add(id, hash);
    }

    pub fn bucket(self: *const EcsChunkIndex, hash: i64) []const EntityId {
        const list = self.by_chunk.get(hash) orelse return &.{};
        return list.items;
    }

    pub fn count(self: *const EcsChunkIndex) usize {
        return self.chunk_of.count();
    }
};

test "chunk index buckets entities and moves them between chunks" {
    const allocator = std.testing.allocator;
    var index = EcsChunkIndex.init(allocator);
    defer index.deinit();

    const first = EntityId{ .index = 0, .generation = 1, .kind = .item };
    const second = EntityId{ .index = 1, .generation = 1, .kind = .item };

    try index.add(first, 100);
    try index.add(second, 100);
    try std.testing.expectEqual(@as(usize, 2), index.bucket(100).len);

    try index.update(first, 200);
    try std.testing.expectEqual(@as(usize, 1), index.bucket(100).len);
    try std.testing.expectEqual(@as(usize, 1), index.bucket(200).len);
    try std.testing.expectEqual(@as(u64, @bitCast(first)), @as(u64, @bitCast(index.bucket(200)[0])));

    try index.update(first, 200);
    try std.testing.expectEqual(@as(usize, 1), index.bucket(200).len);

    try std.testing.expect(index.remove(first));
    try std.testing.expectEqual(@as(usize, 0), index.bucket(200).len);
    try std.testing.expect(!index.remove(first));
    try std.testing.expectEqual(@as(usize, 1), index.count());
}
