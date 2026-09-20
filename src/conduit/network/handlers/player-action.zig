const std = @import("std");
const Raknet = @import("Raknet");
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const BlockPermutation = @import("../../world/block/block-permutation.zig").BlockPermutation;
const Events = @import("../../events/types.zig");
const ItemType = @import("../../items/item-type.zig").ItemType;
const handlePlayerBlockAction = @import("./player-auth-input.zig").handlePlayerBlockAction;

pub fn handlePlayerAction(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const player = network.conduit.getPlayerByConnection(connection) orelse return;
    const packet = try Protocol.PlayerActionPacket.deserialize(stream);

    switch (packet.action) {
        .Respawn => {},
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
            player.network.conduit.instances.assignDimension(player.entity.runtime_id, dim) catch {};
            player.pending_dimension = null;
            player.spawned = true;
            network.conduit.setPlayerLocation(player.uuid, dim.world.identifier, dim.identifier);

            var str = BinaryStream.init(network.allocator, null, null);
            defer str.deinit();
            var status = Protocol.PlayStatusPacket{ .status = .PlayerSpawn };
            const serialized = status.serialize(&str) catch return;
            network.sendPacket(player.connection, serialized) catch {};
        },
        .StartItemUseOn => {},
        .StopItemUseOn => {},
        .CreativePlayerDestroyBlock, .PredictDestroyBlock => {
            try handlePlayerBlockAction(network, player, .{
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
