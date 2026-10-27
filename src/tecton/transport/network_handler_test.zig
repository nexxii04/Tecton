pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Connection = scope.Connection;
        const ThreadedTaskQueue = scope.ThreadedTaskQueue;
        const NetworkHandler = scope.NetworkHandler;
        const TestDispatchState = scope.TestDispatchState;
        const TransportFake = scope.TransportFake;

        fn testDispatch(ctx: *anyopaque, conn: *Connection, packets: []const []const u8) void {
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

        fn drainUntilIdle(tasks: *ThreadedTaskQueue, handler: *NetworkHandler, io: std.Io) !void {
            var attempts: usize = 0;
            while (handler.decompress_pending.load(.monotonic) != 0 and attempts < 1000) : (attempts += 1) {
                tasks.drainCompleted(std.math.maxInt(u64));
                io.sleep(.fromNanoseconds(1_000_000), .awake) catch {};
            }
            try std.testing.expectEqual(@as(usize, 0), handler.decompress_pending.load(.monotonic));
        }

        pub fn case_000() !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;

            var tasks = ThreadedTaskQueue.init(io, allocator, 1);
            try tasks.start();
            defer tasks.deinit();

            var dispatch_state = TestDispatchState{};
            const handler = try NetworkHandler.init(io, allocator, &tasks, .{
                .ctx = &dispatch_state,
                .dispatch = testDispatch,
            });
            defer handler.deinit();

            var backend: u128 = 0;
            const conn = try handler.connections.create(&backend);

            for (0..10) |_| {
                conn.retain();
                try handler.packet_queue.append(allocator, .{
                    .conn = conn,
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

            try drainUntilIdle(&tasks, handler, io);
            handler.connections.closeAndRelease(conn);
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;

            var tasks = ThreadedTaskQueue.init(io, allocator, 1);
            try tasks.start();
            defer tasks.deinit();

            var dispatch_state = TestDispatchState{};
            const handler = try NetworkHandler.init(io, allocator, &tasks, .{
                .ctx = &dispatch_state,
                .dispatch = testDispatch,
            });
            defer handler.deinit();
            try handler.enableInboundRing(8, 64);

            const ring = handler.inbound_ring.?;

            var live_backend: u128 = 0;
            var closed_backend: u128 = 0;
            const live = try handler.connections.create(&live_backend);
            const resigned = try handler.connections.create(&closed_backend);

            for (0..4) |i| {
                const payload = [_]u8{@intCast(i + 1)} ** 16;
                NetworkHandler.onPacket(handler, live, &payload);
            }
            NetworkHandler.onPacket(handler, resigned, "stale");
            handler.connections.closeAndRelease(resigned);

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
            try drainUntilIdle(&tasks, handler, io);
            try std.testing.expectEqual(@as(usize, 0), ring.depth());
            try std.testing.expectEqual(@as(usize, 0), ring.dropped_full.load(.monotonic));

            handler.connections.closeAndRelease(live);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;

            var tasks = ThreadedTaskQueue.init(io, allocator, 1);
            try tasks.start();
            defer tasks.deinit();

            var dispatch_state = TestDispatchState{};
            const handler = try NetworkHandler.init(io, allocator, &tasks, .{
                .ctx = &dispatch_state,
                .dispatch = testDispatch,
            });
            defer handler.deinit();
            try handler.enableInboundRing(4, 64);

            var backend: u128 = 0;
            const conn = try handler.connections.create(&backend);

            const ring = handler.inbound_ring.?;
            const fill: u8 = 0x37;
            const slab_payload = [_]u8{fill} ** 32;
            const overflow_payload = [_]u8{fill} ** 100;
            NetworkHandler.onPacket(handler, conn, &slab_payload);
            NetworkHandler.onPacket(handler, conn, &overflow_payload);

            dispatch_state.expected_fill = fill;
            const result = handler.drainPackets(std.math.maxInt(u64), 4096);
            try std.testing.expectEqual(@as(usize, 2), result.processed);

            var attempts: usize = 0;
            while (dispatch_state.dispatched_packets < 2 and attempts < 1000) : (attempts += 1) {
                tasks.drainCompleted(std.math.maxInt(u64));
                io.sleep(.fromNanoseconds(1_000_000), .awake) catch {};
            }
            try std.testing.expectEqual(@as(usize, 2), dispatch_state.dispatched_packets);
            try drainUntilIdle(&tasks, handler, io);
            try std.testing.expect(!dispatch_state.content_mismatch);
            try std.testing.expectEqual(@as(usize, 1), ring.oversize_count.load(.monotonic));

            handler.connections.closeAndRelease(conn);
        }

        pub fn case_004() !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;

            var tasks = ThreadedTaskQueue.init(io, allocator, 1);
            defer tasks.deinit();

            var fake = TransportFake.init(allocator);
            defer fake.deinit();

            var failing = std.testing.FailingAllocator.init(allocator, .{});
            const handler = try NetworkHandler.init(io, failing.allocator(), &tasks, .{
                .ctx = undefined,
                .dispatch = testDispatch,
            });
            defer handler.deinit();
            handler.port = fake.port();

            var backend: u128 = 0;
            const conn = try handler.connections.create(&backend);

            const warmup = [_]u8{0x5A} ** 900;
            for (0..4) |_| try handler.sendPacket(conn, &warmup);
            const slot_count = handler.frame_buffers.?.available();
            fake.clear();

            const allocations = failing.alloc_index;
            failing.fail_index = allocations;

            var expected: [4][300]u8 = undefined;
            for (&expected, 0..) |*packet, index| {
                @memset(packet, @intCast(index + 1));
                try handler.sendPacket(conn, packet);
            }
            try handler.sendUncompressedPacket(conn, "handshake reply");
            try handler.sendPacketsUncompressed(conn, &.{ "first", "second" });

            try std.testing.expectEqual(allocations, failing.alloc_index);
            try std.testing.expect(!failing.has_induced_failure);
            try std.testing.expectEqual(slot_count, handler.frame_buffers.?.available());

            failing.fail_index = std.math.maxInt(usize);

            const sent = fake.sent.items;
            try std.testing.expectEqual(@as(usize, 6), sent.len);
            for (sent[0..4], 0..) |*entry, index| {
                try std.testing.expectEqual(conn.id, entry.conn_id);
                const decoded = try scope.Compression.decompress(entry.bytes, handler.options, allocator);
                defer decoded.deinit();
                try std.testing.expectEqual(@as(usize, 1), decoded.packets.len);
                try std.testing.expectEqualSlices(u8, &expected[index], decoded.packets[0]);
            }

            {
                const decoded = try scope.Compression.decompress(sent[4].bytes, handler.options, allocator);
                defer decoded.deinit();
                try std.testing.expectEqualStrings("handshake reply", decoded.packets[0]);
            }
            {
                const decoded = try scope.Compression.decompress(sent[5].bytes, handler.options, allocator);
                defer decoded.deinit();
                try std.testing.expectEqual(@as(usize, 2), decoded.packets.len);
                try std.testing.expectEqualStrings("first", decoded.packets[0]);
                try std.testing.expectEqualStrings("second", decoded.packets[1]);
            }

            handler.connections.closeAndRelease(conn);
        }

        pub fn case_005() !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;

            var tasks = ThreadedTaskQueue.init(io, allocator, 1);
            defer tasks.deinit();

            var fake = TransportFake.init(allocator);
            defer fake.deinit();

            const handler = try NetworkHandler.init(io, allocator, &tasks, .{
                .ctx = undefined,
                .dispatch = testDispatch,
            });
            defer handler.deinit();
            handler.port = fake.port();

            var backend: u128 = 0;
            const conn = try handler.connections.create(&backend);

            try handler.sendPacketsUncompressedWith(conn, &.{ "first", "second" }, .immediate);

            try std.testing.expectEqual(@as(usize, 1), fake.sent.items.len);
            const frame = fake.sent.items[0].bytes;
            try std.testing.expectEqual(@as(u8, 254), frame[0]);
            try std.testing.expectEqual(@as(u8, 0xFF), frame[1]);

            const decoded = try scope.Compression.decompress(frame, handler.options, allocator);
            defer decoded.deinit();
            try std.testing.expectEqual(@as(usize, 2), decoded.packets.len);
            try std.testing.expectEqualStrings("first", decoded.packets[0]);
            try std.testing.expectEqualStrings("second", decoded.packets[1]);

            handler.connections.closeAndRelease(conn);
        }
    };
}
