pub const std = @import("std");
pub const testing = std.testing;

const EcsWorld = @import("../../entity/ecs.zig").EcsWorld;
pub const EntityTypeRegistry = @import("../../entity/entity_type_registry.zig");
pub const Entity = @import("../../entity/entity.zig").Entity;
pub const EntityTraits = @import("../../entity/traits/root.zig");
const events_mod = @import("../../events/root.zig");
pub const Events = @import("../../events/types.zig");
const Host = @import("../../player/player.zig").Host;
const Player = @import("../../player/player.zig").Player;
const PlayerRegistry = @import("../../server/players.zig").PlayerRegistry;
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
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
const World = @import("../world.zig").World;
// Generic over the provider so this test-only file stays outside the provider cycle.
pub fn Harness(comptime Provider: type) type {
    return struct {
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
        provider: *Provider,

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

        pub fn init(self: *LoadHarness, allocator: std.mem.Allocator, db_name: [*:0]const u8) !void {
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
            self.network.payload_buffers = @import("../../transport/payload_buffers.zig").PayloadBuffers.init(allocator);

            self.provider = try Provider.init(testing.io, allocator, db_name);
            self.world = try World.init(self.host(), allocator, "load-world", self.provider.asProvider());
            self.dim = Dimension.init(&self.world, allocator, "overworld", .Overworld, null);
            self.chunk = try allocator.create(Chunk);
            self.chunk.* = Chunk.init(allocator, 0, 0, .Overworld);
            try self.dim.chunks.put(chunkHash(0, 0), self.chunk);
        }

        pub fn deinit(self: *LoadHarness) void {
            self.dim.deinit();
            self.world.deinit();
            self.network.payload_buffers.deinit();
            self.players.deinit();
            self.ecs.deinit();
            self.events.deinit();
            self.tasks.deinit();
            EntityTraits.deinitEntityTraitRegistry();
            EntityTypeRegistry.EntityTypeRegistry.deinit();
            BlockType.deinitRegistry();
            BlockPermutation.deinitRegistry();
        }

        const LoadHarness = @This();

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
    };
}
