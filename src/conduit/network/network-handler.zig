const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const protocol = @import("protocol");
const Packet = protocol.Packet;
const Raknet = @import("Raknet");

const Conduit = @import("../conduit.zig").Conduit;
const CompressionOptions = @import("./compression/options.zig").CompressionOptions;
const Compression = @import("./compression/root.zig").Compression;
const DecompressResult = @import("./compression/root.zig").DecompressResult;
const handleAnimate = @import("./handlers/animate.zig").handleAnimate;
const handleBlockPickRequest = @import("./handlers/block-pick-request.zig").handleBlockPickRequest;
const handleClientCacheStatus = @import("./handlers/client-cache-status.zig").handleClientCacheStatus;
const handleCommandRequest = @import("./handlers/command-request.zig").handleCommandRequest;
const handleContainerClose = @import("./handlers/container-close.zig").handleContainerClose;
const handleInteract = @import("./handlers/interact.zig").handleInteract;
const handleInventoryTransaction = @import("./handlers/inventory-transaction.zig").handleInventoryTransaction;
const handleItemStackRequest = @import("./handlers/item-stack-request.zig").handleItemStackRequest;
const handleLogin = @import("./handlers/login.zig").handleLogin;
const handleMobEquipment = @import("./handlers/mob-equipment.zig").handleMobEquipment;
const handlePacketViolationWarning = @import("./handlers/packet-violation-warning.zig").handlePacketViolationWarning;
const handlePlayerAction = @import("./handlers/player-action.zig").handlePlayerAction;
const handlePlayerAuthInput = @import("./handlers/player-auth-input.zig").handlePlayerAuthInput;
const handleRequestChunkRadius = @import("./handlers/request-chunk-radius.zig").handleRequestChunkRadius;
const handleNetworkSettings = @import("./handlers/request-network-settings.zig").handleNetworkSettings;
const handleResourcePack = @import("./handlers/resource-packs-response.zig").handleResourcePack;
const handleSetLocalPlayerAsInitialized = @import("./handlers/set-local-player-as-initialized.zig").handleSetLocalPlayerAsInitialized;
const handleTextPacket = @import("./handlers/text.zig").handleTextPacket;
const PlayerLog = @import("./player-log.zig");

const QueuedPacket = struct {
    conn: *Raknet.Connection,
    generation: u64,
    payload: []u8,
};

const PacketDrainResult = struct {
    processed: usize,
    remaining: usize,
};

const DecompressWork = struct {
    conn: *Raknet.Connection,
    generation: u64,
    raw: []u8,
    allocator: std.mem.Allocator,
    handler: *NetworkHandler,
    decompressed: ?DecompressResult = null,
};

const ConnectionRegistry = struct {
    generations: std.AutoHashMap(usize, u64),
    counter: u64 = 0,
    mutex: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) ConnectionRegistry {
        return .{
            .generations = std.AutoHashMap(usize, u64).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *ConnectionRegistry) void {
        self.generations.deinit();
    }

    fn register(self: *ConnectionRegistry, io: std.Io, connection: *Raknet.Connection) void {
        self.mutex.lock(io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.mutex.unlock(io);
        self.counter += 1;
        self.generations.put(@intFromPtr(connection), self.counter) catch {
            std.log.err("failed to register connection", .{});
        };
    }

    fn unregister(self: *ConnectionRegistry, io: std.Io, connection: *Raknet.Connection) void {
        self.mutex.lock(io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.mutex.unlock(io);
        _ = self.generations.remove(@intFromPtr(connection));
    }

    fn currentGeneration(self: *ConnectionRegistry, io: std.Io, connection: *Raknet.Connection) ?u64 {
        self.mutex.lock(io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return null;
        };
        defer self.mutex.unlock(io);
        return self.generations.get(@intFromPtr(connection));
    }

    fn isCurrent(self: *ConnectionRegistry, io: std.Io, connection: *Raknet.Connection, generation: u64) bool {
        const current = self.currentGeneration(io, connection) orelse return false;
        return current == generation;
    }
};

pub const NetworkHandler = struct {
    conduit: *Conduit,
    allocator: std.mem.Allocator,
    options: CompressionOptions,
    packet_queue: std.ArrayList(QueuedPacket),
    packet_queue_mutex: std.Io.Mutex,
    decompress_pool: std.heap.MemoryPool(DecompressWork),
    decompress_pending: usize = 0,
    scratch_stream: BinaryStream,
    connections: ConnectionRegistry,

    pub fn init(c: *Conduit) !*NetworkHandler {
        const self = try c.allocator.create(NetworkHandler);
        self.* = .{
            .conduit = c,
            .allocator = c.allocator,
            .options = .{
                .compression_method = protocol.CompressionMethod.Zlib,
                .compression_threshold = 255,
            },
            .packet_queue = std.ArrayList(QueuedPacket){ .items = &.{}, .capacity = 0 },
            .packet_queue_mutex = .init,
            .decompress_pool = undefined,
            .scratch_stream = undefined,
            .connections = ConnectionRegistry.init(c.allocator),
        };
        self.decompress_pool = try std.heap.MemoryPool(DecompressWork).initCapacity(c.allocator, 1024);
        self.scratch_stream = BinaryStream.init(c.allocator, null, null);
        self.conduit.*.raknet.setConnectCallback(onConnect, self);
        self.conduit.*.raknet.setDisconnectCallback(onDisconnect, self);
        return self;
    }

    pub fn onConnect(connection: *Raknet.Connection, context: ?*anyopaque) void {
        const self = @as(*NetworkHandler, @ptrCast(@alignCast(context)));
        self.connections.register(self.conduit.io, connection);
        connection.setGamePacketCallback(onPacket, self);
    }

    pub fn onDisconnect(connection: *Raknet.Connection, context: ?*anyopaque) void {
        const self = @as(*NetworkHandler, @ptrCast(@alignCast(context)));
        // Must happen before RakNet frees the connection: every queued
        // packet from it becomes a validated-and-dropped entry instead of a
        // dangling pointer dereference at dispatch time.
        self.connections.unregister(self.conduit.io, connection);
        const player = self.conduit.getPlayerByConnection(connection) orelse return;
        PlayerLog.logDisconnect(player.username);
        player.disconnectFromNetwork();
    }

    pub fn onPacket(conn: *Raknet.Connection, payload: []const u8, context: ?*anyopaque) void {
        const self = @as(*NetworkHandler, @ptrCast(@alignCast(context)));
        const generation = self.connections.currentGeneration(self.conduit.io, conn) orelse return;
        const copy = self.allocator.dupe(u8, payload) catch return;

        self.packet_queue_mutex.lock(self.conduit.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            self.allocator.free(copy);
            return;
        };
        defer self.packet_queue_mutex.unlock(self.conduit.io);

        self.packet_queue.append(self.allocator, .{ .conn = conn, .generation = generation, .payload = copy }) catch {
            self.allocator.free(copy);
        };
    }

    pub fn drainPackets(self: *NetworkHandler, budget_ns: u64, max_packets: usize) PacketDrainResult {
        _ = budget_ns;
        _ = max_packets;

        self.packet_queue_mutex.lock(self.conduit.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return .{ .processed = 0, .remaining = self.packet_queue.items.len };
        };

        var queue = self.packet_queue;
        self.packet_queue = .empty;
        self.packet_queue_mutex.unlock(self.conduit.io);

        var enqueued: usize = 0;
        for (queue.items) |entry| {
            if (!self.connections.isCurrent(self.conduit.io, entry.conn, entry.generation)) {
                self.allocator.free(entry.payload);
                continue;
            }
            const work = self.decompress_pool.create(self.allocator) catch {
                self.allocator.free(entry.payload);
                continue;
            };
            work.* = .{
                .conn = entry.conn,
                .generation = entry.generation,
                .raw = entry.payload,
                .allocator = self.allocator,
                .handler = self,
                .decompressed = null,
            };
            self.conduit.threaded_tasks.enqueue(.{
                .work = decompressTask,
                .callback = decompressCallback,
                .cleanup = decompressCleanup,
                .ctx = @ptrCast(work),
                // Same-connection frames must dispatch in receive order:
                // pin them to one worker's FIFO shard.
                .shard_key = @intFromPtr(entry.conn),
            }) catch {
                std.debug.print("[net-drain] threaded_tasks enqueue FAILED\n", .{});
                self.allocator.free(entry.payload);
                self.decompress_pool.destroy(work);
                continue;
            };
            enqueued += 1;
        }

        self.decompress_pending += enqueued;
        queue.deinit(self.allocator);
        return .{ .processed = enqueued, .remaining = 0 };
    }

    fn dispatchPackets(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8) void {
        for (packets) |packet| {
            if (packet.len == 0) continue;

            var stream = BinaryStream.init(self.allocator, packet, null);
            defer stream.deinit();

            const id = stream.readVarInt() catch continue;
            stream.offset = 0;

            switch (id) {
                Packet.RequestNetworkSettings => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleNetworkSettings(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("RequestNetworkSettings error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.Login => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleLogin(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("LoginPacket error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.ResourcePackResponse => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleResourcePack(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("ResourcePackResponse error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.Text => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleTextPacket(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("Text error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.RequestChunkRadius => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleRequestChunkRadius(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("RequestChunkRadius error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_chunk_request, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.SetLocalPlayerAsInitialized => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleSetLocalPlayerAsInitialized(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("SetLocalPlayerAsInitialized error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.PlayerAuthInput => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handlePlayerAuthInput(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("PlayerAuthInput error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_player_auth, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.Animate => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleAnimate(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("Animate error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.ClientCacheStatus => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleClientCacheStatus(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("ClientCacheStatus error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.Interact => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleInteract(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("Interact error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.MobEquipment => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleMobEquipment(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("MobEquipment error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.ContainerClose => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleContainerClose(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("ContainerClose error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.InventoryTransaction => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleInventoryTransaction(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("InventoryTransaction error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_inventory, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.ItemStackRequest => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleItemStackRequest(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("ItemStackRequest error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_inventory, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.PlayerAction => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handlePlayerAction(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("PlayerAction error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.CommandRequest => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleCommandRequest(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("CommandRequest error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.PacketViolationWarning => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handlePacketViolationWarning(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("PacketViolationWarning error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.BlockPickRequest => {
                    const h_start = std.Io.Timestamp.now(self.conduit.io, .awake);
                    handleBlockPickRequest(self, conn, &stream) catch |err| {
                        Raknet.Logger.ERROR("BlockPickRequest error: {any}", .{err});
                    };
                    const h_end = h_start.durationTo(.now(self.conduit.io, .awake));
                    self.conduit.profiler.record(.handler_other, @intCast(@max(0, h_end.nanoseconds)));
                },
                Packet.EmoteList,
                Packet.ServerboundLoadingScreenPacket,
                Packet.SetPlayerInventoryOptions,
                => {
                    std.debug.print("[net-dispatch] id=0x{x:0>2} explicitly ignored (no handler)\n", .{@as(u32, @intCast(id))});
                },
                else => {
                    std.debug.print("[net-dispatch] id=0x{x:0>2} UNHANDLED -> falling through payload_len={d}\n", .{ @as(u32, @intCast(id)), packet.len });
                    Raknet.Logger.INFO("Unhandled packet 0x{x}", .{id});
                },
            }
        }
    }

    pub fn onGamePacket(self: *NetworkHandler, conn: *Raknet.Connection, payload: []const u8) !void {
        const decompressed = try Compression.decompress(payload, self.options, self.allocator);
        defer decompressed.deinit();
        self.dispatchPackets(conn, decompressed.packets);
    }

    fn decompressTask(ctx: *anyopaque) void {
        const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));
        work.decompressed = Compression.decompress(work.raw, work.handler.options, work.allocator) catch |err| {
            std.log.err("decompress failed: {}", .{err});
            work.allocator.free(work.raw);
            work.raw = &.{};
            return;
        };
        work.allocator.free(work.raw);
        work.raw = &.{};
    }

    fn decompressCallback(ctx: *anyopaque) void {
        const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));
        if (work.decompressed) |result| {
            if (work.handler.connections.isCurrent(work.handler.conduit.io, work.conn, work.generation)) {
                const io = work.handler.conduit.io;
                const pd_start = std.Io.Timestamp.now(io, .awake);
                work.handler.dispatchPackets(work.conn, result.packets);
                const pd_end = pd_start.durationTo(.now(io, .awake));
                work.handler.conduit.profiler.record(.packet_dispatch, @intCast(@max(0, pd_end.nanoseconds)));
            }
            result.deinit();
        }
        std.debug.assert(work.handler.decompress_pending > 0);
        work.handler.decompress_pending -= 1;
        work.handler.decompress_pool.destroy(work);
    }

    fn decompressCleanup(ctx: *anyopaque) void {
        const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));
        if (work.decompressed) |result| {
            result.deinit();
        }
        if (work.raw.len > 0) {
            work.allocator.free(work.raw);
        }
        std.debug.assert(work.handler.decompress_pending > 0);
        work.handler.decompress_pending -= 1;
        work.handler.decompress_pool.destroy(work);
    }

    pub fn sendUncompressedPacket(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
        const packets = [_][]const u8{packet};
        const options = CompressionOptions{ .compression_method = .NotPresent, .compression_threshold = 255 };
        const compressed = try Compression.compress(&packets, options, self.allocator);
        defer self.allocator.free(compressed);
        conn.sendReliableMessage(compressed, .Normal);
    }

    pub fn sendPacket(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
        const packets = [_][]const u8{packet};
        const compressed = try Compression.compress(&packets, self.options, self.allocator);
        defer self.allocator.free(compressed);
        conn.sendReliableMessage(compressed, .Normal);
    }

    pub fn sendImmediate(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
        const packets = [_][]const u8{packet};
        const compressed = try Compression.compress(&packets, self.options, self.allocator);
        defer self.allocator.free(compressed);
        conn.sendReliableMessage(compressed, .Immediate);
    }

    pub fn sendPackets(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8) !void {
        const compressed = try Compression.compress(packets, self.options, self.allocator);
        defer self.allocator.free(compressed);
        conn.sendReliableMessage(compressed, .Normal);
    }

    pub fn deinit(self: *NetworkHandler) void {
        for (self.packet_queue.items) |entry| self.allocator.free(entry.payload);
        self.packet_queue.deinit(self.allocator);
        self.decompress_pool.deinit(self.allocator);
        self.scratch_stream.deinit();
        self.connections.deinit();
        self.allocator.destroy(self);
    }
};

test "connection registry validates generations across pointer reuse" {
    const registry_box = try std.testing.allocator.create(ConnectionRegistry);
    defer std.testing.allocator.destroy(registry_box);
    registry_box.* = ConnectionRegistry.init(std.testing.allocator);
    defer registry_box.deinit();

    var conn_storage: u128 align(16) = 0;
    const conn: *Raknet.Connection = @ptrCast(&conn_storage);

    registry_box.register(std.testing.io, conn);
    const first_gen = registry_box.currentGeneration(std.testing.io, conn) orelse return error.TestUnexpectedResult;
    try std.testing.expect(registry_box.isCurrent(std.testing.io, conn, first_gen));

    // Same address, new connection: the old generation must be rejected.
    registry_box.unregister(std.testing.io, conn);
    try std.testing.expectEqual(@as(?u64, null), registry_box.currentGeneration(std.testing.io, conn));
    try std.testing.expect(!registry_box.isCurrent(std.testing.io, conn, first_gen));

    registry_box.register(std.testing.io, conn);
    const second_gen = registry_box.currentGeneration(std.testing.io, conn) orelse return error.TestUnexpectedResult;
    try std.testing.expect(second_gen != first_gen);
    try std.testing.expect(registry_box.isCurrent(std.testing.io, conn, second_gen));
    try std.testing.expect(!registry_box.isCurrent(std.testing.io, conn, first_gen));
}
