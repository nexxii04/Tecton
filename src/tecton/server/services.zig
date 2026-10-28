const std = @import("std");
const Protocol = @import("protocol");
const Connection = @import("../transport/connection.zig").Connection;

const contracts = @import("../core/contracts.zig");
const CommandContext = @import("../command/context.zig").CommandContext;
const tecton_mod = @import("../tecton.zig");
const Tecton = tecton_mod.Tecton;
const Entity = @import("../entity/entity.zig").Entity;
const EcsWorld = @import("../entity/ecs.zig").EcsWorld;
const events_mod = @import("../events/root.zig");
const NetworkHandler = @import("../transport/network_handler.zig").NetworkHandler;
const Player = @import("../player/player.zig").Player;
const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const World = @import("../world/world.zig").World;
const worlds = @import("./worlds.zig");
const WorldLifecycle = @import("../world/world_lifecycle.zig");
const players = @import("host_players.zig");
const perms = @import("host_perms.zig");
const worldAdapters = @import("host_worlds.zig").Suite(Tecton, World);
const lifecycle = @import("host_shutdown.zig").Suite(Tecton, Entity, Dimension);

pub const Host = contracts.ServerHost(Player, Entity, events_mod.Events, Dimension, World, EcsWorld, NetworkHandler);

pub const HostError = error{ NetworkNotInitialized, TectonMoved };

pub fn host(tecton: *Tecton) Host {
    return hostChecked(tecton) catch |err| std.debug.panic("services.host() invariant violated: {s}", .{@errorName(err)});
}

pub fn hostChecked(tecton: *Tecton) HostError!Host {
    if (!tecton.network_initialized) return error.NetworkNotInitialized;
    if (tecton.address_stamp != @intFromPtr(tecton)) return error.TectonMoved;
    return .{
        .ctx = tecton,
        .io = tecton.io,
        .allocator = tecton.allocator,
        .config = &tecton.config,
        .network = tecton.network,
        .events = &tecton.events,
        .ecs = &tecton.ecs,
        .tasks = &tecton.tasks,
        .threaded_tasks = &tecton.threaded_tasks,
        .profiler = &tecton.profiler,
        .players = .{ .ctx = tecton, .by_runtime_id = players.byRuntimeId },
        .instances = .{ .ctx = tecton, .assign_dimension = lifecycle.assignDimension },
        .permission_manager = .{ .ctx = tecton, .get_player_group = perms.getPlayerGroup },
        .worlds = .{ .ctx = tecton, .build_world = buildWorld, .adopt_world = worldAdapters.adoptWorld, .destroy_world = worldAdapters.destroyWorld, .end_op = worldAdapters.endOp },
        .mob_broadcast_interval = tecton.mob_broadcast_interval,
        .get_player_snapshots = players.getPlayerSnapshots,
        .get_player_count = players.getPlayerCount,
        .find_player_by_runtime_id = players.findPlayerByRuntimeId,
        .register_ecs_entity = lifecycle.registerEcsEntity,
        .unregister_ecs_entity = lifecycle.unregisterEcsEntity,
        .set_player_location = players.setPlayerLocation,
        .enqueue_player_removal = players.enqueuePlayerRemoval,
        .remove_player = players.removePlayer,
        .remove_connection_mapping = players.removeConnectionMapping,
        .target_tps = players.targetTps,
        .current_tps = players.currentTps,
        .current_mspt = players.currentMspt,
        .tick_count = players.tickCount,
        .refresh_world_command_enums = lifecycle.refreshWorldCommandEnums,
        .refresh_floating_text_command_enums = lifecycle.refreshFloatingTextCommandEnums,
        .reply_to = replyTo,
    };
}

pub fn commandViews(tecton: *Tecton) @import("../command/context.zig").CommandViews {
    if (!tecton.network_initialized or tecton.address_stamp != @intFromPtr(tecton)) {
        std.debug.panic("command views require an initialized Tecton at its fixed address", .{});
    }

    const selection: contracts.SelectionHost(Player) = .{
        .ctx = tecton,
        .io = tecton.io,
        .get_player_snapshots = players.getPlayerSnapshots,
    };
    const query: contracts.WorldQuery(World) = .{ .registry = &tecton.worlds.by_name };

    return .{
        .selection = selection,
        .permissions = .{ .ctx = tecton, .has_permission = perms.commandPermission },
        .permission_admin = .{ .ctx = tecton, .get_group = perms.getPlayerGroup, .set_group = perms.setPermissionGroup, .default_group = perms.defaultPermissionGroup, .refresh_abilities = perms.refreshPlayerAbilities },
        .bans = .{ .ctx = tecton, .is_banned = perms.isBanned, .add = perms.addBan, .remove = perms.removeBan, .entry_name = perms.banEntryName },
        .shutdown = .{ .ctx = tecton, .shutdown = lifecycle.shutdown },
        .about = .{ .players = selection, .max_players = &tecton.config.max_players },
        .world_info = .{
            .worlds = query,
            .players = selection,
            .ctx = tecton,
            .target_tps = players.targetTps,
            .current_tps = &tecton.current_tps,
            .current_mspt = &tecton.current_mspt,
            .current_network_io_mspt = &tecton.current_network_io_mspt,
            .current_network_dispatch_mspt = &tecton.current_network_dispatch_mspt,
            .current_game_mspt = &tecton.current_game_mspt,
            .profiler = &tecton.profiler,
        },
        .enchantment = .{ .events = &tecton.events },
        .floating_text = .{ .worlds = query, .ctx = tecton, .refresh_command_enums = lifecycle.refreshFloatingTextCommandEnums },
        .world_admin = .{
            .ctx = tecton,
            .allocator = tecton.allocator,
            .get_world = worldAdapters.getWorld,
            .has_world = worldAdapters.hasWorld,
            .count_worlds = worldAdapters.countWorlds,
            .op_in_flight = worldAdapters.worldOpInFlight,
            .begin_op = worldAdapters.beginWorldOp,
            .end_op = worldAdapters.endOp,
            .detach_world = worldAdapters.detachWorld,
            .adopt_world = worldAdapters.adoptWorld,
            .collect_world_names = worldAdapters.collectWorldNames,
            .world_dir_exists = worldAdapters.worldDirExists,
            .queue_create = queueWorldCreate,
            .queue_load = queueWorldLoad,
            .queue_unload = queueWorldUnload,
        },
    };
}

fn queueWorldCreate(ctx: *anyopaque, name: []u8, sender: ?*Player, origin_type: []const u8, uuid: [16]u8, request_id: []const u8) anyerror!void {
    return WorldLifecycle.queueCreate(host(cast(ctx)), name, sender, origin_type, uuid, request_id);
}

fn queueWorldLoad(ctx: *anyopaque, name: []u8, sender: ?*Player, origin_type: []const u8, uuid: [16]u8, request_id: []const u8) anyerror!void {
    return WorldLifecycle.queueLoad(host(cast(ctx)), name, sender, origin_type, uuid, request_id);
}

fn queueWorldUnload(ctx: *anyopaque, world: *World, name: []u8, sender: ?*Player, origin_type: []const u8, uuid: [16]u8, request_id: []const u8) anyerror!void {
    return WorldLifecycle.queueUnload(host(cast(ctx)), world, name, sender, origin_type, uuid, request_id);
}

fn cast(ctx: *anyopaque) *Tecton {
    return @ptrCast(@alignCast(ctx));
}

fn replyTo(
    ctx: *anyopaque,
    sender_runtime_id: ?i64,
    origin_type: []const u8,
    uuid: [16]u8,
    request_id: []const u8,
    success: bool,
    message: []const u8,
) void {
    const tecton = cast(ctx);
    var sender: ?*Player = null;
    if (sender_runtime_id) |runtime_id| {
        sender = tecton.players.byRuntimeId(runtime_id) orelse return;
        if (sender.?.pending_removal.load(.acquire)) return;
    }
    var cmd = CommandContext{
        .player = sender,
        .args = "",
        .network = tecton.network,
        .views = commandViews(tecton),
        .allocator = tecton.allocator,
        .origin_type = origin_type,
        .uuid = uuid,
        .request_id = request_id,
    };
    defer cmd.deinit();
    cmd.sendOutput(success, message);
}

fn buildWorld(ctx: *anyopaque, name: []const u8) anyerror!*World {
    const tecton = cast(ctx);
    return worlds.build(host(tecton), tecton.paths.worlds, name);
}

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const Tecton = test_owner.Tecton;
    pub const Host = test_owner.Host;
    pub const host = test_owner.host;
    pub const hostChecked = test_owner.hostChecked;
    pub const commandViews = test_owner.commandViews;
    pub const CommandContext = test_owner.CommandContext;
    pub const Command = @import("../command/command.zig").Command;
    pub const Player = test_owner.Player;
    pub const Entity = test_owner.Entity;
    pub const EcsWorld = test_owner.EcsWorld;
    pub const NetworkHandler = test_owner.NetworkHandler;
    pub const Dimension = test_owner.Dimension;
    pub const World = test_owner.World;
    pub const Connection = test_owner.Connection;
    pub const Protocol = test_owner.Protocol;
    pub const block_root = test_owner.tecton_mod.block_root;
};

const players_suite = @import("services_players_test.zig").Suite(test_scope);
const worlds_suite = @import("services_worlds_test.zig").Suite(test_scope);
const perms_suite = @import("services_perms_test.zig").Suite(test_scope);
const host_suite = @import("services_host_test.zig").Suite(test_scope);

test "the host fails in a controlled way when built before the network exists" {
    try host_suite.case_000();
}

test "players.by_runtime_id sees a player registered after the host was built" {
    try players_suite.case_001();
}

test "get_player_count sees a player registered after the host was built" {
    try players_suite.case_002();
}

test "get_player_snapshots sees a player registered after the host was built" {
    try players_suite.case_003();
}

test "find_player_by_runtime_id sees a player registered after the host was built" {
    try players_suite.case_004();
}

test "register_ecs_entity registers an entity created after the host was built" {
    try host_suite.case_005();
}

test "unregister_ecs_entity removes an entity created after the host was built" {
    try host_suite.case_006();
}

test "set_player_location stores a location that did not exist at construction" {
    try players_suite.case_007();
}

test "enqueue_player_removal queues a player created after the host was built" {
    try players_suite.case_008();
}

test "remove_player removes a player registered after the host was built" {
    try players_suite.case_009();
}

test "remove_connection_mapping unmaps a connection registered after the host was built" {
    try players_suite.case_010();
}

test "target_tps reads the config value current at call time" {
    try players_suite.case_011();
}

test "current_tps reads the value current at call time" {
    try players_suite.case_012();
}

test "current_mspt reads the value current at call time" {
    try players_suite.case_013();
}

test "tick_count reads the value current at call time" {
    try players_suite.case_014();
}

test "refresh_world_command_enums sees worlds adopted after the host was built" {
    try worlds_suite.case_015();
}

test "refresh_floating_text_command_enums sees holograms added after the host was built" {
    try worlds_suite.case_016();
}

test "reply_to resolves the sender and the network current at call time" {
    try host_suite.case_017();
}

test "worlds.build builds under the paths current at call time" {
    try worlds_suite.case_018();
}

test "worlds.adopt registers a world created after the host was built" {
    try worlds_suite.case_019();
}

test "worlds.destroy removes a world adopted after the host was built" {
    try worlds_suite.case_020();
}

test "worlds.end_op closes an operation opened after the host was built" {
    try worlds_suite.case_021();
}

test "instances.assign_dimension sees an instance created after the host was built" {
    try host_suite.case_022();
}

test "permission_manager.get_player_group sees a group set after the host was built" {
    try perms_suite.case_023();
}

test "hostChecked rejects a Tecton that was copied after construction" {
    try host_suite.case_024();
}

test "events pointer sees the member initialized after the host was built" {
    try host_suite.case_025();
}

test "ecs pointer sees the member initialized after the host was built" {
    try host_suite.case_026();
}

test "tasks pointer sees the member initialized after the host was built" {
    try host_suite.case_027();
}

test "threaded_tasks pointer sees the member initialized after the host was built" {
    try host_suite.case_028();
}

test "profiler pointer sees the member initialized after the host was built" {
    try host_suite.case_029();
}

test "mob_broadcast_interval is fixed at host construction" {
    try host_suite.case_030();
}

test "command permissions preserve live custom checker priority and manager fallback" {
    try perms_suite.case_031();
}

test "command views observe mutable metrics configuration and paths after construction" {
    try host_suite.case_032();
}

test "command query views observe registries initialized after construction" {
    try worlds_suite.case_033();
}

test "command dispatch preserves denial output handler isolation and console permission bypass" {
    try perms_suite.case_034();
}

test "floating text command view resolves refresh at call time and observes later registries" {
    try worlds_suite.case_035();
}

test "world admin command view resolves registry state at call time" {
    try worlds_suite.case_036();
}

test "a world reload restores a stored entity, a chest with items and a player inventory" {
    try worlds_suite.case_037();
}

test {
    _ = @import("host_rules_test.zig");
}
