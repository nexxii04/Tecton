const Raknet = @import("Raknet");
const std = @import("std");
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

pub fn handleNetworkSettings(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const request = try Protocol.RequestNetworkSettingsPacket.deserialize(stream);
    if (request.protocol != Protocol.PROTOCOL) {
        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();

        var reason: Protocol.DisconnectReason = .OutdatedClient;
        if (request.protocol > Protocol.PROTOCOL) reason = .OutdatedServer;

        var disconnect = Protocol.DisconnectPacket{
            .reason = reason,
        };
        const serialized = try disconnect.serialize(&str);
        try network.sendPacket(connection, serialized);
        return;
    }

    var write = BinaryStream.init(network.allocator, null, null);
    defer write.deinit();

    var response = Protocol.NetworkSettingsPacket{
        .client_scalar = 0,
        .compression_threshold = network.options.compression_threshold,
        .compression_method = network.options.compression_method,
        .client_threshold = 0,
        .client_throttle = false,
    };
    const packet = try response.serialize(&write);
    try network.sendUncompressedPacket(connection, packet);
}
