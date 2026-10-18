pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Protocol = scope.Protocol;
        const block_pos = scope.block_pos;
        const broadcast = scope.broadcast;
        const random_tick = scope.random_tick;
        const tick_scheduler = scope.tick_scheduler;
        const ChunkHash = scope.ChunkHash;
        const chunkHash = scope.chunkHash;
        const ChunkPacketCache = scope.ChunkPacketCache;
        const Dimension = scope.Dimension;

        pub fn case_000() !void {
            try std.testing.expect(Dimension.withinViewDistance(0, 0, 8));
            try std.testing.expect(Dimension.withinViewDistance(128, 0, 8));
            try std.testing.expect(!Dimension.withinViewDistance(129, 0, 8));
            try std.testing.expect(Dimension.withinViewDistance(90, 90, 8));
            try std.testing.expect(!Dimension.withinViewDistance(100, 100, 8));
            try std.testing.expect(Dimension.withinViewDistance(16, 0, 1));
            try std.testing.expect(!Dimension.withinViewDistance(17, 0, 1));
        }

        pub fn case_001() !void {
            const entity_index = scope.test_dependency_0;
            try std.testing.expectEqual(chunkHash(0, 0), entity_index.chunkHash(0, 0));
            try std.testing.expectEqual(chunkHash(-33, 17), entity_index.chunkHash(-33, 17));
            try std.testing.expectEqual(chunkHash(1000, -1000), entity_index.chunkHash(1000, -1000));
            try std.testing.expectEqual(chunkHash(-1, -1), entity_index.chunkHash(-1, -1));
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            var rng = std.Random.DefaultPrng.init(0x12345678);
            const random = rng.random();

            var blocks = std.AutoHashMap(i64, Protocol.BlockPosition).init(allocator);
            defer blocks.deinit();
            var blocks_by_chunk = std.AutoHashMap(ChunkHash, std.ArrayList(i64)).init(allocator);
            defer {
                var it = blocks_by_chunk.valueIterator();
                while (it.next()) |list| list.deinit(allocator);
                blocks_by_chunk.deinit();
            }

            for (0..100) |_| {
                const pos = Protocol.BlockPosition{
                    .x = random.intRangeAtMost(i32, -64, 64),
                    .y = random.intRangeAtMost(i32, 0, 255),
                    .z = random.intRangeAtMost(i32, -64, 64),
                };
                const hash = Dimension.blockPosHash(pos);
                const ch = chunkHash(pos.x >> 4, pos.z >> 4);

                if (random.boolean()) {
                    blocks.put(hash, pos) catch continue;
                    const gop = blocks_by_chunk.getOrPut(ch) catch continue;
                    if (!gop.found_existing) {
                        gop.value_ptr.* = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
                    }
                    var already = false;
                    for (gop.value_ptr.items) |h| {
                        if (h == hash) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) gop.value_ptr.append(allocator, hash) catch continue;
                } else {
                    if (blocks.fetchRemove(hash)) |_| {
                        if (blocks_by_chunk.getPtr(ch)) |list| {
                            for (list.items, 0..) |h, i| {
                                if (h == hash) {
                                    _ = list.swapRemove(i);
                                    break;
                                }
                            }
                        }
                    }
                }

                var block_it = blocks.iterator();
                while (block_it.next()) |entry| {
                    const p = entry.value_ptr.*;
                    const c = chunkHash(p.x >> 4, p.z >> 4);
                    const list = blocks_by_chunk.getPtr(c);
                    try std.testing.expect(list != null);
                    var found = false;
                    for (list.?.items) |h| {
                        if (h == entry.key_ptr.*) {
                            found = true;
                            break;
                        }
                    }
                    try std.testing.expect(found);
                }
            }
        }

        pub fn case_003() !void {
            const allocator = std.testing.allocator;
            var rng = std.Random.DefaultPrng.init(0x87654321);
            const random = rng.random();

            for (0..100) |_| {
                var blocks = std.AutoHashMap(i64, Protocol.BlockPosition).init(allocator);
                defer blocks.deinit();
                var blocks_by_chunk = std.AutoHashMap(ChunkHash, std.ArrayList(i64)).init(allocator);
                defer {
                    var it = blocks_by_chunk.valueIterator();
                    while (it.next()) |list| list.deinit(allocator);
                    blocks_by_chunk.deinit();
                }

                const target_cx = random.intRangeAtMost(i32, -4, 4);
                const target_cz = random.intRangeAtMost(i32, -4, 4);

                for (0..20) |_| {
                    const cx = random.intRangeAtMost(i32, -4, 4);
                    const cz = random.intRangeAtMost(i32, -4, 4);
                    const pos = Protocol.BlockPosition{
                        .x = cx * 16 + random.intRangeAtMost(i32, 0, 15),
                        .y = random.intRangeAtMost(i32, 0, 255),
                        .z = cz * 16 + random.intRangeAtMost(i32, 0, 15),
                    };
                    const hash = Dimension.blockPosHash(pos);
                    const ch = chunkHash(pos.x >> 4, pos.z >> 4);
                    blocks.put(hash, pos) catch continue;
                    const gop = blocks_by_chunk.getOrPut(ch) catch continue;
                    if (!gop.found_existing) {
                        gop.value_ptr.* = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
                    }
                    var already = false;
                    for (gop.value_ptr.items) |h| {
                        if (h == hash) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) gop.value_ptr.append(allocator, hash) catch continue;
                }

                const total_before = blocks.count();
                const target_ch = chunkHash(target_cx, target_cz);
                const target_count = if (blocks_by_chunk.getPtr(target_ch)) |list| list.items.len else 0;

                if (blocks_by_chunk.fetchRemove(target_ch)) |entry| {
                    var list = entry.value;
                    for (list.items) |h| {
                        _ = blocks.remove(h);
                    }
                    list.deinit(allocator);
                }

                try std.testing.expectEqual(total_before - target_count, blocks.count());

                var remaining_it = blocks.iterator();
                while (remaining_it.next()) |entry| {
                    const p = entry.value_ptr.*;
                    try std.testing.expect((p.x >> 4) != target_cx or (p.z >> 4) != target_cz);
                }
            }
        }

        pub fn case_004() !void {
            const allocator = std.testing.allocator;
            var rng = std.Random.DefaultPrng.init(0xface1234);
            const random = rng.random();

            var generations = std.AutoHashMap(ChunkHash, u64).init(allocator);
            defer generations.deinit();

            for (0..100) |_| {
                const cx = random.intRangeAtMost(i32, -10, 10);
                const cz = random.intRangeAtMost(i32, -10, 10);
                const hash = chunkHash(cx, cz);

                const old_gen = generations.get(hash) orelse 0;
                const new_gen = old_gen + 1;
                try generations.put(hash, new_gen);

                try std.testing.expect(new_gen > old_gen);
                try std.testing.expectEqual(new_gen, generations.get(hash).?);
            }
        }

        pub fn case_005() !void {
            const allocator = std.testing.allocator;
            var rng = std.Random.DefaultPrng.init(0xbabe5678);
            const random = rng.random();

            var cache = ChunkPacketCache.init(allocator);
            defer cache.deinit();

            for (0..100) |_| {
                const cx = random.intRangeAtMost(i32, -5, 5);
                const cz = random.intRangeAtMost(i32, -5, 5);
                const hash = chunkHash(cx, cz);
                const gen = random.intRangeAtMost(u64, 0, 1_000_000);

                cache.put(hash, gen, try allocator.dupe(u8, "packet"));
                try std.testing.expect(cache.get(hash, gen) != null);

                try std.testing.expect(cache.get(hash, gen + 1) == null);
                try std.testing.expectEqual(@as(usize, 0), cache.count());
                try std.testing.expectEqual(@as(usize, 0), cache.bytesHeld());
            }
        }

        pub fn case_006() !void {
            _ = block_pos;
            _ = broadcast;
            _ = random_tick;
            _ = tick_scheduler;
        }

        pub fn case_007() !void {
            const source = @embedFile("dimension.zig");
            const deinit_start = std.mem.indexOf(u8, source, "pub fn deinit(self: *Dimension) void {") orelse
                return error.TestUnexpectedResult;
            const remove = std.mem.indexOfPos(u8, source, deinit_start, "self.blocks.remove(blockPosHash(block.position));") orelse {
                std.debug.print("dimension.zig: deinit detaches blocks whose neighbours still resolve them\n", .{});
                return error.TestUnexpectedResult;
            };
            const detach = std.mem.indexOfPos(u8, source, deinit_start, "block.deinit();") orelse
                return error.TestUnexpectedResult;
            try std.testing.expect(remove < detach);
        }

        pub fn case_008() !void {
            const allocator = std.testing.allocator;
            var world: scope.World = undefined;
            var dim = Dimension.init(&world, allocator, "test", .Overworld, null);
            defer dim.deinit();

            const hash = chunkHash(4, -7);
            dim.putCachedChunkPacket(hash, try allocator.dupe(u8, "packet-bytes"));
            try dim.chunk_generations.put(hash, 3);

            try std.testing.expectEqual(@as(usize, 1), dim.cachedPacketCount());
            try std.testing.expectEqual(@as(usize, 12), dim.cachedPacketBytes());
            try std.testing.expectEqual(@as(usize, 1), dim.chunkGenerationCount());

            dim.forgetChunkResources(hash);

            try std.testing.expectEqual(@as(usize, 0), dim.cachedPacketCount());
            try std.testing.expectEqual(@as(usize, 0), dim.cachedPacketBytes());
            try std.testing.expectEqual(@as(usize, 0), dim.chunkGenerationCount());

            dim.forgetChunkResources(hash);
            try std.testing.expectEqual(@as(usize, 0), dim.cachedPacketCount());
        }

        pub fn case_009() !void {
            const source = @embedFile("dimension.zig");
            try expectForgetIn(source, "pub fn removeChunk");
            try expectForgetIn(source, "pub fn releaseUnrenderedChunks");
        }

        pub fn case_010() !void {
            const allocator = std.testing.allocator;
            var world: scope.World = undefined;
            var dim = Dimension.init(&world, allocator, "test", .Overworld, null);
            defer dim.deinit();

            const hash = chunkHash(3, 4);
            try std.testing.expect(!dim.isPacketInflight(hash));

            dim.markPacketInflight(hash);
            dim.markPacketInflight(hash);
            try std.testing.expect(dim.isPacketInflight(hash));
            try std.testing.expectEqual(@as(usize, 1), dim.inflightPacketCount());

            dim.clearPacketInflight(hash);
            dim.clearPacketInflight(hash);
            try std.testing.expect(!dim.isPacketInflight(hash));
            try std.testing.expectEqual(@as(usize, 0), dim.inflightPacketCount());
        }

        fn expectForgetIn(source: []const u8, signature: []const u8) !void {
            const start = std.mem.indexOf(u8, source, signature) orelse {
                std.debug.print("dimension.zig: missing {s}\n", .{signature});
                return error.TestUnexpectedResult;
            };
            const next_fn = std.mem.indexOfPos(u8, source, start + signature.len, "\n    pub fn ") orelse source.len;
            const body = source[start..next_fn];
            if (std.mem.indexOf(u8, body, "forgetChunkResources") == null) {
                std.debug.print("dimension.zig: {s} must drop the cached packet and generation\n", .{signature});
                return error.TestUnexpectedResult;
            }
        }

    };
}
