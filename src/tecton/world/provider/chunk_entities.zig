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
const Host = @import("../../player/player.zig").Host;
const Player = @import("../../player/player.zig").Player;
const PlayerRegistry = @import("../../server/players.zig").PlayerRegistry;
const ServerProperties = @import("../../core/config.zig").ServerProperties;
const TickProfiler = @import("../../core/tick_profiler.zig").TickProfiler;
const TaskQueue = @import("../../tasks/tasks.zig").TaskQueue;
const ThreadedTaskQueue = @import("../../tasks/threaded_tasks.zig").ThreadedTaskQueue;
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
    allocator: std.mem.Allocator,
    config: ServerProperties,
    events: events_mod.Events,
    ecs: EcsWorld,
    players: PlayerRegistry,
    tasks: TaskQueue,
    threaded_tasks: ThreadedTaskQueue,
    profiler: TickProfiler,
    network: NetworkHandler,
    world: World,
    dim: Dimension,
    chunk: *Chunk,
    provider: *LevelDBProvider,

    fn host(self: *LoadHarness) Host {
        return .{
            .ctx = self,
            .io = testing.io,
            .allocator = self.allocator,
            .config = &self.config,
            .network = &self.network,
            .events = &self.events,
            .ecs = &self.ecs,
            .tasks = &self.tasks,
            .threaded_tasks = &self.threaded_tasks,
            .profiler = &self.profiler,
            .players = .{ .ctx = self, .by_runtime_id = harnessByRuntimeId },
            .instances = .{ .ctx = self, .assign_dimension = harnessAssignDimension },
            .permission_manager = .{ .ctx = self, .get_player_group = harnessGetPlayerGroup },
            .worlds = .{ .ctx = self, .build_world = harnessBuildWorld, .adopt_world = harnessAdoptWorld, .destroy_world = harnessDestroyWorld, .end_op = harnessEndOp },
            .mob_broadcast_interval = 2,
            .get_player_snapshots = harnessSnapshots,
            .get_player_count = harnessPlayerCount,
            .find_player_by_runtime_id = harnessFindPlayer,
            .register_ecs_entity = harnessRegisterEcs,
            .unregister_ecs_entity = harnessUnregisterEcs,
            .set_player_location = harnessSetPlayerLocation,
            .enqueue_player_removal = harnessEnqueuePlayerRemoval,
            .remove_player = harnessRemovePlayer,
            .remove_connection_mapping = harnessRemoveConnectionMapping,
            .target_tps = harnessTargetTps,
            .current_tps = harnessCurrentTps,
            .current_mspt = harnessCurrentMspt,
            .tick_count = harnessTickCount,
            .refresh_world_command_enums = harnessNoop,
            .refresh_floating_text_command_enums = harnessNoop,
            .reply_to = harnessReplyTo,
        };
    }

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

        self.allocator = allocator;
        self.config = .{ .allocator = allocator };
        self.events = events_mod.Events.init(allocator);
        self.ecs = try EcsWorld.init(allocator, 16);
        self.players = PlayerRegistry.init(testing.io, allocator);
        self.tasks = TaskQueue.init(allocator);
        self.threaded_tasks = ThreadedTaskQueue.init(testing.io, allocator, 1);
        self.profiler = .{};
        self.network = undefined;
        self.network.allocator = allocator;
        self.network.options = .{ .compression_method = .Zlib, .compression_threshold = 255 };

        self.provider = try LevelDBProvider.init(testing.io, allocator, db_name);
        self.world = try World.init(self.host(), allocator, "load-world", self.provider.asProvider());
        self.dim = Dimension.init(&self.world, allocator, "overworld", .Overworld, null);
        self.chunk = try allocator.create(Chunk);
        self.chunk.* = Chunk.init(allocator, 0, 0, .Overworld);
        try self.dim.chunks.put(chunkHash(0, 0), self.chunk);
    }

    fn deinit(self: *LoadHarness) void {
        self.dim.deinit();
        self.world.deinit();
        self.players.deinit();
        self.ecs.deinit();
        self.events.deinit();
        self.tasks.deinit();
        EntityTraits.deinitEntityTraitRegistry();
        EntityTypeRegistry.EntityTypeRegistry.deinit();
        BlockType.deinitRegistry();
        BlockPermutation.deinitRegistry();
    }
};

fn harnessCast(ctx: *anyopaque) *LoadHarness {
    return @ptrCast(@alignCast(ctx));
}

fn harnessSnapshots(ctx: *anyopaque) []const *Player {
    _ = ctx;
    return &.{};
}

fn harnessPlayerCount(ctx: *anyopaque) usize {
    _ = ctx;
    return 0;
}

fn harnessFindPlayer(ctx: *anyopaque, runtime_id: i64) ?*Player {
    return harnessCast(ctx).players.byRuntimeId(runtime_id);
}

fn harnessByRuntimeId(ctx: *anyopaque, runtime_id: i64) ?*Player {
    return harnessCast(ctx).players.byRuntimeId(runtime_id);
}

fn harnessRegisterEcs(ctx: *anyopaque, entity: *Entity) void {
    const self = harnessCast(ctx);
    if (entity.ecs_id != 0) return;
    const id = self.ecs.registerLegacy(
        entity.position,
        entity.rotation,
        entity.motion,
        @bitCast(entity.flags.flags_one),
        1.0,
        0,
    ) catch return;
    entity.ecs_id = @bitCast(id);
}

fn harnessUnregisterEcs(ctx: *anyopaque, entity: *Entity) void {
    const self = harnessCast(ctx);
    if (entity.ecs_id == 0) return;
    _ = self.ecs.destroy(@bitCast(entity.ecs_id));
    entity.ecs_id = 0;
}

fn harnessSetPlayerLocation(ctx: *anyopaque, uuid: []const u8, world_identifier: []const u8, dimension_identifier: []const u8) void {
    _ = ctx;
    _ = uuid;
    _ = world_identifier;
    _ = dimension_identifier;
}

fn harnessEnqueuePlayerRemoval(ctx: *anyopaque, player: *Player) void {
    _ = ctx;
    _ = player;
}

fn harnessRemovePlayer(ctx: *anyopaque, player: *Player) void {
    _ = ctx;
    _ = player;
}

fn harnessRemoveConnectionMapping(ctx: *anyopaque, connection: *anyopaque) void {
    _ = ctx;
    _ = connection;
}

fn harnessTargetTps(ctx: *anyopaque) f64 {
    _ = ctx;
    return 20.0;
}

fn harnessCurrentTps(ctx: *anyopaque) f64 {
    _ = ctx;
    return 20.0;
}

fn harnessCurrentMspt(ctx: *anyopaque) f64 {
    _ = ctx;
    return 0.0;
}

fn harnessTickCount(ctx: *anyopaque) u64 {
    _ = ctx;
    return 0;
}

fn harnessNoop(ctx: *anyopaque) void {
    _ = ctx;
}

fn harnessReplyTo(ctx: *anyopaque, sender_runtime_id: ?i64, origin_type: []const u8, uuid: [16]u8, request_id: []const u8, success: bool, message: []const u8) void {
    _ = ctx;
    _ = sender_runtime_id;
    _ = origin_type;
    _ = uuid;
    _ = request_id;
    _ = success;
    _ = message;
}

fn harnessAssignDimension(ctx: *anyopaque, runtime_id: i64, dimension: *Dimension) anyerror!void {
    _ = ctx;
    _ = runtime_id;
    _ = dimension;
}

fn harnessGetPlayerGroup(ctx: *anyopaque, player_name: []const u8) []const u8 {
    _ = ctx;
    _ = player_name;
    return "default";
}

fn harnessBuildWorld(ctx: *anyopaque, name: []const u8) anyerror!*World {
    _ = ctx;
    _ = name;
    return error.Unsupported;
}

fn harnessAdoptWorld(ctx: *anyopaque, world: *World) anyerror!void {
    _ = ctx;
    _ = world;
}

fn harnessDestroyWorld(ctx: *anyopaque, world: *World) void {
    _ = ctx;
    _ = world;
}

fn harnessEndOp(ctx: *anyopaque, name: []const u8) void {
    _ = ctx;
    _ = name;
}

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
