const std = @import("std");
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

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
        .players = .{ .ctx = tecton, .by_runtime_id = byRuntimeId },
        .instances = .{ .ctx = tecton, .assign_dimension = assignDimension },
        .permission_manager = .{ .ctx = tecton, .get_player_group = getPlayerGroup },
        .worlds = .{ .ctx = tecton, .build_world = buildWorld, .adopt_world = adoptWorld, .destroy_world = destroyWorld, .end_op = endOp },
        .mob_broadcast_interval = tecton.mob_broadcast_interval,
        .get_player_snapshots = getPlayerSnapshots,
        .get_player_count = getPlayerCount,
        .find_player_by_runtime_id = findPlayerByRuntimeId,
        .register_ecs_entity = registerEcsEntity,
        .unregister_ecs_entity = unregisterEcsEntity,
        .set_player_location = setPlayerLocation,
        .enqueue_player_removal = enqueuePlayerRemoval,
        .remove_player = removePlayer,
        .remove_connection_mapping = removeConnectionMapping,
        .target_tps = targetTps,
        .current_tps = currentTps,
        .current_mspt = currentMspt,
        .tick_count = tickCount,
        .refresh_world_command_enums = refreshWorldCommandEnums,
        .refresh_floating_text_command_enums = refreshFloatingTextCommandEnums,
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
        .get_player_snapshots = getPlayerSnapshots,
    };
    const query: contracts.WorldQuery(World) = .{ .registry = &tecton.worlds.by_name };

    return .{
        .selection = selection,
        .permissions = .{ .ctx = tecton, .has_permission = commandPermission },
        .permission_admin = .{ .ctx = tecton, .get_group = getPlayerGroup, .set_group = setPermissionGroup, .default_group = defaultPermissionGroup },
        .bans = .{ .ctx = tecton, .is_banned = isBanned, .add = addBan, .remove = removeBan, .entry_name = banEntryName },
        .shutdown = .{ .ctx = tecton, .shutdown = shutdown },
        .about = .{ .players = selection, .max_players = &tecton.config.max_players },
        .world_info = .{
            .worlds = query,
            .players = selection,
            .ctx = tecton,
            .target_tps = targetTps,
            .current_tps = &tecton.current_tps,
            .current_mspt = &tecton.current_mspt,
            .current_raknet_mspt = &tecton.current_raknet_mspt,
            .current_game_mspt = &tecton.current_game_mspt,
            .profiler = &tecton.profiler,
        },
        .enchantment = .{ .events = &tecton.events },
    };
}

fn commandPermission(ctx: *anyopaque, username: []const u8, xuid: []const u8, permission: []const u8) bool {
    if (permission.len == 0) return true;
    const tecton = cast(ctx);

    if (tecton.command_permission_checker) |checker| {
        return checker(tecton.command_permission_userdata, xuid, permission);
    }
    return tecton.permission_manager.hasPermission(username, permission);
}

fn setPermissionGroup(ctx: *anyopaque, name: []const u8, group: []const u8) anyerror!void {
    return cast(ctx).permission_manager.setPlayerGroup(name, group);
}

fn defaultPermissionGroup(ctx: *anyopaque) []const u8 {
    return cast(ctx).permission_manager.default_group;
}

fn isBanned(ctx: *anyopaque, name: []const u8) bool {
    return cast(ctx).ban_manager.isBanned(name);
}

fn addBan(ctx: *anyopaque, uuid: []const u8, name: []const u8, source: []const u8, reason: []const u8) anyerror!void {
    return cast(ctx).ban_manager.ban(uuid, name, source, reason);
}

fn removeBan(ctx: *anyopaque, name: []const u8) bool {
    return cast(ctx).ban_manager.unban(name);
}

fn banEntryName(ctx: *anyopaque, index: usize) ?[]const u8 {
    const entries = cast(ctx).ban_manager.entries.items;
    return if (index < entries.len) entries[index].name else null;
}

fn shutdown(ctx: *anyopaque) anyerror!void {
    return cast(ctx).shutdown();
}

fn cast(ctx: *anyopaque) *Tecton {
    return @ptrCast(@alignCast(ctx));
}

fn getPlayerSnapshots(ctx: *anyopaque) []const *Player {
    return cast(ctx).getPlayerSnapshots();
}

fn getPlayerCount(ctx: *anyopaque) usize {
    return cast(ctx).getPlayerCount();
}

fn findPlayerByRuntimeId(ctx: *anyopaque, runtime_id: i64) ?*Player {
    return cast(ctx).findPlayerByRuntimeId(runtime_id);
}

fn registerEcsEntity(ctx: *anyopaque, entity: *Entity) void {
    cast(ctx).registerEcsEntity(entity);
}

fn unregisterEcsEntity(ctx: *anyopaque, entity: *Entity) void {
    cast(ctx).unregisterEcsEntity(entity);
}

fn setPlayerLocation(ctx: *anyopaque, uuid: []const u8, world_identifier: []const u8, dimension_identifier: []const u8) void {
    cast(ctx).setPlayerLocation(uuid, world_identifier, dimension_identifier);
}

fn enqueuePlayerRemoval(ctx: *anyopaque, player: *Player) void {
    cast(ctx).enqueuePlayerRemoval(player);
}

fn removePlayer(ctx: *anyopaque, player: *Player) void {
    cast(ctx).removePlayer(player);
}

fn removeConnectionMapping(ctx: *anyopaque, connection: *anyopaque) void {
    cast(ctx).removeConnectionMapping(@ptrCast(@alignCast(connection)));
}

fn targetTps(ctx: *anyopaque) f64 {
    return cast(ctx).targetTps();
}

fn currentTps(ctx: *anyopaque) f64 {
    return cast(ctx).current_tps;
}

fn currentMspt(ctx: *anyopaque) f64 {
    return cast(ctx).current_mspt;
}

fn tickCount(ctx: *anyopaque) u64 {
    return cast(ctx).tick_count;
}

fn refreshWorldCommandEnums(ctx: *anyopaque) void {
    cast(ctx).refreshWorldCommandEnums();
}

fn refreshFloatingTextCommandEnums(ctx: *anyopaque) void {
    cast(ctx).refreshFloatingTextCommandEnums();
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

fn byRuntimeId(ctx: *anyopaque, runtime_id: i64) ?*Player {
    return cast(ctx).players.byRuntimeId(runtime_id);
}

fn assignDimension(ctx: *anyopaque, runtime_id: i64, dimension: *Dimension) anyerror!void {
    return cast(ctx).instances.assignDimension(runtime_id, dimension);
}

fn getPlayerGroup(ctx: *anyopaque, player_name: []const u8) []const u8 {
    return cast(ctx).permission_manager.getPlayerGroup(player_name);
}

fn buildWorld(ctx: *anyopaque, name: []const u8) anyerror!*World {
    const tecton = cast(ctx);
    return worlds.build(host(tecton), tecton.paths.worlds, name);
}

fn adoptWorld(ctx: *anyopaque, world: *World) anyerror!void {
    return cast(ctx).worlds.adopt(world);
}

fn destroyWorld(ctx: *anyopaque, world: *World) void {
    cast(ctx).worlds.destroy(world);
}

fn endOp(ctx: *anyopaque, name: []const u8) void {
    cast(ctx).worlds.endOp(name);
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
    pub const Raknet = test_owner.Raknet;
    pub const Protocol = test_owner.Protocol;
    pub const block_root = test_owner.tecton_mod.block_root;
};

test "the host fails in a controlled way when built before the network exists" {
    try @import("services_test.zig").Suite(test_scope).case_000();
}

test "players.by_runtime_id sees a player registered after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_001();
}

test "get_player_count sees a player registered after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_002();
}

test "get_player_snapshots sees a player registered after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_003();
}

test "find_player_by_runtime_id sees a player registered after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_004();
}

test "register_ecs_entity registers an entity created after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_005();
}

test "unregister_ecs_entity removes an entity created after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_006();
}

test "set_player_location stores a location that did not exist at construction" {
    try @import("services_test.zig").Suite(test_scope).case_007();
}

test "enqueue_player_removal queues a player created after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_008();
}

test "remove_player removes a player registered after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_009();
}

test "remove_connection_mapping unmaps a connection registered after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_010();
}

test "target_tps reads the config value current at call time" {
    try @import("services_test.zig").Suite(test_scope).case_011();
}

test "current_tps reads the value current at call time" {
    try @import("services_test.zig").Suite(test_scope).case_012();
}

test "current_mspt reads the value current at call time" {
    try @import("services_test.zig").Suite(test_scope).case_013();
}

test "tick_count reads the value current at call time" {
    try @import("services_test.zig").Suite(test_scope).case_014();
}

test "refresh_world_command_enums sees worlds adopted after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_015();
}

test "refresh_floating_text_command_enums sees holograms added after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_016();
}

test "reply_to resolves the sender and the network current at call time" {
    try @import("services_test.zig").Suite(test_scope).case_017();
}

test "worlds.build builds under the paths current at call time" {
    try @import("services_test.zig").Suite(test_scope).case_018();
}

test "worlds.adopt registers a world created after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_019();
}

test "worlds.destroy removes a world adopted after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_020();
}

test "worlds.end_op closes an operation opened after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_021();
}

test "instances.assign_dimension sees an instance created after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_022();
}

test "permission_manager.get_player_group sees a group set after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_023();
}

test "hostChecked rejects a Tecton that was copied after construction" {
    try @import("services_test.zig").Suite(test_scope).case_024();
}

test "events pointer sees the member initialized after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_025();
}

test "ecs pointer sees the member initialized after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_026();
}

test "tasks pointer sees the member initialized after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_027();
}

test "threaded_tasks pointer sees the member initialized after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_028();
}

test "profiler pointer sees the member initialized after the host was built" {
    try @import("services_test.zig").Suite(test_scope).case_029();
}

test "mob_broadcast_interval is fixed at host construction" {
    try @import("services_test.zig").Suite(test_scope).case_030();
}

test "command permissions preserve live custom checker priority and manager fallback" {
    try @import("services_test.zig").Suite(test_scope).case_031();
}

test "command views observe mutable metrics configuration and paths after construction" {
    try @import("services_test.zig").Suite(test_scope).case_032();
}

test "command query views observe registries initialized after construction" {
    try @import("services_test.zig").Suite(test_scope).case_033();
}

test "command dispatch preserves denial output handler isolation and console permission bypass" {
    try @import("services_test.zig").Suite(test_scope).case_034();
}
