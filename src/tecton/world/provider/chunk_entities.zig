const std = @import("std");
const testing = std.testing;

const LevelDB = @import("leveldb");
const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const Protocol = @import("protocol");

const Chunk = @import("../chunk/chunk.zig").Chunk;
const Dimension = @import("../dimension/dimension.zig").Dimension;
const entities = @import("../dimension/entities.zig");
const key_mod = @import("./leveldb_keys.zig");
const LevelDBProvider = @import("./leveldb_provider.zig").LevelDBProvider;
const persistence = @import("./persistence.zig");
const serialization = @import("./serialization.zig");
const harness_mod = @import("chunk_entities_harness.zig");
const stored_actors = @import("chunk_entities_stored_actors.zig");
const LoadHarness = harness_mod.Harness(LevelDBProvider);

pub fn writeChunkEntities(provider: *LevelDBProvider, chunk: *Chunk, dimension: *Dimension) !void {
    const dim_index = key_mod.dimensionIndex(dimension);
    var record = persistence.Record{};
    errdefer record.deinit(provider.allocator);

    var entities_in_chunk = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
    defer entities_in_chunk.deinit(provider.allocator);

    for (dimension.entitiesInChunk(chunk.x, chunk.z)) |entity| {
        var tag = serialization.serializeEntity(provider.allocator, entity) catch continue;
        defer tag.deinit(provider.allocator);
        const data = serialization.encodeNbt(provider.allocator, &tag) catch continue;
        defer provider.allocator.free(data);
        const actor_key = key_mod.actorKey(entity.unique_id);
        try record.addPut(provider.allocator, actor_key.slice(), data);
        try entities_in_chunk.append(provider.allocator, entity.unique_id);
    }

    if (dimension.ecs) |state| {
        const ecs_persistence = @import("../../ecs/persistence.zig");
        for (state.chunk_index.bucket(@import("../dimension/dimension.zig").chunkHash(chunk.x, chunk.z))) |id| {
            if (id.kind != .mob) continue;
            var tag = (ecs_persistence.serializeEcsEntity(provider.allocator, &state.world, id) catch null) orelse continue;
            defer tag.deinit(provider.allocator);
            const data = serialization.encodeNbt(provider.allocator, &tag) catch continue;
            defer provider.allocator.free(data);
            const unique = state.world.get(id, @import("../../ecs/components.zig").ProtocolId).?.unique;
            const actor_key = key_mod.actorKey(unique);
            try record.addPut(provider.allocator, actor_key.slice(), data);
            try entities_in_chunk.append(provider.allocator, unique);
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

pub fn loadChunkEntities(provider: *LevelDBProvider, chunk: *Chunk, dimension: *Dimension) !void {
    var tags = try readChunkEntities(provider, chunk, dimension);
    defer {
        for (tags.items) |*tag| tag.deinit(provider.allocator);
        tags.deinit(provider.allocator);
    }
    for (tags.items) |*tag| {
        _ = entities.spawnStoredEntity(dimension, tag) catch continue;
    }
}

const test_owner = @This();
const test_scope = struct {
    pub const harness_init = test_owner.LoadHarness.init;
    pub const harness_deinit = test_owner.LoadHarness.deinit;
    pub const std = test_owner.std;
    pub const testing = test_owner.testing;
    pub const Protocol = test_owner.Protocol;
    pub const EntityTypeRegistry = harness_mod.EntityTypeRegistry;
    pub const Entity = harness_mod.Entity;
    pub const EntityTraits = harness_mod.EntityTraits;
    pub const Events = harness_mod.Events;
    pub const entities = test_owner.entities;
    pub const writeChunkEntities = test_owner.writeChunkEntities;
    pub const loadChunkEntities = test_owner.loadChunkEntities;
    pub const LoadHarness = test_owner.LoadHarness;
    pub const putStoredActor = stored_actors.putStoredActor;
    pub const putStoredActorWithPosition = stored_actors.putStoredActorWithPosition;
    pub const putStoredDigest = stored_actors.putStoredDigest;
};

test "a stored mob comes back burning after its chunk reloads" {
    try @import("chunk_entities_test.zig").Suite(test_scope).case_000();
}

test "stored actors that cannot spawn are skipped without losing the chunk" {
    try @import("chunk_entities_test.zig").Suite(test_scope).case_001();
}

test "a stored mob keeps the health it had when the world was saved" {
    try @import("chunk_entities_test.zig").Suite(test_scope).case_002();
}

test "a stored mob saved at zero health is not rebuilt" {
    try @import("chunk_entities_test.zig").Suite(test_scope).case_003();
}

test "a stored mob with a corrupt position is clamped before it reaches the save" {
    try @import("chunk_entities_test.zig").Suite(test_scope).case_004();
}

test "a stored mob without a health tag comes back at full" {
    try @import("chunk_entities_test.zig").Suite(test_scope).case_005();
}
