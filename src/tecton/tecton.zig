const std = @import("std");
const log = @import("core/log.zig");
const Timestamp = std.Io.Timestamp;

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

const connection_mod = @import("./transport/connection.zig");
const Connection = connection_mod.Connection;
const events_mod = @import("./transport/events.zig");
const port_mod = @import("./transport/port.zig");

/// Longest a shutdown waits for queued disconnects to leave the transport.
const shutdown_flush_ms: i64 = 500;
const NetherNetAdapter = @import("./transport/nethernet.zig").Adapter;
const tls_front_mod = @import("./server/tls_front.zig");

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
const NetworkHandler = @import("./network/root.zig").NetworkHandler;
const SendPriority = @import("./network/root.zig").SendPriority;
const PlayerLog = @import("./network/player_log.zig");
const PermissionManager = @import("./player/permission_manager.zig").PermissionManager;
const PlayerLocations = @import("./player/player_locations.zig").PlayerLocations;
const PlayerLocation = @import("./player/player_locations.zig").Location;
const PlayerSnapshot = @import("./player/player_snapshot.zig").PlayerSnapshot;
const player_mod = @import("./player/player.zig");
const Player = player_mod.Player;
const ShutdownSignal = @import("./server/shutdown_signal.zig");
const TaskQueue = @import("./tasks/tasks.zig").TaskQueue;
const threaded_tasks = @import("./tasks/threaded_tasks.zig");
const ThreadedTaskQueue = threaded_tasks.ThreadedTaskQueue;
const WorkerCountResolution = @import("./tasks/threaded_tasks.zig").WorkerCountResolution;
const visibility_mod = @import("./entity/traits/visibility.zig");
const resolveWorkerCount = @import("./tasks/threaded_tasks.zig").resolveWorkerCount;
const totalServerThreadCount = @import("./tasks/threaded_tasks.zig").totalServerThreadCount;
const TickProfiler = @import("./core/tick_profiler.zig").TickProfiler;
const pool_allocator = @import("./core/pool_allocator.zig");
const alloc_counter = @import("./core/alloc_counter.zig");
pub const block_root = @import("./world/block/root.zig");
const deinitRegistries = @import("./world/block/root.zig").deinitRegistries;
const EcsWorld = @import("entity/ecs.zig").EcsWorld;
const Events = @import("events/root.zig");
const PluginRuntime = @import("plugins/runtime.zig").PluginRuntime;
const GameInstanceRegistry = @import("world/game_instance.zig").GameInstanceRegistry;
const players_mod = @import("server/players.zig");
const PlayerRegistry = players_mod.PlayerRegistry;
const options_mod = @import("server/options.zig");
const SaveScheduler = @import("server/save.zig").SaveScheduler;
const tick_mod = @import("server/tick.zig");
const tick_loop = @import("server/tick_loop.zig");
const movement_mod = @import("server/movement.zig");
const worlds_mod = @import("server/worlds.zig");

pub const ServerPaths = options_mod.ServerPaths;
pub const CommandPermissionChecker = options_mod.CommandPermissionChecker;

pub const Composition = struct {
    prepare: *const fn (*Tecton) anyerror!void,
    dispatch: *const fn (*anyopaque, *Connection, []const []const u8) void,
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
    nethernet: ?*NetherNetAdapter = null,
    tls_front: ?*tls_front_mod.Front = null,
    transport_clock: ?tick_loop.Clock = null,
    transport_events: std.ArrayList(events_mod.Event) = .empty,
    reconcile_batch: std.ArrayList(*Player) = .empty,
    game_clock: ?tick_loop.Clock = null,
    running: std.atomic.Value(bool) = .init(false),
    shutdown_event: std.Io.Event = .unset,
    network: *NetworkHandler,
    network_initialized: bool = false,
    address_stamp: usize = 0,
    players: PlayerRegistry,
    movement_priority: SendPriority = .immediate,
    movement_channel: port_mod.Channel = .reliable,
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
    last_dropped_packets: usize = 0,
    counting_allocations: bool = false,
    last_tick_allocations: std.atomic.Value(usize) = .init(0),
    peak_tick_allocations: std.atomic.Value(usize) = .init(0),
    work_time_accumulator: u64 = 0,
    /// Written by the transport clock thread and reset by the game tick.
    network_io_accumulator: std.atomic.Value(u64) = .init(0),
    network_io_samples: std.atomic.Value(u64) = .init(0),
    network_dispatch_accumulator: u64 = 0,
    tick_interval_accumulator: u64 = 0,
    tick_interval_samples: u64 = 0,
    tasks_time_accumulator: u64 = 0,
    current_tps: f64 = 20.0,
    current_mspt: f64 = 0.0,
    current_network_io_mspt: f64 = 0.0,
    current_network_dispatch_mspt: f64 = 0.0,
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
        const base_allocator = options.allocator;
        var owned_config = options.properties orelse try ServerProperties.load(io, base_allocator, "server.properties");
        errdefer owned_config.deinit();

        const counting_allocations = owned_config.count_allocations and alloc_counter.install(base_allocator);
        if (owned_config.count_allocations and !counting_allocations) {
            log.warn("count-allocations is already bound to another allocator in this process; the tick allocation count stays off", .{});
        }
        const allocator = if (counting_allocations) counted: {
            log.info("Allocation accounting enabled: counting allocator calls made by the tick thread", .{});
            break :counted alloc_counter.allocator();
        } else base_allocator;

        var auth_service: ?AuthService = null;
        errdefer if (auth_service) |*service| service.deinit();
        if (owned_config.online_mode) {
            auth_service = AuthService.init(io, allocator, .{}) catch |err| {
                log.err(
                    "Online mode: cannot reach the authorization service ({s}), refusing to start",
                    .{@errorName(err)},
                );
                return error.OnlineModeUnavailable;
            };
            log.info("Online mode enabled", .{});
        } else {
            log.info("Online mode disabled", .{});
        }
        if ((!owned_config.online_mode or owned_config.online_mode_offline_fallback) and
            std.mem.eql(u8, owned_config.default_group, "operator"))
        {
            log.warn("default-group=operator without verified identities: any client becomes an operator by claiming an operator name", .{});
        }

        const transport_tick_ms = ServerProperties.clampTransportTickMs(owned_config.transport_tick_ms);
        if (transport_tick_ms != owned_config.transport_tick_ms) {
            log.warn("transport-tick-ms={d} is outside the supported range {d}-{d}, using {d}", .{
                owned_config.transport_tick_ms,
                ServerProperties.min_transport_tick_ms,
                ServerProperties.max_transport_tick_ms,
                transport_tick_ms,
            });
        }
        if (owned_config.tlsProblem()) |problem| {
            switch (problem) {
                .missing_certificate => log.err(
                    "tls-mode=native needs tls-cert pointing at a PEM certificate chain",
                    .{},
                ),
                .missing_key => log.err(
                    "tls-mode=native needs tls-key pointing at the PEM private key",
                    .{},
                ),
                .plain_listener_exposed => log.err(
                    "tls-mode={s} requires a loopback signaling listener; set signaling-bind=127.0.0.1 (or ::1) instead of {s}",
                    .{ @tagName(owned_config.tls_mode), owned_config.plainSignalingHost() },
                ),
                .zero_port => log.err(
                    "tls-mode=native needs a real port: 0 would bind an ephemeral public port clients cannot guess",
                    .{},
                ),
            }
            return error.TlsMisconfigured;
        }
        const movement_priority = SendPriority.parse(owned_config.movement_send_priority) orelse fallback: {
            log.warn("movement-send-priority={s} is not a known priority, using immediate", .{owned_config.movement_send_priority});
            break :fallback SendPriority.immediate;
        };
        const movement_channel = port_mod.Channel.parse(owned_config.movement_channel) orelse fallback: {
            log.warn("movement-channel={s} is not a known channel, using reliable", .{owned_config.movement_channel});
            break :fallback port_mod.Channel.reliable;
        };
        const mob_broadcast_interval = ServerProperties.clampMobBroadcastInterval(owned_config.mob_broadcast_interval);
        if (mob_broadcast_interval != owned_config.mob_broadcast_interval) {
            log.warn("mob-broadcast-interval={d} is outside the supported range {d}-{d}, using {d}", .{
                owned_config.mob_broadcast_interval,
                ServerProperties.min_mob_broadcast_interval,
                ServerProperties.max_mob_broadcast_interval,
                mob_broadcast_interval,
            });
        }

        if (owned_config.max_view_distance > ServerProperties.max_view_distance_limit) {
            log.warn("max-view-distance={d} exceeds the supported ceiling {d}: client requests are clamped to {d}", .{
                owned_config.max_view_distance,
                ServerProperties.max_view_distance_limit,
                ServerProperties.max_view_distance_limit,
            });
        }

        const ecs_capacity = @max(@as(usize, 64), @as(usize, owned_config.ecs_capacity));
        var ecs = try EcsWorld.init(allocator, ecs_capacity);
        errdefer ecs.deinit();
        return Tecton{
            .io = io,
            .allocator = allocator,
            .counting_allocations = counting_allocations,
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
            .movement_channel = movement_channel,
            .movement_distance_bands = owned_config.movement_distance_bands,
            .mob_broadcast_interval = mob_broadcast_interval,
            .events = Events.Events.init(allocator),
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
            .current_network_io_mspt = 0.0,
            .current_network_dispatch_mspt = 0.0,
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

    pub fn isCountingAllocations(self: *const Tecton) bool {
        return self.counting_allocations;
    }

    pub fn lastTickAllocations(self: *const Tecton) usize {
        return self.last_tick_allocations.load(.acquire);
    }

    pub fn peakTickAllocations(self: *const Tecton) usize {
        return self.peak_tick_allocations.load(.acquire);
    }

    pub fn recordTickAllocations(self: *Tecton, allocations: usize) void {
        self.last_tick_allocations.store(allocations, .release);
        var peak = self.peak_tick_allocations.load(.monotonic);
        while (allocations > peak) {
            peak = self.peak_tick_allocations.cmpxchgWeak(peak, allocations, .acq_rel, .monotonic) orelse break;
        }
    }

    pub fn resetTickAllocationPeak(self: *Tecton) void {
        self.peak_tick_allocations.store(0, .release);
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
        ShutdownSignal.install();

        self.fixAddress();
        self.network = try NetworkHandler.init(self.io, self.allocator, &self.threaded_tasks, .{
            .ctx = self,
            .dispatch = self.composition.dispatch,
        });
        self.network_initialized = true;
        try self.attachNetherNetPort();
        try self.attachTlsFront();
        try self.prepare();
        self.tick_thread_id.store(0, .release);
        const worker_resolution: WorkerCountResolution = resolveWorkerCount(self.config.worker_threads);
        self.threaded_tasks.setLayout(self.config.worker_layout);
        try self.threaded_tasks.start();
        if (!worker_resolution.auto_selected and worker_resolution.resolved_count < worker_resolution.requested_count) {
            log.warn(
                "Configured worker-threads={d} exceeds recommended max for {d} CPUs, clamping to {d}",
                .{
                    worker_resolution.requested_count,
                    worker_resolution.cpu_count,
                    worker_resolution.resolved_count,
                },
            );
        }
        log.info("NetherNet: signaling on {s}:{d}, {d} sessions, {d} ms transport tick", .{
            if (self.config.signaling_bind.len > 0) self.config.signaling_bind else self.config.address,
            if (self.nethernet) |adapter| adapter.signalingPort() else self.config.port,
            self.config.effectiveMaxSessions(),
            ServerProperties.clampTransportTickMs(self.config.transport_tick_ms),
        });
        if (self.config.lan_discovery) {
            log.info("LAN discovery: UDP {d}", .{self.config.lan_port});
        } else {
            log.info("LAN discovery: disabled", .{});
        }
        switch (self.config.tls_mode) {
            .off => log.info("Signaling TLS: off (plain HTTP; clients prompt before trusting it)", .{}),
            .proxy => log.info("Signaling TLS: terminated by a proxy in front of the listener", .{}),
            .native => log.info("Signaling TLS: native on {s}:{d} (TLS and plain HTTP in one port), loopback listener on {s}:{d}", .{
                self.config.address,
                self.config.port,
                self.config.plainSignalingHost(),
                if (self.nethernet) |adapter| adapter.signalingPort() else 0,
            }),
        }
        if (self.config.lan_discovery and self.config.lan_port == self.config.motdPort()) {
            log.warn("lan-port and motd-port share {d}: LAN discovery and the MOTD listener both need UDP, so one of them will not bind", .{self.config.motdPort()});
        }
        log.info("Mob broadcast interval: {d} ticks", .{self.mob_broadcast_interval});
        if (self.config.parallel_visibility and self.threaded_tasks.worldWorkerCount() > 1) {
            log.info("Visibility pass: {d} world workers (parallel-visibility=true)", .{
                self.threaded_tasks.worldWorkerCount(),
            });
        } else {
            log.info("Visibility pass: inline on the tick thread (parallel-visibility=false)", .{});
        }
        const pump_threads: usize = if (self.threaded_tasks.layoutResolution().layout == .split) 1 else 0;
        log.info("Loaded {d} threads, {d} worker threads available", .{
            totalServerThreadCount(self.threaded_tasks.workerCount()) + pump_threads,
            self.threaded_tasks.workerCount(),
        });
        const pool_layout = self.threaded_tasks.layoutResolution();
        if (pool_layout.layout == .split) {
            log.info("Worker pool: split layout, {d} input + {d} world workers ({d} CPUs)", .{
                pool_layout.input_worker_count,
                pool_layout.world_worker_count,
                pool_layout.cpu_count,
            });
        } else {
            log.info("Worker pool: shared layout, {d} workers ({d} CPUs)", .{
                pool_layout.worker_count,
                pool_layout.cpu_count,
            });
        }
        if (self.config.network_inbound_ring) {
            self.network.enableInboundRing(
                ServerProperties.clampInboundRingSlots(self.config.inbound_ring_slots),
                ServerProperties.clampInboundRingSlotSize(self.config.inbound_ring_slot_size),
            ) catch |err| {
                log.warn("network-inbound-ring could not be enabled ({s}); using the legacy packet queue", .{@errorName(err)});
            };
        }
        if (self.network.inbound_ring) |ring| {
            const buffer_mib = (ring.capacity() * ring.slot_size) / (1024 * 1024);
            log.info("Inbound ring: {d} slots x {d} bytes ({d} MiB buffer)", .{
                ring.capacity(),
                ring.slot_size,
                buffer_mib,
            });
        } else {
            log.info("Inbound ring disabled; using the legacy packet queue", .{});
        }

        if (self.threaded_tasks.layoutResolution().layout == .split) {
            try self.network.startInputPump();
            log.info("Input pump: dedicated thread draining the input queue", .{});
        } else {
            log.info("Input pump: disabled (shared layout drains input from the tick)", .{});
        }

        var event = Events.types.ServerStartEvent{};
        _ = self.events.emit(Events.Event.ServerStart, &event);

        if (self.nethernet) |adapter| {
            try adapter.start();
            if (self.tls_front) |front| {
                front.start() catch |err| {
                    adapter.stop();
                    return err;
                };
            }
            self.transport_clock = tick_loop.Clock.init(
                self.io,
                @as(u64, ServerProperties.clampTransportTickMs(self.config.transport_tick_ms)) * std.time.ns_per_ms,
                netherNetTick,
                self,
            );
            if (self.transport_clock) |*clock| try clock.start();
        }
        self.running.store(true, .release);
        self.shutdown_event.reset();
        self.game_clock = tick_loop.Clock.init(self.io, std.time.ns_per_s / @max(1, @as(u64, self.config.max_tps)), tick_mod.onTick, self);
        if (self.game_clock) |*clock| try clock.start();
        self.plugin_runtime.setServerState(1);

        if (self.enable_console) {
            try self.console.start(self);
            self.console_started = true;
        }
        self.started = true;
        if (self.start_callback) |callback| callback(self.lifecycle_userdata);
    }

    fn attachNetherNetPort(self: *Tecton) !void {
        const adapter = try NetherNetAdapter.init(self.io, self.allocator, .{
            .address = self.config.address,
            .port = self.config.port,
            .signaling_port = if (self.config.tls_mode == .native) 0 else null,
            .motd_port = self.config.motd_port,
            .motd = self.config.motd,
            .level_name = self.config.level_name,
            .gamemode = self.config.gameMode(),
            .max_players = self.config.max_players,
            .online_mode = self.config.online_mode,
            .jwks_uri = self.config.jwks_uri,
            .identity_key = self.config.identity_key,
            .require_client_identity = self.config.clientIdentityRequired(),
            .lan_discovery = self.config.lan_discovery,
            .lan_port = self.config.lan_port,
            .signaling_bind = self.config.signaling_bind,
            .public_candidate = self.config.public_candidate,
            .ice_servers = self.config.ice_servers,
            .max_sessions = self.config.effectiveMaxSessions(),
            .max_message_size = ServerProperties.clampMaxMessageSize(self.config.max_message_size),
            .transport_tick_ms = ServerProperties.clampTransportTickMs(self.config.transport_tick_ms),
        }, .{
            .registry = &self.network.connections,
            .events = &self.network.events,
            .publish = .{ .ctx = self.network, .packet = NetworkHandler.onPacket },
            .players = .{ .ctx = self, .count = countOnlinePlayers },
        });
        errdefer adapter.deinit();

        // Every frame is compressed into a pool slot, so the slot must hold the largest
        // message the session negotiates.
        const send_slots = @max(@as(usize, 8), @min(@as(usize, 32), @as(usize, self.config.worker_threads) + 2));
        try self.network.configureSendBuffers(ServerProperties.clampMaxMessageSize(self.config.max_message_size), send_slots);
        self.nethernet = adapter;
        self.network.attachPort(adapter.port());
    }

    fn attachTlsFront(self: *Tecton) !void {
        if (self.config.tls_mode != .native) return;
        const adapter = self.nethernet orelse return error.TransportUnavailable;
        const bind = std.Io.net.IpAddress.parse(self.config.address, self.config.port) catch {
            log.err("port={d} cannot be served on address={s}: not an IP address", .{ self.config.port, self.config.address });
            return error.InvalidAddress;
        };
        const backend = std.Io.net.IpAddress.parse(self.config.plainSignalingHost(), adapter.signalingPort()) catch {
            log.err("tls-mode=native needs signaling-bind to be an IP literal, not {s}", .{self.config.plainSignalingHost()});
            return error.InvalidAddress;
        };
        self.tls_front = try tls_front_mod.Front.init(self.io, self.allocator, .{
            .bind = bind,
            .backend = backend,
            .cert_path = self.config.tls_cert,
            .key_path = self.config.tls_key,
            // One thread per TLS session; cap it even when max-sessions is higher.
            .max_connections = @min(self.config.effectiveMaxSessions(), 256),
        });
    }

    fn netherNetTick(context: ?*anyopaque) void {
        const self: *Tecton = @ptrCast(@alignCast(context.?));
        const started = Timestamp.now(self.io, .awake);
        if (self.nethernet) |adapter| adapter.tick();
        const elapsed = started.durationTo(Timestamp.now(self.io, .awake)).nanoseconds;
        const ns: u64 = @intCast(@max(0, elapsed));
        _ = self.network_io_accumulator.fetchAdd(ns, .monotonic);
        _ = self.network_io_samples.fetchAdd(1, .monotonic);
        self.profiler.record(.net_io, ns);
    }

    fn countOnlinePlayers(context: *anyopaque) usize {
        const self: *Tecton = @ptrCast(@alignCast(context));
        return self.players.count();
    }

    pub fn run(self: *Tecton) !void {
        while (self.running.load(.acquire)) {
            if (ShutdownSignal.isShutdownRequested()) {
                self.stop() catch {};
                return;
            }
            self.shutdown_event.waitTimeout(self.io, .{
                .duration = .{ .raw = .fromNanoseconds(std.time.ns_per_s / 20), .clock = .awake },
            }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
        }
    }

    pub fn stop(self: *Tecton) !void {
        if (self.stopped) return;
        self.running.store(false, .release);
        if (self.game_clock) |*clock| clock.stop();
        defer {
            self.stopped = true;
            self.started = false;
            self.shutdown_event.set(self.io);
            if (self.shutdown_callback) |callback| callback(self.lifecycle_userdata);
        }
        self.plugin_runtime.setServerState(2);
        var event = Events.types.ServerShutdownEvent{};
        _ = self.events.emit(.ServerShutdown, &event);

        // Include a player that logged in after this tick's snapshot, then copy: closing a
        // player republishes the snapshot this loop would otherwise walk.
        self.players.rebuild();
        const closing = try self.allocator.dupe(*Player, self.players.list());
        defer self.allocator.free(closing);
        for (closing) |player| {
            self.closePlayer(player, .flush, .{ .message = "Server shutdown." });
        }

        // Stop TLS first: no new signaling connection may reach a transport that is going away.
        if (self.tls_front) |front| front.stop();
        self.shutdownTransport();
    }

    /// Server-initiated close; runs only on the game tick. The player is freed later,
    /// in `drainPendingPlayerRemovals`, once the transport has flushed.
    pub fn closePlayer(self: *Tecton, player: *Player, mode: port_mod.CloseMode, reason: player_mod.CloseReason) void {
        if (self.stopped) return;
        player.close(mode, reason);
    }

    /// Stops the transport last: the disconnects above only leave while it still ticks.
    fn shutdownTransport(self: *Tecton) void {
        const adapter = self.nethernet orelse return;
        if (self.transport_clock) |*clock| clock.stop();

        // The clock is stopped, so this thread is the only one ticking and a peer that never
        // drains cannot hold the process open past the deadline.
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{
            .clock = .awake,
            .raw = .fromMilliseconds(shutdown_flush_ms),
        });
        while (adapter.sessionCount() > 0 and std.Io.Clock.Timestamp.now(self.io, .awake).compare(.lt, deadline)) {
            adapter.tick();
            self.io.sleep(.fromMilliseconds(2), .awake) catch break;
        }
        if (adapter.sessionCount() > 0) {
            log.warn("Shutdown deadline reached with {d} transport sessions still open", .{adapter.sessionCount()});
        }
        adapter.stop();
    }

    pub fn shutdown(self: *Tecton) !void {
        try self.stop();
    }

    pub fn getPlayerByConnection(self: *Tecton, connection: *Connection) ?*Player {
        return self.players.byConnection(connection);
    }

    /// Consumes what transport callbacks published: the tick is the only place that touches a player.
    pub fn drainTransportEvents(self: *Tecton) void {
        self.network.drainEvents(&self.transport_events);
        for (self.transport_events.items) |event| switch (event) {
            // A session becomes a player only when its login packet arrives.
            .opened => {},
            .closed => |id| {
                const player = self.players.byConnectionId(id) orelse continue;
                PlayerLog.logDisconnect(player.username);
                player.disconnectFromNetwork();
            },
        };
    }

    /// A `closed` event can be dropped; the transport state is the backstop. The batch is reused
    /// because closing a player republishes the snapshot the registry would otherwise hand out.
    pub fn reconcileClosedConnections(self: *Tecton) void {
        self.reconcile_batch.clearRetainingCapacity();
        self.reconcile_batch.appendSlice(self.allocator, self.players.list()) catch |err| {
            log.warn("Could not reconcile closed connections this tick: {s}", .{@errorName(err)});
            return;
        };
        _ = players_mod.reconcileClosedConnections(self.reconcile_batch.items);
    }

    pub fn addPlayer(self: *Tecton, player: *Player) !void {
        try self.players.insert(player);
    }

    pub fn removePlayer(self: *Tecton, player: *Player) void {
        self.players.remove(player);
    }

    pub fn removeConnectionMapping(self: *Tecton, connection: *Connection) void {
        self.players.removeConnection(connection);
    }

    pub fn enqueuePlayerRemoval(self: *Tecton, player: *Player) void {
        self.players.enqueueRemoval(player);
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
        ) catch |err| {
            log.warn("ECS registration failed: {s}", .{@errorName(err)});
            return;
        };
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

    pub fn movementSendChannel(self: *const Tecton) port_mod.Channel {
        return self.movement_channel;
    }

    pub fn rollMetricsWindow(self: *Tecton, metrics_window_ticks: u64) void {
        const avg_work_ns = self.work_time_accumulator / metrics_window_ticks;
        const net_dispatch_ns = self.network_dispatch_accumulator / metrics_window_ticks;
        const net_io_samples = self.network_io_samples.swap(0, .monotonic);
        const net_io_total_ns = self.network_io_accumulator.swap(0, .monotonic);
        const avg_net_io_ns = if (net_io_samples > 0) net_io_total_ns / net_io_samples else 0;
        const avg_interval_ns = if (self.tick_interval_samples > 0)
            self.tick_interval_accumulator / self.tick_interval_samples
        else
            0;
        self.work_time_accumulator = 0;
        self.network_dispatch_accumulator = 0;
        self.tasks_time_accumulator = 0;

        self.current_game_mspt = @as(f64, @floatFromInt(avg_work_ns)) / 1_000_000.0;
        self.current_network_io_mspt = @as(f64, @floatFromInt(avg_net_io_ns)) / 1_000_000.0;
        self.current_network_dispatch_mspt = @as(f64, @floatFromInt(net_dispatch_ns)) / 1_000_000.0;
        self.current_mspt = @as(f64, @floatFromInt(avg_work_ns)) / 1_000_000.0;

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

    pub fn deinit(self: *Tecton) void {
        if (!self.stopped and self.started) {
            self.stop() catch |err| log.err("Shutdown before deinit failed: {s}", .{@errorName(err)});
        }
        self.running.store(false, .release);
        if (self.game_clock) |*clock| clock.stop();

        if (self.network_initialized) self.network.stopInputPump();

        self.profiler.writeReport(self.io, "dump/tick-profile.txt");

        self.threaded_tasks.stop();
        self.threaded_tasks.drainCompleted(std.math.maxInt(u64));
        self.drainPendingPlayerRemovals();
        self.saveAllWorlds();
        self.save.deinit(self.allocator);
        self.threaded_tasks.deinit();
        self.shutting_down = true;

        log.info("Allocator: {d} KiB mapped in {d} pool chunks, {d} contention spins", .{
            pool_allocator.mappedBytes() / 1024,
            pool_allocator.poolChunks(),
            pool_allocator.contentionSpins(),
        });
        var pool_class: usize = 0;
        while (pool_class < pool_allocator.class_total) : (pool_class += 1) {
            const stats = pool_allocator.classStats(pool_class);
            if (stats.chunks == 0) continue;
            log.info("Pool class {d} B: {d} KiB mapped, {d} chunks, {d} live slots", .{
                stats.slot,
                stats.mapped_bytes / 1024,
                stats.chunks,
                stats.live,
            });
        }

        if (self.transport_clock) |*clock| clock.stop();
        if (self.tls_front) |front| {
            front.deinit();
            self.tls_front = null;
        }
        if (self.nethernet) |adapter| {
            adapter.deinit();
            self.nethernet = null;
        }

        self.transport_events.deinit(self.allocator);
        self.reconcile_batch.deinit(self.allocator);

        self.players.silence();
        self.players.destroyPlayers();
        self.players.deinit();
        self.visibility_batch.deinit(self.allocator);
        self.plugin_runtime.deinit();

        self.worlds.deinit();

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
    pub const Protocol = test_owner.Protocol;
    pub const NetherNet = @import("./transport/nethernet.zig");
    pub const ServerProperties = test_owner.ServerProperties;
    pub const Tecton = test_owner.Tecton;
};

test "the advertisement carries Tecton's protocol and the clamped message cap" {
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

test "world info reports net I/O and net dispatch, never RakNet" {
    try @import("tecton_test.zig").Suite(test_scope).case_005();
}
