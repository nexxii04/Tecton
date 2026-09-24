const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const Events = @import("../../events/root.zig");
const Player = @import("../../player/player.zig").Player;
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const PlayerLog = @import("../player-log.zig");

pub fn handleLogin(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    // TODO Offline mode

    const login = try Protocol.LoginPacket.deserialize(stream);
    if (login.protocol != Protocol.PROTOCOL) {
        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();

        var reason: Protocol.DisconnectReason = .OutdatedClient;
        if (login.protocol > Protocol.PROTOCOL) reason = .OutdatedServer;

        var disconnect = Protocol.DisconnectPacket{
            .reason = reason,
        };
        const serialized = try disconnect.serialize(&str);
        try network.sendPacket(connection, serialized);
        return;
    }

    const player_count = network.conduit.getPlayerCount();
    if (player_count >= network.conduit.config.max_players) {
        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();

        var disconnect = Protocol.DisconnectPacket{
            .reason = .ServerFull,
        };
        const serialized = try disconnect.serialize(&str);
        try network.sendPacket(connection, serialized);
        return;
    }

    var data = Protocol.Login.Decoder.decodeLoginChain(network.allocator, login.identity, login.client) catch {
        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();
        var status = Protocol.PlayStatusPacket{
            .status = .FailedClient,
        };
        if (status.serialize(&str)) |ser| {
            network.sendPacket(connection, ser) catch {};
        } else |_| {}
        return;
    };
    errdefer {
        data.deinit();

        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();
        var status = Protocol.PlayStatusPacket{
            .status = .FailedClient,
        };
        if (status.serialize(&str)) |ser| {
            network.sendPacket(connection, ser) catch {};
        } else |_| {}
    }

    {
        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();
        var status = Protocol.PlayStatusPacket{
            .status = .LoginSuccess,
        };
        if (status.serialize(&str)) |serialized| {
            network.sendPacket(connection, serialized) catch {};
        } else |_| {}
    }

    if (network.conduit.ban_manager.isBanned(data.identity_data.display_name) or
        network.conduit.ban_manager.isBannedByXuid(data.identity_data.xuid))
    {
        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();
        var disconnect = Protocol.DisconnectPacket{
            .reason = .Kicked,
            .messages = .{
                .message = "You are banned from this server.",
                .filtered_message = "You are banned from this server.",
            },
        };
        const serialized = try disconnect.serialize(&str);
        try network.sendPacket(connection, serialized);
        return;
    }

    const player = try network.allocator.create(Player);
    errdefer network.allocator.destroy(player);
    try player.init(
        network.allocator,
        connection,
        network,
        data,
        &network.conduit.player_entity_type,
    );

    var event = Events.types.PlayerJoinEvent{
        .player = player,
    };
    if (!network.conduit.events.emit(.PlayerJoin, &event)) {
        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();
        var disconnect = Protocol.DisconnectPacket{
            .reason = .Disconnected,
            .messages = .{
                .message = "PlayerJoinEvent was cancelled",
                .filtered_message = "PlayerJoinEvent was cancelled",
            },
        };
        const serialized = try disconnect.serialize(&str);
        try network.sendPacket(connection, serialized);
        return;
    }

    try network.conduit.addPlayer(player);
    PlayerLog.logJoin(data.identity_data.display_name);

    {
        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();
        var packs = Protocol.ResourcePacksInfoPacket{
            .force_disable_vibrant_visuals = false,
            .has_addons = false,
            .has_scripts = false,
            .must_accept = false,
            .packs = &[_]Protocol.ResourcePackDescriptor{},
            .world_template_uuid = "00000000-0000-0000-0000-000000000000",
            .world_template_version = "",
        };
        const serialized = try packs.serialize(&str);
        try network.sendPacket(connection, serialized);
    }
}
