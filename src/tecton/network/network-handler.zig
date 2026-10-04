const std = @import("std");

const protocol = @import("protocol");
const Raknet = @import("Raknet");

const ThreadedTaskQueue = @import("../tasks/threaded-tasks.zig").ThreadedTaskQueue;
const CompressionOptions = @import("./compression/options.zig").CompressionOptions;
const Compression = @import("./compression/root.zig").Compression;
const DecompressResult = @import("./compression/root.zig").DecompressResult;

const node_pool = @import("./node-pool.zig");
const queue = @import("./queue.zig");
const scratch_mod = @import("./scratch.zig");
const connections_mod = @import("./connections.zig");
const priority_mod = @import("./priority.zig");
const host_mod = @import("./host.zig");

pub const QueuedPacket = queue.QueuedPacket;
pub const PacketDrainResult = queue.PacketDrainResult;
pub const ScratchBuffer = scratch_mod.ScratchBuffer;
pub const SendPriority = priority_mod.SendPriority;

const DECOMPRESS_POOL_CAPACITY: usize = 1024;

const DecompressWork = struct {
    conn: *Raknet.Connection,
    generation: u64,
    raw: []u8,
    allocator: std.mem.Allocator,
    handler: *NetworkHandler,
    decompressed: ?DecompressResult = null,
};

const DecompressWorkPool = node_pool.NodePool(DecompressWork);

pub const NetworkHandler = struct {
    host: host_mod.Host,
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
    connections: connections_mod.ConnectionRegistry,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        tasks: *ThreadedTaskQueue,
        host: host_mod.Host,
    ) !*NetworkHandler {
        const self = try allocator.create(NetworkHandler);
        self.* = .{
            .host = host,
            .io = io,
            .tasks = tasks,
            .allocator = allocator,
            .options = .{
                .compression_method = protocol.CompressionMethod.Zlib,
                .compression_threshold = 255,
            },
            .packet_queue = .empty,
            .packet_queue_mutex = .init,
            .decompress_pool = undefined,
            .scratch = undefined,
            .connections = connections_mod.ConnectionRegistry.init(allocator),
        };
        self.decompress_pool = try DecompressWorkPool.init(io, allocator, DECOMPRESS_POOL_CAPACITY);
        self.scratch = ScratchBuffer.init(allocator);
        return self;
    }

    pub fn onConnect(connection: *Raknet.Connection, context: ?*anyopaque) void {
        const self = @as(*NetworkHandler, @ptrCast(@alignCast(context)));
        self.connections.register(self.io, connection);
        connection.setGamePacketCallback(onPacket, self);
    }

    pub fn onDisconnect(connection: *Raknet.Connection, context: ?*anyopaque) void {
        const self = @as(*NetworkHandler, @ptrCast(@alignCast(context)));
        self.connections.unregister(self.io, connection);
        self.host.disconnected(self.host.ctx, connection);
    }

    pub fn onPacket(conn: *Raknet.Connection, payload: []const u8, context: ?*anyopaque) void {
        const self = @as(*NetworkHandler, @ptrCast(@alignCast(context)));
        const generation = self.connections.currentGeneration(self.io, conn) orelse return;
        const copy = self.allocator.dupe(u8, payload) catch return;

        self.packet_queue_mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            self.allocator.free(copy);
            return;
        };
        defer self.packet_queue_mutex.unlock(self.io);

        if (self.packet_queue.items.len >= queue.MAX_PACKET_QUEUE) {
            _ = self.dropped_packets.fetchAdd(1, .monotonic);
            self.allocator.free(copy);
            return;
        }

        self.packet_queue.append(self.allocator, .{ .conn = conn, .generation = generation, .payload = copy }) catch {
            self.allocator.free(copy);
        };
    }

    /// Moves up to `max_packets` onto the workers within `budget_ns`; the rest stays queued.
    pub fn drainPackets(self: *NetworkHandler, budget_ns: u64, max_packets: usize) PacketDrainResult {
        const io = self.io;
        const started = std.Io.Timestamp.now(io, .awake);
        const cap = queue.drainCap(max_packets);

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
        queue.requeueLeftover(&batch, &arrivals, self.allocator, consumed);
        self.packet_queue = batch;
        const remaining = self.packet_queue.items.len;
        self.packet_queue_mutex.unlock(io);

        _ = self.decompress_pending.fetchAdd(enqueued, .monotonic);
        return .{ .processed = enqueued, .remaining = remaining };
    }

    pub fn onGamePacket(self: *NetworkHandler, conn: *Raknet.Connection, payload: []const u8) !void {
        const decompressed = try Compression.decompress(payload, self.options, self.allocator);
        defer decompressed.deinit();
        self.host.dispatch(self.host.ctx, conn, decompressed.packets);
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
                work.handler.host.dispatch(work.handler.host.ctx, work.conn, result.packets);
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

test "drainPackets caps by queue bound and budget, and requeues the rest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tasks = ThreadedTaskQueue.init(io, allocator, 1);
    try tasks.start();

    var handler = NetworkHandler{
        .host = undefined,
        .io = io,
        .tasks = &tasks,
        .allocator = allocator,
        .options = .{ .compression_method = .Zlib, .compression_threshold = 255 },
        .packet_queue = .empty,
        .packet_queue_mutex = .init,
        .decompress_pool = try DecompressWorkPool.init(io, allocator, 16),
        .scratch = undefined,
        .connections = connections_mod.ConnectionRegistry.init(allocator),
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
