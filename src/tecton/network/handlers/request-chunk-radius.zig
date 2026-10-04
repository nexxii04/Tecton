const std = @import("std");
const Raknet = @import("Raknet");
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

pub fn handleRequestChunkRadius(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const packet = try Protocol.RequestChunkRadiusPacket.deserialize(stream);
    const player = tecton.getPlayerByConnection(connection) orelse return;

    const max_radius: i32 = @intCast(tecton.config.max_view_distance);
    const new_distance = if (packet.radius > max_radius) max_radius else packet.radius;
    const changed = new_distance != player.view_distance;
    player.view_distance = new_distance;

    if (changed) {
        Raknet.Logger.DEBUG("Player {s} requested chunk radius: {d}, set to: {d}", .{
            player.username,
            packet.radius,
            player.view_distance,
        });
    }

    var str = BinaryStream.init(network.allocator, null, null);
    defer str.deinit();
    var response = Protocol.ChunkRadiusUpdatePacket{
        .radius = player.view_distance,
    };
    const serialized = try response.serialize(&str);
    try network.sendPacket(connection, serialized);
}
