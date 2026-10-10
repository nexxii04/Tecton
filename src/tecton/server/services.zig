const std = @import("std");

const contracts = @import("../core/contracts.zig");
const CommandContext = @import("../command/context.zig").CommandContext;
const Tecton = @import("../tecton.zig").Tecton;
const Entity = @import("../entity/entity.zig").Entity;
const EcsWorld = @import("../entity/ecs.zig").EcsWorld;
const events_mod = @import("../events/root.zig");
const NetworkHandler = @import("../transport/network_handler.zig").NetworkHandler;
const Player = @import("../player/player.zig").Player;
const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const World = @import("../world/world.zig").World;
const worlds = @import("./worlds.zig");

pub const Host = contracts.ServerHost(Player, Entity, events_mod.Events, Dimension, World, EcsWorld, NetworkHandler);

pub fn host(tecton: *Tecton) Host {
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
        .tecton = tecton,
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
