const std = @import("std");

const nethernet = @import("nethernet");
const protocol = @import("protocol");

const log = @import("../core/log.zig");
const connection_mod = @import("connection.zig");
const events_mod = @import("events.zig");
const port_mod = @import("port.zig");
const priority_mod = @import("priority.zig");

const Connection = connection_mod.Connection;
const SendPriority = priority_mod.SendPriority;

/// The advertisement type lives behind NetherNet's host config; the alias keeps this
/// file on the public surface of that module.
const ServerData = @FieldType(nethernet.server.Host.Config, "server_data");
const GameType = @FieldType(ServerData, "game_type");

pub const default_jwks_uri = "https://authorization.franchise.minecraft-services.net/.well-known/keys";

/// NetherNet's per-session send queue. The slab is allocated on the first send, so an idle
/// session only costs the descriptor array; a busy one is bounded by `outboxBytes`.
pub const outbox_slots: usize = 512;
pub const outbox_min_bytes: usize = 64 * 1024;

/// `Outbox.Message`: kind, offset and length.
pub const outbox_entry_bytes: usize = nethernet.server.Host.outbox_descriptor_bytes;

/// Worst case with both listeners active: 2 x 152 sessions.
pub const outbox_budget_bytes: usize = 80 * 1024 * 1024;

/// The outbox must hold one full message, which is the negotiated message size.
pub fn outboxBytes(max_message_size: u32) usize {
    return @max(@as(usize, max_message_size), outbox_min_bytes);
}

/// What Tecton tells the adapter. Everything here comes from `server.properties`.
pub const Config = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 19132,
    /// Port for the plain signaling listener: null follows `port`, 0 asks the kernel
    /// for one (the native front forwards to whatever it got).
    signaling_port: ?u16 = null,
    motd_port: u16 = 0,
    motd: []const u8 = "Tecton Server",
    level_name: []const u8 = "Bedrock level",
    gamemode: protocol.GameMode = .Survival,
    max_players: u32 = 120,
    online_mode: bool = false,
    jwks_uri: []const u8 = default_jwks_uri,
    identity_key: []const u8 = "server.key",
    /// A verified identity is required from every client, offline server or not.
    require_client_identity: bool = false,
    lan_discovery: bool = true,
    lan_port: u16 = 7551,
    /// Host the plain signaling listener binds to; empty follows `address`.
    signaling_bind: []const u8 = "",
    /// `ip:port` or `[ipv6]:port` announced to clients behind NAT.
    public_candidate: []const u8 = "",
    /// Comma-separated STUN/TURN URLs; TURN credentials follow the URL as `@user:pass`.
    ice_servers: []const u8 = "",
    /// Concurrent sessions; zero derives the cap from `max_players`.
    max_sessions: u32 = 0,
    max_message_size: u32 = 256 * 1024,
    transport_tick_ms: u32 = 10,
};

/// Where the adapter reports what the transport saw. Both callbacks run on NetherNet's
/// threads, so they only publish: the game tick is still the only place that runs game code.
pub const Deps = struct {
    registry: *connection_mod.ConnectionRegistry,
    events: *events_mod.Queue,
    publish: Publish,
    players: ?nethernet.server.PlayerSource = null,

    pub const Publish = struct {
        ctx: *anyopaque,
        packet: *const fn (ctx: *anyopaque, conn: *Connection, payload: []const u8) void,
    };
};

/// Delivers Tecton's frames through a NetherNet host. This is the only file in Tecton
/// that imports NetherNet.
pub const Adapter = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    deps: Deps,
    identity: nethernet.identity.ServerProvider,
    verifier: ?nethernet.identity.Verifier = null,
    ice_servers: []nethernet.web_rtc.IceServer = &.{},
    public_candidate: ?nethernet.sdp_edit.PublicCandidate = null,
    host: *nethernet.server.Host,
    alive: std.atomic.Value(bool) = .init(true),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: Config, deps: Deps) !*Adapter {
        const signal_host = if (config.signaling_bind.len > 0) config.signaling_bind else config.address;
        const signaling_port = config.signaling_port orelse config.port;
        const bind = std.Io.net.IpAddress.parse(signal_host, signaling_port) catch {
            log.err("NetherNet cannot bind signaling to {s}:{d}: invalid address", .{ signal_host, signaling_port });
            return error.InvalidAddress;
        };

        const ice_servers = parseIceServers(allocator, config.ice_servers) catch |err| {
            log.err("ice-servers={s} is invalid: {s}", .{ config.ice_servers, @errorName(err) });
            return err;
        };
        errdefer {
            for (ice_servers) |server| freeIceServer(allocator, server);
            allocator.free(ice_servers);
        }
        const public_candidate = parsePublicCandidate(allocator, config.public_candidate) catch |err| {
            log.err("public-candidate={s} is invalid: expected ip:port or [ipv6]:port", .{config.public_candidate});
            return err;
        };
        errdefer if (public_candidate) |candidate| allocator.free(candidate.address);

        const identity = nethernet.identity.ServerProvider.loadOrCreate(io, allocator, config.identity_key) catch |err| {
            log.err("NetherNet could not load the operator key {s}: {s}", .{ config.identity_key, @errorName(err) });
            return err;
        };
        var verifier: ?nethernet.identity.Verifier = null;
        if (config.online_mode) {
            verifier = nethernet.identity.Verifier.init(io, allocator, .{ .jwks_uri = config.jwks_uri }) catch |err| {
                log.err("online-mode needs a usable JWKS ({s}): {s}", .{ config.jwks_uri, @errorName(err) });
                return err;
            };
        }
        errdefer if (verifier) |*live| live.deinit();

        const self = try allocator.create(Adapter);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .config = config,
            .deps = deps,
            .identity = identity,
            .verifier = verifier,
            .ice_servers = ice_servers,
            .public_candidate = public_candidate,
            .host = undefined,
        };

        self.host = try nethernet.server.Host.init(io, allocator, hostConfig(config, self, bind));
        log.info("NetherNet listening on {s}:{d} (signaling), UDP {d} (motd) and UDP {d} (lan)", .{
            signal_host,
            self.host.signalingPort(),
            motdPort(config),
            if (config.lan_discovery) config.lan_port else 0,
        });
        return self;
    }

    pub fn signalingPort(self: *const Adapter) u16 {
        return self.host.signalingPort();
    }

    pub fn port(self: *Adapter) port_mod.Port {
        return .{
            .ctx = self,
            .send = sendBytes,
            .close = closeConn,
            .max_payload = maxPayload,
        };
    }

    pub fn start(self: *Adapter) !void {
        try self.host.start();
    }

    pub fn tick(self: *Adapter) void {
        self.host.tick();
    }

    pub fn stop(self: *Adapter) void {
        self.host.stop();
    }

    pub fn deinit(self: *Adapter) void {
        // Callbacks fired by `host.deinit` must not touch a Tecton that is going away.
        self.alive.store(false, .release);
        self.host.deinit();
        if (self.verifier) |*verifier| verifier.deinit();
        const allocator = self.allocator;
        for (self.ice_servers) |server| freeIceServer(allocator, server);
        if (self.ice_servers.len > 0) allocator.free(self.ice_servers);
        if (self.public_candidate) |candidate| allocator.free(candidate.address);
        allocator.destroy(self);
    }

    pub fn sessionCount(self: *const Adapter) usize {
        return self.host.connectionCount();
    }

    pub fn playerCount(self: *const Adapter) usize {
        return self.host.playerCount();
    }

    fn onOpen(raw: *anyopaque, session: *nethernet.web_rtc.PeerHandle) void {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        if (!self.alive.load(.acquire)) return;

        const conn = self.deps.registry.createWithId(session.id, session) catch |err| {
            log.err("NetherNet session {d} could not be registered: {s}", .{ session.id, @errorName(err) });
            return;
        };
        session.user_data = conn;
        conn.max_payload = self.host.sessionMaxMessageSize(session.id) orelse 0;
        log.info("NetherNet session {d} opened", .{conn.id});
    }

    fn onMessage(raw: *anyopaque, session: *nethernet.web_rtc.PeerHandle, kind: nethernet.web_rtc.ChannelKind, message: []const u8) ?[]const u8 {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        if (!self.alive.load(.acquire)) return null;
        // Every frame travels the reliable channel today; the kind is kept for the
        // unreliable path once the frame contract carries it.
        _ = kind;

        const conn = connectionOf(session) orelse return null;
        self.deps.publish.packet(self.deps.publish.ctx, conn, message);
        return null;
    }

    fn onClose(raw: *anyopaque, session: *nethernet.web_rtc.PeerHandle) void {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        const conn = connectionOf(session);
        // The session is gone either way; only a live adapter may touch the game's registry.
        session.user_data = null;
        if (!self.alive.load(.acquire)) return;

        const closed = conn orelse return;
        // The release can destroy the connection when no player holds it.
        const id = closed.id;
        self.deps.registry.closeAndRelease(closed);
        log.info("NetherNet session {d} closed", .{id});
    }

    fn connectionOf(session: *nethernet.web_rtc.PeerHandle) ?*Connection {
        const raw = session.user_data orelse return null;
        return @ptrCast(@alignCast(raw));
    }

    fn sendBytes(raw: *anyopaque, conn: *Connection, bytes: []const u8, channel: port_mod.Channel, priority: SendPriority) port_mod.SendError!void {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        if (!self.alive.load(.acquire)) return error.Closed;
        if (!conn.isOpen()) return error.Closed;
        // NetherNet has no priority knob: the outbox is ordered per session.
        _ = priority;

        const kind: nethernet.web_rtc.ChannelKind = switch (channel) {
            .reliable => .reliable,
            .unreliable => .unreliable,
        };
        self.host.send(conn.id, kind, bytes) catch |err| return switch (err) {
            error.UnknownSession, error.Closed => error.Closed,
            error.Backpressure => error.Backpressure,
            error.PayloadTooLarge => error.PayloadTooLarge,
        };
    }

    fn closeConn(raw: *anyopaque, conn: *Connection, mode: port_mod.CloseMode) void {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        if (!self.alive.load(.acquire)) return;
        switch (mode) {
            .flush => self.host.closeSession(conn.id),
            .abort => self.host.abortSession(conn.id),
        }
    }

    fn maxPayload(raw: *anyopaque, conn: *Connection) usize {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        if (!self.alive.load(.acquire)) return 0;
        return if (conn.max_payload != 0)
            conn.max_payload
        else
            self.host.sessionMaxMessageSize(conn.id) orelse 0;
    }

    fn countPlayers(raw: *anyopaque) usize {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        return self.playerCount();
    }
};

/// The advertisement the client reads before it joins. `protocol` and `game_version`
/// are Tecton's, not the transport defaults: a client whose build does not match would
/// be turned away after the handshake.
fn motdPort(config: Config) u16 {
    return if (config.motd_port == 0) config.port else config.motd_port;
}

pub fn serverData(config: Config) ServerData {
    return .{
        .server_name = config.motd,
        .protocol = @intCast(protocol.PROTOCOL),
        .game_version = protocol.MINECRAFT_VERSION,
        .level_name = config.level_name,
        .player_count = 0,
        .max_player_count = @intCast(@min(config.max_players, std.math.maxInt(i32))),
        .game_type = gameType(config.gamemode),
        .accepts_online_auth = config.online_mode,
    };
}

pub fn gameType(mode: protocol.GameMode) GameType {
    return switch (mode) {
        .Survival, .SurvivalSpectator => .survival,
        .Creative, .CreativeSpectator => .creative,
        // NetherNet advertises three modes; a spectator world is sent as adventure.
        .Adventure, .Spectator, .Fallback => .adventure,
    };
}

fn freeIceServer(allocator: std.mem.Allocator, server: nethernet.web_rtc.IceServer) void {
    allocator.free(server.url);
    allocator.free(server.username);
    allocator.free(server.credential);
}

/// `stun:host:port, turn:host:port@user:pass`. TURN credentials are required by most
/// relays, so they travel with the entry instead of a second property.
fn parseIceServers(allocator: std.mem.Allocator, text: []const u8) ![]nethernet.web_rtc.IceServer {
    var servers: std.ArrayList(nethernet.web_rtc.IceServer) = .empty;
    errdefer {
        for (servers.items) |server| freeIceServer(allocator, server);
        servers.deinit(allocator);
    }

    var entries = std.mem.splitScalar(u8, text, ',');
    while (entries.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) continue;

        var url_text = entry;
        var username: []const u8 = "";
        var credential: []const u8 = "";
        if (std.mem.indexOfScalar(u8, entry, '@')) |at| {
            url_text = entry[0..at];
            const credentials = entry[at + 1 ..];
            const colon = std.mem.indexOfScalar(u8, credentials, ':') orelse return error.InvalidIceServer;
            username = credentials[0..colon];
            credential = credentials[colon + 1 ..];
        }
        // TLS-wrapped ICE (`stuns:`/`turns:`) is not supported by the peer stack.
        if (!std.mem.startsWith(u8, url_text, "stun:") and !std.mem.startsWith(u8, url_text, "turn:")) {
            return error.InvalidIceServer;
        }

        const url = try allocator.dupe(u8, url_text);
        errdefer allocator.free(url);
        const user = try allocator.dupe(u8, username);
        errdefer allocator.free(user);
        const pass = try allocator.dupe(u8, credential);
        errdefer allocator.free(pass);
        try servers.append(allocator, .{ .url = url, .username = user, .credential = pass });
    }

    return servers.toOwnedSlice(allocator);
}

fn parsePublicCandidate(allocator: std.mem.Allocator, text: []const u8) !?nethernet.sdp_edit.PublicCandidate {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;

    var host: []const u8 = undefined;
    var port_text: []const u8 = undefined;
    if (trimmed[0] == '[') {
        const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return error.InvalidPublicCandidate;
        if (close + 1 >= trimmed.len or trimmed[close + 1] != ':') return error.InvalidPublicCandidate;
        host = trimmed[1..close];
        port_text = trimmed[close + 2 ..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return error.InvalidPublicCandidate;
        host = trimmed[0..colon];
        port_text = trimmed[colon + 1 ..];
    }

    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidPublicCandidate;
    const address = try allocator.dupe(u8, host);
    errdefer allocator.free(address);
    const candidate = nethernet.sdp_edit.PublicCandidate{ .address = address, .port = port };
    nethernet.sdp_edit.validateCandidate(candidate) catch return error.InvalidPublicCandidate;
    return candidate;
}

fn hostConfig(config: Config, self: *Adapter, bind: std.Io.net.IpAddress) nethernet.server.Host.Config {
    const requested_sessions = if (config.max_sessions != 0)
        @as(usize, config.max_sessions)
    else
        @as(usize, config.max_players) + 32;
    const max_sessions: usize = std.math.clamp(requested_sessions, 64, 4096);
    const players = self.deps.players orelse nethernet.server.PlayerSource{ .ctx = self, .count = Adapter.countPlayers };
    return .{
        .server_data = serverData(config),
        .paths = .{ .http = true, .lan = config.lan_discovery, .motd = true },
        .handler = .{
            .ctx = self,
            .on_open = Adapter.onOpen,
            .on_message = Adapter.onMessage,
            .on_close = Adapter.onClose,
        },
        // A transport that echoes turns every frame into two; Tecton answers itself.
        .echo_packets = false,
        .max_message_size = config.max_message_size,
        .http_config = .{
            .bind_address = bind,
            .max_sessions = max_sessions,
            // One transport thread: the inbound ring is single-producer, so a second shard
            // would corrupt it without an MPSC publish path.
            .tick_shards = 1,
            .tick_interval_ms = config.transport_tick_ms,
            .max_concurrent_requests = 16,
            .outbox_slots = outbox_slots,
            .outbox_bytes = outboxBytes(config.max_message_size),
        },
        .lan_config = .{
            .port = config.lan_port,
            .max_pending_connections = max_sessions,
            .outbox_slots = outbox_slots,
            .outbox_bytes = outboxBytes(config.max_message_size),
        },
        .motd_config = .{ .port = motdPort(config) },
        .identity = self.identity,
        .identity_verifier = if (self.verifier) |*verifier| verifier else null,
        .accept_unverified_identity = !config.online_mode and !config.require_client_identity,
        .require_client_identity = config.require_client_identity,
        .ice_servers = self.ice_servers,
        .public_candidate = self.public_candidate,
        .spawn_ticker = false,
        .player_source = players,
    };
}

const testing = std.testing;

const PublishSink = struct {
    calls: usize = 0,

    fn packet(ctx: *anyopaque, _: *Connection, _: []const u8) void {
        const self: *PublishSink = @ptrCast(@alignCast(ctx));
        self.calls += 1;
    }
};

/// The registry and the adapter hold pointers into the fixture, so it lives on the heap:
/// a copy would leave both pointing at the frame that built it.
const Fixture = struct {
    events: events_mod.Queue,
    registry: connection_mod.ConnectionRegistry,
    sink: PublishSink = .{},
    adapter: *Adapter,

    fn create(key_path: []const u8) !*Fixture {
        return createWith(key_path, .{});
    }

    fn createWith(key_path: []const u8, options: struct {
        lan_discovery: bool = false,
        max_message_size: u32 = 256 * 1024,
    }) !*Fixture {
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);

        self.* = .{
            .events = events_mod.Queue.init(testing.io, testing.allocator),
            .registry = undefined,
            .adapter = undefined,
        };
        self.registry = connection_mod.ConnectionRegistry.init(testing.allocator, testing.io, &self.events);
        errdefer self.registry.deinit();
        self.adapter = try Adapter.init(testing.io, testing.allocator, .{
            .address = "127.0.0.1",
            .port = 0,
            .motd = "adapter test",
            .level_name = "world",
            .lan_discovery = options.lan_discovery,
            .lan_port = 0,
            .max_message_size = options.max_message_size,
            .identity_key = key_path,
        }, .{
            .registry = &self.registry,
            .events = &self.events,
            .publish = .{ .ctx = &self.sink, .packet = PublishSink.packet },
        });
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.adapter.deinit();
        self.registry.deinit();
        self.events.deinit();
        testing.allocator.destroy(self);
    }
};

test "an offline adapter binds without a verifier and leaves the ticking to Tecton" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var key_buffer: [256]u8 = undefined;
    const key_path = try std.fmt.bufPrint(&key_buffer, ".zig-cache/tmp/{s}/server.key", .{tmp.sub_path});

    const fixture = try Fixture.create(key_path);
    defer fixture.destroy();
    const adapter = fixture.adapter;

    try testing.expect(adapter.verifier == null);
    try testing.expect(!adapter.host.config.echo_packets);
    try testing.expect(!adapter.host.config.spawn_ticker);
    try testing.expectEqualStrings("adapter test", adapter.host.config.server_data.server_name);
    try testing.expectEqualStrings("world", adapter.host.config.server_data.level_name);
    try testing.expectEqual(GameType.survival, adapter.host.config.server_data.game_type);
    try testing.expectEqual(@as(u32, 256 * 1024), adapter.host.config.max_message_size);
    try testing.expectEqual(@as(usize, 1), adapter.host.config.http_config.tick_shards);
    try testing.expectEqual(outbox_slots, adapter.host.http.?.config.outbox_slots);
    try testing.expectEqual(outboxBytes(256 * 1024), adapter.host.http.?.config.outbox_bytes);
    try testing.expect(!adapter.host.config.require_client_identity.?);
    try testing.expect(adapter.host.config.accept_unverified_identity);

    const strict = hostConfig(.{ .require_client_identity = true, .max_sessions = 128 }, adapter, adapter.host.config.http_config.bind_address);
    try testing.expect(strict.require_client_identity.?);
    try testing.expect(!strict.accept_unverified_identity);
    try testing.expectEqual(@as(usize, 128), strict.http_config.max_sessions);

    try adapter.start();
    try testing.expect(adapter.host.run_thread == null);
    adapter.tick();
    adapter.stop();

    const key_file = try std.Io.Dir.cwd().openFile(testing.io, key_path, .{});
    key_file.close(testing.io);
}

test "the outbox settings reach both listener configs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var key_buffer: [256]u8 = undefined;
    const key_path = try std.fmt.bufPrint(&key_buffer, ".zig-cache/tmp/{s}/server.key", .{tmp.sub_path});

    const fixture = try Fixture.createWith(key_path, .{ .lan_discovery = true, .max_message_size = 64 * 1024 });
    defer fixture.destroy();

    const http = fixture.adapter.host.http.?.config;
    const lan = fixture.adapter.host.lan.?.config;
    try testing.expectEqual(outbox_slots, http.outbox_slots);
    try testing.expectEqual(outboxBytes(64 * 1024), http.outbox_bytes);
    try testing.expectEqual(outbox_slots, lan.outbox_slots);
    try testing.expectEqual(outboxBytes(64 * 1024), lan.outbox_bytes);

    const sessions: usize = 152;
    const per_listener = sessions * (http.outbox_bytes + http.outbox_slots * outbox_entry_bytes);
    try testing.expect(per_listener <= 40 * 1024 * 1024);
    try testing.expect(2 * per_listener <= outbox_budget_bytes);
}

test "the port closes a session the host never adopted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var key_buffer: [256]u8 = undefined;
    const key_path = try std.fmt.bufPrint(&key_buffer, ".zig-cache/tmp/{s}/server.key", .{tmp.sub_path});

    const fixture = try Fixture.create(key_path);
    defer fixture.destroy();

    var backend: u128 = 0;
    const conn = try fixture.registry.createWithId(7, &backend);
    conn.retain();
    defer conn.release();

    try testing.expectError(error.Closed, fixture.adapter.port().sendBytes(conn, "frame", .reliable, .normal));
    try testing.expectEqual(@as(usize, 0), fixture.adapter.port().maxPayload(conn));
    try testing.expectEqual(@as(usize, 0), fixture.adapter.sessionCount());
}

test "the advertisement carries Tecton's protocol and level, not the transport's" {
    const data = serverData(.{
        .motd = "Tecton test",
        .level_name = "world",
        .max_players = 40,
        .gamemode = .Creative,
        .online_mode = true,
    });
    try testing.expectEqualStrings("Tecton test", data.server_name);
    try testing.expectEqualStrings("world", data.level_name);
    try testing.expectEqual(@as(i32, @intCast(protocol.PROTOCOL)), data.protocol);
    try testing.expectEqualStrings(protocol.MINECRAFT_VERSION, data.game_version);
    try testing.expectEqual(@as(i32, 40), data.max_player_count);
    try testing.expectEqual(GameType.creative, data.game_type);
    try testing.expect(data.accepts_online_auth);
}

test "the outbox budget follows the message cap and never drops below its floor" {
    try testing.expectEqual(@as(usize, 256 * 1024), outboxBytes(256 * 1024));
    try testing.expectEqual(@as(usize, 128 * 1024), outboxBytes(128 * 1024));
    try testing.expectEqual(outbox_min_bytes, outboxBytes(1024));

    // Both listeners keep their own max-sessions (152 each), so the worst case is 2 x 152.
    const sessions: usize = 152;
    const per_listener = sessions * (outboxBytes(256 * 1024) + outbox_slots * outbox_entry_bytes);
    try testing.expect(per_listener <= 40 * 1024 * 1024);
    try testing.expect(2 * per_listener <= outbox_budget_bytes);
}

test "spectator is advertised as adventure" {
    try testing.expectEqual(GameType.adventure, gameType(.Spectator));
    try testing.expectEqual(GameType.survival, gameType(.Survival));
}

test "ice servers parse with optional turn credentials" {
    const servers = try parseIceServers(testing.allocator, " stun:stun.example.org:3478 , turn:relay.example.org:3478@alice:secret");
    defer {
        for (servers) |server| freeIceServer(testing.allocator, server);
        testing.allocator.free(servers);
    }

    try testing.expectEqual(@as(usize, 2), servers.len);
    try testing.expectEqualStrings("stun:stun.example.org:3478", servers[0].url);
    try testing.expectEqualStrings("", servers[0].username);
    try testing.expectEqualStrings("turn:relay.example.org:3478", servers[1].url);
    try testing.expectEqualStrings("alice", servers[1].username);
    try testing.expectEqualStrings("secret", servers[1].credential);

    try testing.expectError(error.InvalidIceServer, parseIceServers(testing.allocator, "http://example.org"));
    try testing.expectError(error.InvalidIceServer, parseIceServers(testing.allocator, "turn:relay.example.org@alice"));
    const empty = try parseIceServers(testing.allocator, "  ");
    testing.allocator.free(empty);
}

test "the public candidate accepts both address families and rejects bare hosts" {
    const ipv4 = (try parsePublicCandidate(testing.allocator, "203.0.113.7:19132")).?;
    defer testing.allocator.free(ipv4.address);
    try testing.expectEqualStrings("203.0.113.7", ipv4.address);
    try testing.expectEqual(@as(u16, 19132), ipv4.port);

    const ipv6 = (try parsePublicCandidate(testing.allocator, "[2001:db8::1]:19133")).?;
    defer testing.allocator.free(ipv6.address);
    try testing.expectEqualStrings("2001:db8::1", ipv6.address);
    try testing.expectEqual(@as(u16, 19133), ipv6.port);

    try testing.expect((try parsePublicCandidate(testing.allocator, "")) == null);
    try testing.expectError(error.InvalidPublicCandidate, parsePublicCandidate(testing.allocator, "203.0.113.7"));
    try testing.expectError(error.InvalidPublicCandidate, parsePublicCandidate(testing.allocator, "203.0.113.7:0"));
}

test "a player count past the protocol field is clamped, not wrapped" {
    const data = serverData(.{ .max_players = std.math.maxInt(u32) });
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), data.max_player_count);
}

test "a transport close after the adapter is down never touches the registry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var key_buffer: [256]u8 = undefined;
    const key_path = try std.fmt.bufPrint(&key_buffer, ".zig-cache/tmp/{s}/server.key", .{tmp.sub_path});

    const fixture = try Fixture.create(key_path);
    defer fixture.destroy();

    var backend: u128 = 0;
    const conn = try fixture.registry.createWithId(7, &backend);
    // Stands in for the player reference: the object must outlive the transport close.
    conn.retain();
    defer conn.release();

    var handle = nethernet.web_rtc.PeerHandle{ .id = 7, .peer = undefined, .user_data = conn };

    fixture.adapter.alive.store(false, .release);
    Adapter.onClose(fixture.adapter, &handle);
    try testing.expect(handle.user_data == null);
    try testing.expect(fixture.registry.get(7).? == conn);
    try testing.expect(conn.isOpen());

    fixture.adapter.alive.store(true, .release);
    handle.user_data = conn;
    Adapter.onClose(fixture.adapter, &handle);
    try testing.expect(!conn.isOpen());
    try testing.expect(fixture.registry.get(7) == null);

    handle.user_data = conn;
    Adapter.onClose(fixture.adapter, &handle);

    var drained: std.ArrayList(events_mod.Event) = .empty;
    defer drained.deinit(testing.allocator);
    fixture.events.drain(&drained);
    try testing.expectEqual(@as(usize, 2), drained.items.len);
    try testing.expectEqual(@as(u64, 7), drained.items[0].opened);
    try testing.expectEqual(@as(u64, 7), drained.items[1].closed);
}
