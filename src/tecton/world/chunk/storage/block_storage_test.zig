pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const BlockPermutation = scope.BlockPermutation;
        const BlockState = scope.BlockState;
        const NBT = scope.NBT;
        const computePermutationHashFast = scope.computePermutationHashFast;

        pub fn case_000() !void {
            const allocator = std.testing.allocator;

            const identifiers = [_][]const u8{
                "minecraft:stone",
                "minecraft:air",
                "minecraft:oak_planks",
                "minecraft:grass_block",
                "minecraft:cobblestone",
            };

            for (identifiers) |identifier| {
                const hash_fast = computePermutationHashFast(identifier, null);

                var empty_state = BlockState.init(allocator);
                defer empty_state.deinit();
                const hash_calc = try BlockPermutation.calculateHash(allocator, identifier, empty_state);

                try std.testing.expectEqual(hash_calc, hash_fast);
            }

            {
                var state_nbt = NBT.CompoundTag.init(allocator, null);
                defer state_nbt.deinit(allocator);
                try state_nbt.set("facing", .{ .String = NBT.StringTag.init(try allocator.dupe(u8, "north"), null) });
                try state_nbt.set("open", .{ .Byte = NBT.ByteTag.init(1, null) });

                const hash_fast = computePermutationHashFast("minecraft:oak_door", state_nbt);

                var state_bs = BlockState.init(allocator);
                defer {
                    var it = state_bs.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        if (entry.value_ptr.* == .string) allocator.free(entry.value_ptr.string);
                    }
                    state_bs.deinit();
                }
                try state_bs.put(try allocator.dupe(u8, "facing"), .{ .string = try allocator.dupe(u8, "north") });
                try state_bs.put(try allocator.dupe(u8, "open"), .{ .boolean = true });

                const hash_calc = try BlockPermutation.calculateHash(allocator, "minecraft:oak_door", state_bs);

                try std.testing.expectEqual(hash_calc, hash_fast);
            }

            {
                var state_nbt = NBT.CompoundTag.init(allocator, null);
                defer state_nbt.deinit(allocator);
                try state_nbt.set("age", .{ .Int = NBT.IntTag.init(7, null) });

                const hash_fast = computePermutationHashFast("minecraft:wheat", state_nbt);

                var state_bs = BlockState.init(allocator);
                defer {
                    var it = state_bs.iterator();
                    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
                    state_bs.deinit();
                }
                try state_bs.put(try allocator.dupe(u8, "age"), .{ .integer = 7 });

                const hash_calc = try BlockPermutation.calculateHash(allocator, "minecraft:wheat", state_bs);

                try std.testing.expectEqual(hash_calc, hash_fast);
            }
        }
    };
}
