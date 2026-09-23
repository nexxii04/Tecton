const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const Events = @import("../../events/root.zig");
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const PlayerLog = @import("../player-log.zig");

pub fn handleTextPacket(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const text = try Protocol.TextPacket.deserialize(stream);

    if (text.text_type == .Chat) {
        const sender = network.conduit.getPlayerByConnection(connection) orelse return;

        var event = Events.types.PlayerChatEvent{
            .player = sender,
            .message = text.message,
        };
        const accepted = network.conduit.events.emit(.PlayerChat, &event);
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

        const snapshots = network.conduit.getPlayerSnapshots();
        for (snapshots) |p| {
            try network.sendPacket(p.connection, serialized);
        }
    }
}
