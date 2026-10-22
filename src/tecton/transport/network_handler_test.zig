const FrameBuffers = @import("./frame_buffers.zig").FrameBuffers;
const PayloadBuffers = @import("./payload_buffers.zig").PayloadBuffers;

pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Raknet = scope.Raknet;
        const ThreadedTaskQueue = scope.ThreadedTaskQueue;
        const queue = scope.queue;
        const connections_mod = scope.connections_mod;
        const DecompressWorkPool = scope.DecompressWorkPool;
        const NetworkHandler = scope.NetworkHandler;
        const TestDispatchState = scope.TestDispatchState;

        fn testDispatch(ctx: *anyopaque, conn: *Raknet.Connection, packets: []const []const u8) void {
            _ = conn;
            const state: *TestDispatchState = @ptrCast(@alignCast(ctx));
            state.dispatched_packets += packets.len;
            if (state.expected_fill) |fill| {
                for (packets) |packet| {
                    for (packet) |byte| {
                        if (byte != fill) state.content_mismatch = true;
                    }
                }
            }
        }

        fn testDisconnected(ctx: *anyopaque, conn: *Raknet.Connection) void {
            _ = ctx;
            _ = conn;
        }

        fn buildTestHandler(io: std.Io, allocator: std.mem.Allocator, tasks: *ThreadedTaskQueue, dispatch_ctx: *anyopaque) NetworkHandler {
            return .{
                .host = .{ .ctx = dispatch_ctx, .dispatch = testDispatch, .disconnected = testDisconnected },
                .io = io,
                .tasks = tasks,
                .allocator = allocator,
                .options = .{ .compression_method = .Zlib, .compression_threshold = 255 },
                .packet_queue = .empty,
                .packet_queue_mutex = .init,
                .decompress_pool = DecompressWorkPool.init(io, allocator, 16) catch unreachable,
                .scratch = undefined,
                .frame_buffers = null,
                .payload_buffers = PayloadBuffers.init(allocator),
                .connections = connections_mod.ConnectionRegistry.init(allocator),
            };
        }

        fn releaseTestRing(handler: *NetworkHandler, allocator: std.mem.Allocator) void {
            for (handler.worker_buffers) |*buffers| buffers.deinit();
            if (handler.worker_buffers.len > 0) allocator.free(handler.worker_buffers);
            handler.worker_buffers = &.{};
            if (handler.inbound_ring) |ring| ring.deinit();
            handler.inbound_ring = null;
        }

        pub fn case_000() !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;

            var tasks = ThreadedTaskQueue.init(io, allocator, 1);
            try tasks.start();

            var dispatch_state = TestDispatchState{};
            var handler = buildTestHandler(io, allocator, &tasks, &dispatch_state);

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

            var attempts: usize = 0;
            while (handler.decompress_pending.load(.monotonic) != 0 and attempts < 1000) : (attempts += 1) {
                tasks.drainCompleted(std.math.maxInt(u64));
                io.sleep(.fromNanoseconds(1_000_000), .awake) catch {};
            }
            try std.testing.expectEqual(@as(usize, 0), handler.decompress_pending.load(.monotonic));

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

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;

            var tasks = ThreadedTaskQueue.init(io, allocator, 1);
            try tasks.start();

            var dispatch_state = TestDispatchState{};
            var handler = buildTestHandler(io, allocator, &tasks, &dispatch_state);
            try handler.enableInboundRing(8, 64);

            defer releaseTestRing(&handler, allocator);
            defer handler.decompress_pool.deinit(allocator);
            defer tasks.deinit();
            defer handler.connections.deinit();

            var conn_storage: [2]u128 align(16) = .{ 0, 0 };
            const live: *Raknet.Connection = @ptrCast(&conn_storage[0]);
            const resigned: *Raknet.Connection = @ptrCast(&conn_storage[1]);
            handler.connections.register(io, live);
            handler.connections.register(io, resigned);
            const live_generation = handler.connections.currentGeneration(io, live) orelse return error.TestUnexpectedResult;
            const resigned_generation = handler.connections.currentGeneration(io, resigned) orelse return error.TestUnexpectedResult;

            const ring = handler.inbound_ring.?;
            for (0..4) |i| {
                const payload = [_]u8{@intCast(i)} ** 16;
                try std.testing.expectEqual(false, ring.publish(live, live_generation, &payload).?);
            }
            try std.testing.expectEqual(false, ring.publish(resigned, resigned_generation, "stale").?);

            handler.connections.unregister(io, resigned);

            const capped = handler.drainPackets(std.math.maxInt(u64), 2);
            try std.testing.expectEqual(@as(usize, 2), capped.processed);
            try std.testing.expectEqual(@as(usize, 3), capped.remaining);

            const starved = handler.drainPackets(0, 4096);
            try std.testing.expectEqual(@as(usize, 1), starved.processed);
            try std.testing.expectEqual(@as(usize, 2), starved.remaining);

            const rest = handler.drainPackets(std.math.maxInt(u64), 4096);
            try std.testing.expectEqual(@as(usize, 1), rest.processed);
            try std.testing.expectEqual(@as(usize, 0), rest.remaining);

            const empty = handler.drainPackets(std.math.maxInt(u64), 4096);
            try std.testing.expectEqual(@as(usize, 0), empty.processed);
            try std.testing.expectEqual(@as(usize, 0), empty.remaining);

            var attempts: usize = 0;
            while (dispatch_state.dispatched_packets < 4 and attempts < 1000) : (attempts += 1) {
                tasks.drainCompleted(std.math.maxInt(u64));
                io.sleep(.fromNanoseconds(1_000_000), .awake) catch {};
            }
            try std.testing.expectEqual(@as(usize, 4), dispatch_state.dispatched_packets);
            try std.testing.expectEqual(@as(usize, 0), handler.decompress_pending.load(.monotonic));
            try std.testing.expectEqual(@as(usize, 0), ring.depth());
            try std.testing.expectEqual(@as(usize, 0), ring.dropped_full.load(.monotonic));
        }

        pub fn case_003() !void {
            const allocator = std.testing.allocator;
            var failing = std.testing.FailingAllocator.init(allocator, .{});
            var transport = try Raknet.Server.init(std.testing.io, .{
                .allocator = failing.allocator(),
                .address = "127.0.0.1",
                .port = 0,
                .output_slab_slots = 4,
                .transient_slab_slots = 4,
                .outbound_queue_slots = 8,
            });
            defer transport.deinit();
            var tasks = ThreadedTaskQueue.init(std.testing.io, allocator, 1);
            defer tasks.deinit();
            var state = TestDispatchState{};
            const handler = try NetworkHandler.init(std.testing.io, allocator, &tasks, .{
                .ctx = &state,
                .dispatch = testDispatch,
                .disconnected = testDisconnected,
            });
            defer handler.deinit();
            const conn = try allocator.create(Raknet.Connection);
            defer allocator.destroy(conn);
            conn.* = Raknet.Connection.init(&transport, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 1 } }, 1400, 1);
            defer conn.deinit();
            const packets = [_][]const u8{ "first", "second" };
            const allocations = failing.alloc_index;
            failing.fail_index = allocations;
            try handler.sendPacketsUncompressedWith(conn, &packets, .immediate);
            try std.testing.expectEqual(allocations, failing.alloc_index);
            try std.testing.expect(!failing.has_induced_failure);
            try std.testing.expectEqual(@as(usize, 1), conn.comm_data.output_backup.count());
            var iter = conn.comm_data.output_backup.valueIterator();
            const backup = iter.next().?;
            var frames: [2]Raknet.Proto.Frame = undefined;
            const frameset = try Raknet.Proto.FrameSet.deserializeInto(backup.bytes, &frames);
            try std.testing.expectEqual(@as(usize, 1), frameset.frames.len);
            const decoded = try scope.Compression.decompress(frameset.frames[0].payload, handler.options, allocator);
            defer decoded.deinit();
            try std.testing.expectEqualStrings("first", decoded.packets[0]);
            try std.testing.expectEqualStrings("second", decoded.packets[1]);
            var ack_buf: [64]u8 = undefined;
            const ack = try Raknet.Proto.Ack.serializeInto(&.{frameset.sequence_number}, Raknet.Proto.Packets.Ack, &ack_buf);
            try conn.handleAck(ack);
            try std.testing.expectEqual(@as(usize, 4), transport.output_slab.available());
            failing.fail_index = std.math.maxInt(usize);
            try handler.sendPacketsUncompressedWith(conn, &packets, .normal);
            try std.testing.expectEqual(@as(usize, 1), conn.comm_data.output_frame_queue.items.len);
            try handler.sendPacketWith(conn, "owned by a distinct allocator", .normal);
            try std.testing.expectEqual(@as(usize, 2), conn.comm_data.output_frame_queue.items.len);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;

            var tasks = ThreadedTaskQueue.init(io, allocator, 1);
            try tasks.start();

            var dispatch_state = TestDispatchState{};
            var handler = buildTestHandler(io, allocator, &tasks, &dispatch_state);
            try handler.enableInboundRing(4, 64);

            defer releaseTestRing(&handler, allocator);
            defer handler.decompress_pool.deinit(allocator);
            defer tasks.deinit();
            defer handler.connections.deinit();

            var conn_storage: u128 align(16) = 0;
            const conn: *Raknet.Connection = @ptrCast(&conn_storage);
            handler.connections.register(io, conn);
            const generation = handler.connections.currentGeneration(io, conn) orelse return error.TestUnexpectedResult;

            const ring = handler.inbound_ring.?;
            const fill: u8 = 0x37;
            const slab_payload = [_]u8{fill} ** 32;
            const overflow_payload = [_]u8{fill} ** 100;
            try std.testing.expectEqual(false, ring.publish(conn, generation, &slab_payload).?);
            try std.testing.expectEqual(true, ring.publish(conn, generation, &overflow_payload).?);

            dispatch_state.expected_fill = fill;
            const result = handler.drainPackets(std.math.maxInt(u64), 4096);
            try std.testing.expectEqual(@as(usize, 2), result.processed);

            var attempts: usize = 0;
            while (dispatch_state.dispatched_packets < 2 and attempts < 1000) : (attempts += 1) {
                tasks.drainCompleted(std.math.maxInt(u64));
                io.sleep(.fromNanoseconds(1_000_000), .awake) catch {};
            }
            try std.testing.expectEqual(@as(usize, 2), dispatch_state.dispatched_packets);
            try std.testing.expectEqual(@as(usize, 0), handler.decompress_pending.load(.monotonic));
            try std.testing.expect(!dispatch_state.content_mismatch);
            try std.testing.expectEqual(@as(usize, 1), ring.oversize_count.load(.monotonic));
        }

        pub fn case_004() !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;

            var transport_failing = std.testing.FailingAllocator.init(allocator, .{});
            var transport = try Raknet.Server.init(io, .{
                .allocator = transport_failing.allocator(),
                .address = "127.0.0.1",
                .port = 0,
                .output_slab_slots = 4,
                .transient_slab_slots = 4,
                .outbound_queue_slots = 8,
            });
            defer transport.deinit();

            var tasks = ThreadedTaskQueue.init(io, allocator, 1);
            defer tasks.deinit();

            var handler_failing = std.testing.FailingAllocator.init(allocator, .{});
            var state = TestDispatchState{};
            const handler = try NetworkHandler.init(io, handler_failing.allocator(), &tasks, .{
                .ctx = &state,
                .dispatch = testDispatch,
                .disconnected = testDisconnected,
            });
            defer handler.deinit();

            const conn = try allocator.create(Raknet.Connection);
            defer allocator.destroy(conn);
            conn.* = Raknet.Connection.init(&transport, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 1 } }, 1400, 1);
            defer conn.deinit();

            try conn.comm_data.output_frame_queue.ensureTotalCapacity(transport_failing.allocator(), 64);

            const warmup = [_]u8{0x5A} ** 900;
            for (0..4) |_| try handler.sendPacket(conn, &warmup);
            for (conn.comm_data.output_frame_queue.items) |*frame| frame.deinit();
            conn.comm_data.output_frame_queue.clearRetainingCapacity();
            try std.testing.expect(handler.frame_buffers != null);
            try std.testing.expectEqual(@as(usize, FrameBuffers.slot_count), handler.frame_buffers.?.available());

            const transport_before = transport_failing.alloc_index;
            const handler_before = handler_failing.alloc_index;
            transport_failing.fail_index = transport_before;
            handler_failing.fail_index = handler_before;

            const queued_before = conn.comm_data.output_frame_queue.items.len;

            var expected: [4][300]u8 = undefined;
            for (&expected, 0..) |*packet, index| {
                @memset(packet, @intCast(index + 1));
                try handler.sendPacket(conn, packet);
            }
            try handler.sendUncompressedPacket(conn, "handshake reply");
            try handler.sendPacketsUncompressed(conn, &.{ "first", "second" });

            try std.testing.expectEqual(transport_before, transport_failing.alloc_index);
            try std.testing.expectEqual(handler_before, handler_failing.alloc_index);
            try std.testing.expect(!transport_failing.has_induced_failure);
            try std.testing.expect(!handler_failing.has_induced_failure);

            transport_failing.fail_index = std.math.maxInt(usize);
            handler_failing.fail_index = std.math.maxInt(usize);

            const frames = conn.comm_data.output_frame_queue.items[queued_before..];
            try std.testing.expectEqual(@as(usize, 6), frames.len);
            for (frames[0..4], 0..) |*frame, index| {
                const decoded = try scope.Compression.decompress(frame.payload, handler.options, allocator);
                defer decoded.deinit();
                try std.testing.expectEqual(@as(usize, 1), decoded.packets.len);
                try std.testing.expectEqualSlices(u8, &expected[index], decoded.packets[0]);
            }

            {
                const decoded = try scope.Compression.decompress(frames[4].payload, handler.options, allocator);
                defer decoded.deinit();
                try std.testing.expectEqualStrings("handshake reply", decoded.packets[0]);
            }
            {
                const decoded = try scope.Compression.decompress(frames[5].payload, handler.options, allocator);
                defer decoded.deinit();
                try std.testing.expectEqual(@as(usize, 2), decoded.packets.len);
                try std.testing.expectEqualStrings("first", decoded.packets[0]);
                try std.testing.expectEqualStrings("second", decoded.packets[1]);
            }

            for (conn.comm_data.output_frame_queue.items) |*frame| frame.deinit();
            try std.testing.expectEqual(@as(usize, FrameBuffers.slot_count), handler.frame_buffers.?.available());
        }
    };
}
