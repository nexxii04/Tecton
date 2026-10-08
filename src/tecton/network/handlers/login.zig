const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const Events = @import("../../events/root.zig");
const Player = @import("../../player/player.zig").Player;
const auth = @import("../auth/root.zig");
const NetworkHandler = @import("../network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const PlayerLog = @import("../player_log.zig");
const offline_identity = @import("../offline_identity.zig");

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

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const Protocol = test_owner.Protocol;
    pub const offline_identity = test_owner.offline_identity;
    pub const applyOfflineIdentity = test_owner.applyOfflineIdentity;
    pub const applyVerifiedIdentity = test_owner.applyVerifiedIdentity;
    pub const Policy = test_owner.Policy;
    pub const policyFor = test_owner.policyFor;
    pub const chainTokens = test_owner.chainTokens;
    pub const testing = test_owner.testing;
    pub const testJwt = test_owner.testJwt;
    pub const testChain = test_owner.testChain;
    pub const testVerified = test_owner.testVerified;
};

test "a chain that claims someone else's identity is replaced by one derived from the name" {
    try @import("login_test.zig").Suite(test_scope).case_000();
}

test "the same name always lands on the same identity" {
    try @import("login_test.zig").Suite(test_scope).case_001();
}

test "a verified identity replaces every claim the client made" {
    try @import("login_test.zig").Suite(test_scope).case_002();
}

test "an online login that did not verify is refused unless the fallback is on" {
    try @import("login_test.zig").Suite(test_scope).case_003();
}

test "only a certificate chain produces chain tokens" {
    try @import("login_test.zig").Suite(test_scope).case_004();
}

test "a display name outside the offline rules is refused before anything is replaced" {
    try @import("login_test.zig").Suite(test_scope).case_005();
}
