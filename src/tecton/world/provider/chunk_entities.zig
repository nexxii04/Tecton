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
const EntityTypeRegistry = @import("../../entity/entity_type_registry.zig");
const Entity = @import("../../entity/entity.zig").Entity;
const EntityTraits = @import("../../entity/traits/root.zig");
const events_mod = @import("../../events/root.zig");
const Events = @import("../../events/types.zig");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const PlayerRegistry = @import("../../server/players.zig").PlayerRegistry;
const Tecton = @import("../../tecton.zig").Tecton;
const BlockState = @import("../block/block_permutation.zig").BlockState;
const BlockPermutation = @import("../block/block_permutation.zig").BlockPermutation;
const BlockType = @import("../block/block_type.zig").BlockType;
const Chunk = @import("../chunk/chunk.zig").Chunk;
const Dimension = @import("../dimension/dimension.zig").Dimension;
const chunkHash = @import("../dimension/dimension.zig").chunkHash;
const entities = @import("../dimension/entities.zig");
const World = @import("../world.zig").World;
const key_mod = @import("./leveldb_keys.zig");
const LevelDBProvider = @import("./leveldb_provider.zig").LevelDBProvider;
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

const test_owner = @This();
const test_scope = struct {
    pub const harness_init = test_owner.LoadHarness.init;
    pub const harness_deinit = test_owner.LoadHarness.deinit;
    pub const std = test_owner.std;
    pub const testing = test_owner.testing;
    pub const Protocol = test_owner.Protocol;
    pub const EntityTypeRegistry = test_owner.EntityTypeRegistry;
    pub const Entity = test_owner.Entity;
    pub const EntityTraits = test_owner.EntityTraits;
    pub const Events = test_owner.Events;
    pub const entities = test_owner.entities;
    pub const writeChunkEntities = test_owner.writeChunkEntities;
    pub const loadChunkEntities = test_owner.loadChunkEntities;
    pub const LoadHarness = test_owner.LoadHarness;
    pub const putStoredActor = test_owner.putStoredActor;
    pub const putStoredActorWithPosition = test_owner.putStoredActorWithPosition;
    pub const putStoredDigest = test_owner.putStoredDigest;
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
