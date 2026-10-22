pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const releaseCachedPackets = scope.releaseCachedPackets;
        const dropPendingHashes = scope.dropPendingHashes;

        pub fn case_000() !void {
            var rng = std.Random.DefaultPrng.init(0xabcd1234);
            const random = rng.random();

            for (0..100) |_| {
                const cx = random.intRangeAtMost(i32, -1000, 1000);
                const cz = random.intRangeAtMost(i32, -1000, 1000);
                const px = random.intRangeAtMost(i32, -1000, 1000);
                const pz = random.intRangeAtMost(i32, -1000, 1000);
                const sim_dist = random.intRangeAtMost(i32, 1, 16);

                const dx = cx - px;
                const dz = cz - pz;
                const in_simulation = dx * dx + dz * dz <= sim_dist * sim_dist;

                const dx_f: f64 = @floatFromInt(dx);
                const dz_f: f64 = @floatFromInt(dz);
                const sd_f: f64 = @floatFromInt(sim_dist);
                const expected = (dx_f * dx_f + dz_f * dz_f) <= (sd_f * sd_f);

                try std.testing.expectEqual(expected, in_simulation);
            }
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;

            var cached = [_][]const u8{ &.{}, &.{}, &.{} };
            cached[0] = try allocator.dupe(u8, "cached-0");
            cached[2] = try allocator.dupe(u8, "cached-2");

            releaseCachedPackets(allocator, &cached);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            var pending = std.AutoHashMap(i64, void).init(allocator);
            defer pending.deinit();

            for (1..6) |i| try pending.put(@intCast(i), {});

            const hashes = [_]i64{ 2, 4, 99 };
            dropPendingHashes(&pending, &hashes);

            try std.testing.expectEqual(@as(usize, 3), pending.count());
            try std.testing.expect(pending.contains(1));
            try std.testing.expect(!pending.contains(2));
            try std.testing.expect(pending.contains(3));
            try std.testing.expect(!pending.contains(4));
            try std.testing.expect(pending.contains(5));

            dropPendingHashes(&pending, &hashes);
            try std.testing.expectEqual(@as(usize, 3), pending.count());
        }

        pub fn case_003() !void {
            const source = @embedFile("chunk_streaming.zig");

            try std.testing.expect(containsBetween(
                source,
                "fn cleanupBatchWork",
                "for (0..work.count) |i| {",
                "dropPendingHashes",
            ));
            try std.testing.expect(containsBetween(
                source,
                "if (player.entity.dimension != work.dimension) {",
                "const dimension: ?*Dimension",
                "dropPendingHashes",
            ));
        }

        pub fn case_004() !void {
            const PacketAction = scope.PacketAction;
            const choose = scope.choosePacketAction;

            try std.testing.expectEqual(PacketAction.send_cached, choose(false, false, true, false));
            try std.testing.expectEqual(PacketAction.send_cached, choose(false, false, true, true));
            try std.testing.expectEqual(PacketAction.send_cached, choose(true, true, true, false));
            try std.testing.expectEqual(PacketAction.send_cached, choose(true, true, true, true));
            try std.testing.expectEqual(PacketAction.wait, choose(true, false, true, true));
            try std.testing.expectEqual(PacketAction.wait, choose(false, false, false, true));
            try std.testing.expectEqual(PacketAction.wait, choose(true, true, false, true));
            try std.testing.expectEqual(PacketAction.schedule, choose(true, false, true, false));
            try std.testing.expectEqual(PacketAction.schedule, choose(false, false, false, false));
            try std.testing.expectEqual(PacketAction.schedule, choose(true, true, false, false));
            try std.testing.expectEqual(PacketAction.schedule, choose(true, false, false, false));
        }

        pub fn case_005() !void {
            const source = @embedFile("chunk_streaming.zig");

            try std.testing.expect(containsBetween(
                source,
                "fn onBatchComplete",
                "const player =",
                "clearPacketInflight",
            ));
            try std.testing.expect(containsBetween(
                source,
                "fn cleanupBatchWork",
                "for (0..work.count) |i| {",
                "clearPacketInflight",
            ));
        }

        pub fn case_006() !void {
            const Raknet = scope.Raknet;
            const allocator = std.testing.allocator;

            var transport = try Raknet.Server.init(std.testing.io, .{
                .allocator = allocator,
                .address = "127.0.0.1",
                .port = 0,
                .output_slab_slots = 4,
                .transient_slab_slots = 4,
                .outbound_queue_slots = 8,
            });
            defer transport.deinit();

            const conn = try allocator.create(Raknet.Connection);
            defer allocator.destroy(conn);
            conn.* = Raknet.Connection.init(&transport, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 7 } }, 1400, 7);
            defer conn.deinit();
            try conn.comm_data.output_frame_queue.ensureTotalCapacity(allocator, 4);

            const packet = "chunk-packet-payload";
            const owned = try allocator.dupe(u8, packet);
            scope.sendOwnedChunkPacket(conn, allocator, owned);
            try std.testing.expectEqual(@as(usize, 1), conn.comm_data.output_frame_queue.items.len);
            try std.testing.expectEqual(@intFromPtr(owned.ptr), @intFromPtr(conn.comm_data.output_frame_queue.items[0].payload.ptr));
            for (conn.comm_data.output_frame_queue.items) |*frame| frame.deinit();
            conn.comm_data.output_frame_queue.clearRetainingCapacity();

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();
            const copied = try arena_allocator.dupe(u8, packet);
            scope.sendOwnedChunkPacket(conn, arena_allocator, copied);
            try std.testing.expectEqual(@as(usize, 1), conn.comm_data.output_frame_queue.items.len);
            const copied_frame = &conn.comm_data.output_frame_queue.items[0];
            try std.testing.expect(@intFromPtr(copied_frame.payload.ptr) != @intFromPtr(copied.ptr));
            try std.testing.expectEqualStrings(packet, copied_frame.payload);
            for (conn.comm_data.output_frame_queue.items) |*frame| frame.deinit();
            conn.comm_data.output_frame_queue.clearRetainingCapacity();
        }

        fn containsBetween(source: []const u8, start_marker: []const u8, end_marker: []const u8, needle: []const u8) bool {
            const start = std.mem.indexOf(u8, source, start_marker) orelse return false;
            const end = std.mem.indexOfPos(u8, source, start + start_marker.len, end_marker) orelse return false;
            return std.mem.indexOf(u8, source[start..end], needle) != null;
        }
    };
}
