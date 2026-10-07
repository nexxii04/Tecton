const std = @import("std");
const testing = std.testing;

const LevelDB = @import("leveldb");
const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const LongTag = NBT.LongTag;
const IntTag = NBT.IntTag;
const FloatTag = NBT.FloatTag;
const StringTag = NBT.StringTag;
const Protocol = @import("protocol");

const EcsWorld = @import("../../entity/ecs.zig").EcsWorld;
const EntityTypeRegistry = @import("../../entity/entity-type-registry.zig");
const Entity = @import("../../entity/entity.zig").Entity;
const EntityTraits = @import("../../entity/traits/root.zig");
const events_mod = @import("../../events/root.zig");
const Events = @import("../../events/types.zig");
const NetworkHandler = @import("../../network/network-handler.zig").NetworkHandler;
const PlayerRegistry = @import("../../server/players.zig").PlayerRegistry;
const Tecton = @import("../../tecton.zig").Tecton;
const BlockState = @import("../block/block-permutation.zig").BlockState;
const BlockPermutation = @import("../block/block-permutation.zig").BlockPermutation;
const BlockType = @import("../block/block-type.zig").BlockType;
const Chunk = @import("../chunk/chunk.zig").Chunk;
const Dimension = @import("../dimension/dimension.zig").Dimension;
const chunkHash = @import("../dimension/dimension.zig").chunkHash;
const entities = @import("../dimension/entities.zig");
const World = @import("../world.zig").World;
const key_mod = @import("./leveldb-keys.zig");
const LevelDBProvider = @import("./leveldb-provider.zig").LevelDBProvider;
const persistence = @import("./persistence.zig");
const serialization = @import("./serialization.zig");

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

/// Rebuilds the actors the chunk's digest lists, skipping any that cannot spawn.
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

/// Provider + registries wired enough to rebuild stored actors without a network.
const LoadHarness = struct {
    tecton: Tecton,
    network: NetworkHandler,
    world: World,
    dim: Dimension,
    chunk: *Chunk,
    provider: *LevelDBProvider,

    fn init(self: *LoadHarness, allocator: std.mem.Allocator, db_name: [*:0]const u8) !void {
        self.* = undefined;

        try BlockPermutation.initRegistry(allocator);
        errdefer BlockPermutation.deinitRegistry();
        try BlockType.initRegistry(allocator);
        errdefer BlockType.deinitRegistry();
        const air_type = try BlockType.init(allocator, "minecraft:air");
        try air_type.register();
        const air_perm = try BlockPermutation.init(allocator, 0, "minecraft:air", BlockState.init(allocator));
        try air_perm.register();
        try air_type.addPermutation(air_perm);

        _ = try EntityTypeRegistry.initRegistry(allocator);
        errdefer EntityTypeRegistry.EntityTypeRegistry.deinit();
        EntityTraits.initEntityTraitRegistry(allocator);
        errdefer EntityTraits.deinitEntityTraitRegistry();
        try EntityTraits.HealthTrait.register();
        try EntityTraits.FireTrait.register();

        self.tecton = undefined;
        self.tecton.events = events_mod.Events.init(allocator);
        self.tecton.ecs = try EcsWorld.init(allocator, 16);
        self.tecton.players = PlayerRegistry.init(testing.io, allocator);
        self.network = undefined;
        self.network.allocator = allocator;
        self.network.options = .{ .compression_method = .Zlib, .compression_threshold = 255 };
        self.tecton.network = &self.network;

        self.provider = try LevelDBProvider.init(testing.io, allocator, db_name);
        self.world = try World.init(&self.tecton, allocator, "load-world", self.provider.asProvider());
        self.dim = Dimension.init(&self.world, allocator, "overworld", .Overworld, null);
        self.chunk = try allocator.create(Chunk);
        self.chunk.* = Chunk.init(allocator, 0, 0, .Overworld);
        try self.dim.chunks.put(chunkHash(0, 0), self.chunk);
    }

    fn deinit(self: *LoadHarness) void {
        self.dim.deinit();
        self.world.deinit();
        self.tecton.players.deinit();
        self.tecton.ecs.deinit();
        self.tecton.events.deinit();
        EntityTraits.deinitEntityTraitRegistry();
        EntityTypeRegistry.EntityTypeRegistry.deinit();
        BlockType.deinitRegistry();
        BlockPermutation.deinitRegistry();
    }
};

fn putStoredActor(provider: *LevelDBProvider, uid: i64, identifier: []const u8, fire_ticks: i32, health: ?f32) !void {
    const allocator = provider.allocator;
    var tag = CompoundTag.init(allocator, null);
    defer tag.deinit(allocator);
    try tag.set("identifier", .{ .String = StringTag.init(try allocator.dupe(u8, identifier), null) });
    try tag.set("UniqueID", .{ .Long = LongTag.init(uid, null) });
    if (fire_ticks > 0) try tag.set("FireTicks", .{ .Int = IntTag.init(fire_ticks, null) });
    if (health) |value| {
        try tag.set("Health", .{ .Float = FloatTag.init(value, null) });
        try tag.set("MaxHealth", .{ .Float = FloatTag.init(20.0, null) });
    }
    const data = try serialization.encodeNbt(allocator, &tag);
    defer allocator.free(data);
    const key = key_mod.actorKey(uid);
    try provider.db.put(key.slice(), data);
}

fn putStoredActorWithPosition(provider: *LevelDBProvider, uid: i64, identifier: []const u8, x: f32, y: f32, z: f32) !void {
    const allocator = provider.allocator;
    var tag = CompoundTag.init(allocator, null);
    defer tag.deinit(allocator);

    try tag.set("identifier", .{ .String = StringTag.init(try allocator.dupe(u8, identifier), null) });
    try tag.set("UniqueID", .{ .Long = LongTag.init(uid, null) });

    const pos = try allocator.alloc(NBT.Tag, 3);
    pos[0] = .{ .Float = FloatTag.init(x, null) };
    pos[1] = .{ .Float = FloatTag.init(y, null) };
    pos[2] = .{ .Float = FloatTag.init(z, null) };

    try tag.set("Pos", .{ .List = NBT.ListTag.init(pos, null) });
    const data = try serialization.encodeNbt(allocator, &tag);
    defer allocator.free(data);

    const key = key_mod.actorKey(uid);
    try provider.db.put(key.slice(), data);
}

fn putStoredDigest(provider: *LevelDBProvider, dim_index: i32, x: i32, z: i32, uids: []const i64) !void {
    const allocator = provider.allocator;
    const digest = try allocator.alloc(u8, uids.len * 8);
    defer allocator.free(digest);
    for (uids, 0..) |uid, i| {
        const bytes: [8]u8 = @bitCast(std.mem.nativeToLittle(i64, uid));
        @memcpy(digest[i * 8 .. (i + 1) * 8], &bytes);
    }
    const key = key_mod.digpKey(x, z, dim_index);
    try provider.db.put(key.slice(), digest);
}

test "a stored mob comes back burning after its chunk reloads" {
    const allocator = testing.allocator;
    var harness: LoadHarness = undefined;
    try harness.init(allocator, "test_chunk_entities_db\x00");
    defer {
        harness.deinit();
        std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_db") catch {};
    }

    const entity_type = EntityTypeRegistry.EntityTypeRegistry.get("minecraft:zombie").?;
    const mob = try allocator.create(Entity);
    mob.* = Entity.init(allocator, entity_type, &harness.dim);
    mob.position = Protocol.Vector3f.init(2.5, 64.0, 2.5);
    try mob.addTrait(try EntityTraits.FireTrait.create(allocator, .{
        .fire_ticks = 120,
        .damage_timer = 7,
        .burn_source = .lava,
    }));
    const stored_uid = mob.unique_id;
    const stored_runtime_id = mob.runtime_id;
    try harness.dim.entities.put(stored_runtime_id, mob);

    try writeChunkEntities(harness.provider, harness.chunk, &harness.dim);

    // The chunk is released and re-read while the mob is still alive: it must not double.
    try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);
    try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());

    // Then the mob dies and is flushed; the chunk comes back from storage.
    const removed = harness.dim.entities.fetchRemove(stored_runtime_id).?.value;
    removed.deinit();
    allocator.destroy(removed);

    try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);
    try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());

    var it = harness.dim.entities.valueIterator();
    const loaded = it.next().?.*;
    try testing.expectEqual(stored_uid, loaded.unique_id);
    try testing.expectEqual(@as(f32, 2.5), loaded.position.x);
    try testing.expectEqual(@as(f32, 64.0), loaded.position.y);
    try testing.expectEqual(@as(f32, 2.5), loaded.position.z);
    try testing.expect(loaded.ecs_id != 0);
    try testing.expectEqual(@as(usize, 1), harness.dim.entity_index.count());

    const fire_state = loaded.getTraitState(EntityTraits.FireTrait).?;
    try testing.expectEqual(@as(i32, 120), fire_state.fire_ticks);
    try testing.expectEqual(@as(i32, 7), fire_state.damage_timer);
    try testing.expectEqual(Events.CombustSource.lava, fire_state.burn_source);

    // The first tick after the load re-synchronizes the OnFire actor flag.
    loaded.fireEvent(.Tick, .{loaded});
    try testing.expect(loaded.flags.getFlag(.OnFire));
    try testing.expectEqual(@as(i32, 119), fire_state.fire_ticks);
}

test "stored actors that cannot spawn are skipped without losing the chunk" {
    const allocator = testing.allocator;
    var harness: LoadHarness = undefined;
    try harness.init(allocator, "test_chunk_entities_skip_db\x00");
    defer {
        harness.deinit();
        std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_skip_db") catch {};
    }

    try putStoredActor(harness.provider, 9001, "minecraft:not_a_real_mob", 0, null);
    try putStoredActor(harness.provider, 9002, "minecraft:item", 0, null);
    try putStoredActor(harness.provider, 9003, "minecraft:player", 0, null);
    try putStoredActor(harness.provider, 9004, "minecraft:zombie", 55, null);
    try putStoredDigest(harness.provider, 0, 0, 0, &.{ 9001, 9002, 9003, 9004 });

    try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);

    try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());
    var it = harness.dim.entities.valueIterator();
    const loaded = it.next().?.*;
    try testing.expectEqual(@as(i64, 9004), loaded.unique_id);
    const fire_state = loaded.getTraitState(EntityTraits.FireTrait).?;
    try testing.expectEqual(@as(i32, 55), fire_state.fire_ticks);
}

// A mob hurt before the save must come back hurt, with its `Health` attribute in sync.
test "a stored mob keeps the health it had when the world was saved" {
    const allocator = testing.allocator;
    var harness: LoadHarness = undefined;
    try harness.init(allocator, "test_chunk_entities_health_db\x00");
    defer {
        harness.deinit();
        std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_health_db") catch {};
    }

    const entity_type = EntityTypeRegistry.EntityTypeRegistry.get("minecraft:zombie").?;
    const mob = try allocator.create(Entity);
    mob.* = Entity.init(allocator, entity_type, &harness.dim);
    mob.position = Protocol.Vector3f.init(2.5, 64.0, 2.5);
    try mob.addTrait(try EntityTraits.HealthTrait.create(allocator, .{ .current = 7.5, .max = 20.0 }));
    const stored_uid = mob.unique_id;
    const stored_runtime_id = mob.runtime_id;
    try harness.dim.entities.put(stored_runtime_id, mob);

    try writeChunkEntities(harness.provider, harness.chunk, &harness.dim);

    const removed = harness.dim.entities.fetchRemove(stored_runtime_id).?.value;
    removed.deinit();
    allocator.destroy(removed);

    try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);
    try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());

    var it = harness.dim.entities.valueIterator();
    const loaded = it.next().?.*;
    try testing.expectEqual(stored_uid, loaded.unique_id);
    const health_state = loaded.getTraitState(EntityTraits.HealthTrait).?;
    try testing.expectEqual(@as(f32, 7.5), health_state.current);
    try testing.expectEqual(@as(f32, 20.0), health_state.max);
    try testing.expectEqual(@as(f32, 7.5), loaded.attributes.get(.Health).?.current);
    try testing.expectEqual(@as(f32, 20.0), loaded.attributes.get(.Health).?.max);
}

// Regression: a digest still listing a corpse must not revive the mob the player killed.
test "a stored mob saved at zero health is not rebuilt" {
    const allocator = testing.allocator;
    var harness: LoadHarness = undefined;
    try harness.init(allocator, "test_chunk_entities_dead_db\x00");
    defer {
        harness.deinit();
        std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_dead_db") catch {};
    }

    try putStoredActor(harness.provider, 9101, "minecraft:zombie", 0, 0.0);
    try putStoredActor(harness.provider, 9102, "minecraft:zombie", 0, 7.0);
    try putStoredDigest(harness.provider, 0, 0, 0, &.{ 9101, 9102 });

    try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);

    try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());
    var it = harness.dim.entities.valueIterator();
    const loaded = it.next().?.*;
    try testing.expectEqual(@as(i64, 9102), loaded.unique_id);
    try testing.expectEqual(@as(f32, 7.0), loaded.getTraitState(EntityTraits.HealthTrait).?.current);
}

test "a stored mob with a corrupt position is clamped before it reaches the save" {
    const allocator = testing.allocator;
    var harness: LoadHarness = undefined;
    try harness.init(allocator, "test_chunk_entities_corrupt_db\x00");
    defer {
        harness.deinit();
        std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_corrupt_db") catch {};
    }

    try putStoredActorWithPosition(harness.provider, 9301, "minecraft:zombie", std.math.inf(f32), std.math.nan(f32), std.math.nan(f32));
    try putStoredDigest(harness.provider, 0, 0, 0, &.{9301});

    try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);
    try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());

    var it = harness.dim.entities.valueIterator();
    const loaded = it.next().?.*;
    try testing.expect(std.math.isFinite(loaded.position.x));
    try testing.expect(std.math.isFinite(loaded.position.y));
    try testing.expect(std.math.isFinite(loaded.position.z));
    try testing.expect(@abs(loaded.position.x) < 16 and @abs(loaded.position.z) < 16);

    try writeChunkEntities(harness.provider, harness.chunk, &harness.dim);
}

// Legacy records carry no health keys: they must load at full, not at zero.
test "a stored mob without a health tag comes back at full" {
    const allocator = testing.allocator;
    var harness: LoadHarness = undefined;
    try harness.init(allocator, "test_chunk_entities_legacy_db\x00");
    defer {
        harness.deinit();
        std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_legacy_db") catch {};
    }

    try putStoredActor(harness.provider, 9201, "minecraft:zombie", 0, null);
    try putStoredDigest(harness.provider, 0, 0, 0, &.{9201});

    try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);

    var it = harness.dim.entities.valueIterator();
    const loaded = it.next().?.*;
    try testing.expectEqual(@as(f32, 20.0), loaded.getTraitState(EntityTraits.HealthTrait).?.current);
    try testing.expectEqual(@as(f32, 20.0), loaded.getTraitState(EntityTraits.HealthTrait).?.max);
    try testing.expectEqual(@as(f32, 20.0), loaded.attributes.get(.Health).?.current);
}
