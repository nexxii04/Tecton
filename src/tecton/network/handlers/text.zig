const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const transport = @import("../../transport/root.zig");

const Events = @import("../../events/root.zig");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const PlayerLog = @import("../player_log.zig");

pub fn acceptedChat(events: *Events.Events, event: *Events.types.PlayerChatEvent) ?[]const u8 {
    if (!events.emit(.PlayerChat, event)) return null;
    return event.message;
}

pub fn handleTextPacket(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *transport.Connection,
    stream: *BinaryStream,
) !void {
    const text = try Protocol.TextPacket.deserialize(stream);

    if (text.text_type == .Chat) {
        const sender = tecton.getPlayerByConnection(connection) orelse return;

        var event = Events.types.PlayerChatEvent{
            .player = sender,
            .message = text.message,
        };
        const accepted = acceptedChat(&tecton.events, &event);
        defer if (event.owned_message) |message| network.allocator.free(message);
        const message = accepted orelse return;
        PlayerLog.logChat(sender.username, message);

        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();

        var packet = Protocol.TextPacket{
            .text_type = .Chat,
            .source_name = sender.username,
            .message = message,
            .xuid = sender.xuid,
        };

        const serialized = try packet.serialize(&str);

        const snapshots = tecton.getPlayerSnapshots();
        for (snapshots) |p| {
            try network.sendPacket(p.connection, serialized);
        }
    }
}

test "a canceled chat is not broadcast by the text packet handler" {
    const RootEvents = @import("../../events/root.zig");
    const PluginRuntime = @import("../../plugins/runtime.zig").PluginRuntime;
    const abi = @import("../../plugins/abi.zig");
    const Player = @import("../../player/player.zig").Player;
    const PlayerRegistry = @import("../../server/players.zig").PlayerRegistry;
    const Connection = @import("../../transport/connection.zig").Connection;
    const ScratchBuffer = @import("../../transport/scratch.zig").ScratchBuffer;
    const TransportFake = @import("../../transport/fake_port.zig").TransportFake;

    const allocator = std.testing.allocator;

    var events = RootEvents.Events.init(allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);
    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 1, .state = .running };

    const Cancel = struct {
        fn callback(_: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
            view.result.* = @intFromEnum(abi.EventResult.cancel);
        }
    };
    var subscription: u64 = 0;
    try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.player_chat), abi.event_phase_pre, 0, Cancel.callback, null, &subscription));

    var fake = TransportFake.init(allocator);
    defer fake.deinit();

    var network: NetworkHandler = undefined;
    network.allocator = allocator;
    network.options = .{ .compression_method = .NotPresent, .compression_threshold = 255 };
    network.port = fake.port();
    network.send_buffers = .empty;
    network.scratch = ScratchBuffer.init(allocator);
    defer network.scratch.deinit();
    network.outbound_dropped = .init(0);
    network.oversize_sends = .init(0);
    network.backpressure_sends = .init(0);

    var backend: u128 = 0;
    const connection = try allocator.create(Connection);
    connection.* = .{
        .id = 1,
        .backend = &backend,
        .allocator = allocator,
        .refs = .init(1),
        .state = .init(.open),
    };
    defer connection.release();

    var tecton: Tecton = undefined;
    tecton.io = std.testing.io;
    tecton.allocator = allocator;
    tecton.events = events;
    tecton.players = PlayerRegistry.init(std.testing.io, allocator);
    defer tecton.players.deinit();

    var player: Player = undefined;
    player.entity.runtime_id = 7;
    player.connection = connection;
    player.username = "tester";
    player.xuid = "0";
    player.pending_removal = .init(false);
    try tecton.players.insert(&player);

    var packet = Protocol.TextPacket{ .text_type = .Chat, .source_name = player.username, .message = "hello", .xuid = player.xuid };
    var writer = BinaryStream.init(allocator, null, null);
    defer writer.deinit();
    _ = try packet.serialize(&writer);

    var rejected = BinaryStream.init(allocator, writer.getBuffer(), 0);
    try handleTextPacket(&tecton, &network, connection, &rejected);
    try std.testing.expectEqual(@as(usize, 0), fake.sent.items.len);

    try std.testing.expectEqual(abi.result_ok, runtime.events_api.unsubscribe(@ptrCast(&slot), subscription));
    tecton.events = events;

    var accepted = BinaryStream.init(allocator, writer.getBuffer(), 0);
    try handleTextPacket(&tecton, &network, connection, &accepted);
    try std.testing.expectEqual(@as(usize, 1), fake.sentTo(connection.id));
}
