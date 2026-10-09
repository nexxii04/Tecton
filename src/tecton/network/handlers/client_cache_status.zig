const Raknet = @import("Raknet");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

pub fn handleClientCacheStatus(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    _ = tecton;
    _ = network;
    _ = connection;
    _ = try Protocol.ClientCacheStatusPacket.deserialize(stream);
}
