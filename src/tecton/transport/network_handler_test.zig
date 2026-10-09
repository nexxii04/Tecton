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
                try std.testing.expectEqual(false, ring.publish(allocator, live, live_generation, &payload).?);
            }
            try std.testing.expectEqual(false, ring.publish(allocator, resigned, resigned_generation, "stale").?);

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
            const heap_payload = [_]u8{fill} ** 100;
            try std.testing.expectEqual(false, ring.publish(allocator, conn, generation, &slab_payload).?);
            try std.testing.expectEqual(true, ring.publish(allocator, conn, generation, &heap_payload).?);

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
    };
}
