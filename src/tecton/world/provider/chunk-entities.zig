const std = @import("std");

const LevelDB = @import("leveldb");
const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;

const Chunk = @import("../chunk/chunk.zig").Chunk;
const Dimension = @import("../dimension/dimension.zig").Dimension;
const key_mod = @import("./leveldb-keys.zig");
const persistence = @import("./persistence.zig");
const serialization = @import("./serialization.zig");
const LevelDBProvider = @import("./leveldb-provider.zig").LevelDBProvider;

pub fn writeChunkEntities(provider: *LevelDBProvider, chunk: *Chunk, dimension: *Dimension) !void {
    const dim_index = key_mod.dimensionIndex(dimension);
    var record = persistence.Record{};
    errdefer record.deinit(provider.allocator);

    var entities_in_chunk = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
    defer entities_in_chunk.deinit(provider.allocator);

    var ent_iter = dimension.entities.valueIterator();
    while (ent_iter.next()) |entity_ptr| {
        const entity = entity_ptr.*;
        const ecx = @as(i32, @intFromFloat(@floor(entity.position.x))) >> 4;
        const ecz = @as(i32, @intFromFloat(@floor(entity.position.z))) >> 4;
        if (ecx == chunk.x and ecz == chunk.z) {
            var tag = serialization.serializeEntity(provider.allocator, entity) catch continue;
            defer tag.deinit(provider.allocator);
            const data = serialization.encodeNbt(provider.allocator, &tag) catch continue;
            defer provider.allocator.free(data);
            const actor_key = key_mod.actorKey(entity.unique_id);
            try record.addPut(provider.allocator, actor_key.slice(), data);
            try entities_in_chunk.append(provider.allocator, entity.unique_id);
        }
    }

    const digp = key_mod.digpKey(chunk.x, chunk.z, dim_index);
    if (entities_in_chunk.items.len > 0) {
        const digest_data = try provider.allocator.alloc(u8, entities_in_chunk.items.len * 8);
        defer provider.allocator.free(digest_data);
        for (entities_in_chunk.items, 0..) |uid, i| {
            const bytes: [8]u8 = @bitCast(std.mem.nativeToLittle(i64, uid));
            @memcpy(digest_data[i * 8 .. (i + 1) * 8], &bytes);
        }
        try record.addPut(provider.allocator, digp.slice(), digest_data);
    } else {
        try record.addDelete(provider.allocator, digp.slice());
    }

    provider.dispatch(.entities, dim_index, chunk.x, chunk.z, record);
}

pub fn readChunkEntities(provider: *LevelDBProvider, chunk: *Chunk, dimension: *Dimension) !std.ArrayList(CompoundTag) {
    provider.awaitChunkRecords(chunk.x, chunk.z, dimension.dimension_type, &.{.entities});
    const dim_index = key_mod.dimensionIndex(dimension);
    var result = std.ArrayList(CompoundTag){ .items = &.{}, .capacity = 0 };
    const digp = key_mod.digpKey(chunk.x, chunk.z, dim_index);
    const digest_data = provider.db.get(digp.slice()) orelse return result;
    defer LevelDB.DB.freeValue(digest_data);

    const count = digest_data.len / 8;
    for (0..count) |i| {
        const uid_bytes: *const [8]u8 = @ptrCast(digest_data[i * 8 .. (i + 1) * 8]);
        const uid = std.mem.littleToNative(i64, @bitCast(uid_bytes.*));
        const actor_k = key_mod.actorKey(uid);
        const entity_data = provider.db.get(actor_k.slice()) orelse continue;
        defer LevelDB.DB.freeValue(entity_data);
        const tag = serialization.decodeNbt(provider.allocator, entity_data) catch continue;
        result.append(provider.allocator, tag) catch {
            var t = tag;
            t.deinit(provider.allocator);
            continue;
        };
    }
    return result;
}
