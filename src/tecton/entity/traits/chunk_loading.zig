const std = @import("std");

const Entity = @import("../entity.zig").Entity;
const Player = @import("../../player/player.zig").Player;
const chunk_streaming = @import("./chunk_streaming.zig");
const EntityTrait = @import("./trait.zig").EntityTrait;
const visibility = @import("./visibility.zig");

pub const State = struct {
    last_chunk_x: i32,
    last_chunk_z: i32,
    initialized: bool,
    visibility_tick: u8,
};

fn getPlayer(entity: *Entity) ?*Player {
    if (!std.mem.eql(u8, entity.entity_type.identifier, "minecraft:player")) return null;
    return @fieldParentPtr("entity", entity);
}

fn onTick(state: *State, entity: *Entity) void {
    const player = getPlayer(entity) orelse return;
    if (!player.spawned) return;
    const player_count = player.tecton.getPlayerCount();
    const visibility_interval: u8 = if (player_count <= 16)
        visibility.VISIBILITY_UPDATE_INTERVAL
    else if (player_count <= 48)
        10
    else
        20;

    const cx = @as(i32, @intFromFloat(@floor(entity.position.x))) >> 4;
    const cz = @as(i32, @intFromFloat(@floor(entity.position.z))) >> 4;
    const moved_chunks = !state.initialized or cx != state.last_chunk_x or cz != state.last_chunk_z;

    state.visibility_tick +%= 1;
    if (moved_chunks or state.visibility_tick >= visibility_interval) {
        state.visibility_tick = 0;

        player.visibility_due = true;
    }

    if (!moved_chunks) return;

    state.last_chunk_x = cx;
    state.last_chunk_z = cz;

    if (!state.initialized) {
        state.initialized = true;
        player.sent_chunks.clearRetainingCapacity();
        player.pending_chunks.clearRetainingCapacity();
        visibility.sendPublisherUpdate(player);
        chunk_streaming.queueChunkStreaming(player) catch {};
        return;
    }

    visibility.sendPublisherUpdate(player);
    chunk_streaming.queueChunkStreaming(player) catch {};
}

pub const ChunkLoadingTrait = EntityTrait(State, .{
    .identifier = "chunk_loading",
    .on_tick = onTick,
});
