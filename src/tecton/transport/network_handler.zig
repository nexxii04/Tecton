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
const FrameBuffers = @import("./frame_buffers.zig").FrameBuffers;

pub const QueuedPacket = queue.QueuedPacket;
pub const PacketDrainResult = queue.PacketDrainResult;
pub const ScratchBuffer = scratch_mod.ScratchBuffer;
pub const SendPriority = priority_mod.SendPriority;

const DECOMPRESS_POOL_CAPACITY: usize = 256;

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
    frame_buffers: ?*FrameBuffers = null,
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
        errdefer allocator.destroy(self);
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
        errdefer self.decompress_pool.deinit(allocator);
        self.scratch = ScratchBuffer.init(allocator);
        errdefer self.scratch.deinit();
        if (self.scratch.stream.capacity() == 0) return error.OutOfMemory;
        const frame_buffers = try allocator.create(FrameBuffers);
        errdefer allocator.destroy(frame_buffers);
        frame_buffers.* = FrameBuffers.init(allocator);
        self.frame_buffers = frame_buffers;
        return self;
    }

    pub fn startInputPump(self: *NetworkHandler) !void {
        if (self.input_pump != null) return;
        self.input_pump_running.store(true, .release);
        errdefer self.input_pump_running.store(false, .release);
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

    const publishToRing = @import("receive.zig").Methods(helper_scope).publishToRing;

    const enqueueLegacy = @import("receive.zig").Methods(helper_scope).enqueueLegacy;

    pub fn drainPackets(self: *NetworkHandler, budget_ns: u64, max_packets: usize) PacketDrainResult {
        if (self.inbound_ring) |ring| return self.drainRing(ring, budget_ns, max_packets);
        return self.drainLegacy(budget_ns, max_packets);
    }

    const drainRing = @import("receive.zig").Methods(helper_scope).drainRing;

    const drainLegacy = @import("receive.zig").Methods(helper_scope).drainLegacy;

    pub fn onGamePacket(self: *NetworkHandler, conn: *Raknet.Connection, payload: []const u8) !void {
        const decompressed = try Compression.decompress(payload, self.options, self.allocator);
        defer decompressed.deinit();
        self.host.dispatch(self.host.ctx, conn, decompressed.packets);
    }

    const workerBuffersForCurrentThread = @import("decompression.zig").Methods(helper_scope).workerBuffersForCurrentThread;

    const decompressTask = @import("decompression.zig").Methods(helper_scope).decompressTask;

    const ringDecompressTask = @import("decompression.zig").Methods(helper_scope).ringDecompressTask;

    const decompressCallback = @import("decompression.zig").Methods(helper_scope).decompressCallback;

    const decompressCleanup = @import("decompression.zig").Methods(helper_scope).decompressCleanup;

    pub const sendUncompressedPacket = @import("send.zig").Methods(helper_scope).sendUncompressedPacket;
    pub const sendPacket = @import("send.zig").Methods(helper_scope).sendPacket;
    pub const sendPacketWith = @import("send.zig").Methods(helper_scope).sendPacketWith;
    pub const sendImmediate = @import("send.zig").Methods(helper_scope).sendImmediate;
    pub const sendPackets = @import("send.zig").Methods(helper_scope).sendPackets;
    pub const sendPacketsWith = @import("send.zig").Methods(helper_scope).sendPacketsWith;
    pub const sendPacketsUncompressed = @import("send.zig").Methods(helper_scope).sendPacketsUncompressed;
    pub const sendPacketsUncompressedWith = @import("send.zig").Methods(helper_scope).sendPacketsUncompressedWith;

    pub fn deinit(self: *NetworkHandler) void {
        self.stopInputPump();
        Compression.deinitThreadLocal();
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
        if (self.frame_buffers) |buffers| {
            buffers.deinit();
            self.allocator.destroy(buffers);
            self.frame_buffers = null;
        }
        self.allocator.destroy(self);
    }
};

fn exerciseHandlerInit(allocator: std.mem.Allocator) !void {
    var tasks = ThreadedTaskQueue.init(std.testing.io, allocator, 1);
    defer tasks.deinit();
    const handler = try NetworkHandler.init(std.testing.io, allocator, &tasks, .{
        .ctx = &tasks,
        .dispatch = struct {
            fn run(_: *anyopaque, _: *Raknet.Connection, _: []const []const u8) void {}
        }.run,
        .disconnected = struct {
            fn run(_: *anyopaque, _: *Raknet.Connection) void {}
        }.run,
    });
    defer handler.deinit();
    try handler.enableInboundRing(64, 64);
}

test "network initialization unwinds allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseHandlerInit, .{});
}

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
    pub const Compression = test_owner.Compression;
};

test "drainPackets caps by queue bound and budget, and requeues the rest" {
    try @import("network_handler_test.zig").Suite(test_scope).case_000();
}

test "ring drainPackets processes in order, drops stale generations and honors the cap" {
    try @import("network_handler_test.zig").Suite(test_scope).case_001();
}

test "immediate batches borrow slab storage while normal sends retain their priority and allocator ownership" {
    try @import("network_handler_test.zig").Suite(test_scope).case_003();
}

test "oversize ring payloads dispatch intact bytes from reserved overflow slots" {
    try @import("network_handler_test.zig").Suite(test_scope).case_002();
}

test "steady state sends frame packets without allocating" {
    try @import("network_handler_test.zig").Suite(test_scope).case_004();
}

const helper_owner = @This();
const helper_scope = struct {
    pub const Raknet = helper_owner.Raknet;
    pub const CompressionOptions = helper_owner.CompressionOptions;
    pub const SendPriority = helper_owner.SendPriority;
    pub const std = helper_owner.std;
    pub const NetworkHandler = helper_owner.NetworkHandler;
    pub const InboundRing = helper_owner.InboundRing;
    pub const PacketDrainResult = helper_owner.PacketDrainResult;
    pub const queue = helper_owner.queue;
    pub const INPUT_DECOMPRESS_CAP = helper_owner.INPUT_DECOMPRESS_CAP;
    pub const DecompressWork = helper_owner.DecompressWork;
    pub const WorkerBuffers = helper_owner.WorkerBuffers;
    pub const threaded_tasks = helper_owner.threaded_tasks;
    pub const Compression = helper_owner.Compression;
    pub const ringDecompressTask = helper_owner.NetworkHandler.ringDecompressTask;
    pub const decompressTask = helper_owner.NetworkHandler.decompressTask;
    pub const decompressCallback = helper_owner.NetworkHandler.decompressCallback;
    pub const decompressCleanup = helper_owner.NetworkHandler.decompressCleanup;
};
