const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const Events = @import("../../events/root.zig");
const NetworkHandler = @import("../network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const PlayerLog = @import("../player_log.zig");

pub fn handleTextPacket(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const text = try Protocol.TextPacket.deserialize(stream);

    if (text.text_type == .Chat) {
        const sender = tecton.getPlayerByConnection(connection) orelse return;

        var event = Events.types.PlayerChatEvent{
            .player = sender,
            .message = text.message,
        };
        const accepted = tecton.events.emit(.PlayerChat, &event);
        defer if (event.owned_message) |message| network.allocator.free(message);
        if (!accepted) return;
        PlayerLog.logChat(sender.username, event.message);

        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();

        var packet = Protocol.TextPacket{
            .text_type = .Chat,
            .source_name = sender.username,
            .message = event.message,
            .xuid = sender.xuid,
        };

        const serialized = try packet.serialize(&str);

        const snapshots = tecton.getPlayerSnapshots();
        for (snapshots) |p| {
            try network.sendPacket(p.connection, serialized);
        }
    }
}
