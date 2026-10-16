const std = @import("std");
const NBT = @import("nbt");

pub fn Suite(comptime model: type) type {
    return struct {
        const BlockPermutation = model.BlockPermutation;
        const BlockType = model.BlockType;
        const BlockState = model.BlockState;

        fn add(identifier: []const u8, state: BlockState) !*BlockPermutation {
            const allocator = std.testing.allocator;
            const hash = try BlockPermutation.calculateHash(allocator, identifier, state);
            const perm = try BlockPermutation.init(allocator, hash, identifier, state);
            try perm.register();
            try BlockType.get(identifier).?.addPermutation(perm);
            return perm;
        }

        pub fn resolution() !void {
            const allocator = std.testing.allocator;
            try BlockPermutation.initRegistry(allocator);
            defer BlockPermutation.deinitRegistry();
            try BlockType.initRegistry(allocator);
            defer BlockType.deinitRegistry();
            // Repeated initialization must preserve the same registries.
            try BlockPermutation.initRegistry(allocator);
            try BlockType.initRegistry(allocator);
            try std.testing.expectError(error.BlockTypeNotFound, BlockPermutation.resolve(allocator, "minecraft:unknown", null));
            const empty = try BlockType.init(allocator, "minecraft:empty");
            try empty.register();
            try std.testing.expectError(error.NoPermutationsFound, BlockPermutation.resolve(allocator, "minecraft:empty", null));

            const air_type = try BlockType.init(allocator, "minecraft:air");
            try air_type.register();
            const air = try add("minecraft:air", BlockState.init(allocator));
            const kind = try BlockType.init(allocator, "minecraft:test_state");
            try kind.register();
            var first_state = BlockState.init(allocator);
            try first_state.put(try allocator.dupe(u8, "open"), .{ .boolean = false });
            try first_state.put(try allocator.dupe(u8, "direction"), .{ .integer = 0 });
            const first = try add(kind.identifier, first_state);
            var second_state = BlockState.init(allocator);
            try second_state.put(try allocator.dupe(u8, "open"), .{ .boolean = true });
            try second_state.put(try allocator.dupe(u8, "direction"), .{ .integer = 1 });
            const second = try add(kind.identifier, second_state);

            try std.testing.expect(first == try BlockPermutation.resolve(allocator, kind.identifier, null));
            try std.testing.expect(second == try BlockPermutation.resolve(allocator, kind.identifier, second.state));
            var partial = BlockState.init(allocator);
            defer partial.deinit();
            try partial.put("open", .{ .boolean = true });
            try std.testing.expect(second == try BlockPermutation.resolve(allocator, kind.identifier, partial));
            try partial.put("direction", .{ .integer = 99 });
            try std.testing.expect(first == try BlockPermutation.resolve(allocator, kind.identifier, partial));
            partial.clearRetainingCapacity();
            try std.testing.expect(first == try BlockPermutation.resolve(allocator, kind.identifier, partial));
            try std.testing.expect(air == try BlockPermutation.resolve(allocator, "minecraft:unknown", null));
            try std.testing.expect(air == BlockPermutation.getByNetworkId(air.network_id).?);
            try BlockPermutation.initNbtHashLookup(allocator);
            try std.testing.expectEqual(second.network_id, BlockPermutation.lookupByNbtHash(second.network_id).?);
        }

        pub fn hashAndNbt() !void {
            const allocator = std.testing.allocator;
            var forward = BlockState.init(allocator);
            defer forward.deinit();
            try forward.put("a", .{ .boolean = true });
            try forward.put("b", .{ .integer = -7 });
            try forward.put("c", .{ .string = "value" });
            var reverse = BlockState.init(allocator);
            defer reverse.deinit();
            try reverse.put("c", .{ .string = "value" });
            try reverse.put("b", .{ .integer = -7 });
            try reverse.put("a", .{ .boolean = true });
            const hash = try BlockPermutation.calculateHash(allocator, "minecraft:test", forward);
            try std.testing.expectEqual(hash, try BlockPermutation.calculateHash(allocator, "minecraft:test", reverse));
            const perm = BlockPermutation{ .allocator = allocator, .network_id = hash, .identifier = "minecraft:test", .state = forward };
            var compound = try perm.toNBT(allocator);
            defer compound.deinit(allocator);
            const BinaryStream = @import("BinaryStream").BinaryStream;
            var writer = BinaryStream.init(allocator, null, null);
            defer writer.deinit();
            const options = NBT.ReadWriteOptions{ .name = true, .tag_type = true, .varint = false, .endian = .Little };
            // CompoundTag iteration is hash-map order; the hash contract is canonical
            // NBT with name first and state keys sorted, independent of insertion.
            try writer.writeUint8(10);
            try writer.writeUint16(0, .Little);
            var name = compound.get("name").?;
            try name.write(&writer, options);
            try writer.writeUint8(10);
            try writer.writeUint16(6, .Little);
            try writer.write("states");
            const states = compound.get("states").?.Compound;
            for ([_][]const u8{ "a", "b", "c" }) |key| {
                var tag = states.get(key).?;
                try tag.write(&writer, options);
            }
            try writer.writeUint8(0);
            try writer.writeUint8(0);
            var expected: u32 = 0x811c9dc5;
            for (writer.getBuffer()) |byte| {
                expected ^= byte;
                expected *%= 16777619;
            }
            try std.testing.expectEqual(hash, @as(i32, @bitCast(expected)));
        }
    };
}
