const std = @import("std");

const protocol = @import("protocol");
const Raknet = @import("Raknet");

const threaded_tasks = @import("../tasks/threaded_tasks.zig");
const ThreadedTaskQueue = threaded_tasks.ThreadedTaskQueue;
const CompressionOptions = @import("./compression/options.zig").CompressionOptions;
const Compression = @import("./compression/root.zig").Compression;
const DecompressResult = @import("./compression/root.zig").DecompressResult;
const ArenaDecompressResult = @import("./compression/root.zig").ArenaDecompressResult;

const node_pool = @import("./node_pool.zig");
const queue = @import("./queue.zig");
const scratch_mod = @import("./scratch.zig");
const connections_mod = @import("./connections.zig");
const priority_mod = @import("./priority.zig");
const host_mod = @import("./host.zig");
const InboundRing = @import("./inbound_ring.zig").InboundRing;
const worker_buffers_mod = @import("./worker_buffers.zig");
const WorkerBuffers = worker_buffers_mod.WorkerBuffers;

pub const QueuedPacket = queue.QueuedPacket;
pub const PacketDrainResult = queue.PacketDrainResult;
pub const ScratchBuffer = scratch_mod.ScratchBuffer;
pub const SendPriority = priority_mod.SendPriority;

const DECOMPRESS_POOL_CAPACITY: usize = 1024;

const INPUT_DECOMPRESS_CAP: usize = 128;

const INPUT_PUMP_SLEEP_NS: u64 = 200_000;
const INPUT_PUMP_BUDGET_NS: u64 = 2_000_000;
const INPUT_PUMP_MAX_PACKETS: usize = 4096;

const RingSlot = struct {
    ring: *InboundRing,
    slot: u32,
};

const DecompressWork = struct {
    conn: *Raknet.Connection,
    generation: u64,
    raw: []const u8,

    raw_heap: ?[]u8 = null,
    ring: ?RingSlot = null,
    allocator: std.mem.Allocator,
    handler: *NetworkHandler,
    decompressed: ?DecompressResult = null,
    arena_result: ?ArenaDecompressResult = null,

    arena_outstanding: ?*std.atomic.Value(u32) = null,
    completed: bool = false,
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
    inbound_ring: ?*InboundRing = null,

    input_pump: ?std.Thread = null,
    input_pump_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_buffers: []WorkerBuffers = &.{},

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

    pub fn startInputPump(self: *NetworkHandler) !void {
        if (self.input_pump != null) return;
        self.input_pump_running.store(true, .release);
        self.input_pump = try std.Thread.spawn(.{}, inputPumpLoop, .{self});
    }

    pub fn stopInputPump(self: *NetworkHandler) void {
        self.input_pump_running.store(false, .release);
        if (self.input_pump) |thread| {
            thread.join();
            self.input_pump = null;
        }
    }

    pub fn inputPumpActive(self: *const NetworkHandler) bool {
        return self.input_pump != null;
    }

    pub fn queuedInputDepth(self: *NetworkHandler) usize {
        if (self.inbound_ring) |ring| return ring.depth();
        self.packet_queue_mutex.lock(self.io) catch return 0;
        defer self.packet_queue_mutex.unlock(self.io);
        return self.packet_queue.items.len;
    }

    fn inputPumpLoop(self: *NetworkHandler) void {
        while (self.input_pump_running.load(.acquire)) {
            const result = self.drainPackets(INPUT_PUMP_BUDGET_NS, INPUT_PUMP_MAX_PACKETS);
            if (result.processed > 0) continue;
            if (result.remaining > 0) {
                std.Thread.yield() catch {};
                continue;
            }
            self.io.sleep(.fromNanoseconds(INPUT_PUMP_SLEEP_NS), .awake) catch {};
        }
    }

    pub fn enableInboundRing(self: *NetworkHandler, slots: usize, slot_size: usize) !void {
        if (self.inbound_ring != null) return;
        const slot_count = std.math.ceilPowerOfTwo(usize, @max(slots, 64)) catch return error.InvalidRingSize;
        const ring = try InboundRing.create(self.allocator, slot_count, @max(slot_size, 64));
        errdefer ring.deinit();

        const worker_count = @max(@as(usize, 1), self.tasks.workerCount());
        const buffers = try self.allocator.alloc(WorkerBuffers, worker_count);
        errdefer self.allocator.free(buffers);
        for (buffers) |*buffers_entry| buffers_entry.* = WorkerBuffers.init(self.allocator);

        self.worker_buffers = buffers;
        self.inbound_ring = ring;
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
        if (self.inbound_ring) |ring| {
            self.publishToRing(ring, conn, payload);
            return;
        }
        self.enqueueLegacy(conn, payload);
    }

    fn publishToRing(self: *NetworkHandler, ring: *InboundRing, conn: *Raknet.Connection, payload: []const u8) void {
        const generation = self.connections.currentGeneration(self.io, conn) orelse return;
        _ = ring.publish(self.allocator, conn, generation, payload) orelse {
            _ = self.dropped_packets.fetchAdd(1, .monotonic);
            return;
        };
    }

    fn enqueueLegacy(self: *NetworkHandler, conn: *Raknet.Connection, payload: []const u8) void {
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

        self.packet_queue.append(self.allocator, .{
            .conn = conn,
            .generation = generation,
            .payload = copy,
        }) catch {
            self.allocator.free(copy);
            return;
        };
    }

    pub fn drainPackets(self: *NetworkHandler, budget_ns: u64, max_packets: usize) PacketDrainResult {
        if (self.inbound_ring) |ring| return self.drainRing(ring, budget_ns, max_packets);
        return self.drainLegacy(budget_ns, max_packets);
    }

    fn drainRing(self: *NetworkHandler, ring: *InboundRing, budget_ns: u64, max_packets: usize) PacketDrainResult {
        const io = self.io;
        const started = std.Io.Timestamp.now(io, .awake);
        const cap = queue.drainCap(max_packets);

        var scanned: usize = 0;
        var enqueued: usize = 0;
        while (scanned < cap) {
            const elapsed: u64 = @intCast(@max(0, started.durationTo(.now(io, .awake)).nanoseconds));
            if (enqueued > 0 and elapsed >= budget_ns) break;
            if (self.decompress_pending.load(.monotonic) >= INPUT_DECOMPRESS_CAP) {
                if (elapsed >= budget_ns) break;
                std.Thread.yield() catch {};
                continue;
            }

            const popped = ring.pop() orelse break;
            scanned += 1;

            const current_generation = self.connections.currentGeneration(io, popped.entry.conn) orelse {
                ring.discard(popped);
                continue;
            };
            if (current_generation != popped.entry.generation) {
                ring.discard(popped);
                continue;
            }

            const work = self.decompress_pool.acquire(self.allocator) orelse {
                ring.discard(popped);
                continue;
            };
            const raw: []const u8 = if (popped.heap) |heap|
                heap
            else
                ring.slab[popped.slot * ring.slot_size ..][0..popped.entry.len];
            work.* = .{
                .conn = popped.entry.conn,
                .generation = popped.entry.generation,
                .raw = raw,
                .raw_heap = popped.heap,
                .ring = .{ .ring = ring, .slot = popped.slot },
                .allocator = self.allocator,
                .handler = self,
            };

            _ = self.decompress_pending.fetchAdd(1, .monotonic);
            self.tasks.enqueue(.{
                .work = ringDecompressTask,
                .callback = decompressCallback,
                .cleanup = decompressCleanup,
                .ctx = @ptrCast(work),

                .shard_key = popped.entry.generation,
                .kind = .input,
            }) catch {
                _ = self.decompress_pending.fetchSub(1, .monotonic);
                ring.discard(popped);
                self.decompress_pool.release(work);
                continue;
            };

            enqueued += 1;
        }

        return .{ .processed = enqueued, .remaining = ring.depth() };
    }

    fn drainLegacy(self: *NetworkHandler, budget_ns: u64, max_packets: usize) PacketDrainResult {
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

            if (self.decompress_pending.load(.monotonic) >= INPUT_DECOMPRESS_CAP) break;

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
            _ = self.decompress_pending.fetchAdd(1, .monotonic);
            self.tasks.enqueue(.{
                .work = decompressTask,
                .callback = decompressCallback,
                .cleanup = decompressCleanup,
                .ctx = @ptrCast(work),
                .shard_key = entry.generation,
                .kind = .input,
            }) catch {
                std.debug.print("[net-drain] threaded_tasks enqueue FAILED\n", .{});
                _ = self.decompress_pending.fetchSub(1, .monotonic);
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
            return .{ .processed = enqueued, .remaining = 0 };
        };
        var arrivals = self.packet_queue;
        queue.requeueLeftover(&batch, &arrivals, self.allocator, consumed);
        self.packet_queue = batch;
        const remaining = self.packet_queue.items.len;
        self.packet_queue_mutex.unlock(io);

        return .{ .processed = enqueued, .remaining = remaining };
    }

    pub fn onGamePacket(self: *NetworkHandler, conn: *Raknet.Connection, payload: []const u8) !void {
        const decompressed = try Compression.decompress(payload, self.options, self.allocator);
        defer decompressed.deinit();
        self.host.dispatch(self.host.ctx, conn, decompressed.packets);
    }

    fn workerBuffersForCurrentThread(self: *NetworkHandler) ?*WorkerBuffers {
        if (self.worker_buffers.len == 0) return null;
        const index = threaded_tasks.currentWorkerIndex() orelse return &self.worker_buffers[0];
        if (index >= self.worker_buffers.len) return &self.worker_buffers[index % self.worker_buffers.len];
        return &self.worker_buffers[index];
    }

    fn decompressTask(ctx: *anyopaque) void {
        const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));
        defer {
            work.completed = true;
            _ = work.handler.decompress_pending.fetchSub(1, .monotonic);
        }
        work.decompressed = Compression.decompress(work.raw, work.handler.options, work.allocator) catch |err| {
            std.log.err("decompress failed: {}", .{err});
            work.allocator.free(work.raw);
            work.raw = &.{};
            return;
        };
        work.allocator.free(work.raw);
        work.raw = &.{};
    }

    fn ringDecompressTask(ctx: *anyopaque) void {
        const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));
        defer {
            work.completed = true;
            _ = work.handler.decompress_pending.fetchSub(1, .monotonic);
        }

        var decoded = false;
        if (work.handler.workerBuffersForCurrentThread()) |buffers| {
            if (buffers.claim(&work.handler.tasks.stop_requested)) |index| {
                const arena_allocator = buffers.arenas[index].allocator();
                if (Compression.decompressInto(work.raw, work.handler.options, arena_allocator)) |result| {
                    work.arena_result = result;
                    work.arena_outstanding = buffers.outstandingCounter(index);
                    _ = work.arena_outstanding.?.fetchAdd(1, .release);
                    decoded = true;
                } else |err| {
                    std.log.err("decompress failed: {}", .{err});
                }
            }
        }

        if (!decoded) {
            if (Compression.decompress(work.raw, work.handler.options, work.allocator)) |result| {
                work.decompressed = result;
            } else |err| {
                std.log.err("decompress failed: {}", .{err});
            }
        }
    }

    fn decompressCallback(ctx: *anyopaque) void {
        const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));
        const packets: ?[][]const u8 = if (work.arena_result) |result|
            result.packets
        else if (work.decompressed) |result|
            result.packets
        else
            null;

        if (packets) |entries| {
            if (work.handler.connections.isCurrent(work.handler.io, work.conn, work.generation)) {
                work.handler.host.dispatch(work.handler.host.ctx, work.conn, entries);
            }
        }
        if (work.decompressed) |result| result.deinit();
        work.decompressed = null;

        if (work.raw_heap) |heap| {
            work.allocator.free(heap);
            work.raw_heap = null;
        }

        if (work.ring) |ring_slot| ring_slot.ring.release(ring_slot.slot);
        work.ring = null;
        if (work.arena_outstanding) |outstanding| {
            const previous = outstanding.fetchSub(1, .acq_rel);
            std.debug.assert(previous > 0);
        }
        work.arena_outstanding = null;

        work.handler.decompress_pool.release(work);
    }

    fn decompressCleanup(ctx: *anyopaque) void {
        const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));
        if (work.decompressed) |result| result.deinit();
        work.decompressed = null;
        if (work.raw_heap) |heap| {
            work.allocator.free(heap);
            work.raw_heap = null;
        }
        if (work.raw.len > 0 and work.raw_heap == null and work.ring == null) {
            work.allocator.free(work.raw);
            work.raw = &.{};
        }
        if (work.ring) |ring_slot| ring_slot.ring.release(ring_slot.slot);
        work.ring = null;
        if (work.arena_outstanding) |outstanding| {
            _ = outstanding.fetchSub(1, .acq_rel);
        }
        work.arena_outstanding = null;

        if (!work.completed) {
            work.completed = true;
            const pending_before = work.handler.decompress_pending.fetchSub(1, .monotonic);
            std.debug.assert(pending_before > 0);
        }
        work.handler.decompress_pool.release(work);
    }

    pub fn sendUncompressedPacket(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
        const packets = [_][]const u8{packet};
        const options = CompressionOptions{ .compression_method = .NotPresent, .compression_threshold = 255 };
        const compressed = try Compression.compress(&packets, options, self.allocator);
        defer self.allocator.free(compressed);
        deliver(conn, compressed, .normal);
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
        self.stopInputPump();
        for (self.packet_queue.items) |entry| self.allocator.free(entry.payload);
        self.packet_queue.deinit(self.allocator);
        for (self.worker_buffers) |*buffers| buffers.deinit();
        if (self.worker_buffers.len > 0) self.allocator.free(self.worker_buffers);
        self.worker_buffers = &.{};
        if (self.inbound_ring) |ring| ring.deinit();
        self.inbound_ring = null;
        self.decompress_pool.deinit(self.allocator);
        self.scratch.deinit();
        self.connections.deinit();
        self.allocator.destroy(self);
    }
};

const TestDispatchState = struct {
    dispatched_packets: usize = 0,
    expected_fill: ?u8 = null,
    content_mismatch: bool = false,
};

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const Raknet = test_owner.Raknet;
    pub const ThreadedTaskQueue = test_owner.ThreadedTaskQueue;
    pub const queue = test_owner.queue;
    pub const connections_mod = test_owner.connections_mod;
    pub const DecompressWorkPool = test_owner.DecompressWorkPool;
    pub const NetworkHandler = test_owner.NetworkHandler;
    pub const TestDispatchState = test_owner.TestDispatchState;
};

test "drainPackets caps by queue bound and budget, and requeues the rest" {
    try @import("network_handler_test.zig").Suite(test_scope).case_000();
}

test "ring drainPackets processes in order, drops stale generations and honors the cap" {
    try @import("network_handler_test.zig").Suite(test_scope).case_001();
}

test "oversize ring payloads dispatch intact bytes from the heap fallback" {
    try @import("network_handler_test.zig").Suite(test_scope).case_002();
}
