pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const CompressionOptions = scope.CompressionOptions;
        const Compression = scope.Compression;
        const private_compression_readVarInt = scope.private_compression_readVarInt;
        const private_compression_unframe = scope.private_compression_unframe;
        pub fn case_000() !void {
            defer Compression.deinitThreadLocal();
            const allocator = std.testing.allocator;
            var rng = std.Random.DefaultPrng.init(0xdeadbeef);
            const random = rng.random();

            const options = CompressionOptions{
                .compression_method = .Zlib,
                .compression_threshold = 1,
            };

            for (0..100) |_| {
                const len = random.intRangeAtMost(usize, 16, 512);
                const data = try allocator.alloc(u8, len);
                defer allocator.free(data);
                random.bytes(data);

                const pkts = [_][]const u8{data};
                const compressed = try Compression.compress(&pkts, options, allocator);
                defer allocator.free(compressed);

                const result = try Compression.decompress(compressed, options, allocator);
                defer result.deinit();

                try std.testing.expectEqual(@as(usize, 1), result.packets.len);
                try std.testing.expectEqualSlices(u8, data, result.packets[0]);
            }
        }

        pub fn case_001() !void {
            defer Compression.deinitThreadLocal();
            const allocator = std.testing.allocator;
            var rng = std.Random.DefaultPrng.init(0xcafe9876);
            const random = rng.random();

            const options = CompressionOptions{
                .compression_method = .Zlib,
                .compression_threshold = 1,
            };

            for (0..100) |_| {
                const pkt_count = random.intRangeAtMost(usize, 1, 8);
                var pkts: [8][]u8 = undefined;
                var pkt_slices: [8][]const u8 = undefined;

                for (0..pkt_count) |i| {
                    const len = random.intRangeAtMost(usize, 16, 256);
                    pkts[i] = try allocator.alloc(u8, len);
                    random.bytes(pkts[i]);
                    pkt_slices[i] = pkts[i];
                }
                defer for (0..pkt_count) |i| allocator.free(pkts[i]);

                const compressed = try Compression.compress(pkt_slices[0..pkt_count], options, allocator);
                defer allocator.free(compressed);

                const result = try Compression.decompress(compressed, options, allocator);
                defer result.deinit();

                try std.testing.expectEqual(pkt_count, result.packets.len);
                for (0..pkt_count) |i| {
                    try std.testing.expectEqualSlices(u8, pkts[i], result.packets[i]);
                }
            }
        }

        pub fn case_002() !void {
            const cases = [_]u32{ 0, 1, 127, 128, 16383, 16384, 2097151, 2097152, 268435455, 0xFFFFFFFF };
            for (cases) |value| {
                var buf: [5]u8 = undefined;
                const size = scope.private_compression_writeVarInt(&buf, value);
                const decoded = private_compression_readVarInt(buf[0..size]) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(value, decoded.value);
                try std.testing.expectEqual(size, decoded.size);
            }
        }

        pub fn case_003() !void {
            try std.testing.expect(private_compression_readVarInt(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 }) == null);
            try std.testing.expect(private_compression_readVarInt(&.{0x80}) == null);
            try std.testing.expect(private_compression_readVarInt(&.{}) == null);
            try std.testing.expect(private_compression_readVarInt(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x70 }) == null);
        }

        pub fn case_004() !void {
            const allocator = std.testing.allocator;
            const payload = [_]u8{ 0xFF, 0xFF, 0x01, 0xAA, 0xBB };
            try std.testing.expectError(error.MalformedPacketFraming, private_compression_unframe(&payload, allocator));
        }

        pub fn case_005() !void {
            const allocator = std.testing.allocator;
            const payload = [_]u8{0x80};
            try std.testing.expectError(error.MalformedPacketFraming, private_compression_unframe(&payload, allocator));
        }

        pub fn case_006() !void {
            const allocator = std.testing.allocator;
            const payload = [_]u8{ 0x05, 0xAA, 0xBB };
            try std.testing.expectError(error.MalformedPacketFraming, private_compression_unframe(&payload, allocator));
        }

        pub fn case_007() !void {
            const allocator = std.testing.allocator;
            const payload = [_]u8{ 0x02, 0xAA, 0xBB, 0x00, 0x03, 0xCC, 0xDD, 0xEE };
            const packets = try private_compression_unframe(&payload, allocator);
            defer allocator.free(packets);
            try std.testing.expectEqual(@as(usize, 3), packets.len);
            try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, packets[0]);
            try std.testing.expectEqual(@as(usize, 0), packets[1].len);
            try std.testing.expectEqualSlices(u8, &.{ 0xCC, 0xDD, 0xEE }, packets[2]);
        }

        pub fn case_008() !void {
            defer Compression.deinitThreadLocal();
            const allocator = std.testing.allocator;
            var rng = std.Random.DefaultPrng.init(0x5eed1234);
            const random = rng.random();

            const options = CompressionOptions{
                .compression_method = .Zlib,
                .compression_threshold = 1,
            };

            for (0..100) |_| {
                const pkt_count = random.intRangeAtMost(usize, 1, 8);
                var pkts: [8][]u8 = undefined;
                var pkt_slices: [8][]const u8 = undefined;
                for (0..pkt_count) |i| {
                    const len = random.intRangeAtMost(usize, 16, 512);
                    pkts[i] = try allocator.alloc(u8, len);
                    random.bytes(pkts[i]);
                    pkt_slices[i] = pkts[i];
                }
                defer for (0..pkt_count) |i| allocator.free(pkts[i]);

                const compressed = try Compression.compress(pkt_slices[0..pkt_count], options, allocator);
                defer allocator.free(compressed);

                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const result = try Compression.decompressInto(compressed, options, arena.allocator());

                try std.testing.expectEqual(pkt_count, result.packets.len);
                for (0..pkt_count) |i| {
                    try std.testing.expectEqualSlices(u8, pkts[i], result.packets[i]);
                }
            }
        }

        pub fn case_009() !void {
            defer Compression.deinitThreadLocal();
            const allocator = std.testing.allocator;
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            const options = CompressionOptions{
                .compression_method = .Zlib,
                .compression_threshold = 255,
            };

            const packet = [_]u8{ 1, 2, 3, 4, 5 };
            const packets = [_][]const u8{&packet};
            const compressed = try Compression.compress(&packets, options, allocator);
            defer allocator.free(compressed);
            try std.testing.expect(compressed[1] != 0xFE);

            const result = try Compression.decompressInto(compressed, options, arena.allocator());
            try std.testing.expectEqual(@as(usize, 1), result.packets.len);
            try std.testing.expectEqualSlices(u8, &packet, result.packets[0]);
            const payload_ptr = @intFromPtr(result.packets[0].ptr);
            try std.testing.expect(payload_ptr >= @intFromPtr(compressed.ptr));
            try std.testing.expect(payload_ptr + result.packets[0].len <= @intFromPtr(compressed.ptr) + compressed.len);
        }

        pub fn case_010() !void {
            defer Compression.deinitThreadLocal();
            const allocator = std.testing.allocator;
            const options = CompressionOptions{
                .compression_method = .Zlib,
                .compression_threshold = 1,
            };

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            var rng = std.Random.DefaultPrng.init(0xf00d9876);
            const random = rng.random();
            for (0..200) |_| {
                var payload: [1024]u8 = undefined;
                const len = random.intRangeAtMost(usize, 256, payload.len);
                random.bytes(payload[0..len]);

                const slices = [_][]const u8{payload[0..len]};
                const compressed = try Compression.compress(&slices, options, allocator);
                defer allocator.free(compressed);

                const result = try Compression.decompressInto(compressed, options, arena.allocator());
                try std.testing.expectEqualSlices(u8, payload[0..len], result.packets[0]);
                _ = arena.reset(.retain_capacity);
            }
        }

        pub fn case_011() !void {
            defer Compression.deinitThreadLocal();
            var medium: [600]u8 = undefined;
            for (&medium, 0..) |*byte, index| byte.* = @intCast(index % 251);
            var large: [4096]u8 = undefined;
            @memset(&large, 0x7E);
            const small = [_]u8{0x11} ** 40;

            try expectSameBytes(&.{&small}, .{ .compression_method = .Zlib, .compression_threshold = 255 });
            try expectSameBytes(&.{&medium}, .{ .compression_method = .Zlib, .compression_threshold = 255 });
            try expectSameBytes(&.{ &medium, &small }, .{ .compression_method = .Zlib, .compression_threshold = 1 });
            try expectSameBytes(&.{&large}, .{ .compression_method = .Zlib, .compression_threshold = 255 });
            try expectSameBytes(&.{&medium}, .{ .compression_method = .NotPresent, .compression_threshold = 255 });
        }

        fn expectSameBytes(packets: []const []const u8, options: CompressionOptions) !void {
            const allocator = std.testing.allocator;
            const capacity = Compression.frameCapacity(packets, options);

            const expected = try Compression.compress(packets, options, allocator);
            defer allocator.free(expected);
            try std.testing.expect(capacity >= expected.len);

            const buffer = try allocator.alloc(u8, capacity);
            defer allocator.free(buffer);
            const framed = try Compression.compressInto(packets, options, buffer);
            try std.testing.expectEqualSlices(u8, expected, framed);

            const tight = try allocator.alloc(u8, capacity - 1);
            defer allocator.free(tight);
            try std.testing.expectError(error.CompressionBufferTooSmall, Compression.compressInto(packets, options, tight));
        }
    };
}
