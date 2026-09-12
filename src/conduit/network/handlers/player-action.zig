const std = @import("std");
const Raknet = @import("Raknet");
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const BlockPermutation = @import("../../world/block/block-permutation.zig").BlockPermutation;
const Events = @import("../../events/types.zig");
const ItemType = @import("../../items/item-type.zig").ItemType;

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
            if (player.pending_dimension) |dim| {
                const spawn = dim.spawn_position;
                player.entity.position = Protocol.Vector3f.init(
                    @as(f32, @floatFromInt(spawn.x)) + 0.5,
                    @as(f32, @floatFromInt(spawn.y)),
                    @as(f32, @floatFromInt(spawn.z)) + 0.5,
                );
                player.entity.dimension = dim;
                player.pending_dimension = null;
                player.spawned = true;

                var str = BinaryStream.init(network.allocator, null, null);
                defer str.deinit();
                var status = Protocol.PlayStatusPacket{ .status = .PlayerSpawn };
                const serialized = status.serialize(&str) catch return;
                network.sendPacket(player.connection, serialized) catch {};
            }
        },
        .StartItemUseOn => {},
        .StopItemUseOn => {},
        .CreativePlayerDestroyBlock => {},
        else => {
            Raknet.Logger.DEBUG("Unhandled PlayerAction: {any}", .{packet.action});
        },
    }
}
