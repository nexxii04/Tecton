pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Protocol = scope.Protocol;
        const Block = scope.Block;
        const Chunk = scope.Chunk;
        const Dimension = scope.Dimension;
        const ChunkEntityIndex = scope.ChunkEntityIndex;
        const CachedPacket = scope.CachedPacket;
        const chunkHash = scope.chunkHash;
        const BlockPermutation = scope.BlockPermutation;
        const BlockState = scope.BlockState;
        const BlockType = scope.BlockType;
        const Entity = scope.Entity;
        const CompoundTag = scope.CompoundTag;
        const NBT = scope.NBT;
        const trait_mod = scope.trait_mod;
        const serialization = scope.serialization;
        const ItemStack = scope.ItemStack;
        const ItemType = scope.ItemType;
        const restoreAdjacentPairing = scope.restoreAdjacentPairing;
        const tileFixNetworkIds = scope.tileFixNetworkIds;
        const ChestTrait = scope.ChestTrait;

        pub fn case_003() !void {
            const allocator = std.testing.allocator;

            try BlockPermutation.initRegistry(allocator);
            defer BlockPermutation.deinitRegistry();
            try BlockType.initRegistry(allocator);
            defer BlockType.deinitRegistry();
            trait_mod.initTraitRegistry(allocator);
            defer trait_mod.deinitTraitRegistry();
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();
            try ChestTrait.register();

            const air_type = try BlockType.init(allocator, "minecraft:air");
            try air_type.register();
            const air_state = BlockState.init(allocator);
            const air_perm = try BlockPermutation.init(allocator, 0, "minecraft:air", air_state);
            try air_perm.register();
            try air_type.addPermutation(air_perm);

            const chest_type = try BlockType.init(allocator, "minecraft:chest");
            try chest_type.register();

            var chest_state = BlockState.init(allocator);
            try chest_state.put(
                try allocator.dupe(u8, "minecraft:cardinal_direction"),
                .{ .string = try allocator.dupe(u8, "north") },
            );
            const chest_perm = try BlockPermutation.init(allocator, 1, "minecraft:chest", chest_state);
            try chest_perm.register();
            try chest_type.addPermutation(chest_perm);

            const test_item = try ItemType.init(
                allocator,
                try allocator.dupe(u8, "test:item"),
                1,
                64,
                true,
                try allocator.alloc([]const u8, 0),
                false,
                0,
                NBT.Tag{ .Compound = NBT.CompoundTag.init(allocator, null) },
            );
            try test_item.register();

            var dim = Dimension{
                .world = undefined,
                .allocator = allocator,
                .identifier = "test",
                .dimension_type = .Overworld,
                .chunks = std.AutoHashMap(@TypeOf(chunkHash(0, 0)), *Chunk).init(allocator),
                .entities = std.AutoHashMap(i64, *Entity).init(allocator),
                .entity_index = ChunkEntityIndex.init(allocator),
                .blocks = std.AutoHashMap(i64, *Block).init(allocator),
                .blocks_by_chunk = std.AutoHashMap(@TypeOf(chunkHash(0, 0)), std.ArrayList(*Block)).init(allocator),
                .chunk_packet_cache = std.AutoHashMap(@TypeOf(chunkHash(0, 0)), CachedPacket).init(allocator),
                .chunk_generations = std.AutoHashMap(@TypeOf(chunkHash(0, 0)), u64).init(allocator),
                .pending_removals = std.ArrayList(i64){ .items = &.{}, .capacity = 0 },
                .spawn_position = .{ .x = 0, .y = 0, .z = 0 },
                .simulation_distance = 4,
                .generator = null,
            };
            defer dim.deinit();

            const chunk = try allocator.create(Chunk);
            chunk.* = Chunk.init(allocator, 0, 0, .Overworld);
            try dim.chunks.put(chunkHash(0, 0), chunk);

            const left = Protocol.BlockPosition{ .x = 0, .y = 64, .z = 0 };
            const right = Protocol.BlockPosition{ .x = 1, .y = 64, .z = 0 };
            try chunk.setPermutation(left.x, left.y, left.z, chest_perm, 0);
            try chunk.setPermutation(right.x, right.y, right.z, chest_perm, 0);

            try trait_mod.applyTraitsForBlock(allocator, &dim, right);
            try trait_mod.applyTraitsForBlock(allocator, &dim, left);

            const initial_left = dim.getBlockPtr(left).?;
            const initial_left_state = initial_left.getTraitState(ChestTrait).?;
            try std.testing.expect(initial_left_state.is_parent);

            if (initial_left_state.container) |*container| {
                container.base.setItem(30, ItemStack.init(allocator, test_item, .{ .stack_size = 7 }));
            } else {
                return error.TestUnexpectedResult;
            }

            var cycle: usize = 0;
            while (cycle < 5) : (cycle += 1) {
                var left_tag = CompoundTag.init(allocator, null);
                defer left_tag.deinit(allocator);
                var right_tag = CompoundTag.init(allocator, null);
                defer right_tag.deinit(allocator);

                dim.getBlockPtr(left).?.fireEvent(.Serialize, .{&left_tag});
                dim.getBlockPtr(right).?.fireEvent(.Serialize, .{&right_tag});

                dim.removeBlock(left);
                dim.removeBlock(right);

                if (cycle % 2 == 0) {
                    try trait_mod.applyTraitsForBlock(allocator, &dim, right);
                    try trait_mod.applyTraitsForBlock(allocator, &dim, left);
                } else {
                    try trait_mod.applyTraitsForBlock(allocator, &dim, left);
                    try trait_mod.applyTraitsForBlock(allocator, &dim, right);
                }

                const loaded_left = dim.getBlockPtr(left).?;
                const loaded_right = dim.getBlockPtr(right).?;

                restoreAdjacentPairing(loaded_right);
                restoreAdjacentPairing(loaded_left);

                if (cycle % 2 == 0) {
                    loaded_right.fireEvent(.Deserialize, .{&right_tag});
                    loaded_left.fireEvent(.Deserialize, .{&left_tag});
                } else {
                    loaded_left.fireEvent(.Deserialize, .{&left_tag});
                    loaded_right.fireEvent(.Deserialize, .{&right_tag});
                }

                const loaded_left_state = loaded_left.getTraitState(ChestTrait).?;
                const loaded_right_state = loaded_right.getTraitState(ChestTrait).?;
                try std.testing.expect(loaded_left_state.is_parent);
                try std.testing.expect(!loaded_right_state.is_parent);
                try std.testing.expectEqual(@as(u32, 54), loaded_left_state.container.?.base.getSize());
                try std.testing.expectEqual(@as(u32, 27), loaded_right_state.container.?.base.getSize());

                const item = loaded_left_state.container.?.base.getItem(30) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(u16, 7), item.stack_size);
            }
        }
    };
}
