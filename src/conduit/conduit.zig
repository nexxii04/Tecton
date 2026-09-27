const std = @import("std");
const Timestamp = std.Io.Timestamp;

const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const CommandRegistry = @import("./command/registry.zig").CommandRegistry;
const ServerProperties = @import("./config.zig").ServerProperties;
const shouldEmitVerboseStartupLogs = @import("./config.zig").shouldEmitVerboseStartupLogs;
const Console = @import("./console/console.zig").Console;
const EntityTypeRegistry = @import("./entity/entity-type-registry.zig");
const EntityType = @import("./entity/entity-type.zig").EntityType;
const Entity = @import("./entity/entity.zig").Entity;
const EntityTraits = @import("./entity/traits/root.zig");
const GravityTrait = EntityTraits.GravityTrait;
const HealthTrait = EntityTraits.HealthTrait;
const VillagerTradeTrait = EntityTraits.VillagerTradeTrait;
const CreativeContentLoader = @import("./items/creative-content-loader.zig");
const ItemPalette = @import("./items/item-palette.zig");
const AuthService = @import("./network/auth/root.zig").AuthService;
const BanManager = @import("./network/ban-manager.zig").BanManager;
const MovementBroadcast = @import("./network/movement-broadcast.zig");
const NetworkHandler = @import("./network/root.zig").NetworkHandler;
const SendPriority = @import("./network/root.zig").SendPriority;
const MoveDelta = @import("./player/move-delta.zig");
const PermissionManager = @import("./player/permission-manager.zig").PermissionManager;
const PlayerLocations = @import("./player/player-locations.zig").PlayerLocations;
const PlayerLocation = @import("./player/player-locations.zig").Location;
const PlayerSnapshot = @import("./player/player-snapshot.zig").PlayerSnapshot;
const Player = @import("./player/player.zig").Player;
const TaskQueue = @import("./tasks/tasks.zig").TaskQueue;
const ThreadedTaskQueue = @import("./tasks/threaded-tasks.zig").ThreadedTaskQueue;
const WorkerCountResolution = @import("./tasks/threaded-tasks.zig").WorkerCountResolution;
const resolveWorkerCount = @import("./tasks/threaded-tasks.zig").resolveWorkerCount;
const totalServerThreadCount = @import("./tasks/threaded-tasks.zig").totalServerThreadCount;
const TickProfiler = @import("./tick-profiler.zig").TickProfiler;
const BlockPermutation = @import("./world/block/block-permutation.zig").BlockPermutation;
const loadBlockPermutations = @import("./world/block/root.zig").loadBlockPermutations;
const initRegistries = @import("./world/block/root.zig").initRegistries;
const deinitRegistries = @import("./world/block/root.zig").deinitRegistries;
const BarrelTrait = @import("./world/block/traits/barrel.zig").BarrelTrait;
const ChestTrait = @import("./world/block/traits/chest.zig").ChestTrait;
const OpenBitTrait = @import("./world/block/traits/open-bit.zig").OpenBitTrait;
const UpperBlockTrait = @import("./world/block/traits/upper-block.zig").UpperBlockTrait;
const WallConnectionTrait = @import("./world/block/traits/wall-connection.zig").WallConnectionTrait;
const ChunkHash = @import("./world/dimension/dimension.zig").ChunkHash;
const Generator = @import("./world/generator/root.zig");
const LevelDBProvider = @import("./world/provider/leveldb-provider.zig").LevelDBProvider;
const WorldProvider = @import("./world/provider/world-provider.zig").WorldProvider;
const World = @import("./world/world.zig").World;
const EcsWorld = @import("entity/ecs.zig").EcsWorld;
const EcsEntityId = @import("entity/ecs.zig").EntityId;
const Events = @import("events/root.zig");
const PluginRuntime = @import("plugins/runtime.zig").PluginRuntime;
const GameInstanceRegistry = @import("world/game-instance.zig").GameInstanceRegistry;

pub const ServerPaths = struct {
    worlds: []const u8 = "worlds",
    plugins: []const u8 = "plugins",
    banned_players: []const u8 = "banned-players.json",
    permissions: []const u8 = "permissions.json",
    player_locations: []const u8 = "player_locations.json",
};

pub const CommandPermissionChecker = *const fn (?*anyopaque, []const u8, []const u8) bool;

pub const ServerOptions = struct {
    paths: ServerPaths = .{},
    enable_console: bool = true,
    discover_native_plugins: bool = true,
    auto_load_worlds: bool = true,
    create_default_world: bool = true,
    tick_callback: ?*const fn (?*anyopaque) void = null,
    tick_userdata: ?*anyopaque = null,
    prepare_callback: ?*const fn (?*anyopaque) void = null,
    start_callback: ?*const fn (?*anyopaque) void = null,
    shutdown_callback: ?*const fn (?*anyopaque) void = null,
    lifecycle_userdata: ?*anyopaque = null,
    command_permission_checker: ?CommandPermissionChecker = null,
    command_permission_userdata: ?*anyopaque = null,
};

const save_chunks_per_tick: usize = 32;
const save_players_per_tick: usize = 2;
const save_ns_budget: u64 = 2_000_000;

const SaveGroup = struct {
    world: []u8,
    dim: []u8,
    hashes: []ChunkHash,
};

pub const Conduit = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: ServerProperties,
    paths: ServerPaths,
    enable_console: bool,
    discover_native_plugins: bool,
    auto_load_worlds: bool,
    create_default_world: bool,
    tick_callback: ?*const fn (?*anyopaque) void,
    tick_userdata: ?*anyopaque,
    prepare_callback: ?*const fn (?*anyopaque) void,
    start_callback: ?*const fn (?*anyopaque) void,
    shutdown_callback: ?*const fn (?*anyopaque) void,
    lifecycle_userdata: ?*anyopaque,
    command_permission_checker: ?CommandPermissionChecker,
    command_permission_userdata: ?*anyopaque,
    events: Events.Events,
    raknet: Raknet.Server,
    network: *NetworkHandler,
    network_initialized: bool = false,
    players: std.AutoHashMap(i64, *Player),
    connection_map: std.AutoHashMap(usize, *Player),
    players_mutex: std.Io.Mutex = .init,
    players_count: std.atomic.Value(usize) = .init(0),
    players_snapshot: PlayerSnapshot,
    pending_player_removals: std.ArrayList(*Player),
    pending_player_removals_mutex: std.Io.Mutex = .init,
    movement_deltas: std.ArrayList(MovementBroadcast.DeltaRef) = .empty,
    movement_batch: std.ArrayList([]const u8) = .empty,
    movement_priority: SendPriority = .normal,
    tick_thread_id: std.atomic.Value(usize) = .init(0),
    save_in_flight: bool = false,
    save_plan: std.ArrayListUnmanaged(SaveGroup) = .empty,
    save_cursor: struct { group: usize = 0, chunk: usize = 0 } = .{},
    save_players_pending: bool = false,
    save_player_cursor: usize = 0,
    worlds: std.StringHashMap(*World),
    world_ops: std.StringHashMap(void),
    player_entity_type: EntityType,
    creative_content: ?CreativeContentLoader.CreativeContentData,
    pre_spawn_data: ?Protocol.PreSpawnData.PreSpawnData = null,
    serialized_item_registry: ?[]const u8,
    serialized_biome_definitions: ?[]const u8,
    tick_count: u64 = 0,
    work_time_accumulator: u64 = 0,
    raknet_time_accumulator: u64 = 0,
    tick_interval_accumulator: u64 = 0,
    tick_interval_samples: u64 = 0,
    tasks_time_accumulator: u64 = 0,
    current_tps: f64 = 20.0,
    current_mspt: f64 = 0.0,
    current_raknet_mspt: f64 = 0.0,
    current_game_mspt: f64 = 0.0,
    last_tick_started_at: ?Timestamp = null,
    tasks: TaskQueue,
    threaded_tasks: ThreadedTaskQueue,
    profiler: TickProfiler,
    command_registry: CommandRegistry,
    console: Console,
    console_started: bool = false,
    prepared: bool = false,
    started: bool = false,
    stopped: bool = false,
    shutting_down: bool = false,
    auth_service: ?AuthService = null,
    ban_manager: BanManager,
    permission_manager: PermissionManager,
    player_locations: PlayerLocations,
    plugin_runtime: PluginRuntime,
    instances: GameInstanceRegistry,
    ecs: EcsWorld,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !Conduit {
        Raknet.Logger.init(allocator);
        const config = try ServerProperties.load(io, allocator, "server.properties");
        return initWithConfig(io, allocator, config);
    }

    /// Initializes the vanilla server with configuration owned by the server.
    pub fn initWithConfig(io: std.Io, allocator: std.mem.Allocator, config: ServerProperties) !Conduit {
        return initWithConfigAndPaths(io, allocator, config, .{});
    }

    pub fn initWithConfigAndPaths(io: std.Io, allocator: std.mem.Allocator, config: ServerProperties, paths: ServerPaths) !Conduit {
        return initWithOptions(io, allocator, config, .{ .paths = paths });
    }

    pub fn initWithOptions(io: std.Io, allocator: std.mem.Allocator, config: ServerProperties, options: ServerOptions) !Conduit {
        Raknet.Logger.init(allocator);
        var owned_config = config;
        errdefer owned_config.deinit();

        var auth_service: ?AuthService = null;
        errdefer if (auth_service) |*service| service.deinit();
        if (owned_config.online_mode) {
            auth_service = AuthService.init(io, allocator, .{}) catch |err| {
                Raknet.Logger.ERROR(
                    "Online mode: cannot reach the authorization service ({s}), refusing to start",
                    .{@errorName(err)},
                );
                return error.OnlineModeUnavailable;
            };
            Raknet.Logger.INFO("Online mode enabled", .{});
        } else {
            Raknet.Logger.INFO("Online mode disabled", .{});
        }
        if ((!owned_config.online_mode or owned_config.online_mode_offline_fallback) and
            std.mem.eql(u8, owned_config.default_group, "operator"))
        {
            Raknet.Logger.WARN("default-group=operator without verified identities: any client becomes an operator by claiming an operator name", .{});
        }

        const max_mtu = ServerProperties.clampMaxMtu(owned_config.max_mtu);
        if (max_mtu != owned_config.max_mtu) {
            Raknet.Logger.WARN("max-mtu={d} is outside the supported range {d}-{d}, using {d}", .{
                owned_config.max_mtu,
                ServerProperties.min_max_mtu,
                ServerProperties.max_max_mtu,
                max_mtu,
            });
        }
        const movement_priority = SendPriority.parse(owned_config.movement_send_priority) orelse fallback: {
            Raknet.Logger.WARN("movement-send-priority={s} is not a known priority, using normal", .{owned_config.movement_send_priority});
            break :fallback SendPriority.normal;
        };
        const ecs_capacity = @max(@as(usize, 4096), @as(usize, @intCast(owned_config.max_players)) * 8);
        var ecs = try EcsWorld.init(allocator, ecs_capacity);
        errdefer ecs.deinit();
        return Conduit{
            .io = io,
            .allocator = allocator,
            .config = owned_config,
            .paths = options.paths,
            .enable_console = options.enable_console,
            .discover_native_plugins = options.discover_native_plugins,
            .auto_load_worlds = options.auto_load_worlds,
            .create_default_world = options.create_default_world,
            .tick_callback = options.tick_callback,
            .tick_userdata = options.tick_userdata,
            .prepare_callback = options.prepare_callback,
            .start_callback = options.start_callback,
            .shutdown_callback = options.shutdown_callback,
            .lifecycle_userdata = options.lifecycle_userdata,
            .command_permission_checker = options.command_permission_checker,
            .command_permission_userdata = options.command_permission_userdata,
            .movement_priority = movement_priority,
            .events = Events.Events.init(allocator),
            .raknet = try Raknet.Server.init(io, .{
                .address = owned_config.address,
                .port = owned_config.port,
                .tick_rate = @intCast(owned_config.max_tps),
                .allocator = allocator,
                .advertisement = .{
                    .game_type = .MCPE,
                    .level_name = owned_config.motd,
                    .protocol = Protocol.PROTOCOL,
                    .version = Protocol.MINECRAFT_VERSION,
                    .player_count = 0,
                    .max_players = @intCast(owned_config.max_players),
                    .guid = 0,
                    .name = owned_config.motd,
                    .gamemode = "Creative",
                },
                .max_mtu = max_mtu,
            }),
            .players = std.AutoHashMap(i64, *Player).init(allocator),
            .connection_map = std.AutoHashMap(usize, *Player).init(allocator),
            .players_snapshot = PlayerSnapshot.init(),
            .pending_player_removals = std.ArrayList(*Player).empty,
            .worlds = std.StringHashMap(*World).init(allocator),
            .world_ops = std.StringHashMap(void).init(allocator),
            .player_entity_type = EntityType.init("minecraft:player", 1, &.{}, &.{}),
            .creative_content = null,
            .pre_spawn_data = null,
            .serialized_item_registry = null,
            .serialized_biome_definitions = null,
            .network = undefined,
            .current_tps = @as(f64, @floatFromInt(@max(@as(u32, 1), owned_config.max_tps))),
            .current_mspt = 1000.0 / @as(f64, @floatFromInt(@max(@as(u32, 1), owned_config.max_tps))),
            .current_raknet_mspt = 0.0,
            .current_game_mspt = 0.0,
            .tasks = TaskQueue.init(allocator),
            .threaded_tasks = ThreadedTaskQueue.init(io, allocator, owned_config.worker_threads),
            .profiler = .{},
            .command_registry = CommandRegistry.init(allocator),
            .console = undefined,
            .auth_service = auth_service,
            .ban_manager = BanManager.init(io, allocator, options.paths.banned_players),
            .permission_manager = PermissionManager.init(io, allocator, options.paths.permissions, owned_config.default_group),
            .player_locations = PlayerLocations.init(io, allocator, options.paths.player_locations),
            .plugin_runtime = PluginRuntime.init(allocator),
            .instances = GameInstanceRegistry.init(allocator),
            .ecs = ecs,
        };
    }

    pub fn prepare(self: *Conduit) !void {
        if (self.prepared) return;
        try initRegistries(self.allocator);
        // TODO: Implement registerTrait instead of trait.register()
        try ChestTrait.register();
        try BarrelTrait.register();
        try UpperBlockTrait.registerForState("upper_block_bit");
        try OpenBitTrait.registerForState("open_bit");
        try WallConnectionTrait.register();
        const count = try loadBlockPermutations(self.allocator);
        if (shouldEmitVerboseStartupLogs(@import("builtin").mode)) {
            Raknet.Logger.INFO("Loaded {d} block permutations", .{count});
        }
        try BlockPermutation.initNbtHashLookup(self.allocator);

        EntityTraits.initEntityTraitRegistry(self.allocator);
        try GravityTrait.register();
        try HealthTrait.register();
        try VillagerTradeTrait.register();

        try ItemPalette.initRegistry(self.allocator);
        const item_count = try ItemPalette.loadItemTypes(self.allocator);
        if (shouldEmitVerboseStartupLogs(@import("builtin").mode)) {
            Raknet.Logger.INFO("Loaded {d} item types", .{item_count});
        }
        {
            const entries = try ItemPalette.getItemRegistry(self.allocator);
            defer self.allocator.free(entries);
            var stream = BinaryStream.init(self.allocator, null, null);
            defer stream.deinit();
            const pkt = Protocol.ItemRegistryPacket{ .entries = entries };
            const raw = try pkt.serialize(&stream);
            self.serialized_item_registry = try self.allocator.dupe(u8, raw);
            if (shouldEmitVerboseStartupLogs(@import("builtin").mode)) {
                Raknet.Logger.INFO("Pre-serialized item registry ({d} bytes)", .{self.serialized_item_registry.?.len});
            }
        }

        {
            self.serialized_biome_definitions = Protocol.BiomeDefinitionsLoader.loadVanillaSerialized(self.allocator) catch |err| blk: {
                Raknet.Logger.ERROR("Failed to serialize biome definitions: {any}", .{err});
                break :blk null;
            };
            if (self.serialized_biome_definitions) |raw| {
                if (shouldEmitVerboseStartupLogs(@import("builtin").mode)) {
                    Raknet.Logger.INFO("Pre-serialized biome definitions ({d} bytes)", .{raw.len});
                }
            }
        }

        const entity_type_count = try EntityTypeRegistry.initRegistry(self.allocator);
        if (shouldEmitVerboseStartupLogs(@import("builtin").mode)) {
            Raknet.Logger.INFO("Loaded {d} entity types", .{entity_type_count});
        }

        self.creative_content = CreativeContentLoader.loadCreativeContent(self.allocator) catch |err| blk: {
            Raknet.Logger.ERROR("Failed to load creative content: {any}", .{err});
            break :blk null;
        };
        if (self.creative_content) |cc| {
            if (shouldEmitVerboseStartupLogs(@import("builtin").mode)) {
                Raknet.Logger.INFO("Loaded {d} creative groups and {d} creative items", .{ cc.group_count, cc.item_count });
            }
        }

        {
            self.pre_spawn_data = Protocol.PreSpawnData.load(self.allocator) catch |err| blk: {
                Raknet.Logger.ERROR("Failed to load pre-spawn data: {any}", .{err});
                break :blk null;
            };
            if (self.pre_spawn_data) |psd| {
                if (shouldEmitVerboseStartupLogs(@import("builtin").mode)) {
                    Raknet.Logger.INFO("Loaded pre-spawn data ({d} block palette entries, {d} voxel shapes)", .{ psd.block_palette.len, psd.voxel_shapes.len });
                }
            }
        }

        if (self.auto_load_worlds) {
            if (std.Io.Dir.cwd().openDir(self.io, self.paths.worlds, .{ .iterate = true })) |worlds_dir_val| {
                var worlds_dir = worlds_dir_val;
                defer worlds_dir.close(self.io);
                var dir_it = worlds_dir.iterate();
                while (dir_it.next(self.io) catch null) |entry| {
                    if (entry.kind != .directory) continue;
                    _ = self.loadWorld(entry.name) catch |err| {
                        Raknet.Logger.ERROR("Failed to load world '{s}': {any}", .{ entry.name, err });
                        continue;
                    };
                    Raknet.Logger.INFO("Loaded world: {s}", .{entry.name});
                }
            } else |_| {
                std.Io.Dir.cwd().createDir(self.io, self.paths.worlds, .default_dir) catch {};
            }

            if (self.worlds.count() == 0 and self.create_default_world) {
                Raknet.Logger.INFO("No worlds found, creating default world", .{});
                _ = try self.loadWorld("world");
            }
        }

        self.player_locations.load();
        self.ecs.setDropCallback(@ptrCast(self), ecsDrop);
        self.plugin_runtime.attach(self, &self.events, Protocol.PROTOCOL);
        if (self.discover_native_plugins) {
            self.plugin_runtime.discover(self.io, Protocol.PROTOCOL, self.paths.plugins);
        }
        var world_instances = self.worlds.valueIterator();
        while (world_instances.next()) |world| {
            if (world.*.getDimension("overworld")) |dimension| {
                _ = self.instances.create(world.*.identifier, world.*, dimension) catch |err| {
                    Raknet.Logger.ERROR("Failed to create instance for world '{s}': {any}", .{ world.*.identifier, err });
                };
            }
        }
        if (shouldEmitVerboseStartupLogs(@import("builtin").mode)) {
            Raknet.Logger.INFO("Loaded {d} player locations", .{self.player_locations.count()});
        }

        const commands = .{
            @import("./command/list/summon.zig"),
            @import("./command/list/about.zig"),
            @import("./command/list/stop.zig"),
            @import("./command/list/tp.zig"),
            @import("./command/list/gamemode.zig"),
            @import("./command/list/kick.zig"),
            @import("./command/list/ban.zig"),
            @import("./command/list/give.zig"),
            @import("./command/list/weather.zig"),
            @import("./command/list/op.zig"),
            @import("./command/list/floating-text.zig"),
        };
        inline for (commands) |cmd| {
            try cmd.register(&self.command_registry);
        }
        try @import("./command/list/worlds.zig").register(&self.command_registry, self);
        try @import("./command/list/world.zig").register(&self.command_registry, self);
        self.prepared = true;
        if (self.prepare_callback) |callback| callback(self.lifecycle_userdata);
    }

    pub fn registerCommand(self: *Conduit, command: *@import("./command/command.zig").Command) !void {
        try self.command_registry.registerCommand(command);
    }

    pub fn eventBus(self: *Conduit) *Events.Events {
        return &self.events;
    }

    pub fn commandRegistry(self: *Conduit) *CommandRegistry {
        return &self.command_registry;
    }

    pub fn scheduler(self: *Conduit) *TaskQueue {
        return &self.tasks;
    }

    pub fn serverConfig(self: *const Conduit) *const ServerProperties {
        return &self.config;
    }

    pub fn isPrepared(self: *const Conduit) bool {
        return self.prepared;
    }

    pub fn isStarted(self: *const Conduit) bool {
        return self.started;
    }

    pub fn setCommandPermissionChecker(self: *Conduit, checker: ?CommandPermissionChecker, userdata: ?*anyopaque) void {
        self.command_permission_checker = checker;
        self.command_permission_userdata = userdata;
    }

    pub fn setTickCallback(self: *Conduit, callback: ?*const fn (?*anyopaque) void, userdata: ?*anyopaque) void {
        self.tick_callback = callback;
        self.tick_userdata = userdata;
    }

    pub fn setLifecycleCallbacks(
        self: *Conduit,
        prepare_callback: ?*const fn (?*anyopaque) void,
        start_callback: ?*const fn (?*anyopaque) void,
        shutdown_callback: ?*const fn (?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.prepare_callback = prepare_callback;
        self.start_callback = start_callback;
        self.shutdown_callback = shutdown_callback;
        self.lifecycle_userdata = userdata;
    }

    pub fn start(self: *Conduit) !void {
        if (self.started) return;
        try self.prepare();
        self.network = try NetworkHandler.init(self);
        self.network_initialized = true;

        self.tick_thread_id.store(0, .release);
        self.raknet.setTickCallback(onTick, self);
        const worker_resolution: WorkerCountResolution = resolveWorkerCount(self.config.worker_threads);
        try self.threaded_tasks.start();
        if (!worker_resolution.auto_selected and worker_resolution.resolved_count < worker_resolution.requested_count) {
            Raknet.Logger.WARN(
                "Configured worker-threads={d} exceeds recommended max for {d} CPUs, clamping to {d}",
                .{
                    worker_resolution.requested_count,
                    worker_resolution.cpu_count,
                    worker_resolution.resolved_count,
                },
            );
        }
        Raknet.Logger.INFO("RakNet MTU cap: {d}", .{self.raknet.options.max_mtu});
        Raknet.Logger.INFO("Movement send priority: {s}", .{self.movement_priority.label()});
        Raknet.Logger.INFO("Loaded {d} threads, {d} worker threads available", .{
            totalServerThreadCount(self.threaded_tasks.workerCount()),
            self.threaded_tasks.workerCount(),
        });
        var event = Events.types.ServerStartEvent{};
        _ = self.events.emit(Events.Event.ServerStart, &event);

        try self.raknet.start();
        self.plugin_runtime.setServerState(1);

        if (self.enable_console) {
            try self.console.start(self);
            self.console_started = true;
        }
        self.started = true;
        if (self.start_callback) |callback| callback(self.lifecycle_userdata);
    }

    /// Runs the vanilla server loop after `start` has completed.
    ///
    /// The embedding application owns initialization and teardown; this method
    /// only waits while the network server is running.
    pub fn run(self: *Conduit) !void {
        while (self.raknet.running.load(.acquire)) {
            try self.io.sleep(.fromNanoseconds(std.time.ns_per_s / 20), .awake);
        }
    }

    pub fn stop(self: *Conduit) !void {
        if (self.stopped) return;
        defer {
            self.stopped = true;
            self.started = false;
            self.raknet.running.store(false, .release);
            if (self.shutdown_callback) |callback| callback(self.lifecycle_userdata);
        }
        self.plugin_runtime.setServerState(2);
        var event = Events.types.ServerShutdownEvent{};
        _ = self.events.emit(.ServerShutdown, &event);

        var it = self.players.valueIterator();
        while (it.next()) |player_ptr| {
            const player = player_ptr.*;
            if (!self.network_initialized) break;
            var str = BinaryStream.init(self.allocator, null, null);
            defer str.deinit();
            var disconnect = Protocol.DisconnectPacket{
                .reason = .Disconnected,
                .messages = .{
                    .message = "Server shutdown.",
                    .filtered_message = "Server shutdown.",
                },
            };
            const serialized = try disconnect.serialize(&str);
            try self.network.sendImmediate(player.connection, serialized);
            player.connection.active = false;
        }
    }

    pub fn shutdown(self: *Conduit) !void {
        try self.stop();
    }

    pub fn getPlayerByConnection(self: *Conduit, connection: *Raknet.Connection) ?*Player {
        self.players_mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return null;
        };
        defer self.players_mutex.unlock(self.io);
        if (self.connection_map.count() == 0) return null;
        return self.connection_map.get(@intFromPtr(connection));
    }

    fn publishPlayerCountLocked(self: *Conduit) void {
        self.players_count.store(self.players.count(), .release);
    }

    pub fn addPlayer(self: *Conduit, player: *Player) !void {
        try self.players_mutex.lock(self.io);
        defer self.players_mutex.unlock(self.io);
        try self.players.put(player.entity.runtime_id, player);
        self.publishPlayerCountLocked();
        try self.connection_map.put(@intFromPtr(player.connection), player);
        self.raknet.options.advertisement.player_count = @intCast(self.players.count());
        self.players_snapshot.publish(self.allocator, self.players.valueIterator());
    }

    pub fn removePlayer(self: *Conduit, player: *Player) void {
        self.players_mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.players_mutex.unlock(self.io);
        _ = self.players.remove(player.entity.runtime_id);
        self.publishPlayerCountLocked();
        _ = self.connection_map.remove(@intFromPtr(player.connection));
        self.raknet.options.advertisement.player_count = @intCast(self.players.count());
        self.players_snapshot.publish(self.allocator, self.players.valueIterator());
    }
    pub fn removeConnectionMapping(self: *Conduit, connection: *Raknet.Connection) void {
        self.players_mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.players_mutex.unlock(self.io);
        _ = self.connection_map.remove(@intFromPtr(connection));
        self.players_snapshot.publish(self.allocator, self.players.valueIterator());
    }

    pub fn enqueuePlayerRemoval(self: *Conduit, player: *Player) void {
        self.pending_player_removals_mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.pending_player_removals_mutex.unlock(self.io);
        self.pending_player_removals.append(self.allocator, player) catch {
            std.log.err("failed to enqueue player removal: {s}", .{player.username});
        };
    }

    pub fn drainPendingPlayerRemovals(self: *Conduit) void {
        self.pending_player_removals_mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        var pending = self.pending_player_removals;
        self.pending_player_removals = .empty;
        self.pending_player_removals_mutex.unlock(self.io);

        defer pending.deinit(self.allocator);
        for (pending.items) |player| {
            var event = Events.types.PlayerDisconnectEvent{ .player = player };
            _ = self.events.emit(.PlayerDisconnect, &event);
            self.instances.leave(player.entity.runtime_id);
            player.finalizeRemoval();
        }
    }

    fn flushMovementBroadcasts(self: *Conduit) void {
        const started = Timestamp.now(self.io, .awake);
        defer {
            const elapsed = started.durationTo(.now(self.io, .awake));
            self.profiler.record(.movement_broadcast, @intCast(@max(0, elapsed.nanoseconds)));
        }

        const snapshots = self.getPlayerSnapshots();

        const scratch = self.network.scratch.begin();
        defer scratch.deinit();
        const stream = scratch.stream();

        self.movement_deltas.clearRetainingCapacity();
        for (snapshots) |emitter| {
            const state = emitter.pending_move orelse continue;
            emitter.pending_move = null;

            if (emitter.pending_removal.load(.acquire)) continue;

            const delta = MoveDelta.nextDelta(
                &emitter.last_broadcast,
                @intCast(emitter.entity.runtime_id),
                state,
                self.tick_count,
            ) orelse continue;

            const before = stream.getBuffer().len;
            _ = delta.serialize(stream) catch continue;

            self.movement_deltas.append(
                self.allocator,
                MovementBroadcast.markRef(stream, emitter.entity.runtime_id, before),
            ) catch continue;
        }

        if (self.movement_deltas.items.len == 0) return;

        const payload = stream.getBuffer();

        for (snapshots) |viewer| {
            if (!viewer.spawned) continue;
            if (viewer.pending_removal.load(.acquire)) continue;

            var index: usize = 0;
            while (index < self.movement_deltas.items.len) {
                self.movement_batch.clearRetainingCapacity();
                index = MovementBroadcast.fillBatch(
                    &self.movement_batch,
                    self.allocator,
                    payload,
                    self.movement_deltas.items,
                    index,
                    viewer.entity.runtime_id,
                    viewer.visible_players,
                    MovementBroadcast.MAX_BATCH_BYTES,
                );
                if (self.movement_batch.items.len == 0) break;
                self.network.sendPacketsUncompressedWith(viewer.connection, self.movement_batch.items, self.movement_priority) catch {};
            }
        }
    }

    pub fn rebuildPlayerSnapshot(self: *Conduit) void {
        self.players_mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.players_mutex.unlock(self.io);
        self.players_snapshot.publish(self.allocator, self.players.valueIterator());
    }

    pub fn getPlayerSnapshots(self: *Conduit) []const *Player {
        if (self.shutting_down) return &.{};
        return self.players_snapshot.items();
    }

    pub fn getPlayerCount(self: *const Conduit) usize {
        return self.players_count.load(.acquire);
    }

    pub fn registerEcsEntity(self: *Conduit, entity: *Entity) void {
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

    pub fn unregisterEcsEntity(self: *Conduit, entity: *Entity) void {
        if (entity.ecs_id == 0) return;
        _ = self.ecs.destroy(@bitCast(entity.ecs_id));
        entity.ecs_id = 0;
    }

    pub fn syncEcsEntity(self: *Conduit, entity: *Entity) void {
        if (entity.ecs_id == 0) return;
        self.ecs.updateTransform(@bitCast(entity.ecs_id), entity.position, entity.rotation, entity.motion);
    }

    pub fn targetTps(self: *const Conduit) f64 {
        return @as(f64, @floatFromInt(@max(@as(u32, 1), self.config.max_tps)));
    }

    /// Switches the movement broadcast between buffered (`normal`) and queue
    /// flushing (`immediate`) at runtime.
    pub fn setMovementSendPriority(self: *Conduit, priority: SendPriority) void {
        self.movement_priority = priority;
    }

    pub fn movementSendPriority(self: *const Conduit) SendPriority {
        return self.movement_priority;
    }

    fn onTick(context: ?*anyopaque) void {
        const self = @as(*Conduit, @ptrCast(@alignCast(context)));
        if (self.tick_thread_id.load(.monotonic) == 0) {
            self.tick_thread_id.store(@intCast(std.Thread.getCurrentId()), .release);
        }
        const work_start = Timestamp.now(self.io, .awake);
        const target_tps_u64 = @max(@as(u64, 1), @as(u64, self.config.max_tps));
        const tick_budget_ns: u64 = std.time.ns_per_s / target_tps_u64;
        const metrics_window_ticks = target_tps_u64;
        self.profiler.tick_budget_ns = tick_budget_ns;

        if (self.last_tick_started_at) |last_tick_started_at| {
            const elapsed = work_start.durationTo(last_tick_started_at).nanoseconds;
            const interval_ns: u64 = @intCast(@max(0, elapsed));
            self.tick_interval_accumulator += interval_ns;
            self.tick_interval_samples += 1;
        }
        self.last_tick_started_at = work_start;

        self.tick_count += 1;
        var tick_event = Events.types.ServerTickEvent{ .tick = self.tick_count };
        _ = self.events.emit(.ServerTick, &tick_event);
        self.ecs.tick();

        const raknet_ns: u64 = @intCast(@max(0, self.raknet.last_connection_tick_ns.nanoseconds));
        self.raknet_time_accumulator += raknet_ns;
        self.profiler.record(.raknet_tick, raknet_ns);

        const packet_drain_budget = tick_budget_ns * 5 / 100;
        const packet_drain_cap: usize = @max(256, self.getPlayerCount() * 8);
        const pd_start = Timestamp.now(self.io, .awake);
        const drain_result = self.network.drainPackets(packet_drain_budget, packet_drain_cap);
        const pd_end = pd_start.durationTo(.now(self.io, .awake));
        self.profiler.record(.packet_drain, @intCast(@max(0, pd_end.nanoseconds)));

        const decompress_pending = self.network.decompress_pending.load(.monotonic);
        const dropped_packets = self.network.dropped_packets.load(.monotonic);
        if ((decompress_pending > 256 or dropped_packets > 0) and self.tick_count % target_tps_u64 == 0) {
            Raknet.Logger.WARN("Network packet backlog: pending={d} queued={d} dropped={d}", .{
                decompress_pending,
                drain_result.remaining,
                dropped_packets,
            });
        }

        self.drainPendingPlayerRemovals();
        self.rebuildPlayerSnapshot();

        var phase_start = Timestamp.now(self.io, .awake);
        const snapshots = self.getPlayerSnapshots();
        for (snapshots) |player| {
            if (!player.spawned) continue;
            player.entity.fireEvent(.Tick, .{&player.entity});
        }
        var phase_end = phase_start.durationTo(.now(self.io, .awake));
        self.profiler.record(.player_tick, @intCast(@max(0, phase_end.nanoseconds)));

        phase_start = Timestamp.now(self.io, .awake);
        var worlds_it = self.worlds.valueIterator();
        while (worlds_it.next()) |world| {
            var dims_it = world.*.dimensions.valueIterator();
            while (dims_it.next()) |dim| {
                var ent_it = dim.*.entities.valueIterator();
                while (ent_it.next()) |entity| {
                    entity.*.fireEvent(.Tick, .{entity.*});
                    dim.*.reindexEntity(entity.*);
                }
                dim.*.flushPendingRemovals();
            }
        }
        phase_end = phase_start.durationTo(.now(self.io, .awake));
        self.profiler.record(.world_tick, @intCast(@max(0, phase_end.nanoseconds)));

        const drain_budget = tick_budget_ns * 15 / 100;

        phase_start = Timestamp.now(self.io, .awake);
        self.threaded_tasks.drainCompleted(drain_budget);
        phase_end = phase_start.durationTo(.now(self.io, .awake));
        self.profiler.record(.drain_completed_1, @intCast(@max(0, phase_end.nanoseconds)));

        phase_start = Timestamp.now(self.io, .awake);
        _ = self.tasks.runUntil(self.io, work_start, tick_budget_ns * 50 / 100);
        phase_end = phase_start.durationTo(.now(self.io, .awake));
        const tasks_ns: u64 = @intCast(@max(0, phase_end.nanoseconds));
        self.tasks_time_accumulator += tasks_ns;
        self.profiler.record(.main_tasks, tasks_ns);

        phase_start = Timestamp.now(self.io, .awake);
        self.threaded_tasks.drainCompleted(drain_budget);
        phase_end = phase_start.durationTo(.now(self.io, .awake));
        self.profiler.record(.drain_completed_2, @intCast(@max(0, phase_end.nanoseconds)));

        if (self.console_started) self.console.drainCommands();
        if (self.tick_callback) |callback| callback(self.tick_userdata);

        self.flushMovementBroadcasts();

        const work_end = work_start.durationTo(.now(self.io, .awake));
        const work_ns: u64 = @intCast(@max(0, work_end.nanoseconds));
        const total_tick_ns = raknet_ns + work_ns;
        self.work_time_accumulator += work_ns;
        self.profiler.recordTick(total_tick_ns);

        if (self.tick_count % metrics_window_ticks == 0) {
            const avg_work_ns = self.work_time_accumulator / metrics_window_ticks;
            const avg_raknet_ns = self.raknet_time_accumulator / metrics_window_ticks;
            const avg_interval_ns = if (self.tick_interval_samples > 0)
                self.tick_interval_accumulator / self.tick_interval_samples
            else
                0;
            self.work_time_accumulator = 0;
            self.raknet_time_accumulator = 0;
            self.tasks_time_accumulator = 0;

            self.current_game_mspt = @as(f64, @floatFromInt(avg_work_ns)) / 1_000_000.0;
            self.current_raknet_mspt = @as(f64, @floatFromInt(avg_raknet_ns)) / 1_000_000.0;
            self.current_mspt = @as(f64, @floatFromInt(avg_work_ns + avg_raknet_ns)) / 1_000_000.0;

            if (avg_interval_ns > 0) {
                const interval_s = @as(f64, @floatFromInt(avg_interval_ns)) / 1_000_000_000.0;
                self.current_tps = if (interval_s > 0.0)
                    @min(self.targetTps(), 1.0 / interval_s)
                else
                    self.targetTps();
            } else {
                self.current_tps = self.targetTps();
            }

            self.tick_interval_accumulator = 0;
            self.tick_interval_samples = 0;
        }

        if (self.tick_count % 6000 == 0) self.beginSavePass();
        self.tickIncrementalSave();
    }

    pub fn buildWorld(self: *Conduit, name: []const u8) !*World {
        var path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}/db", .{ self.paths.worlds, name });
        std.Io.Dir.cwd().createDirPath(self.io, db_path) catch {};

        const provider = try LevelDBProvider.init(self.io, self.allocator, db_path);
        const world = self.allocator.create(World) catch |err| {
            provider.deinit();
            return err;
        };

        world.* = World.init(self, self.allocator, name, provider.asProvider()) catch |err| {
            self.allocator.destroy(world);
            provider.deinit();
            return err;
        };
        errdefer {
            world.deinit();
            self.allocator.destroy(world);
        }
        try self.createWorldDimensions(world);
        return world;
    }

    pub fn loadWorld(self: *Conduit, name: []const u8) !*World {
        const world = try self.buildWorld(name);
        self.worlds.put(world.identifier, world) catch |err| {
            world.deinit();
            self.allocator.destroy(world);
            return err;
        };
        return world;
    }

    fn createWorldDimensions(self: *Conduit, world: *World) !void {
        try self.createWorldDimension(world, "overworld", .Overworld, true);
        try self.createWorldDimension(world, "nether", .Nether, false);
        try self.createWorldDimension(world, "end", .End, false);

        var level_dat_buf: [512]u8 = undefined;
        const level_dat_path = std.fmt.bufPrint(&level_dat_buf, "{s}/{s}/level.dat", .{ self.paths.worlds, world.identifier }) catch return;
        if (readLevelDatSpawn(self.io, self.allocator, level_dat_path)) |spawn| {
            if (world.getDimension("overworld")) |dim| {
                dim.spawn_position = spawn;
                Raknet.Logger.INFO("World '{s}' spawn: {d}, {d}, {d}", .{ world.identifier, spawn.x, spawn.y, spawn.z });
            }
        } else |_| {}
    }

    fn createWorldDimension(
        self: *Conduit,
        world: *World,
        identifier: []const u8,
        dimension_type: Protocol.DimensionType,
        load_spawn_chunks: bool,
    ) !void {
        const props = Generator.GeneratorProperties.init(self.io, null, dimension_type);
        const superflat = try Generator.SuperflatGenerator.init(self.allocator, props);
        const threaded = Generator.ThreadedGenerator.init(self.io, self.allocator, superflat.asGenerator()) catch |err| {
            superflat.deinit();
            return err;
        };
        const dim = try world.createDimension(identifier, dimension_type, threaded, load_spawn_chunks);
        dim.simulation_distance = @intCast(self.config.simulation_distance);
    }

    pub fn destroyWorld(self: *Conduit, world: *World) void {
        _ = self.worlds.remove(world.identifier);
        world.deinit();
        self.allocator.destroy(world);
    }

    pub fn getWorld(self: *Conduit, identifier: []const u8) ?*World {
        return self.worlds.get(identifier);
    }

    pub fn setPlayerLocation(self: *Conduit, uuid: []const u8, world_identifier: []const u8, dimension_identifier: []const u8) void {
        self.player_locations.set(uuid, world_identifier, dimension_identifier);
        self.player_locations.flush();
    }

    pub fn resolvePlayerLocation(self: *Conduit, uuid: []const u8) ?*const PlayerLocation {
        return self.player_locations.getPtr(uuid);
    }

    pub fn broadcastAvailableCommands(self: *Conduit) void {
        const snapshots = self.getPlayerSnapshots();
        for (snapshots) |player| {
            if (!player.spawned) continue;
            var stream = BinaryStream.init(self.allocator, null, null);
            defer stream.deinit();
            const serialized = self.command_registry.buildAvailableCommandsPacket(&stream) catch continue;
            self.network.sendPacket(player.connection, serialized) catch {};
        }
    }

    pub fn refreshWorldCommandEnums(self: *Conduit) void {
        const world_count = self.worlds.count();
        const world_name_values = self.allocator.alloc([]const u8, world_count) catch return;
        const transfer_values = self.allocator.alloc([]const u8, world_count) catch {
            self.allocator.free(world_name_values);
            return;
        };

        var index: usize = 0;
        var names_it = self.worlds.keyIterator();
        while (names_it.next()) |name| {
            world_name_values[index] = name.*;
            transfer_values[index] = name.*;
            index += 1;
        }

        const world_name_updated = self.command_registry.updateEnumValues("WorldName", world_name_values) catch false;
        if (!world_name_updated) self.allocator.free(world_name_values);
        const transfer_updated = self.command_registry.updateEnumValues("TransferWorld", transfer_values) catch false;
        if (!transfer_updated) self.allocator.free(transfer_values);

        self.broadcastAvailableCommands();
    }

    pub fn refreshFloatingTextCommandEnums(self: *Conduit) void {
        var names = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        defer names.deinit(self.allocator);
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        var worlds_it = self.worlds.valueIterator();
        while (worlds_it.next()) |world| {
            var dims_it = world.*.dimensions.valueIterator();
            while (dims_it.next()) |dim| {
                const manager = dim.*.floating_texts orelse continue;
                for (manager.items()) |hologram| {
                    if (seen.contains(hologram.name)) continue;
                    seen.put(hologram.name, {}) catch return;
                    names.append(self.allocator, hologram.name) catch return;
                }
            }
        }

        const values = self.allocator.alloc([]const u8, names.items.len) catch return;
        @memcpy(values, names.items);
        const updated = self.command_registry.updateEnumValues("FloatingTextName", values) catch false;
        if (!updated) self.allocator.free(values);

        self.broadcastAvailableCommands();
    }

    /// Plans a save pass over every loaded chunk. The pass keeps its own copy
    /// of the world and dimension names, so a world unloaded mid-pass is
    /// skipped instead of dangling.
    fn beginSavePass(self: *Conduit) void {
        self.freeSavePlan();
        self.save_cursor = .{};
        self.save_player_cursor = 0;
        self.save_players_pending = true;
        self.save_in_flight = true;

        var worlds_it = self.worlds.valueIterator();
        while (worlds_it.next()) |world| {
            var dims_it = world.*.dimensions.valueIterator();
            while (dims_it.next()) |dim| {
                var hashes = std.ArrayListUnmanaged(ChunkHash).empty;
                var chunk_it = dim.*.chunks.keyIterator();
                while (chunk_it.next()) |hash| hashes.append(self.allocator, hash.*) catch break;
                if (hashes.items.len == 0) {
                    hashes.deinit(self.allocator);
                    continue;
                }
                const owned = hashes.toOwnedSlice(self.allocator) catch {
                    hashes.deinit(self.allocator);
                    continue;
                };
                const world_name = self.allocator.dupe(u8, world.*.identifier) catch {
                    self.allocator.free(owned);
                    continue;
                };
                const dim_name = self.allocator.dupe(u8, dim.*.identifier) catch {
                    self.allocator.free(owned);
                    self.allocator.free(world_name);
                    continue;
                };
                self.save_plan.append(self.allocator, .{ .world = world_name, .dim = dim_name, .hashes = owned }) catch {
                    self.allocator.free(owned);
                    self.allocator.free(world_name);
                    self.allocator.free(dim_name);
                    continue;
                };
            }
        }
    }

    fn freeSavePlan(self: *Conduit) void {
        for (self.save_plan.items) |group| {
            self.allocator.free(group.hashes);
            self.allocator.free(group.world);
            self.allocator.free(group.dim);
        }
        self.save_plan.deinit(self.allocator);
        self.save_plan = .empty;
    }

    fn tickIncrementalSave(self: *Conduit) void {
        if (!self.save_in_flight) return;

        const started = Timestamp.now(self.io, .awake);
        var budget = save_chunks_per_tick;
        while (budget > 0 and self.save_cursor.group < self.save_plan.items.len) {
            const group = self.save_plan.items[self.save_cursor.group];
            if (self.save_cursor.chunk >= group.hashes.len) {
                self.save_cursor.group += 1;
                self.save_cursor.chunk = 0;
                continue;
            }
            const hash = group.hashes[self.save_cursor.chunk];
            self.save_cursor.chunk += 1;
            budget -= 1;
            self.saveOneChunk(group, hash);
            if (started.durationTo(.now(self.io, .awake)).nanoseconds >= save_ns_budget) break;
        }

        if (self.save_cursor.group < self.save_plan.items.len) return;

        if (self.save_players_pending) {
            const snapshots = self.getPlayerSnapshots();
            var saved: usize = 0;
            while (saved < save_players_per_tick and self.save_player_cursor < snapshots.len) : (saved += 1) {
                snapshots[self.save_player_cursor].savePlayerData();
                self.save_player_cursor += 1;
            }
            if (self.save_player_cursor < snapshots.len) return;
            self.save_players_pending = false;
        }

        self.save_in_flight = false;
        self.freeSavePlan();
    }

    /// Same work as `World.save` for one chunk, but reached through the plan so
    /// the walk can be spread across ticks.
    fn saveOneChunk(self: *Conduit, group: SaveGroup, hash: ChunkHash) void {
        const world = self.worlds.get(group.world) orelse return;
        const dim = world.getDimension(group.dim) orelse return;
        const chunk = dim.chunks.get(hash) orelse return;
        world.provider.writeChunkEntities(chunk, dim) catch {};
        world.provider.writeBlockEntities(chunk, dim) catch {};
        if (chunk.dirty) world.provider.writeChunk(chunk, dim) catch {};
    }

    pub fn saveAllWorlds(self: *Conduit) void {
        var worlds_it = self.worlds.valueIterator();
        while (worlds_it.next()) |world| {
            world.*.save();
        }

        const snapshots = self.getPlayerSnapshots();
        for (snapshots) |player| {
            player.savePlayerData();
        }
    }

    pub fn deinit(self: *Conduit) void {
        self.profiler.writeReport(self.io, "dump/tick-profile.txt");

        self.threaded_tasks.clearPending();
        self.threaded_tasks.stop();
        self.threaded_tasks.drainCompleted(std.math.maxInt(u64));
        self.drainPendingPlayerRemovals();
        self.saveAllWorlds();
        self.freeSavePlan();
        self.threaded_tasks.deinit();
        self.shutting_down = true;

        var it = self.players.valueIterator();
        while (it.next()) |player| {
            player.*.deinit();
            self.allocator.destroy(player.*);
        }
        self.movement_deltas.deinit(self.allocator);
        self.movement_batch.deinit(self.allocator);
        self.players.deinit();
        self.connection_map.deinit();
        self.players_snapshot.deinit(self.allocator);
        self.plugin_runtime.deinit();

        var worlds_it = self.worlds.valueIterator();
        while (worlds_it.next()) |world| {
            world.*.deinit();
            self.allocator.destroy(world.*);
        }
        self.worlds.deinit();

        self.raknet.deinit();

        self.pending_player_removals.deinit(self.allocator);

        deinitRegistries();
        EntityTraits.deinitEntityTraitRegistry();
        ItemPalette.deinitRegistry();
        EntityTypeRegistry.EntityTypeRegistry.deinit();
        if (self.creative_content) |*cc| cc.deinit();
        if (self.pre_spawn_data) |*psd| psd.deinit();
        if (self.serialized_item_registry) |s| self.allocator.free(s);
        if (self.serialized_biome_definitions) |s| self.allocator.free(s);
        self.config.deinit();
        self.instances.deinit();
        self.ecs.deinit();
        self.events.deinit();
        if (self.network_initialized) self.network.deinit();
        if (self.console_started) self.console.deinit();
        self.tasks.deinit();
        self.world_ops.deinit();
        self.command_registry.deinit();
        self.ban_manager.deinit();
        self.permission_manager.deinit();
        self.player_locations.flush();
        self.player_locations.deinit();
        if (self.auth_service) |*service| service.deinit();
    }
};

fn ecsDrop(context: *anyopaque, _: EcsEntityId, position: Protocol.Vector3f, item: @import("entity/ecs.zig").ItemDrop) void {
    const conduit: *Conduit = @ptrCast(@alignCast(context));
    const dimension = conduit.getWorld("world") orelse return;
    const overworld = dimension.getDimension("overworld") orelse return;
    const item_type = @import("items/item-type.zig").ItemType.get(item.identifier) orelse return;
    _ = overworld.spawnItemEntity(item_type, item.count, position, item.pickup_delay, Protocol.Vector3f.init(0, 0.1, 0)) catch {};
}

fn readLevelDatSpawn(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Protocol.BlockPosition {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const data = try reader.interface.allocRemaining(allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(data);
    if (data.len < 8) return error.InvalidLevelDat;

    var stream = BinaryStream.init(allocator, data[8..], null);
    defer stream.deinit();
    var root = try NBT.CompoundTag.read(&stream, allocator, NBT.ReadWriteOptions.default);
    defer root.deinit(allocator);

    const sx = switch (root.get("SpawnX") orelse return error.NoSpawn) {
        .Int => |t| t.value,
        else => return error.NoSpawn,
    };
    const sy = switch (root.get("SpawnY") orelse return error.NoSpawn) {
        .Int => |t| t.value,
        else => return error.NoSpawn,
    };
    const sz = switch (root.get("SpawnZ") orelse return error.NoSpawn) {
        .Int => |t| t.value,
        else => return error.NoSpawn,
    };

    return Protocol.BlockPosition{ .x = sx, .y = sy, .z = sz };
}

test "every `players` mutation refreshes the atomic count" {
    const source = @embedFile("conduit.zig");
    const mutating_calls = [_][]const u8{
        "self.players.put(",
        "self.players.putNoClobber(",
        "self.players.remove(",
        "self.players.fetchRemove(",
        "self.players.clearRetainingCapacity(",
        "self.players.clearAndFree(",
    };
    const refresh = "publishPlayerCountLocked()";
    const max_gap: usize = 4;

    var mutations: usize = 0;
    var missing: ?usize = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    var last_mutation_line: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        var is_mutation = false;
        for (mutating_calls) |needle| {
            if (std.mem.indexOf(u8, line, needle) != null) is_mutation = true;
        }
        if (is_mutation) {
            mutations += 1;
            last_mutation_line = line_no;
            continue;
        }
        if (last_mutation_line != 0 and line_no - last_mutation_line <= max_gap) {
            if (std.mem.indexOf(u8, line, refresh) != null) last_mutation_line = 0;
        }
        if (last_mutation_line != 0 and line_no - last_mutation_line > max_gap and missing == null) {
            missing = last_mutation_line;
        }
    }

    if (missing) |at| {
        std.debug.print("conduit.zig:{d}: `players` mutation without refreshing the counter\n", .{at});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), last_mutation_line);
    try std.testing.expect(mutations >= 2);
}

test "the RakNet MTU cap is the clamped config value, never a literal" {
    const source = @embedFile("conduit.zig");
    const cutoff = std.mem.indexOf(u8, source, "test \"the RakNet MTU cap") orelse return error.TestUnexpectedResult;
    const init_code = source[0..cutoff];
    try std.testing.expect(std.mem.indexOf(u8, init_code, "ServerProperties.clampMaxMtu(owned_config.max_mtu)") != null);

    var found: usize = 0;
    var rest: []const u8 = init_code;
    while (std.mem.indexOf(u8, rest, ".max_mtu = ")) |at| {
        const value_start = at + ".max_mtu = ".len;
        const end = std.mem.indexOfScalarPos(u8, rest, value_start, ',') orelse return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, rest[value_start..end], "max_mtu")) {
            std.debug.print("conduit.zig: the RakNet MTU cap is not the clamped config value\n", .{});
            return error.TestUnexpectedResult;
        }
        found += 1;
        rest = rest[end..];
    }
    try std.testing.expectEqual(@as(usize, 1), found);
}

test "the movement flush sends with the configured priority, never a literal" {
    const source = @embedFile("conduit.zig");
    const cutoff = std.mem.indexOf(u8, source, "test \"the movement flush sends with the configured priority") orelse return error.TestUnexpectedResult;
    const code = source[0..cutoff];
    try std.testing.expect(std.mem.indexOf(u8, code, "sendPacketsUncompressedWith(viewer.connection, self.movement_batch.items, self.movement_priority)") != null);
}

test "onTick broadcasts movement and no path skips the flush" {
    const source = @embedFile("conduit.zig");
    const flush_call = "self.flushMovementBroadcasts()";

    const on_tick_start = std.mem.indexOf(u8, source, "fn onTick(context: ?*anyopaque) void {") orelse
        return error.TestUnexpectedResult;
    const on_tick_end = std.mem.indexOfPos(u8, source, on_tick_start, "\n    pub fn buildWorld(") orelse
        return error.TestUnexpectedResult;
    const body = source[on_tick_start..on_tick_end];

    const allocator = std.testing.allocator;
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(allocator);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const stripped = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try code.appendSlice(allocator, stripped);
        try code.append(allocator, '\n');
    }

    const flush_at = std.mem.indexOf(u8, code.items, flush_call) orelse {
        std.debug.print("conduit.zig: onTick no longer calls {s}: movement is not broadcast\n", .{flush_call});
        return error.TestUnexpectedResult;
    };

    if (std.mem.indexOf(u8, code.items[0..flush_at], "return")) |at| {
        const line_no = std.mem.count(u8, code.items[0..at], "\n") + 2;
        std.debug.print(
            "conduit.zig:{d}: onTick returns before the movement flush\n",
            .{on_tick_start_line(source, on_tick_start) + line_no},
        );
        return error.TestUnexpectedResult;
    }
}

test "the player snapshot goes quiet before the players are freed" {
    const source = @embedFile("conduit.zig");
    const silenced = std.mem.indexOf(u8, source, "if (self.shutting_down) return &.{};") orelse {
        std.debug.print("conduit.zig: getPlayerSnapshots hands out a list that teardown frees\n", .{});
        return error.TestUnexpectedResult;
    };
    const deinit_start = std.mem.indexOf(u8, source, "pub fn deinit(self: *Conduit) void {") orelse
        return error.TestUnexpectedResult;
    const guard = std.mem.indexOfPos(u8, source, deinit_start, "self.shutting_down = true;") orelse {
        std.debug.print("conduit.zig: deinit frees the players while block traits can still broadcast\n", .{});
        return error.TestUnexpectedResult;
    };
    const players_freed = std.mem.indexOfPos(u8, source, guard, "self.players.valueIterator()") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(silenced < deinit_start);
    try std.testing.expect(guard < players_freed);
}

fn on_tick_start_line(source: []const u8, at: usize) usize {
    return std.mem.count(u8, source[0..at], "\n") + 1;
}

test {
    _ = @import("./command/list/world.zig");
    _ = @import("./command/list/floating-text.zig");
    _ = @import("./world/provider/leveldb-provider.zig");
    _ = @import("./entity/traits/chunk-loading.zig");
    _ = @import("./player/player-snapshot.zig");
    _ = @import("./player/move-delta.zig");
    _ = @import("./network/movement-broadcast.zig");
}
