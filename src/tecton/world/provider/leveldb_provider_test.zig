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

        pub fn case_000() !void {
            var db = try LevelDB.DB.open("test_prop4_db\x00", true);
            defer {
                db.close();
                std.Io.Dir.cwd().deleteTree(std.testing.io, "test_prop4_db") catch {};
            }

            var rng = std.Random.DefaultPrng.init(0xdeadbeef);
            const random = rng.random();

            for (0..100) |iter| {
                const x: i32 = @intCast(@as(i32, @truncate(@as(i64, @intCast(iter)))) - 50);
                const z: i32 = @intCast(@as(i32, @truncate(@as(i64, @intCast(iter)))) + 10);
                const dim_index: i32 = 0;

                var batch = try LevelDB.WriteBatch.init();
                defer batch.deinit();

                const ver_key = key_mod.versionKey(x, z, dim_index);
                batch.put(ver_key.slice(), &[_]u8{40});

                var expected_data: [chunk_mod.MAX_SUBCHUNKS]?[]u8 = .{null} ** chunk_mod.MAX_SUBCHUNKS;
                defer {
                    for (&expected_data) |*d| {
                        if (d.*) |data| std.testing.allocator.free(data);
                    }
                }

                const num_subchunks = random.intRangeAtMost(usize, 1, 8);
                for (0..num_subchunks) |i| {
                    const len = random.intRangeAtMost(usize, 4, 64);
                    const data = try std.testing.allocator.alloc(u8, len);
                    random.bytes(data);
                    expected_data[i] = data;

                    const sc_index: i8 = @intCast(@as(i32, @intCast(i)));
                    const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
                    batch.put(key.slice(), data);
                }

                try batch.write(&db);

                const ver_read = db.get(ver_key.slice());
                try std.testing.expect(ver_read != null);
                LevelDB.DB.freeValue(ver_read.?);

                for (0..chunk_mod.MAX_SUBCHUNKS) |i| {
                    const sc_index: i8 = @intCast(@as(i32, @intCast(i)));
                    const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
                    const read_val = db.get(key.slice());
                    if (expected_data[i]) |expected| {
                        try std.testing.expect(read_val != null);
                        try std.testing.expectEqualSlices(u8, expected, read_val.?);
                        LevelDB.DB.freeValue(read_val.?);
                    } else {
                        try std.testing.expect(read_val == null);
                    }
                }

                var del_batch = try LevelDB.WriteBatch.init();
                defer del_batch.deinit();
                del_batch.delete(ver_key.slice());
                for (0..num_subchunks) |i| {
                    const sc_index: i8 = @intCast(@as(i32, @intCast(i)));
                    const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
                    del_batch.delete(key.slice());
                }
                try del_batch.write(&db);
            }
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            const BlockType = scope.test_dependency_1.BlockType;
            const BlockState = scope.test_dependency_0.BlockState;

            try BlockPermutation.initRegistry(allocator);
            defer BlockPermutation.deinitRegistry();
            try BlockType.initRegistry(allocator);
            defer BlockType.deinitRegistry();

            const air_type = try BlockType.init(allocator, "minecraft:air");
            try air_type.register();
            const air_state = BlockState.init(allocator);
            const air_perm = try BlockPermutation.init(allocator, 0, "minecraft:air", air_state);
            try air_perm.register();
            try air_type.addPermutation(air_perm);

            const stone_type = try BlockType.init(allocator, "minecraft:stone");
            try stone_type.register();
            const stone_state = BlockState.init(allocator);
            const stone_perm = try BlockPermutation.init(allocator, 1, "minecraft:stone", stone_state);
            try stone_perm.register();
            try stone_type.addPermutation(stone_perm);

            var provider = try LevelDBProvider.init(std.testing.io, allocator, "test_persist2_db\x00");
            defer {
                provider.deinit();
                std.Io.Dir.cwd().deleteTree(std.testing.io, "test_persist2_db") catch {};
            }

            var dimension = Dimension.init(undefined, allocator, "overworld", .Overworld, null);
            defer dimension.deinit();

            var chunk = Chunk.init(allocator, 0, 0, .Overworld);
            defer chunk.deinit();

            var payload: [2048]u8 = undefined;
            @memset(&payload, 0x5a);
            for (0..256) |i| {
                var key_buf: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buf, "flood-{d}", .{i});
                var record = persistence.Record{};
                try record.addPut(allocator, key, &payload);
                try provider.writer.enqueueKeyed(persistence.chunkKey(.subchunks, 9, @intCast(i), 0), record);
            }

            try chunk.setPermutation(1, 64, 1, stone_perm, 0);
            try chunk_store.writeChunk(provider, &chunk, &dimension);

            const persisted = try chunk_store.readChunkDirect(provider, 0, 0, .Overworld);
            defer {
                persisted.deinit();
                allocator.destroy(persisted);
            }
            const permutation = try persisted.getPermutation(1, 64, 1, 0);
            try std.testing.expectEqualStrings("minecraft:stone", permutation.identifier);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            const BlockType = scope.test_dependency_1.BlockType;
            const BlockState = scope.test_dependency_0.BlockState;

            try BlockPermutation.initRegistry(allocator);
            defer BlockPermutation.deinitRegistry();
            try BlockType.initRegistry(allocator);
            defer BlockType.deinitRegistry();

            const air_type = try BlockType.init(allocator, "minecraft:air");
            try air_type.register();
            const air_state = BlockState.init(allocator);
            const air_perm = try BlockPermutation.init(allocator, 0, "minecraft:air", air_state);
            try air_perm.register();
            try air_type.addPermutation(air_perm);

            const stone_type = try BlockType.init(allocator, "minecraft:stone");
            try stone_type.register();
            const stone_state = BlockState.init(allocator);
            const stone_perm = try BlockPermutation.init(allocator, 1, "minecraft:stone", stone_state);
            try stone_perm.register();
            try stone_type.addPermutation(stone_perm);

            var provider = try LevelDBProvider.init(std.testing.io, allocator, "test_prop7_db\x00");
            defer {
                provider.deinit();
                std.Io.Dir.cwd().deleteTree(std.testing.io, "test_prop7_db") catch {};
            }

            var dimension = Dimension.init(undefined, allocator, "overworld", .Overworld, null);
            defer dimension.deinit();

            var chunk = Chunk.init(allocator, 0, 0, .Overworld);
            defer chunk.deinit();

            const sc_slot: usize = 8;
            const sc_index: i8 = @intCast(sc_slot - chunk_mod.yOffset(.Overworld));

            const replaceWithEmptySubChunk = struct {
                fn f(c: *Chunk, alloc: std.mem.Allocator, slot: usize, index: i8) !void {
                    if (c.subchunks[slot]) |old_sc| {
                        old_sc.deinit();
                        alloc.destroy(old_sc);
                    }
                    const sc = try alloc.create(SubChunk);
                    sc.* = try SubChunk.init(alloc, index);
                    c.subchunks[slot] = sc;
                    c.invalidateHeightmap();
                    c.dirty = true;
                }
            }.f;

            try chunk.setPermutation(1, 64, 1, stone_perm, 0);
            try chunk_store.writeChunk(provider, &chunk, &dimension);

            {
                const persisted = try chunk_store.readChunkDirect(provider, 0, 0, .Overworld);
                defer {
                    persisted.deinit();
                    allocator.destroy(persisted);
                }
                try std.testing.expect(persisted.subchunks[sc_slot] != null);
                try std.testing.expect(!persisted.subchunks[sc_slot].?.isEmpty());
                const perm = try persisted.getPermutation(1, 64, 1, 0);
                try std.testing.expectEqualStrings("minecraft:stone", perm.identifier);
            }

            try replaceWithEmptySubChunk(&chunk, allocator, sc_slot, sc_index);
            try std.testing.expect(chunk.subchunks[sc_slot].?.isEmpty());
            try chunk_store.writeChunk(provider, &chunk, &dimension);

            {
                const persisted = try chunk_store.readChunkDirect(provider, 0, 0, .Overworld);
                defer {
                    persisted.deinit();
                    allocator.destroy(persisted);
                }
                try std.testing.expect(persisted.subchunks[sc_slot] == null);
            }

            try chunk.setPermutation(1, 64, 1, stone_perm, 0);
            provider.saveAll();

            {
                const persisted = try chunk_store.readChunkDirect(provider, 0, 0, .Overworld);
                defer {
                    persisted.deinit();
                    allocator.destroy(persisted);
                }
                try std.testing.expect(persisted.subchunks[sc_slot] != null);
                const perm = try persisted.getPermutation(1, 64, 1, 0);
                try std.testing.expectEqualStrings("minecraft:stone", perm.identifier);
            }

            try replaceWithEmptySubChunk(&chunk, allocator, sc_slot, sc_index);
            provider.saveAll();

            {
                const persisted = try chunk_store.readChunkDirect(provider, 0, 0, .Overworld);
                defer {
                    persisted.deinit();
                    allocator.destroy(persisted);
                }
                try std.testing.expect(persisted.subchunks[sc_slot] == null);
            }
        }

        pub fn case_003() !void {
            var db = try LevelDB.DB.open("test_prop6_db\x00", true);
            defer {
                db.close();
                std.Io.Dir.cwd().deleteTree(std.testing.io, "test_prop6_db") catch {};
            }

            var rng = std.Random.DefaultPrng.init(0xcafebabe);
            const random = rng.random();

            const N = 100;
            var keys: [N]key_mod.KeyBuf = undefined;
            var values: [N][8]u8 = undefined;

            var batch = try LevelDB.WriteBatch.init();
            defer batch.deinit();

            for (0..N) |i| {
                const x: i32 = random.intRangeAtMost(i32, -1000, 1000);
                const z: i32 = random.intRangeAtMost(i32, -1000, 1000);
                keys[i] = key_mod.versionKey(x, z, 0);
                random.bytes(&values[i]);
                batch.put(keys[i].slice(), &values[i]);
            }

            try batch.write(&db);

            for (0..N) |i| {
                const read_val = db.get(keys[i].slice());
                try std.testing.expect(read_val != null);
                try std.testing.expectEqualSlices(u8, &values[i], read_val.?);
                LevelDB.DB.freeValue(read_val.?);
            }
        }

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
