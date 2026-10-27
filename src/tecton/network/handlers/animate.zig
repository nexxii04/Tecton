const transport = @import("../../transport/root.zig");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

pub fn handleAnimate(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *transport.Connection,
    stream: *BinaryStream,
) !void {
    const player = tecton.getPlayerByConnection(connection) orelse return;
    const packet = Protocol.AnimatePacket.deserialize(stream) catch return;

    var out_stream = BinaryStream.init(network.allocator, null, null);
    defer out_stream.deinit();

    const out_packet = Protocol.AnimatePacket{
        .action = packet.action,
        .runtime_entity_id = @intCast(player.entity.runtime_id),
        .data = packet.data,
        .swing_source = packet.swing_source,
    };
    const serialized = try out_packet.serialize(&out_stream);

    const dimension = player.entity.dimension orelse return;
    const snapshots = tecton.getPlayerSnapshots();
    for (snapshots) |other| {
        if (other.entity.dimension != dimension) continue;
        if (other.entity.runtime_id == player.entity.runtime_id) continue;
        if (!other.spawned) continue;
        if (!other.visible_players.contains(player.entity.runtime_id)) continue;
        try network.sendPacket(other.connection, serialized);
    }
}
