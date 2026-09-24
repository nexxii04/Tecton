const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const protocol = @import("protocol");
const Packet = protocol.Packet;
const Raknet = @import("Raknet");

const Conduit = @import("../conduit.zig").Conduit;
const ThreadedTaskQueue = @import("../tasks/threaded-tasks.zig").ThreadedTaskQueue;
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
    valid: bool = false,
};

const PacketDrainResult = struct {
    processed: usize,
    remaining: usize,
};

const MAX_PACKET_QUEUE: usize = 4096;
const MAX_PACKETS_PER_DRAIN: usize = 4096;

fn drainCap(max_packets: usize) usize {
    return if (max_packets == 0) MAX_PACKETS_PER_DRAIN else @min(max_packets, MAX_PACKETS_PER_DRAIN);
}

fn requeueLeftover(
    out: *std.ArrayList(QueuedPacket),
    arrivals: *std.ArrayList(QueuedPacket),
    allocator: std.mem.Allocator,
    consumed: usize,
) void {
    std.debug.assert(consumed <= out.items.len);
    const leftover_len = out.items.len - consumed;
    std.mem.copyForwards(QueuedPacket, out.items[0..leftover_len], out.items[consumed..]);
    out.items.len = leftover_len;

    out.appendSlice(allocator, arrivals.items) catch {
        for (arrivals.items) |entry| allocator.free(entry.payload);
    };
    arrivals.deinit(allocator);
}

const DecompressWork = struct {
    conn: *Raknet.Connection,
    generation: u64,
    raw: []u8,
    allocator: std.mem.Allocator,
    handler: *NetworkHandler,
    decompressed: ?DecompressResult = null,
};

const DECOMPRESS_POOL_CAPACITY: usize = 1024;

const DecompressWorkPool = struct {
    pool: std.heap.MemoryPool(DecompressWork),
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    fn init(io: std.Io, allocator: std.mem.Allocator, capacity: usize) !DecompressWorkPool {
        return .{
            .pool = try std.heap.MemoryPool(DecompressWork).initCapacity(allocator, capacity),
            .io = io,
        };
    }

    fn deinit(self: *DecompressWorkPool, allocator: std.mem.Allocator) void {
        self.pool.deinit(allocator);
    }

    fn acquire(self: *DecompressWorkPool, allocator: std.mem.Allocator) ?*DecompressWork {
        self.mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return null;
        };
        defer self.mutex.unlock(self.io);
        return self.pool.create(allocator) catch null;
    }

    fn release(self: *DecompressWorkPool, work: *DecompressWork) void {
        self.mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.mutex.unlock(self.io);
        self.pool.destroy(work);
    }
};

pub const ScratchBuffer = struct {
    stream: BinaryStream,
    held: bool = false,

    pub fn init(allocator: std.mem.Allocator) ScratchBuffer {
        return .{ .stream = BinaryStream.init(allocator, null, null) };
    }

    pub fn deinit(self: *ScratchBuffer) void {
        self.stream.deinit();
    }

    pub fn begin(self: *ScratchBuffer) Lease {
        std.debug.assert(!self.held);
        self.held = true;
        self.stream.reset();
        return .{ .buffer = self };
    }

    pub const Lease = struct {
        buffer: *ScratchBuffer,

        pub fn stream(self: Lease) *BinaryStream {
            return &self.buffer.stream;
        }

        pub fn deinit(self: Lease) void {
            self.buffer.held = false;
        }
    };
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

    fn markValidGenerations(self: *ConnectionRegistry, io: std.Io, entries: []QueuedPacket) void {
        self.mutex.lock(io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            for (entries) |*entry| entry.valid = false;
            return;
        };
        defer self.mutex.unlock(io);
        for (entries) |*entry| {
            const generation = self.generations.get(@intFromPtr(entry.conn));
            entry.valid = generation != null and generation.? == entry.generation;
        }
    }
};

/// When a frame leaves the server. `immediate` flushes the whole outgoing queue
/// of that connection without a time budget, so it belongs to packets whose
/// delay is visible (spawn, teleport, disconnect), not to bulk traffic.
pub const SendPriority = enum {
    normal,
    immediate,

    pub fn parse(value: []const u8) ?SendPriority {
        if (std.mem.eql(u8, value, "normal")) return .normal;
        if (std.mem.eql(u8, value, "immediate")) return .immediate;
        return null;
    }

    pub fn label(self: SendPriority) []const u8 {
        return switch (self) {
            .normal => "normal",
            .immediate => "immediate",
        };
    }
};

test "send priority parses both values and nothing else" {
    try std.testing.expectEqual(SendPriority.normal, SendPriority.parse("normal").?);
    try std.testing.expectEqual(SendPriority.immediate, SendPriority.parse("immediate").?);
    try std.testing.expect(SendPriority.parse("Normal") == null);
    try std.testing.expect(SendPriority.parse("") == null);
    try std.testing.expect(SendPriority.parse("asap") == null);
    try std.testing.expectEqualStrings("normal", SendPriority.normal.label());
    try std.testing.expectEqualStrings("immediate", SendPriority.immediate.label());
}

pub const NetworkHandler = struct {
    conduit: *Conduit,
    io: std.Io,
    tasks: *ThreadedTaskQueue,
    allocator: std.mem.Allocator,
    options: CompressionOptions,
    packet_queue: std.ArrayList(QueuedPacket),
    packet_queue_mutex: std.Io.Mutex,
    decompress_pool: DecompressWorkPool,
    decompress_pending: std.atomic.Value(usize) = .init(0),
    dropped_packets: std.atomic.Value(usize) = .init(0),
    scratch: ScratchBuffer,
    connections: ConnectionRegistry,

    pub fn init(c: *Conduit) !*NetworkHandler {
        const self = try c.allocator.create(NetworkHandler);
        self.* = .{
            .conduit = c,
            .io = c.io,
            .tasks = &c.threaded_tasks,
            .allocator = c.allocator,
            .options = .{
                .compression_method = protocol.CompressionMethod.Zlib,
                .compression_threshold = 255,
            },
            .packet_queue = std.ArrayList(QueuedPacket){ .items = &.{}, .capacity = 0 },
            .packet_queue_mutex = .init,
            .decompress_pool = undefined,
            .scratch = undefined,
            .connections = ConnectionRegistry.init(c.allocator),
        };
        self.decompress_pool = try DecompressWorkPool.init(c.io, c.allocator, DECOMPRESS_POOL_CAPACITY);
        self.scratch = ScratchBuffer.init(c.allocator);
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

        if (self.packet_queue.items.len >= MAX_PACKET_QUEUE) {
            _ = self.dropped_packets.fetchAdd(1, .monotonic);
            self.allocator.free(copy);
            return;
        }

        self.packet_queue.append(self.allocator, .{ .conn = conn, .generation = generation, .payload = copy }) catch {
            self.allocator.free(copy);
        };
    }

    pub fn drainPackets(self: *NetworkHandler, budget_ns: u64, max_packets: usize) PacketDrainResult {
        const io = self.io;
        const started = std.Io.Timestamp.now(io, .awake);
        const cap = drainCap(max_packets);

        self.packet_queue_mutex.lock(io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return .{ .processed = 0, .remaining = 0 };
        };

        var batch = self.packet_queue;
        self.packet_queue = .empty;
        self.packet_queue_mutex.unlock(io);

        const scan_limit = @min(batch.items.len, cap);
        self.connections.markValidGenerations(io, batch.items[0..scan_limit]);

        var consumed: usize = 0;
        var enqueued: usize = 0;
        while (consumed < scan_limit) : (consumed += 1) {
            const entry = &batch.items[consumed];
            if (!entry.valid) {
                self.allocator.free(entry.payload);
                entry.payload = &.{};
                continue;
            }

            if (enqueued > 0) {
                const elapsed: u64 = @intCast(@max(0, started.durationTo(.now(io, .awake)).nanoseconds));
                if (elapsed >= budget_ns) break;
            }

            const work = self.decompress_pool.acquire(self.allocator) orelse {
                self.allocator.free(entry.payload);
                entry.payload = &.{};
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
            self.tasks.enqueue(.{
                .work = decompressTask,
                .callback = decompressCallback,
                .cleanup = decompressCleanup,
                .ctx = @ptrCast(work),
                .shard_key = @intFromPtr(entry.conn),
            }) catch {
                std.debug.print("[net-drain] threaded_tasks enqueue FAILED\n", .{});
                self.allocator.free(entry.payload);
                entry.payload = &.{};
                self.decompress_pool.release(work);
                continue;
            };

            enqueued += 1;
            entry.payload = &.{};
        }

        self.packet_queue_mutex.lock(io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            for (batch.items[consumed..]) |entry| self.allocator.free(entry.payload);
            batch.deinit(self.allocator);
            _ = self.decompress_pending.fetchAdd(enqueued, .monotonic);
            return .{ .processed = enqueued, .remaining = 0 };
        };
        var arrivals = self.packet_queue;
        requeueLeftover(&batch, &arrivals, self.allocator, consumed);
        self.packet_queue = batch;
        const remaining = self.packet_queue.items.len;
        self.packet_queue_mutex.unlock(io);

        _ = self.decompress_pending.fetchAdd(enqueued, .monotonic);
        return .{ .processed = enqueued, .remaining = remaining };
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
            if (work.handler.connections.isCurrent(work.handler.io, work.conn, work.generation)) {
                const io = work.handler.io;
                const pd_start = std.Io.Timestamp.now(io, .awake);
                work.handler.dispatchPackets(work.conn, result.packets);
                const pd_end = pd_start.durationTo(.now(io, .awake));
                work.handler.conduit.profiler.record(.packet_dispatch, @intCast(@max(0, pd_end.nanoseconds)));
            }
            result.deinit();
        }

        const pending_before = work.handler.decompress_pending.fetchSub(1, .monotonic);
        std.debug.assert(pending_before > 0);
        work.handler.decompress_pool.release(work);
    }

    fn decompressCleanup(ctx: *anyopaque) void {
        const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));
        if (work.decompressed) |result| {
            result.deinit();
        }
        if (work.raw.len > 0) {
            work.allocator.free(work.raw);
        }

        const pending_before = work.handler.decompress_pending.fetchSub(1, .monotonic);
        std.debug.assert(pending_before > 0);
        work.handler.decompress_pool.release(work);
    }

    pub fn sendUncompressedPacket(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
        const packets = [_][]const u8{packet};
        const options = CompressionOptions{ .compression_method = .NotPresent, .compression_threshold = 255 };
        const compressed = try Compression.compress(&packets, options, self.allocator);
        defer self.allocator.free(compressed);
        conn.sendReliableMessage(compressed, .Normal);
    }

    pub fn sendPacket(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
        return self.sendPacketWith(conn, packet, .normal);
    }

    pub fn sendPacketWith(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8, priority: SendPriority) !void {
        const packets = [_][]const u8{packet};
        const compressed = try Compression.compress(&packets, self.options, self.allocator);
        defer self.allocator.free(compressed);
        deliver(conn, compressed, priority);
    }

    pub fn sendImmediate(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
        return self.sendPacketWith(conn, packet, .immediate);
    }

    pub fn sendPackets(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8) !void {
        return self.sendPacketsWith(conn, packets, .normal);
    }

    pub fn sendPacketsWith(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8, priority: SendPriority) !void {
        const compressed = try Compression.compress(packets, self.options, self.allocator);
        defer self.allocator.free(compressed);
        deliver(conn, compressed, priority);
    }

    pub fn sendPacketsUncompressed(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8) !void {
        return self.sendPacketsUncompressedWith(conn, packets, .normal);
    }

    pub fn sendPacketsUncompressedWith(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8, priority: SendPriority) !void {
        var options = self.options;
        options.compression_threshold = std.math.maxInt(u16);
        const compressed = try Compression.compress(packets, options, self.allocator);
        defer self.allocator.free(compressed);
        deliver(conn, compressed, priority);
    }

    fn deliver(conn: *Raknet.Connection, bytes: []const u8, priority: SendPriority) void {
        conn.sendReliableMessage(bytes, switch (priority) {
            .normal => .Normal,
            .immediate => .Immediate,
        });
    }

    pub fn deinit(self: *NetworkHandler) void {
        for (self.packet_queue.items) |entry| self.allocator.free(entry.payload);
        self.packet_queue.deinit(self.allocator);
        self.decompress_pool.deinit(self.allocator);
        self.scratch.deinit();
        self.connections.deinit();
        self.allocator.destroy(self);
    }
};

test "the scratch buffer is taken exclusively and starts empty" {
    const allocator = std.testing.allocator;
    var scratch = ScratchBuffer.init(allocator);
    defer scratch.deinit();

    {
        const lease = scratch.begin();
        defer lease.deinit();
        try std.testing.expect(scratch.held);
        try lease.stream().writeUint8(0xab);
        try lease.stream().writeUint8(0xcd);
        try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, lease.stream().getBuffer());
    }
    try std.testing.expect(!scratch.held);

    const second = scratch.begin();
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), second.stream().getBuffer().len);
}

test "the decompression pool never hands one node to two threads" {
    const allocator = std.testing.allocator;
    const thread_count = 2;
    const iterations = 20_000;

    var pool = try DecompressWorkPool.init(std.testing.io, allocator, 4);
    defer pool.deinit(allocator);

    const Registry = struct {
        mutex: std.Io.Mutex = .init,
        held: [thread_count]*DecompressWork = undefined,
        len: usize = 0,

        fn claim(self: *@This(), work: *DecompressWork) void {
            self.mutex.lock(std.testing.io) catch return;
            defer self.mutex.unlock(std.testing.io);
            for (self.held[0..self.len]) |existing| {
                if (existing == work) @panic("el pool entrego el mismo nodo a dos llamantes");
            }
            self.held[self.len] = work;
            self.len += 1;
        }

        fn drop(self: *@This(), work: *DecompressWork) void {
            self.mutex.lock(std.testing.io) catch return;
            defer self.mutex.unlock(std.testing.io);
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.held[i] == work) {
                    self.held[i] = self.held[self.len - 1];
                    self.len -= 1;
                    return;
                }
            }
        }
    };
    var registry = Registry{};

    const Worker = struct {
        fn run(p: *DecompressWorkPool, reg: *Registry, alloc: std.mem.Allocator, count: usize) void {
            for (0..count) |i| {
                const work = p.acquire(alloc) orelse continue;
                reg.claim(work);
                work.generation = i;
                reg.drop(work);
                p.release(work);
            }
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &pool, &registry, allocator, iterations });
    }
    for (&threads) |*thread| thread.join();

    try std.testing.expectEqual(@as(usize, 0), registry.len);
}

test "drainPackets caps by queue bound and budget, and requeues the rest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tasks = ThreadedTaskQueue.init(io, allocator, 1);
    try tasks.start();

    var handler = NetworkHandler{
        .conduit = undefined,
        .io = io,
        .tasks = &tasks,
        .allocator = allocator,
        .options = .{ .compression_method = .Zlib, .compression_threshold = 255 },
        .packet_queue = .empty,
        .packet_queue_mutex = .init,
        .decompress_pool = try DecompressWorkPool.init(io, allocator, 16),
        .scratch = undefined,
        .connections = ConnectionRegistry.init(allocator),
    };

    defer handler.decompress_pool.deinit(allocator);
    defer tasks.deinit();
    defer handler.connections.deinit();
    defer {
        for (handler.packet_queue.items) |entry| allocator.free(entry.payload);
        handler.packet_queue.deinit(allocator);
    }

    var conn_storage: u128 align(16) = 0;
    const conn: *Raknet.Connection = @ptrCast(&conn_storage);
    handler.connections.register(io, conn);
    const generation = handler.connections.currentGeneration(io, conn) orelse return error.TestUnexpectedResult;

    for (0..10) |_| {
        try handler.packet_queue.append(allocator, .{
            .conn = conn,
            .generation = generation,
            .payload = try allocator.dupe(u8, "not-a-deflate-stream"),
        });
    }

    const capped = handler.drainPackets(std.math.maxInt(u64), 4);
    try std.testing.expectEqual(@as(usize, 4), capped.processed);
    try std.testing.expectEqual(@as(usize, 6), capped.remaining);

    const starved = handler.drainPackets(0, 4096);
    try std.testing.expectEqual(@as(usize, 1), starved.processed);
    try std.testing.expectEqual(@as(usize, 5), starved.remaining);

    var drained: usize = 0;
    while (handler.packet_queue.items.len > 0) {
        const result = handler.drainPackets(std.math.maxInt(u64), 4096);
        if (result.processed == 0) break;
        drained += result.processed;
    }
    try std.testing.expectEqual(@as(usize, 5), drained);
    try std.testing.expectEqual(@as(usize, 0), handler.packet_queue.items.len);

    try std.testing.expectEqual(@as(usize, 10), handler.decompress_pending.load(.monotonic));

    handler.connections.unregister(io, conn);
    try handler.packet_queue.append(allocator, .{
        .conn = conn,
        .generation = generation,
        .payload = try allocator.dupe(u8, "stale"),
    });
    const stale = handler.drainPackets(std.math.maxInt(u64), 4096);
    try std.testing.expectEqual(@as(usize, 0), stale.processed);
    try std.testing.expectEqual(@as(usize, 0), stale.remaining);
}

test "leftovers go back ahead of later arrivals" {
    const allocator = std.testing.allocator;
    var batch = std.ArrayList(QueuedPacket).empty;
    defer batch.deinit(allocator);
    var arrivals = std.ArrayList(QueuedPacket).empty;

    var conn_storage: u128 align(16) = 0;
    const conn: *Raknet.Connection = @ptrCast(&conn_storage);

    for ("abcde") |byte| {
        try batch.append(allocator, .{ .conn = conn, .generation = 1, .payload = try allocator.dupe(u8, &.{byte}) });
    }

    for ("fg") |byte| {
        try arrivals.append(allocator, .{ .conn = conn, .generation = 1, .payload = try allocator.dupe(u8, &.{byte}) });
    }

    allocator.free(batch.items[0].payload);
    allocator.free(batch.items[1].payload);

    requeueLeftover(&batch, &arrivals, allocator, 2);

    try std.testing.expectEqual(@as(usize, 5), batch.items.len);
    for (batch.items, "cdefg") |entry, expected| {
        try std.testing.expectEqual(expected, entry.payload[0]);
    }

    for (batch.items) |entry| allocator.free(entry.payload);
    batch.items.len = 0;
}

test "requeueing handles an empty leftover and no arrivals" {
    const allocator = std.testing.allocator;
    var conn_storage: u128 align(16) = 0;
    const conn: *Raknet.Connection = @ptrCast(&conn_storage);

    {
        var batch = std.ArrayList(QueuedPacket).empty;
        defer batch.deinit(allocator);
        try batch.append(allocator, .{ .conn = conn, .generation = 1, .payload = try allocator.dupe(u8, "a") });
        allocator.free(batch.items[0].payload);
        var arrivals = std.ArrayList(QueuedPacket).empty;
        requeueLeftover(&batch, &arrivals, allocator, 1);
        try std.testing.expectEqual(@as(usize, 0), batch.items.len);
    }

    {
        var batch = std.ArrayList(QueuedPacket).empty;
        defer batch.deinit(allocator);
        try batch.append(allocator, .{ .conn = conn, .generation = 1, .payload = try allocator.dupe(u8, "a") });
        var arrivals = std.ArrayList(QueuedPacket).empty;
        try arrivals.append(allocator, .{ .conn = conn, .generation = 1, .payload = try allocator.dupe(u8, "b") });
        requeueLeftover(&batch, &arrivals, allocator, 0);
        try std.testing.expectEqual(@as(usize, 2), batch.items.len);
        try std.testing.expectEqual(@as(u8, 'a'), batch.items[0].payload[0]);
        try std.testing.expectEqual(@as(u8, 'b'), batch.items[1].payload[0]);
        for (batch.items) |entry| allocator.free(entry.payload);
        batch.items.len = 0;
    }
}

test "the per-drain cap cannot rise above the hard cap" {
    try std.testing.expectEqual(MAX_PACKETS_PER_DRAIN, drainCap(0));
    try std.testing.expectEqual(@as(usize, 64), drainCap(64));
    try std.testing.expectEqual(MAX_PACKETS_PER_DRAIN, drainCap(MAX_PACKETS_PER_DRAIN * 100));
}

test "generation validation is per batch, not per packet" {
    const io = std.testing.io;
    var registry = ConnectionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var conn_storage: [2]u128 align(16) = .{ 0, 0 };
    const live: *Raknet.Connection = @ptrCast(&conn_storage[0]);
    const resigned: *Raknet.Connection = @ptrCast(&conn_storage[1]);

    registry.register(io, live);
    registry.register(io, resigned);
    const live_generation = registry.currentGeneration(io, live) orelse return error.TestUnexpectedResult;
    const resigned_generation = registry.currentGeneration(io, resigned) orelse return error.TestUnexpectedResult;
    registry.unregister(io, resigned);

    var entries = [_]QueuedPacket{
        .{ .conn = live, .generation = live_generation, .payload = &.{} },
        .{ .conn = resigned, .generation = resigned_generation, .payload = &.{} },
        .{ .conn = live, .generation = live_generation -% 1, .payload = &.{} },
    };
    registry.markValidGenerations(io, &entries);

    try std.testing.expect(entries[0].valid);
    try std.testing.expect(!entries[1].valid);
    try std.testing.expect(!entries[2].valid);
}

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

    registry_box.unregister(std.testing.io, conn);
    try std.testing.expectEqual(@as(?u64, null), registry_box.currentGeneration(std.testing.io, conn));
    try std.testing.expect(!registry_box.isCurrent(std.testing.io, conn, first_gen));

    registry_box.register(std.testing.io, conn);
    const second_gen = registry_box.currentGeneration(std.testing.io, conn) orelse return error.TestUnexpectedResult;
    try std.testing.expect(second_gen != first_gen);
    try std.testing.expect(registry_box.isCurrent(std.testing.io, conn, second_gen));
    try std.testing.expect(!registry_box.isCurrent(std.testing.io, conn, first_gen));
}
