const std = @import("std");

pub fn Suite(comptime model: type) type {
    return struct {
        const BlockPermutation = model.BlockPermutation;
        const BlockType = model.BlockType;
        const BlockState = model.BlockState;
        const BlockStateValue = model.BlockStateValue;

        pub fn hashLookup() !void {
            const allocator = std.testing.allocator;
            try BlockPermutation.initRegistry(allocator);
            defer BlockPermutation.deinitRegistry();

            try BlockType.initRegistry(allocator);
            defer BlockType.deinitRegistry();

            const Data = @import("protocol").Data;
            var loader = Data.BlockPermutationLoader.init(allocator);
            defer loader.deinit();
            _ = try loader.load();

            var types_created = std.StringHashMap(void).init(allocator);
            defer types_created.deinit();

            for (loader.getPermutations()) |perm_data| {
                const identifier = perm_data.identifier;
                if (!types_created.contains(identifier)) {
                    if (BlockType.get(identifier) == null) {
                        const block_type = try BlockType.init(allocator, identifier);
                        try block_type.register();
                    }
                    try types_created.put(identifier, {});
                }

                var state = BlockState.init(allocator);
                if (perm_data.state == .object) {
                    var iter = perm_data.state.object.iterator();
                    while (iter.next()) |entry| {
                        const key = try allocator.dupe(u8, entry.key_ptr.*);
                        const value = switch (entry.value_ptr.*) {
                            .bool => |b| BlockStateValue{ .boolean = b },
                            .integer => |i| BlockStateValue{ .integer = @intCast(i) },
                            .string => |s| BlockStateValue{ .string = try allocator.dupe(u8, s) },
                            else => continue,
                        };
                        try state.put(key, value);
                    }
                }

                const perm = try BlockPermutation.init(allocator, perm_data.hash, identifier, state);
                try perm.register();

                if (BlockType.get(identifier)) |block_type| {
                    try block_type.addPermutation(perm);
                }
            }

            try BlockPermutation.initNbtHashLookup(allocator);

            var iter = BlockPermutation.valueIterator();
            var checked: usize = 0;
            while (iter.next()) |entry| {
                const perm = entry.*;
                const hash = try BlockPermutation.calculateHash(allocator, perm.identifier, perm.state);
                const looked_up = BlockPermutation.lookupByNbtHash(hash);
                try std.testing.expect(looked_up != null);
                try std.testing.expectEqual(perm.network_id, looked_up.?);
                checked += 1;
            }
            try std.testing.expect(checked > 0);
        }
    };
}
