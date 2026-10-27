const std = @import("std");

const Protocol = @import("protocol");

const Entity = @import("../../entity/entity.zig").Entity;
const Player = @import("../../player/player.zig").Player;
const Dimension = @import("./dimension.zig").Dimension;
const SharedBroadcast = @import("../../transport/shared_broadcast.zig").SharedBroadcast;

pub const SOUND_BROADCAST_RADIUS: f32 = 32.0;
pub const PARTICLE_BROADCAST_RADIUS: f32 = 64.0;

pub fn broadcastToViewers(dim: *Dimension, data: []const u8) void {
    const tecton = dim.world.tecton;
    var broadcast = SharedBroadcast.begin(tecton.network, data) catch return;
    defer broadcast.deinit();

    const snapshots = tecton.getPlayerSnapshots();
    for (snapshots) |player| {
        if (!player.spawned) continue;
        if (player.entity.dimension != dim or player.entity.instance_id != dim.instance_id) continue;
        broadcast.send(player.connection, .normal);
    }
}

pub fn broadcastToEntityViewers(dim: *Dimension, entity: *const Entity, data: []const u8) void {
    const tecton = dim.world.tecton;
    var broadcast = SharedBroadcast.begin(tecton.network, data) catch return;
    defer broadcast.deinit();

    const snapshots = tecton.getPlayerSnapshots();
    for (snapshots) |player| {
        if (!player.spawned) continue;
        if (player.entity.dimension != dim or player.entity.instance_id != dim.instance_id) continue;
        const is_self = player.entity.runtime_id == entity.runtime_id;

        if (!is_self and
            !player.visible_players.contains(entity.runtime_id) and
            !player.visible_entities.contains(entity.runtime_id)) continue;
        broadcast.send(player.connection, .normal);
    }
}

pub fn broadcastBlockUpdateToViewers(dim: *Dimension, pos: Protocol.BlockPosition, data: []const u8) void {
    sendBlockUpdateToViewers(dim, pos, null, data);
}

pub fn broadcastBlockUpdateToViewersExcept(dim: *Dimension, pos: Protocol.BlockPosition, except: *Player, data: []const u8) void {
    sendBlockUpdateToViewers(dim, pos, except, data);
}

fn sendBlockUpdateToViewers(dim: *Dimension, pos: Protocol.BlockPosition, except: ?*Player, data: []const u8) void {
    const tecton = dim.world.tecton;
    var broadcast = SharedBroadcast.begin(tecton.network, data) catch return;
    defer broadcast.deinit();

    const snapshots = tecton.getPlayerSnapshots();
    const block_cx = pos.x >> 4;
    const block_cz = pos.z >> 4;
    for (snapshots) |player| {
        if (!player.spawned) continue;
        if (player.entity.dimension != dim or player.entity.instance_id != dim.instance_id) continue;
        if (except) |skip| {
            if (player == skip) continue;
        }
        const player_cx = @as(i32, @intFromFloat(@floor(player.entity.position.x))) >> 4;
        const player_cz = @as(i32, @intFromFloat(@floor(player.entity.position.z))) >> 4;
        if (!withinChunkViewDistance(block_cx - player_cx, block_cz - player_cz, player.view_distance)) continue;
        broadcast.send(player.connection, .normal);
    }
}

pub fn broadcastToNearby(dim: *Dimension, pos: Protocol.Vector3f, radius: f32, data: []const u8) void {
    const tecton = dim.world.tecton;
    var broadcast = SharedBroadcast.begin(tecton.network, data) catch return;
    defer broadcast.deinit();

    const snapshots = tecton.getPlayerSnapshots();
    for (snapshots) |player| {
        if (!player.spawned) continue;
        if (player.entity.dimension != dim or player.entity.instance_id != dim.instance_id) continue;
        const dx = player.entity.position.x - pos.x;
        const dy = player.entity.position.y - pos.y;
        const dz = player.entity.position.z - pos.z;
        if (!withinRadius(dx, dy, dz, radius)) continue;
        broadcast.send(player.connection, .normal);
    }
}

fn withinChunkViewDistance(dx: i32, dz: i32, view_distance: i32) bool {
    return @max(@abs(dx), @abs(dz)) <= view_distance;
}

fn withinRadius(dx: f32, dy: f32, dz: f32, radius: f32) bool {
    return dx * dx + dy * dy + dz * dz <= radius * radius;
}

test "chunk view distance predicate uses chebyshev distance" {
    try std.testing.expect(withinChunkViewDistance(0, 0, 4));
    try std.testing.expect(withinChunkViewDistance(4, -4, 4));
    try std.testing.expect(!withinChunkViewDistance(5, 4, 4));
    try std.testing.expect(!withinChunkViewDistance(-4, 5, 4));
    try std.testing.expect(withinChunkViewDistance(8, 0, 8));
    try std.testing.expect(!withinChunkViewDistance(9, 0, 8));
}

test "nearby broadcast predicate compares 3d euclidean distance" {
    try std.testing.expect(withinRadius(0, 0, 0, 32));
    try std.testing.expect(withinRadius(32, 0, 0, 32));
    try std.testing.expect(!withinRadius(33, 0, 0, 32));
    try std.testing.expect(withinRadius(16, 16, 16, 32));
    try std.testing.expect(!withinRadius(20, 20, 20, 32));
}
