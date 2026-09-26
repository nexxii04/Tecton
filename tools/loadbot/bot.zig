const std = @import("std");

const Raknet = @import("Raknet");
const Protocol = @import("protocol");
const BinaryStream = @import("BinaryStream").BinaryStream;

const framing = @import("framing.zig");
const identity = @import("identity.zig");

/// Not re-exported by protocol, so taken from the packet that carries it.
const InputDataBits = @TypeOf(@as(Protocol.PlayerAuthInputPacket, undefined).input_data);

pub const Stage = enum(u8) {
    connecting,
    requesting_settings,
    authenticating,
    joining,
    active,
    closed,
};

pub const Layout = enum {
    /// Every bot in one chunk: worst-case movement fan-out.
    cluster,
    /// One bot per `spacing` blocks: realistic streaming.
    grid,
};

pub const Config = struct {
    io: std.Io,
    host: []const u8,
    port: u16,
    mtu_size: u16 = 1492,
    chunk_radius: i32 = 8,
    walk: bool = false,
    speed: f32 = 4.3,
    layout: Layout = .grid,
    spacing: f32 = 16.0,
    frame_options: framing.Options = .{},
    server_address: []const u8,
    game_version: []const u8,
    verbose: bool = false,
    stop: *const std.atomic.Value(bool),
};

pub const Counters = struct {
    started: std.atomic.Value(u64) = .init(0),
    connected: std.atomic.Value(u64) = .init(0),
    spawned: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),
    dead: std.atomic.Value(u64) = .init(0),
    packets_sent: std.atomic.Value(u64) = .init(0),
    bytes_sent: std.atomic.Value(u64) = .init(0),
    packets_received: std.atomic.Value(u64) = .init(0),
    bytes_received: std.atomic.Value(u64) = .init(0),
    move_packets: std.atomic.Value(u64) = .init(0),
    chunk_packets: std.atomic.Value(u64) = .init(0),
    kicked: std.atomic.Value(u64) = .init(0),
};

pub const Bot = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    counters: *Counters,
    index: usize,
    name: []const u8,
    credentials: identity.Credentials,
    client: Raknet.Client = undefined,
    stage: std.atomic.Value(u8) = .init(@intFromEnum(Stage.connecting)),
    origin: Protocol.Vector3f,
    position: Protocol.Vector3f,
    input_tick: u64 = 0,
    walk_offset: f32 = 0,
    walk_direction: f32 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const Config,
        counters: *Counters,
        index: usize,
        name: []const u8,
    ) !*Bot {
        const bot = try allocator.create(Bot);
        errdefer allocator.destroy(bot);

        const credentials = try identity.forge(allocator, name, index, .{
            .server_address = config.server_address,
            .game_version = config.game_version,
        });
        errdefer credentials.deinit();

        bot.* = .{
            .allocator = allocator,
            .config = config,
            .counters = counters,
            .index = index,
            .name = name,
            .credentials = credentials,
            .origin = spawnPoint(config, index),
            .position = undefined,
        };
        bot.position = bot.origin;
        return bot;
    }

    pub fn deinit(self: *Bot) void {
        self.credentials.deinit();
        self.allocator.destroy(self);
    }

    /// Owns the RakNet client and drives the 20 Hz input loop.
    pub fn run(self: *Bot) void {
        self.client = Raknet.Client.init(.{
            .io = self.config.io,
            .allocator = self.allocator,
            .address = self.config.host,
            .port = self.config.port,
            .mtu_size = self.config.mtu_size,
        }) catch {
            _ = self.counters.failed.fetchAdd(1, .monotonic);
            return;
        };
        defer self.client.deinit();

        self.client.setConnectionCallback(onConnect, self);
        self.client.setGamePacketCallback(onGamePacket, self);
        self.client.setDisconnectionCallback(onDisconnect, self);

        self.client.connect() catch {
            _ = self.counters.failed.fetchAdd(1, .monotonic);
            return;
        };
        _ = self.counters.started.fetchAdd(1, .monotonic);

        const period_ns: i96 = std.time.ns_per_s / 20;
        while (!self.config.stop.load(.acquire)) {
            const start = std.Io.Timestamp.now(self.config.io, .awake);

            if (self.stage.load(.acquire) == @intFromEnum(Stage.active)) self.sendAuthInput();

            const elapsed = start.untilNow(self.config.io, .awake).toNanoseconds();
            if (elapsed < period_ns) {
                const remaining: i96 = period_ns - elapsed;
                self.config.io.sleep(std.Io.Duration.fromNanoseconds(remaining), .awake) catch break;
            }
        }

        if (self.stage.load(.acquire) != @intFromEnum(Stage.closed)) self.client.disconnect();
    }

    fn setStage(self: *Bot, stage: Stage) void {
        self.stage.store(@intFromEnum(stage), .release);
    }

    fn log(self: *Bot, comptime format: []const u8, args: anytype) void {
        if (!self.config.verbose) return;
        std.debug.print("[bot {d}] " ++ format ++ "\n", .{self.index} ++ args);
    }

    fn onConnect(client: *Raknet.Client, context: ?*anyopaque) void {
        _ = client;
        const self = fromContext(context);
        _ = self.counters.connected.fetchAdd(1, .monotonic);
        self.setStage(.requesting_settings);
        self.log("raknet handshake complete", .{});
        self.sendRequestNetworkSettings();
    }

    fn onDisconnect(client: *Raknet.Client, context: ?*anyopaque) void {
        _ = client;
        const self = fromContext(context);
        _ = self.counters.dead.fetchAdd(1, .monotonic);
        self.setStage(.closed);
        self.log("connection closed by the server", .{});
    }

    fn onGamePacket(client: *Raknet.Client, payload: []const u8, context: ?*anyopaque) void {
        _ = client;
        const self = fromContext(context);

        _ = self.counters.packets_received.fetchAdd(1, .monotonic);
        _ = self.counters.bytes_received.fetchAdd(payload.len, .monotonic);

        const decoded = framing.decode(payload, self.allocator) catch return;
        defer decoded.deinit();

        for (decoded.packets) |packet| {
            if (packet.len == 0) continue;

            var stream = BinaryStream.init(self.allocator, packet, null);
            defer stream.deinit();

            const id = stream.readVarInt() catch continue;
            // Deserializers expect the stream at the packet id, so rewind.
            stream.offset = 0;
            self.log("recv 0x{x:0>2} ({d} bytes)", .{ id, packet.len });
            self.handlePacket(&stream, id);
        }
    }

    fn handlePacket(self: *Bot, stream: *BinaryStream, id: u32) void {
        switch (id) {
            Protocol.Packet.NetworkSettings => self.sendLogin(),
            Protocol.Packet.PlayStatus => self.handlePlayStatus(stream),
            Protocol.Packet.ResourcePackInfo => self.sendResourcePackResponse(.HaveAllPacks),
            Protocol.Packet.ResourcePackStack => self.sendResourcePackResponse(.Completed),
            Protocol.Packet.StartGame => self.sendRequestChunkRadius(),
            Protocol.Packet.LevelChunk => _ = self.counters.chunk_packets.fetchAdd(1, .monotonic),
            Protocol.Packet.MovePlayer,
            Protocol.Packet.MoveActorDelta,
            Protocol.Packet.MoveActorAbsolute,
            => _ = self.counters.move_packets.fetchAdd(1, .monotonic),
            Protocol.Packet.Disconnect => self.handleDisconnect(stream),
            else => {},
        }
    }

    fn handlePlayStatus(self: *Bot, stream: *BinaryStream) void {
        const status = Protocol.PlayStatusPacket.deserialize(stream) catch return;
        switch (status.status) {
            .LoginSuccess => self.log("login accepted", .{}),
            .PlayerSpawn => self.spawn(),
            else => {
                _ = self.counters.kicked.fetchAdd(1, .monotonic);
                self.setStage(.closed);
                self.log("play status {s} ended the session", .{@tagName(status.status)});
            },
        }
    }

    fn handleDisconnect(self: *Bot, stream: *BinaryStream) void {
        const packet = Protocol.DisconnectPacket.deserialize(stream) catch return;
        const message = if (packet.messages) |messages| messages.message else "";
        self.log("kicked: {s} {s}", .{ @tagName(packet.reason), message });
        _ = self.counters.kicked.fetchAdd(1, .monotonic);
        self.setStage(.closed);
    }

    fn spawn(self: *Bot) void {
        if (self.stage.load(.acquire) == @intFromEnum(Stage.active)) return;

        _ = self.counters.spawned.fetchAdd(1, .monotonic);
        self.sendSetLocalPlayerAsInitialized();
        self.setStage(.active);
        self.log("spawned at {d:.1},{d:.1},{d:.1}", .{ self.position.x, self.position.y, self.position.z });
    }

    fn sendRequestNetworkSettings(self: *Bot) void {
        var packet = Protocol.RequestNetworkSettingsPacket{ .protocol = Protocol.PROTOCOL };

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        const serialized = packet.serialize(&stream) catch return;
        self.send(serialized);
    }

    fn sendLogin(self: *Bot) void {
        if (self.stage.load(.acquire) != @intFromEnum(Stage.requesting_settings)) return;
        self.setStage(.authenticating);

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        // Hand-written: LoginPacket.serialize does not compile in the pinned
        // protocol revision (a usize passed to writeVarInt).
        const identity_bytes = self.credentials.identity;
        const client_bytes = self.credentials.client;
        const body_len: u32 = @intCast(identity_bytes.len + client_bytes.len + 8);

        stream.writeVarInt(Protocol.Packet.Login) catch return;
        stream.writeInt32(Protocol.PROTOCOL, .Big) catch return;
        stream.writeVarInt(body_len) catch return;
        stream.writeString32(identity_bytes, .Little) catch return;
        stream.writeString32(client_bytes, .Little) catch return;

        self.send(stream.getBuffer());
        self.log("login chain sent", .{});
    }

    fn sendResourcePackResponse(self: *Bot, response: Protocol.ResourcePackResponse) void {
        var packet = Protocol.ResourcePackResponsePacket{ .response = response };

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        const serialized = packet.serialize(&stream) catch return;
        self.send(serialized);
    }

    fn sendRequestChunkRadius(self: *Bot) void {
        var packet = Protocol.RequestChunkRadiusPacket{
            .radius = self.config.chunk_radius,
            .max_radius = @intCast(@min(self.config.chunk_radius, 255)),
        };

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        const serialized = packet.serialize(&stream) catch return;
        self.send(serialized);
        self.setStage(.joining);
    }

    fn sendSetLocalPlayerAsInitialized(self: *Bot) void {
        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        stream.writeVarInt(Protocol.Packet.SetLocalPlayerAsInitialized) catch return;
        stream.writeVarInt(0) catch return;
        self.send(stream.getBuffer());
    }

    fn sendAuthInput(self: *Bot) void {
        self.input_tick += 1;

        const delta = self.advance();
        const input_data = InputDataBits.init(inputFlags(self.config));

        var packet = Protocol.PlayerAuthInputPacket{
            .rotation = Protocol.Vector3f.init(0, self.walkYaw(), self.walkYaw()),
            .position = self.position,
            .motion = Protocol.Vector2f.init(delta.x * 20, delta.z * 20),
            .input_data = input_data,
            .input_mode = .Mouse,
            .play_mode = .Normal,
            .interaction_mode = .Crosshair,
            .interact_rotation = Protocol.Vector2f.zero(),
            .input_tick = self.input_tick,
            .position_delta = delta,
        };

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        const serialized = packet.serialize(&stream) catch return;
        self.send(serialized);
    }

    /// Patrols `--spacing` blocks along +x and back, crossing chunk borders.
    fn advance(self: *Bot) Protocol.Vector3f {
        if (!self.config.walk) return Protocol.Vector3f.init(0, 0, 0);

        const step = self.config.speed / 20.0;
        self.walk_offset += step * self.walk_direction;

        if (self.walk_offset >= self.config.spacing) {
            self.walk_offset = self.config.spacing;
            self.walk_direction = -1;
        } else if (self.walk_offset <= 0) {
            self.walk_offset = 0;
            self.walk_direction = 1;
        }

        const previous = self.position;
        self.position.x = self.origin.x + self.walk_offset;

        return Protocol.Vector3f.init(
            self.position.x - previous.x,
            0,
            self.position.z - previous.z,
        );
    }

    fn walkYaw(self: *Bot) f32 {
        if (!self.config.walk) return 0;
        return if (self.walk_direction > 0) 90.0 else 270.0;
    }

    fn send(self: *Bot, packet: []const u8) void {
        const packets = [_][]const u8{packet};
        const encoded = framing.encode(&packets, self.config.frame_options, self.allocator) catch return;
        defer self.allocator.free(encoded);

        self.client.sendReliableMessage(encoded, .Normal);
        _ = self.counters.packets_sent.fetchAdd(1, .monotonic);
        _ = self.counters.bytes_sent.fetchAdd(encoded.len, .monotonic);
    }
};

fn fromContext(context: ?*anyopaque) *Bot {
    return @ptrCast(@alignCast(context.?));
}

fn inputFlags(config: *const Config) u64 {
    var flags: u64 = 0;
    if (!config.walk) return flags;

    flags |= @as(u64, 1) << @intFromEnum(Protocol.InputData.Up);
    if (config.speed > 5.0) flags |= @as(u64, 1) << @intFromEnum(Protocol.InputData.SprintDown);
    return flags;
}

fn spawnPoint(config: *const Config, index: usize) Protocol.Vector3f {
    const y: f32 = 100.0;
    switch (config.layout) {
        .cluster => {
            const per_side: usize = 15;
            const column: f32 = @floatFromInt(index % per_side);
            const row: f32 = @floatFromInt((index / per_side) % per_side);
            const layer: f32 = @floatFromInt(index / (per_side * per_side));
            return Protocol.Vector3f.init(column + 0.5 + layer * 0.01, y, row + 0.5 + layer * 0.01);
        },
        .grid => {
            const columns: usize = 16;
            const column: f32 = @floatFromInt(index % columns);
            const row: f32 = @floatFromInt(index / columns);
            return Protocol.Vector3f.init(column * config.spacing, y, row * config.spacing);
        },
    }
}

const testing = std.testing;

test "grid layout spreads bots one spacing apart" {
    const config = Config{
        .io = undefined,
        .host = "127.0.0.1",
        .port = 19132,
        .layout = .grid,
        .spacing = 16.0,
        .server_address = "127.0.0.1:19132",
        .game_version = "1.26.50",
        .stop = undefined,
    };

    const first = spawnPoint(&config, 0);
    const second = spawnPoint(&config, 1);
    const seventeenth = spawnPoint(&config, 16);

    try testing.expectEqual(@as(f32, 0), first.x);
    try testing.expectEqual(@as(f32, 16), second.x);
    try testing.expectEqual(@as(f32, 16), seventeenth.z);
}

test "cluster layout keeps every bot inside one chunk" {
    const config = Config{
        .io = undefined,
        .host = "127.0.0.1",
        .port = 19132,
        .layout = .cluster,
        .spacing = 16.0,
        .server_address = "127.0.0.1:19132",
        .game_version = "1.26.50",
        .stop = undefined,
    };

    for (0..500) |index| {
        const point = spawnPoint(&config, index);
        try testing.expect(point.x >= 0 and point.x < 16);
        try testing.expect(point.z >= 0 and point.z < 16);
    }
}
