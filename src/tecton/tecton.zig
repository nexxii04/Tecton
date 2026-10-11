const std = @import("std");
const Timestamp = std.Io.Timestamp;

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const CommandRegistry = @import("./command/registry.zig").CommandRegistry;
const ServerProperties = @import("./core/config.zig").ServerProperties;
const shouldEmitStartupLogs = @import("./core/config.zig").shouldEmitStartupLogs;
const Console = @import("./console/console.zig").Console;
const EntityTypeRegistry = @import("./entity/entity_type_registry.zig");
const EntityType = @import("./entity/entity_type.zig").EntityType;
const Entity = @import("./entity/entity.zig").Entity;
const EntityTraits = @import("./entity/traits/root.zig");
const CreativeContentLoader = @import("./items/creative_content_loader.zig");
const ItemPalette = @import("./items/item_palette.zig");
const AuthService = @import("./auth/root.zig").AuthService;
const BanManager = @import("./network/ban_manager.zig").BanManager;
const MovementBroadcast = @import("./network/movement_broadcast.zig");
const NetworkHandler = @import("./network/root.zig").NetworkHandler;
const SendPriority = @import("./network/root.zig").SendPriority;
const PlayerLog = @import("./network/player_log.zig");
const MoveDelta = @import("./player/move_delta.zig");
const PermissionManager = @import("./player/permission_manager.zig").PermissionManager;
const PlayerLocations = @import("./player/player_locations.zig").PlayerLocations;
const PlayerLocation = @import("./player/player_locations.zig").Location;
const PlayerSnapshot = @import("./player/player_snapshot.zig").PlayerSnapshot;
const Player = @import("./player/player.zig").Player;
const TaskQueue = @import("./tasks/tasks.zig").TaskQueue;
const threaded_tasks = @import("./tasks/threaded_tasks.zig");
const ThreadedTaskQueue = threaded_tasks.ThreadedTaskQueue;
const WorkerCountResolution = @import("./tasks/threaded_tasks.zig").WorkerCountResolution;
const visibility_mod = @import("./entity/traits/visibility.zig");
const resolveWorkerCount = @import("./tasks/threaded_tasks.zig").resolveWorkerCount;
const totalServerThreadCount = @import("./tasks/threaded_tasks.zig").totalServerThreadCount;
const TickProfiler = @import("./core/tick_profiler.zig").TickProfiler;
pub const block_root = @import("./world/block/root.zig");
const deinitRegistries = @import("./world/block/root.zig").deinitRegistries;
const EcsWorld = @import("entity/ecs.zig").EcsWorld;
const Events = @import("events/root.zig");
const PluginRuntime = @import("plugins/runtime.zig").PluginRuntime;
const GameInstanceRegistry = @import("world/game_instance.zig").GameInstanceRegistry;
const PlayerRegistry = @import("server/players.zig").PlayerRegistry;
const options_mod = @import("server/options.zig");
const SaveScheduler = @import("server/save.zig").SaveScheduler;
const tick_mod = @import("server/tick.zig");
const movement_mod = @import("server/movement.zig");
const worlds_mod = @import("server/worlds.zig");

pub const ServerPaths = options_mod.ServerPaths;
pub const CommandPermissionChecker = options_mod.CommandPermissionChecker;

pub const Composition = struct {
    prepare: *const fn (*Tecton) anyerror!void,
    dispatch: *const fn (*anyopaque, *Raknet.Connection, []const []const u8) void,
    command_views: ?*const fn (*Tecton) @import("./command/registry.zig").CommandViews = null,
};

pub const ServerOptions = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    composition: Composition,
    properties: ?ServerProperties = null,
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

pub const Tecton = struct {
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
    composition: Composition,
    events: Events.Events,
    raknet: Raknet.Server,
    network: *NetworkHandler,
    network_initialized: bool = false,
    address_stamp: usize = 0,
    players: PlayerRegistry,
    movement_priority: SendPriority = .immediate,
    movement_distance_bands: bool = true,
    mob_broadcast_interval: u8 = 2,
    tick_thread_id: std.atomic.Value(usize) = .init(0),
    save: SaveScheduler = .{},
    worlds: worlds_mod.WorldRegistry,
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

    visibility_batch: std.ArrayList(*Player) = .empty,
    visibility_job: threaded_tasks.ParallelJob = .{},

    pub fn init(options: ServerOptions) !Tecton {
        const io = options.io;
        const allocator = options.allocator;
        Raknet.Logger.init(allocator);
        var owned_config = options.properties orelse try ServerProperties.load(io, allocator, "server.properties");
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
            Raknet.Logger.WARN("movement-send-priority={s} is not a known priority, using immediate", .{owned_config.movement_send_priority});
            break :fallback SendPriority.immediate;
        };
        const mob_broadcast_interval = ServerProperties.clampMobBroadcastInterval(owned_config.mob_broadcast_interval);
        if (mob_broadcast_interval != owned_config.mob_broadcast_interval) {
            Raknet.Logger.WARN("mob-broadcast-interval={d} is outside the supported range {d}-{d}, using {d}", .{
                owned_config.mob_broadcast_interval,
                ServerProperties.min_mob_broadcast_interval,
                ServerProperties.max_mob_broadcast_interval,
                mob_broadcast_interval,
            });
        }
        const ecs_capacity = @max(@as(usize, 4096), @as(usize, @intCast(owned_config.max_players)) * 8);
        var ecs = try EcsWorld.init(allocator, ecs_capacity);
        errdefer ecs.deinit();
        return Tecton{
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
            .composition = options.composition,
            .movement_priority = movement_priority,
            .movement_distance_bands = owned_config.movement_distance_bands,
            .mob_broadcast_interval = mob_broadcast_interval,
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
                    .gamemode = @tagName(owned_config.gameMode()),
                },
                .max_mtu = max_mtu,
            }),
            .players = PlayerRegistry.init(io, allocator),
            .worlds = worlds_mod.WorldRegistry.init(allocator),
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

    pub fn prepare(self: *Tecton) !void {
        return self.composition.prepare(self);
    }

    pub fn commandViews(self: *Tecton) @import("./command/registry.zig").CommandViews {
        const build = self.composition.command_views orelse std.debug.panic("composition has no command view builder", .{});
        return build(self);
    }

    pub fn registerCommand(self: *Tecton, command: *@import("./command/command.zig").Command) !void {
        try self.command_registry.registerCommand(command);
    }

    pub fn eventBus(self: *Tecton) *Events.Events {
        return &self.events;
    }

    pub fn commandRegistry(self: *Tecton) *CommandRegistry {
        return &self.command_registry;
    }

    pub fn scheduler(self: *Tecton) *TaskQueue {
        return &self.tasks;
    }

    pub fn serverConfig(self: *const Tecton) *const ServerProperties {
        return &self.config;
    }

    pub fn isPrepared(self: *const Tecton) bool {
        return self.prepared;
    }

    pub fn isStarted(self: *const Tecton) bool {
        return self.started;
    }

    pub fn setCommandPermissionChecker(self: *Tecton, checker: ?CommandPermissionChecker, userdata: ?*anyopaque) void {
        self.command_permission_checker = checker;
        self.command_permission_userdata = userdata;
    }

    pub fn setTickCallback(self: *Tecton, callback: ?*const fn (?*anyopaque) void, userdata: ?*anyopaque) void {
        self.tick_callback = callback;
        self.tick_userdata = userdata;
    }

    pub fn setLifecycleCallbacks(
        self: *Tecton,
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

    pub fn fixAddress(self: *Tecton) void {
        self.address_stamp = @intFromPtr(self);
    }

    pub fn start(self: *Tecton) !void {
        if (self.started) return;
        self.fixAddress();
        self.network = try NetworkHandler.init(self.io, self.allocator, &self.threaded_tasks, .{
            .ctx = self,
            .dispatch = self.composition.dispatch,
            .disconnected = onNetworkDisconnect,
        });
        self.network_initialized = true;
        self.raknet.setConnectCallback(NetworkHandler.onConnect, self.network);
        self.raknet.setDisconnectCallback(NetworkHandler.onDisconnect, self.network);
        try self.prepare();
        self.tick_thread_id.store(0, .release);
        self.raknet.setTickCallback(tick_mod.onTick, self);
        const worker_resolution: WorkerCountResolution = resolveWorkerCount(self.config.worker_threads);
        self.threaded_tasks.setLayout(self.config.worker_layout);
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
        Raknet.Logger.INFO("Mob broadcast interval: {d} ticks", .{self.mob_broadcast_interval});
        if (self.config.parallel_visibility and self.threaded_tasks.worldWorkerCount() > 1) {
            Raknet.Logger.INFO("Visibility pass: {d} world workers (parallel-visibility=true)", .{
                self.threaded_tasks.worldWorkerCount(),
            });
        } else {
            Raknet.Logger.INFO("Visibility pass: inline on the tick thread (parallel-visibility=false)", .{});
        }
        const pump_threads: usize = if (self.threaded_tasks.layoutResolution().layout == .split) 1 else 0;
        Raknet.Logger.INFO("Loaded {d} threads, {d} worker threads available", .{
            totalServerThreadCount(self.threaded_tasks.workerCount()) + pump_threads,
            self.threaded_tasks.workerCount(),
        });
        const pool_layout = self.threaded_tasks.layoutResolution();
        if (pool_layout.layout == .split) {
            Raknet.Logger.INFO("Worker pool: split layout, {d} input + {d} world workers ({d} CPUs)", .{
                pool_layout.input_worker_count,
                pool_layout.world_worker_count,
                pool_layout.cpu_count,
            });
        } else {
            Raknet.Logger.INFO("Worker pool: shared layout, {d} workers ({d} CPUs)", .{
                pool_layout.worker_count,
                pool_layout.cpu_count,
            });
        }
        if (self.config.network_inbound_ring) {
            self.network.enableInboundRing(
                ServerProperties.clampInboundRingSlots(self.config.inbound_ring_slots),
                ServerProperties.clampInboundRingSlotSize(self.config.inbound_ring_slot_size),
            ) catch |err| {
                Raknet.Logger.WARN("network-inbound-ring could not be enabled ({s}); using the legacy packet queue", .{@errorName(err)});
            };
        }
        if (self.network.inbound_ring) |ring| {
            const slab_mib = (ring.capacity() * ring.slot_size) / (1024 * 1024);
            Raknet.Logger.INFO("Inbound ring: {d} slots x {d} bytes ({d} MiB slab)", .{
                ring.capacity(),
                ring.slot_size,
                slab_mib,
            });
        } else {
            Raknet.Logger.INFO("Inbound ring disabled; using the legacy packet queue", .{});
        }

        if (self.threaded_tasks.layoutResolution().layout == .split) {
            try self.network.startInputPump();
            Raknet.Logger.INFO("Input pump: dedicated thread draining the input queue", .{});
        } else {
            Raknet.Logger.INFO("Input pump: disabled (shared layout drains input from the tick)", .{});
        }

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

    pub fn run(self: *Tecton) !void {
        while (self.raknet.running.load(.acquire)) {
            try self.io.sleep(.fromNanoseconds(std.time.ns_per_s / 20), .awake);
        }
    }

    pub fn stop(self: *Tecton) !void {
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

        for (self.players.list()) |player| {
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
            player.connection.deactivate();
        }
    }

    pub fn shutdown(self: *Tecton) !void {
        try self.stop();
    }

    pub fn getPlayerByConnection(self: *Tecton, connection: *Raknet.Connection) ?*Player {
        return self.players.byConnection(connection);
    }

    fn onNetworkDisconnect(ctx: *anyopaque, connection: *Raknet.Connection) void {
        const self: *Tecton = @ptrCast(@alignCast(ctx));
        const player = self.getPlayerByConnection(connection) orelse return;
        PlayerLog.logDisconnect(player.username);
        player.disconnectFromNetwork();
    }

    pub fn addPlayer(self: *Tecton, player: *Player) !void {
        try self.players.insert(player);
        self.publishPlayerCount();
    }

    pub fn removePlayer(self: *Tecton, player: *Player) void {
        self.players.remove(player);
        self.publishPlayerCount();
    }

    pub fn removeConnectionMapping(self: *Tecton, connection: *Raknet.Connection) void {
        self.players.removeConnection(connection);
        self.publishPlayerCount();
    }

    pub fn enqueuePlayerRemoval(self: *Tecton, player: *Player) void {
        self.players.enqueueRemoval(player);
    }

    fn publishPlayerCount(self: *Tecton) void {
        self.raknet.options.advertisement.player_count = @intCast(self.players.count());
    }

    pub fn drainPendingPlayerRemovals(self: *Tecton) void {
        var pending = self.players.takePendingRemovals();
        defer pending.deinit(self.allocator);
        for (pending.items) |player| {
            var event = Events.types.PlayerDisconnectEvent{ .player = player };
            _ = self.events.emit(.PlayerDisconnect, &event);
            self.instances.leave(player.entity.runtime_id);
            player.finalizeRemoval();
        }
    }

    pub fn flushMovementBroadcasts(self: *Tecton) void {
        movement_mod.flush(self);
    }

    pub fn runVisibilityPass(self: *Tecton) void {
        const snapshots = self.getPlayerSnapshots();
        self.visibility_batch.clearRetainingCapacity();
        for (snapshots) |player| {
            if (!player.visibility_due) continue;
            player.visibility_due = false;
            self.visibility_batch.append(self.allocator, player) catch {};
        }

        const due = self.visibility_batch.items;
        if (due.len == 0) return;

        const parallel = self.config.parallel_visibility and self.threaded_tasks.worldWorkerCount() > 1;
        if (!parallel) {
            for (due) |player| visibility_mod.updatePlayerVisibility(player);
            return;
        }

        self.visibility_job.item_count = due.len;
        self.visibility_job.ctx = self;
        self.visibility_job.body = struct {
            fn run(index: usize, ctx: *anyopaque) void {
                const tecton: *Tecton = @ptrCast(@alignCast(ctx));
                visibility_mod.updatePlayerVisibility(tecton.visibility_batch.items[index]);
            }
        }.run;
        self.threaded_tasks.runParallel(&self.visibility_job, self.threaded_tasks.worldWorkerCount());
    }

    pub fn rebuildPlayerSnapshot(self: *Tecton) void {
        self.players.rebuild();
    }

    pub fn findPlayerByRuntimeId(self: *Tecton, runtime_id: i64) ?*Player {
        return self.players.byRuntimeId(runtime_id);
    }

    pub fn getPlayerSnapshots(self: *Tecton) []const *Player {
        return self.players.list();
    }

    pub fn getPlayerCount(self: *const Tecton) usize {
        return self.players.count();
    }

    pub fn registerEcsEntity(self: *Tecton, entity: *Entity) void {
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

    pub fn unregisterEcsEntity(self: *Tecton, entity: *Entity) void {
        if (entity.ecs_id == 0) return;
        _ = self.ecs.destroy(@bitCast(entity.ecs_id));
        entity.ecs_id = 0;
    }

    pub fn syncEcsEntity(self: *Tecton, entity: *Entity) void {
        if (entity.ecs_id == 0) return;
        self.ecs.updateTransform(@bitCast(entity.ecs_id), entity.position, entity.rotation, entity.motion);
    }

    pub fn targetTps(self: *const Tecton) f64 {
        return @as(f64, @floatFromInt(@max(@as(u32, 1), self.config.max_tps)));
    }

    pub fn setMovementSendPriority(self: *Tecton, priority: SendPriority) void {
        self.movement_priority = priority;
    }

    pub fn movementSendPriority(self: *const Tecton) SendPriority {
        return self.movement_priority;
    }

    pub fn rollMetricsWindow(self: *Tecton, metrics_window_ticks: u64) void {
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

    pub fn setPlayerLocation(self: *Tecton, uuid: []const u8, world_identifier: []const u8, dimension_identifier: []const u8) void {
        self.player_locations.set(uuid, world_identifier, dimension_identifier);
        self.player_locations.flush();
    }

    pub fn resolvePlayerLocation(self: *Tecton, uuid: []const u8) ?*const PlayerLocation {
        return self.player_locations.getPtr(uuid);
    }

    pub fn broadcastAvailableCommands(self: *Tecton) void {
        const snapshots = self.getPlayerSnapshots();
        for (snapshots) |player| {
            if (!player.spawned) continue;
            var stream = BinaryStream.init(self.allocator, null, null);
            defer stream.deinit();
            const serialized = self.command_registry.buildAvailableCommandsPacket(&stream) catch continue;
            self.network.sendPacket(player.connection, serialized) catch {};
        }
    }

    pub fn refreshWorldCommandEnums(self: *Tecton) void {
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

    pub fn refreshFloatingTextCommandEnums(self: *Tecton) void {
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

    pub fn beginSavePass(self: *Tecton) void {
        self.save.begin(self.allocator, &self.worlds);
    }

    pub fn tickIncrementalSave(self: *Tecton) void {
        self.save.tick(self.io, self.allocator, &self.worlds, self.getPlayerSnapshots());
    }

    pub fn saveAllWorlds(self: *Tecton) void {
        var worlds_it = self.worlds.valueIterator();
        while (worlds_it.next()) |world| {
            world.*.save();
        }

        const snapshots = self.getPlayerSnapshots();
        for (snapshots) |player| {
            player.savePlayerData();
        }
    }

    fn stopRaknetTickThread(self: *Tecton) void {
        self.raknet.running.store(false, .release);
        if (self.raknet.tick_thread) |*tick_thread| {
            _ = tick_thread.cancel(self.io);
            self.raknet.tick_thread = null;
        }
    }

    pub fn deinit(self: *Tecton) void {
        self.stopRaknetTickThread();

        if (self.network_initialized) self.network.stopInputPump();

        self.profiler.writeReport(self.io, "dump/tick-profile.txt");

        self.threaded_tasks.stop();
        self.threaded_tasks.drainCompleted(std.math.maxInt(u64));
        self.drainPendingPlayerRemovals();
        self.saveAllWorlds();
        self.save.deinit(self.allocator);
        self.threaded_tasks.deinit();
        self.shutting_down = true;

        self.players.silence();
        self.players.destroyPlayers();
        self.players.deinit();
        self.visibility_batch.deinit(self.allocator);
        self.plugin_runtime.deinit();

        self.worlds.deinit();

        self.raknet.deinit();

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
        self.worlds.deinitOps();
        self.command_registry.deinit();
        self.ban_manager.deinit();
        self.permission_manager.deinit();
        self.player_locations.flush();
        self.player_locations.deinit();
        if (self.auth_service) |*service| service.deinit();
    }
};

const test_owner = @This();
const test_scope = struct {
    pub const test_dependency_0 = @import("./command/list/enchant.zig");
    pub const test_dependency_1 = @import("./command/list/floating_text.zig");
    pub const test_dependency_2 = @import("./command/list/summon.zig");
    pub const test_dependency_3 = @import("./command/list/world.zig");
    pub const test_dependency_4 = @import("./entity/traits/chunk_loading.zig");
    pub const test_dependency_5 = @import("./entity/traits/fire.zig");
    pub const test_dependency_6 = @import("./items/enchantments/compat.zig");
    pub const test_dependency_7 = @import("./items/enchantments/effects.zig");
    pub const test_dependency_8 = @import("./items/enchantments/nbt.zig");
    pub const test_dependency_9 = @import("./items/enchantments/ops.zig");
    pub const test_dependency_10 = @import("./items/enchantments/registry.zig");
    pub const test_dependency_11 = @import("./items/enchantments/rules.zig");
    pub const test_dependency_12 = @import("./items/enchantments/set.zig");
    pub const test_dependency_13 = @import("./items/enchantments/storage.zig");
    pub const test_dependency_15 = @import("./network/handlers/player_hotbar.zig");
    pub const test_dependency_16 = @import("./network/movement_broadcast.zig");
    pub const test_dependency_17 = @import("./player/move_delta.zig");
    pub const test_dependency_18 = @import("./player/player_snapshot.zig");
    pub const test_dependency_19 = @import("./world/provider/chunk_entities.zig");
    pub const test_dependency_20 = @import("./world/provider/leveldb_provider.zig");
    pub const std = test_owner.std;
    pub const ServerProperties = test_owner.ServerProperties;
    pub const Tecton = test_owner.Tecton;
};

test "the RakNet MTU cap is the clamped config value, never a literal" {
    try @import("tecton_test.zig").Suite(test_scope).case_000();
}

test "the movement flush sends with the configured priority, never a literal" {
    try @import("tecton_test.zig").Suite(test_scope).case_001();
}

test "onTick broadcasts movement and no path skips the flush" {
    try @import("tecton_test.zig").Suite(test_scope).case_002();
}

test "the player snapshot goes quiet before the players are freed" {
    try @import("tecton_test.zig").Suite(test_scope).case_003();
}

test {
    try @import("tecton_test.zig").Suite(test_scope).case_004();
}
