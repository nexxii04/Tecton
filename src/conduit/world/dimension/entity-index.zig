const std = @import("std");
const Entity = @import("../../entity/entity.zig").Entity;

pub fn chunkHash(x: i32, z: i32) i64 {
    return (@as(i64, x) << 32) | @as(i64, @as(u32, @bitCast(z)));
}

fn chunkCoord(value: f32) i32 {
    return @as(i32, @intFromFloat(@floor(value))) >> 4;
}

/// Per-dimension spatial index of live entities by chunk, so visibility
/// passes only walk chunks near a player instead of every entity.
pub const ChunkEntityIndex = struct {
    allocator: std.mem.Allocator,
    by_chunk: std.AutoHashMap(i64, std.ArrayList(*Entity)),
    chunk_of: std.AutoHashMap(i64, i64),

    pub fn init(allocator: std.mem.Allocator) ChunkEntityIndex {
        return .{
            .allocator = allocator,
            .by_chunk = std.AutoHashMap(i64, std.ArrayList(*Entity)).init(allocator),
            .chunk_of = std.AutoHashMap(i64, i64).init(allocator),
        };
    }

    pub fn deinit(self: *ChunkEntityIndex) void {
        var it = self.by_chunk.valueIterator();
        while (it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.by_chunk.deinit();
        self.chunk_of.deinit();
    }

    pub fn count(self: *const ChunkEntityIndex) usize {
        return self.chunk_of.count();
    }

    pub fn add(self: *ChunkEntityIndex, entity: *Entity) void {
        self.remove(entity.runtime_id);

        const hash = chunkHash(chunkCoord(entity.position.x), chunkCoord(entity.position.z));
        const gop = self.by_chunk.getOrPut(hash) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        gop.value_ptr.append(self.allocator, entity) catch {
            if (gop.value_ptr.items.len == 0) {
                gop.value_ptr.deinit(self.allocator);
                _ = self.by_chunk.remove(hash);
            }
            return;
        };
        self.chunk_of.put(entity.runtime_id, hash) catch {
            _ = gop.value_ptr.pop();
            if (gop.value_ptr.items.len == 0) {
                gop.value_ptr.deinit(self.allocator);
                _ = self.by_chunk.remove(hash);
            }
        };
    }

    pub fn remove(self: *ChunkEntityIndex, runtime_id: i64) void {
        const removed = self.chunk_of.fetchRemove(runtime_id) orelse return;
        const list = self.by_chunk.getPtr(removed.value) orelse return;
        for (list.items, 0..) |entity, i| {
            if (entity.runtime_id == runtime_id) {
                _ = list.swapRemove(i);
                break;
            }
        }
        if (list.items.len == 0) {
            list.deinit(self.allocator);
            _ = self.by_chunk.remove(removed.value);
        }
    }

    pub fn reindex(self: *ChunkEntityIndex, entity: *Entity) void {
        const new_hash = chunkHash(chunkCoord(entity.position.x), chunkCoord(entity.position.z));
        const old_hash = self.chunk_of.get(entity.runtime_id) orelse {
            self.add(entity);
            return;
        };
        if (old_hash == new_hash) return;
        self.remove(entity.runtime_id);
        self.add(entity);
    }

    pub fn bucket(self: *ChunkEntityIndex, x: i32, z: i32) ?[]const *Entity {
        const list = self.by_chunk.getPtr(chunkHash(x, z)) orelse return null;
        if (list.items.len == 0) return null;
        return list.items;
    }
};

const test_entity_type = @import("../../entity/entity-type.zig").EntityType{
    .identifier = "minecraft:test",
    .network_id = 1,
    .components = &.{},
    .tags = &.{},
};

const Protocol = @import("protocol");

fn setEntityPosition(entity: *Entity, x: f32, z: f32) void {
    entity.position = Protocol.Vector3f.init(x, 64, z);
}

test "entity index buckets entities by chunk" {
    const allocator = std.testing.allocator;

    var e1 = Entity.init(allocator, &test_entity_type, null);
    defer e1.deinit();
    setEntityPosition(&e1, 0.5, 0.5);

    var e2 = Entity.init(allocator, &test_entity_type, null);
    defer e2.deinit();
    setEntityPosition(&e2, 15.9, 0.5);

    var e3 = Entity.init(allocator, &test_entity_type, null);
    defer e3.deinit();
    setEntityPosition(&e3, 16.0, 0.5);

    var index = ChunkEntityIndex.init(allocator);
    defer index.deinit();

    index.add(&e1);
    index.add(&e2);
    index.add(&e3);
    try std.testing.expectEqual(@as(usize, 3), index.count());

    const chunk_00 = index.bucket(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), chunk_00.len);
    try std.testing.expect(chunk_00[0] == &e1 or chunk_00[1] == &e1);
    try std.testing.expect(chunk_00[0] == &e2 or chunk_00[1] == &e2);

    const chunk_10 = index.bucket(1, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), chunk_10.len);
    try std.testing.expect(chunk_10[0] == &e3);

    try std.testing.expect(index.bucket(0, 1) == null);
}

test "entity index reindex moves buckets and drops empty ones" {
    const allocator = std.testing.allocator;

    var entity = Entity.init(allocator, &test_entity_type, null);
    defer entity.deinit();
    setEntityPosition(&entity, 0.5, 0.5);

    var index = ChunkEntityIndex.init(allocator);
    defer index.deinit();

    index.add(&entity);
    try std.testing.expect(index.bucket(0, 0) != null);

    setEntityPosition(&entity, 20.0, -20.0);
    index.reindex(&entity);

    try std.testing.expect(index.bucket(0, 0) == null);
    const moved = index.bucket(1, -2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), moved.len);
    try std.testing.expect(moved[0] == &entity);
    try std.testing.expectEqual(@as(usize, 1), index.count());

    setEntityPosition(&entity, 20.5, -19.5);
    index.reindex(&entity);
    try std.testing.expectEqual(@as(usize, 1), index.count());
    try std.testing.expect(index.bucket(1, -2) != null);
}

test "entity index remove drops empty buckets and keeps the map in sync" {
    const allocator = std.testing.allocator;

    var e1 = Entity.init(allocator, &test_entity_type, null);
    defer e1.deinit();
    setEntityPosition(&e1, 1.0, 1.0);

    var e2 = Entity.init(allocator, &test_entity_type, null);
    defer e2.deinit();
    setEntityPosition(&e2, 2.0, 2.0);

    var index = ChunkEntityIndex.init(allocator);
    defer index.deinit();

    index.add(&e1);
    index.add(&e2);

    index.remove(e1.runtime_id);
    try std.testing.expectEqual(@as(usize, 1), index.count());
    const remaining = index.bucket(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expect(remaining[0] == &e2);

    index.remove(e2.runtime_id);
    try std.testing.expectEqual(@as(usize, 0), index.count());
    try std.testing.expect(index.bucket(0, 0) == null);

    index.remove(e2.runtime_id);
    try std.testing.expectEqual(@as(usize, 0), index.count());
}
