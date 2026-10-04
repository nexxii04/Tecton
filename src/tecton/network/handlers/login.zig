const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const Events = @import("../../events/root.zig");
const Player = @import("../../player/player.zig").Player;
const auth = @import("../auth/root.zig");
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const PlayerLog = @import("../player-log.zig");
const offline_identity = @import("../offline-identity.zig");

fn applyOfflineIdentity(allocator: std.mem.Allocator, data: *Protocol.Login.Decoder.LoginData) !void {
    try offline_identity.validateDisplayName(data.identity_data.display_name);

    const derived = try offline_identity.uuidForDisplayName(allocator, data.identity_data.display_name);
    if (data.identity_data.identity.len > 0) allocator.free(data.identity_data.identity);
    data.identity_data.identity = derived;

    if (data.identity_data.xuid.len > 0) allocator.free(data.identity_data.xuid);
    data.identity_data.xuid = "";
}

fn applyVerifiedIdentity(
    allocator: std.mem.Allocator,
    data: *Protocol.Login.Decoder.LoginData,
    verified: *const auth.Verified,
) !void {
    const xuid = try allocator.dupe(u8, verified.identity.xuid);
    errdefer allocator.free(xuid);
    const display_name = try allocator.dupe(u8, verified.identity.display_name);
    errdefer allocator.free(display_name);
    const uuid = try allocator.dupe(u8, verified.identity.uuid);
    errdefer allocator.free(uuid);
    const title_id = try allocator.dupe(u8, verified.identity.title_id);
    errdefer allocator.free(title_id);

    data.identity_data.deinit(allocator);
    data.identity_data = .{
        .xuid = xuid,
        .display_name = display_name,
        .identity = uuid,
        .title_id = title_id,
    };
}

const Resolution = enum { verified, offline };

const Policy = enum { offline, reject };

fn policyFor(online_mode: bool, allow_offline_fallback: bool) Policy {
    if (!online_mode) return .offline;
    return if (allow_offline_fallback) .offline else .reject;
}

fn chainTokens(
    allocator: std.mem.Allocator,
    data: *const Protocol.Login.Decoder.LoginData,
) ![]const []const u8 {
    const parsed = data.cert_parsed orelse return &.{};
    if (parsed.value != .object) return &.{};
    const chain = parsed.value.object.get("chain") orelse return &.{};
    if (chain != .array or chain.array.items.len == 0) return &.{};

    const tokens = try allocator.alloc([]const u8, chain.array.items.len);
    errdefer allocator.free(tokens);
    for (chain.array.items, 0..) |item, index| {
        if (item != .string) return error.InvalidLoginChain;
        tokens[index] = item.string;
    }
    return tokens;
}

fn resolveIdentity(
    tecton: *Tecton,
    network: *NetworkHandler,
    data: *Protocol.Login.Decoder.LoginData,
    client_data_token: []const u8,
) !Resolution {
    const config = tecton.config;
    if (!config.online_mode) {
        try applyOfflineIdentity(network.allocator, data);
        return .offline;
    }

    const service = if (tecton.auth_service) |*service| service else return error.OnlineModeWithoutService;
    const token = try chainTokens(network.allocator, data);
    defer if (token.len > 0) network.allocator.free(token);

    const now = std.Io.Timestamp.now(tecton.io, .real).toSeconds();
    var verified = service.verifyLogin(.{
        .authentication_type = data.authentication_type,
        .chain = token,
        .multiplayer_token = data.token,
        .client_data_token = client_data_token,
    }, now) catch |err| {
        if (policyFor(true, config.online_mode_offline_fallback) == .reject) return err;
        Raknet.Logger.WARN("Unverified login let in as an offline identity: {s}", .{@errorName(err)});
        try applyOfflineIdentity(network.allocator, data);
        return .offline;
    };
    defer verified.deinit(network.allocator);

    try applyVerifiedIdentity(network.allocator, data, &verified);
    return .verified;
}

fn sendPlayStatus(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    status: Protocol.PlayStatusEnum,
) void {
    var str = BinaryStream.init(network.allocator, null, null);
    defer str.deinit();
    var packet = Protocol.PlayStatusPacket{ .status = status };
    if (packet.serialize(&str)) |serialized| {
        network.sendPacket(connection, serialized) catch {};
    } else |_| {}
}

pub fn handleLogin(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
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

    const player_count = tecton.getPlayerCount();
    if (player_count >= tecton.config.max_players) {
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
        sendPlayStatus(network, connection, .FailedClient);
        return;
    };
    errdefer {
        data.deinit();
        sendPlayStatus(network, connection, .FailedClient);
    }

    const resolution = resolveIdentity(tecton, network, &data, login.client) catch |err| {
        // Never log the rejected name itself: it is attacker-controlled bytes.
        Raknet.Logger.WARN("Rejected login: {s}", .{@errorName(err)});
        data.deinit();
        sendPlayStatus(network, connection, .FailedClient);
        return;
    };

    sendPlayStatus(network, connection, .LoginSuccess);

    if (tecton.ban_manager.isBanned(data.identity_data.display_name) or
        tecton.ban_manager.isBannedByXuid(data.identity_data.xuid))
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
        tecton,
        data,
        &tecton.player_entity_type,
    );

    var event = Events.types.PlayerJoinEvent{
        .player = player,
    };
    if (!tecton.events.emit(.PlayerJoin, &event)) {
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

    try tecton.addPlayer(player);
    PlayerLog.logJoin(data.identity_data.display_name, resolution == .verified);

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

const testing = std.testing;

fn testJwt(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header = "{\"alg\":\"ES384\"}";
    const signature = [_]u8{0} ** 96;

    const total = encoder.calcSize(header.len) + 1 +
        encoder.calcSize(payload.len) + 1 +
        encoder.calcSize(signature.len);
    const token = try allocator.alloc(u8, total);
    errdefer allocator.free(token);

    var offset: usize = 0;
    offset += encoder.encode(token[offset..], header).len;
    token[offset] = '.';
    offset += 1;
    offset += encoder.encode(token[offset..], payload).len;
    token[offset] = '.';
    offset += 1;
    offset += encoder.encode(token[offset..], &signature).len;
    std.debug.assert(offset == total);
    return token;
}

fn testChain(allocator: std.mem.Allocator, xuid: []const u8, name: []const u8, claimed_uuid: ?[]const u8) !struct { chain: []u8, client: []u8 } {
    const payload = if (claimed_uuid) |uuid|
        try std.fmt.allocPrint(
            allocator,
            "{{\"xid\":\"{s}\",\"xname\":\"{s}\",\"tid\":\"89692877\",\"leguuid\":\"{s}\",\"cpk\":\"AQ==\"}}",
            .{ xuid, name, uuid },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{{\"xid\":\"{s}\",\"xname\":\"{s}\",\"tid\":\"89692877\",\"cpk\":\"AQ==\"}}",
            .{ xuid, name },
        );
    defer allocator.free(payload);

    const token = try testJwt(allocator, payload);
    defer allocator.free(token);

    return .{
        .chain = try std.fmt.allocPrint(allocator, "{{\"AuthenticationType\":1,\"Token\":\"{s}\"}}", .{token}),
        .client = try testJwt(allocator, "{\"SkinId\":\"Standard_Custom\",\"DeviceOS\":7}"),
    };
}

test "a chain that claims someone else's identity is replaced by one derived from the name" {
    const allocator = testing.allocator;
    const victim_uuid = "00000000-0000-4000-8000-000000000123";
    const victim_xuid = "2533274799999999";

    const tokens = try testChain(allocator, victim_xuid, "LoadBot", victim_uuid);
    defer allocator.free(tokens.chain);
    defer allocator.free(tokens.client);

    var data = try Protocol.Login.Decoder.decodeLoginChain(allocator, tokens.chain, tokens.client);
    defer data.deinit();

    try testing.expectEqualStrings(victim_uuid, data.identity_data.identity);
    try testing.expectEqualStrings(victim_xuid, data.identity_data.xuid);

    try applyOfflineIdentity(allocator, &data);

    const expected = try offline_identity.uuidForDisplayName(allocator, "LoadBot");
    defer allocator.free(expected);

    try testing.expectEqualStrings(expected, data.identity_data.identity);
    try testing.expect(!std.mem.eql(u8, victim_uuid, data.identity_data.identity));
    try testing.expectEqual(@as(usize, 0), data.identity_data.xuid.len);
    try testing.expectEqualStrings("LoadBot", data.identity_data.display_name);
}

test "the same name always lands on the same identity" {
    const allocator = testing.allocator;

    const first = try testChain(allocator, "2533274799999999", "Steve", null);
    defer allocator.free(first.chain);
    defer allocator.free(first.client);
    const second = try testChain(allocator, "9999999999999999", "Steve", "00000000-0000-4000-8000-000000000456");
    defer allocator.free(second.chain);
    defer allocator.free(second.client);

    var first_data = try Protocol.Login.Decoder.decodeLoginChain(allocator, first.chain, first.client);
    defer first_data.deinit();
    var second_data = try Protocol.Login.Decoder.decodeLoginChain(allocator, second.chain, second.client);
    defer second_data.deinit();

    try applyOfflineIdentity(allocator, &first_data);
    try applyOfflineIdentity(allocator, &second_data);

    try testing.expectEqualStrings(first_data.identity_data.identity, second_data.identity_data.identity);
}

fn testVerified(allocator: std.mem.Allocator) !auth.Verified {
    const secret = std.crypto.sign.ecdsa.EcdsaP384Sha384.SecretKey.fromBytes([_]u8{11} ** 48) catch unreachable;
    const key_pair = std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair.fromSecretKey(secret) catch unreachable;
    return .{
        .identity = try auth.identity.build(allocator, .{
            .xuid = "2533274799999999",
            .display_name = "Verified",
            .claimed_uuid = "",
            .title_id = "20CA2",
            .source = .multiplayer_token,
            .require_xuid = true,
        }),
        .client_public_key = try auth.signature.Secp384PublicKey.fromSec1(
            &key_pair.public_key.toUncompressedSec1(),
        ),
    };
}

test "a verified identity replaces every claim the client made" {
    const allocator = testing.allocator;
    const tokens = try testChain(allocator, "9999999999999999", "Victim", "00000000-0000-4000-8000-000000000123");
    defer allocator.free(tokens.chain);
    defer allocator.free(tokens.client);

    var data = try Protocol.Login.Decoder.decodeLoginChain(allocator, tokens.chain, tokens.client);
    defer data.deinit();

    var verified = try testVerified(allocator);
    defer verified.deinit(allocator);
    try applyVerifiedIdentity(allocator, &data, &verified);

    try testing.expectEqualStrings("2533274799999999", data.identity_data.xuid);
    try testing.expectEqualStrings("Verified", data.identity_data.display_name);
    try testing.expectEqualStrings(verified.identity.uuid, data.identity_data.identity);
    try testing.expectEqualStrings("20CA2", data.identity_data.title_id);
    try testing.expect(!std.mem.eql(u8, "00000000-0000-4000-8000-000000000123", data.identity_data.identity));
}

test "an online login that did not verify is refused unless the fallback is on" {
    try testing.expectEqual(Policy.offline, policyFor(false, false));
    try testing.expectEqual(Policy.offline, policyFor(false, true));
    try testing.expectEqual(Policy.reject, policyFor(true, false));
    try testing.expectEqual(Policy.offline, policyFor(true, true));
}

test "only a certificate chain produces chain tokens" {
    const allocator = testing.allocator;

    const oidc = try testChain(allocator, "2533274799999999", "Steve", null);
    defer allocator.free(oidc.chain);
    defer allocator.free(oidc.client);
    var oidc_data = try Protocol.Login.Decoder.decodeLoginChain(allocator, oidc.chain, oidc.client);
    defer oidc_data.deinit();
    try testing.expectEqual(@as(usize, 0), (try chainTokens(allocator, &oidc_data)).len);

    const last = try testJwt(
        allocator,
        "{\"identityPublicKey\":\"AQ==\",\"extraData\":{\"XUID\":\"2533274799999999\"," ++
            "\"displayName\":\"Steve\",\"identity\":\"00000000-0000-4000-8000-000000000001\",\"titleId\":\"89692877\"}}",
    );
    defer allocator.free(last);
    const chain_json = try std.fmt.allocPrint(
        allocator,
        "{{\"AuthenticationType\":2,\"Certificate\":\"{{\\\"chain\\\":[\\\"first\\\",\\\"{s}\\\"]}}\"}}",
        .{last},
    );
    defer allocator.free(chain_json);

    var chain_data = try Protocol.Login.Decoder.decodeLoginChain(allocator, chain_json, oidc.client);
    defer chain_data.deinit();
    const tokens = try chainTokens(allocator, &chain_data);
    defer allocator.free(tokens);
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqualStrings("first", tokens[0]);
    try testing.expectEqualStrings(last, tokens[1]);
}

test "a display name outside the offline rules is refused before anything is replaced" {
    const allocator = testing.allocator;

    const tokens = try testChain(allocator, "2533274799999999", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", null);
    defer allocator.free(tokens.chain);
    defer allocator.free(tokens.client);

    var data = try Protocol.Login.Decoder.decodeLoginChain(allocator, tokens.chain, tokens.client);
    defer data.deinit();

    try testing.expectError(error.DisplayNameTooLong, applyOfflineIdentity(allocator, &data));
    try testing.expectEqual(@as(usize, 36), data.identity_data.identity.len);
}
