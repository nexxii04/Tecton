const std = @import("std");
const Raknet = @import("Raknet");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const BlockPermutation = @import("../../world/block/block_permutation.zig").BlockPermutation;
const Events = @import("../../events/types.zig");
const ItemType = @import("../../items/item_type.zig").ItemType;
const handlePlayerBlockAction = @import("./player_auth_input.zig").handlePlayerBlockAction;
const respawn = @import("./respawn.zig");
const Player = @import("../../player/player.zig").Player;

pub fn handlePlayerAction(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const player = tecton.getPlayerByConnection(connection) orelse return;
    const packet = try Protocol.PlayerActionPacket.deserialize(stream);

    switch (packet.action) {
        .Respawn => {
            respawn.respawnPlayer(network, player);
        },
        .DimensionChangeDone => {
            const dim = player.pending_dimension orelse return;
            if (dim.world.unloading) {
                player.pending_dimension = null;
                Raknet.Logger.ERROR("Dimension change ack for unloading world '{s}' from {s}", .{ dim.world.identifier, player.username });
                return;
            }

            const spawn = dim.spawn_position;
            player.entity.position = Protocol.Vector3f.init(
                @as(f32, @floatFromInt(spawn.x)) + 0.5,
                @as(f32, @floatFromInt(spawn.y)),
                @as(f32, @floatFromInt(spawn.z)) + 0.5,
            );
            player.entity.dimension = dim;
            player.entity.instance_id = dim.instance_id;
            player.tecton.instances.assignDimension(player.entity.runtime_id, dim) catch {};
            player.pending_dimension = null;
            player.spawned = true;
            tecton.setPlayerLocation(player.uuid, dim.world.identifier, dim.identifier);

            var str = BinaryStream.init(network.allocator, null, null);
            defer str.deinit();
            var status = Protocol.PlayStatusPacket{ .status = .PlayerSpawn };
            const serialized = status.serialize(&str) catch return;
            network.sendPacket(player.connection, serialized) catch {};
        },
        .StartItemUseOn => {},
        .StopItemUseOn => {},
        .CreativePlayerDestroyBlock, .PredictDestroyBlock => {
            try handlePlayerBlockAction(tecton, network, player, .{
                .action = packet.action,
                .block_pos = packet.block_position,
                .face = packet.face,
            });
        },
        else => {
            Raknet.Logger.DEBUG("Unhandled PlayerAction: {any}", .{packet.action});
        },
    }
}
