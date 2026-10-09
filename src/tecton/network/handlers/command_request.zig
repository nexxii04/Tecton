const Raknet = @import("Raknet");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

pub fn handleCommandRequest(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const request = try Protocol.CommandRequestPacket.deserialize(stream);
    const player = tecton.getPlayerByConnection(connection) orelse return;

    const result = tecton.command_registry.dispatch(
        player,
        tecton,
        network,
        request.command_line,
        request.origin_type.toString(),
        request.uuid,
        request.request_id,
    );

    if (!result.success and result.message.len > 0) {
        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();

        const msgs = [_]Protocol.CommandOutputMessage{
            .{ .success = false, .message = result.message, .parameters = &.{} },
        };

        var output = Protocol.CommandOutputPacket{
            .origin_type = request.origin_type.toString(),
            .uuid = request.uuid,
            .request_id = request.request_id,
            .player_unique_id = request.player_unique_id,
            .output_type = "alloutput",
            .success_count = 0,
            .messages = &msgs,
        };

        const serialized = try output.serialize(&str);
        try network.sendPacket(connection, serialized);
    }
}
