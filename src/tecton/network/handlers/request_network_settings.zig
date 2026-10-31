const transport = @import("../../transport/root.zig");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

pub fn handleNetworkSettings(
    _: *Tecton,
    network: *NetworkHandler,
    connection: *transport.Connection,
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
        try network.sendUncompressedPacket(connection, serialized);
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
    connection.markCompressionReady();
}
