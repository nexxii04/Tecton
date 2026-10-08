pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const BinaryStream = scope.BinaryStream;
        const NBT = scope.NBT;
        const BlockPermutation = scope.BlockPermutation;
        const BlockState = scope.BlockState;
        const BlockType = scope.BlockType;
        const Chunk = scope.Chunk;
        const ChunkColumnData = scope.ChunkColumnData;
        const ParsedBlockEntity = scope.ParsedBlockEntity;
        const ChunkBlockData = scope.ChunkBlockData;
        const shouldReadTraitPositions = scope.shouldReadTraitPositions;
        const shouldCacheChunkPacket = scope.shouldCacheChunkPacket;
        const parseBlockEntitiesFromBytes = scope.parseBlockEntitiesFromBytes;
        const serializeChunkPacketFromColumn = scope.serializeChunkPacketFromColumn;
        const serializeChunkPacket = scope.serializeChunkPacket;

        pub fn case_000() !void {
            const data = ChunkBlockData{ .parsed_entities = &.{}, .trait_positions = &.{} };
            try std.testing.expect(shouldCacheChunkPacket(false, &data));
        }

        pub fn case_001() !void {
            const entity = ParsedBlockEntity{
                .x = 0,
                .y = 64,
                .z = 0,
                .trait_ids = &.{},
                .nbt_data = null,
            };

            var parsed = [_]ParsedBlockEntity{entity};
            const data = ChunkBlockData{ .parsed_entities = &parsed, .trait_positions = &.{} };
            try std.testing.expect(!shouldCacheChunkPacket(false, &data));
        }

        pub fn case_002() !void {
            try std.testing.expect(!shouldReadTraitPositions(false));
            try std.testing.expect(shouldReadTraitPositions(true));
        }

        pub fn case_003() !void {
            const allocator = std.testing.allocator;

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

            var chunk = Chunk.init(allocator, 0, 0, .Overworld);
            defer chunk.deinit();
            try chunk.setPermutation(1, 64, 1, stone_perm, 0);
            try chunk.setPermutation(2, 65, 2, stone_perm, 0);

            var column = ChunkColumnData{};
            column.has_version = true;
            defer column.deinit(allocator);

            for (chunk.subchunks, 0..) |maybe_sc, i| {
                const sc = maybe_sc orelse continue;
                var stream = BinaryStream.init(allocator, null, null);
                defer stream.deinit();
                try sc.serializePersistence(&stream, allocator);
                column.subchunks[i] = try allocator.dupe(u8, stream.getBuffer());
            }

            const full_packet = serializeChunkPacket(allocator, &chunk, 0, 0, .Overworld) orelse return error.TestUnexpectedResult;
            defer allocator.free(full_packet);

            const column_packet = serializeChunkPacketFromColumn(allocator, &column, 0, 0, .Overworld) orelse return error.TestUnexpectedResult;
            defer allocator.free(column_packet);

            try std.testing.expectEqualSlices(u8, full_packet, column_packet);
        }

        pub fn case_004() !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            var tag = NBT.CompoundTag.init(allocator, null);
            try tag.set("x", .{ .Int = NBT.IntTag.init(12, null) });
            try tag.set("y", .{ .Int = NBT.IntTag.init(64, null) });
            try tag.set("z", .{ .Int = NBT.IntTag.init(-4, null) });
            try tag.set("id", .{ .String = NBT.StringTag.init(try allocator.dupe(u8, "Chest"), null) });

            const trait_items = try allocator.alloc(NBT.Tag, 1);
            trait_items[0] = .{ .String = NBT.StringTag.init(try allocator.dupe(u8, "test:trait"), null) };
            try tag.set("traits", .{ .List = NBT.ListTag.init(trait_items, null) });

            var stream = BinaryStream.init(allocator, null, null);
            defer stream.deinit();
            try NBT.CompoundTag.write(&stream, &tag, NBT.ReadWriteOptions.default);

            const parsed = parseBlockEntitiesFromBytes(allocator, stream.getBuffer());
            try std.testing.expectEqual(@as(usize, 1), parsed.len);
            try std.testing.expectEqual(@as(i32, 12), parsed[0].x);
            try std.testing.expectEqual(@as(i32, 64), parsed[0].y);
            try std.testing.expectEqual(@as(i32, -4), parsed[0].z);
            try std.testing.expectEqual(@as(usize, 1), parsed[0].trait_ids.len);
            try std.testing.expectEqualStrings("test:trait", parsed[0].trait_ids[0]);
        }
    };
}
