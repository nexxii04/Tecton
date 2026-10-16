pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const LevelDB = scope.LevelDB;
        const BlockPermutation = scope.BlockPermutation;
        const Chunk = scope.Chunk;
        const SubChunk = scope.SubChunk;
        const chunk_mod = scope.chunk_mod;
        const Dimension = scope.Dimension;
        const chunk_store = scope.chunk_store;
        const key_mod = scope.key_mod;
        const persistence = scope.persistence;
        const LevelDBProvider = scope.LevelDBProvider;

        pub fn case_004() !void {
            var provider = try LevelDBProvider.init(std.testing.io, std.testing.allocator, "test_prop5_db\x00");
            defer {
                provider.deinit();
                std.Io.Dir.cwd().deleteTree(std.testing.io, "test_prop5_db") catch {};
            }

            var rng = std.Random.DefaultPrng.init(0xfeed1234);
            const random = rng.random();

            for (0..100) |iter| {
                const x: i32 = @intCast(@as(i32, @truncate(@as(i64, @intCast(iter)))) - 50);
                const z: i32 = @intCast(@as(i32, @truncate(@as(i64, @intCast(iter)))) + 20);
                const dim_index: i32 = 0;

                var batch = try LevelDB.WriteBatch.init();
                defer batch.deinit();

                const ver_key = key_mod.versionKey(x, z, dim_index);
                batch.put(ver_key.slice(), &[_]u8{40});

                const slot_offset: usize = chunk_mod.yOffset(.Overworld);
                const num_sc = random.intRangeAtMost(usize, 1, 4);
                var expected_sc: [chunk_mod.MAX_SUBCHUNKS]?[]u8 = .{null} ** chunk_mod.MAX_SUBCHUNKS;
                defer {
                    for (&expected_sc) |*d| {
                        if (d.*) |data| std.testing.allocator.free(data);
                    }
                }

                for (0..num_sc) |i| {
                    const len = random.intRangeAtMost(usize, 4, 32);
                    const data = try std.testing.allocator.alloc(u8, len);
                    random.bytes(data);
                    expected_sc[slot_offset + i] = data;
                    const sc_index: i8 = @intCast(@as(i32, @intCast(i)));
                    const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
                    batch.put(key.slice(), data);
                }

                var be_data: [16]u8 = undefined;
                random.bytes(&be_data);
                const be_key = key_mod.blockEntityKey(x, z, dim_index);
                batch.put(be_key.slice(), &be_data);

                try batch.write(&provider.db);

                var col_skip = try chunk_store.readChunkColumn(provider, std.testing.allocator, x, z, .Overworld, false);
                defer col_skip.deinit(std.testing.allocator);
                try std.testing.expect(col_skip.has_version);
                try std.testing.expect(col_skip.block_entity_data == null);
                for (0..chunk_mod.MAX_SUBCHUNKS) |i| {
                    if (expected_sc[i]) |expected| {
                        try std.testing.expect(col_skip.subchunks[i] != null);
                        try std.testing.expectEqualSlices(u8, expected, col_skip.subchunks[i].?);
                    } else {
                        try std.testing.expect(col_skip.subchunks[i] == null);
                    }
                }

                var col_full = try chunk_store.readChunkColumn(provider, std.testing.allocator, x, z, .Overworld, true);
                defer col_full.deinit(std.testing.allocator);
                try std.testing.expect(col_full.block_entity_data != null);
                try std.testing.expectEqualSlices(u8, &be_data, col_full.block_entity_data.?);

                const bytes_opt = try chunk_store.readBlockEntityBytes(provider, std.testing.allocator, x, z, .Overworld);
                try std.testing.expect(bytes_opt != null);
                const bytes = bytes_opt.?;
                defer std.testing.allocator.free(bytes);
                try std.testing.expectEqualSlices(u8, &be_data, bytes);
                try std.testing.expect((try chunk_store.readBlockEntityBytes(provider, std.testing.allocator, x + 100000, z, .Overworld)) == null);

                var del_batch = try LevelDB.WriteBatch.init();
                defer del_batch.deinit();
                del_batch.delete(ver_key.slice());
                del_batch.delete(be_key.slice());
                for (0..num_sc) |i| {
                    const sc_index: i8 = @intCast(@as(i32, @intCast(i)));
                    const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
                    del_batch.delete(key.slice());
                }
                try del_batch.write(&provider.db);
            }
        }

        pub fn case_005() !void {
            _ = scope.test_dependency_2;
        }
    };
}
