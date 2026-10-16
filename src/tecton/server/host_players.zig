const Tecton = @import("../tecton.zig").Tecton;
const Player = @import("../player/root.zig").Player;

fn cast(ctx: *anyopaque) *Tecton {
    return @ptrCast(@alignCast(ctx));
}

pub fn getPlayerSnapshots(ctx: *anyopaque) []const *Player {
    return cast(ctx).getPlayerSnapshots();
}

pub fn getPlayerCount(ctx: *anyopaque) usize {
    return cast(ctx).getPlayerCount();
}

pub fn findPlayerByRuntimeId(ctx: *anyopaque, runtime_id: i64) ?*Player {
    return cast(ctx).findPlayerByRuntimeId(runtime_id);
}

pub fn setPlayerLocation(ctx: *anyopaque, uuid: []const u8, world_identifier: []const u8, dimension_identifier: []const u8) void {
    cast(ctx).setPlayerLocation(uuid, world_identifier, dimension_identifier);
}

pub fn enqueuePlayerRemoval(ctx: *anyopaque, player: *Player) void {
    cast(ctx).enqueuePlayerRemoval(player);
}

pub fn removePlayer(ctx: *anyopaque, player: *Player) void {
    cast(ctx).removePlayer(player);
}

pub fn removeConnectionMapping(ctx: *anyopaque, connection: *anyopaque) void {
    cast(ctx).removeConnectionMapping(@ptrCast(@alignCast(connection)));
}

pub fn targetTps(ctx: *anyopaque) f64 {
    return cast(ctx).targetTps();
}

pub fn currentTps(ctx: *anyopaque) f64 {
    return cast(ctx).current_tps;
}

pub fn currentMspt(ctx: *anyopaque) f64 {
    return cast(ctx).current_mspt;
}

pub fn tickCount(ctx: *anyopaque) u64 {
    return cast(ctx).tick_count;
}

pub fn byRuntimeId(ctx: *anyopaque, runtime_id: i64) ?*Player {
    return cast(ctx).players.byRuntimeId(runtime_id);
}
