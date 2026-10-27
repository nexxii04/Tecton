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

/// What Tecton tells the adapter. Everything here comes from `server.properties`.
pub const Config = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 19132,
    motd: []const u8 = "Tecton Server",
    level_name: []const u8 = "Bedrock level",
    gamemode: protocol.GameMode = .Survival,
    max_players: u32 = 120,
    online_mode: bool = false,
    jwks_uri: []const u8 = default_jwks_uri,
    identity_key: []const u8 = "server.key",
    lan_discovery: bool = true,
    lan_port: u16 = 7551,
    max_message_size: u32 = 256 * 1024,
    transport_tick_ms: u32 = 10,
    outbox_slots: u32 = 512,
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
    host: *nethernet.server.Host,
    alive: std.atomic.Value(bool) = .init(true),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: Config, deps: Deps) !*Adapter {
        const bind = std.Io.net.IpAddress.parse(config.address, config.port) catch {
            log.err("NetherNet cannot bind {s}:{d}: invalid address", .{ config.address, config.port });
            return error.InvalidAddress;
        };

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
            .host = undefined,
        };

        self.host = try nethernet.server.Host.init(io, allocator, hostConfig(config, self, bind));
        log.info("NetherNet listening on {s}:{d} (signaling), UDP {d} (motd) and UDP {d} (lan)", .{
            config.address,
            config.port,
            config.port,
            if (config.lan_discovery) config.lan_port else 0,
        });
        return self;
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

    fn sendBytes(raw: *anyopaque, conn: *Connection, bytes: []const u8, priority: SendPriority) port_mod.SendError!void {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        if (!self.alive.load(.acquire)) return error.Closed;
        if (!conn.isOpen()) return error.Closed;
        // NetherNet has no priority knob: the outbox is ordered per session.
        _ = priority;

        self.host.send(conn.id, .reliable, bytes) catch |err| return switch (err) {
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
        return self.host.sessionMaxMessageSize(conn.id) orelse 0;
    }

    fn countPlayers(raw: *anyopaque) usize {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        return self.playerCount();
    }
};

/// The advertisement the client reads before it joins. `protocol` and `game_version`
/// are Tecton's, not the transport defaults: a client whose build does not match would
/// be turned away after the handshake.
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

fn hostConfig(config: Config, self: *Adapter, bind: std.Io.net.IpAddress) nethernet.server.Host.Config {
    const max_sessions: usize = @max(64, @as(usize, config.max_players) + 32);
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
            .tick_shards = 1,
            .tick_interval_ms = config.transport_tick_ms,
            .max_concurrent_requests = 16,
        },
        .lan_config = .{
            .port = config.lan_port,
            .max_pending_connections = max_sessions,
        },
        .motd_config = .{ .port = config.port },
        .identity = self.identity,
        .identity_verifier = if (self.verifier) |*verifier| verifier else null,
        .accept_unverified_identity = !config.online_mode,
        .require_client_identity = config.online_mode,
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
            .lan_discovery = false,
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

    try adapter.start();
    try testing.expect(adapter.host.run_thread == null);
    adapter.tick();
    adapter.stop();

    const key_file = try std.Io.Dir.cwd().openFile(testing.io, key_path, .{});
    key_file.close(testing.io);
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

    try testing.expectError(error.Closed, fixture.adapter.port().sendBytes(conn, "frame", .normal));
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

test "spectator is advertised as adventure" {
    try testing.expectEqual(GameType.adventure, gameType(.Spectator));
    try testing.expectEqual(GameType.survival, gameType(.Survival));
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
