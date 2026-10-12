pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const testing = scope.testing;
        const CompoundTag = scope.CompoundTag;
        const ListTag = scope.ListTag;
        const Tag = scope.Tag;
        const FloatTag = scope.FloatTag;
        const EntityType = scope.EntityType;
        const Entity = scope.Entity;
        const EnchantmentTesting = scope.EnchantmentTesting;
        const ItemStack = scope.ItemStack;
        const serializeItemStack = scope.serializeItemStack;
        const deserializeEntity = scope.deserializeEntity;
        const encodeNbt = scope.encodeNbt;
        const decodeNbt = scope.decodeNbt;
        const world_border = scope.world_border;
        const max_motion = scope.max_motion;

        pub fn case_000() !void {
            const allocator = testing.allocator;

            const entity_type = EntityType.init("minecraft:zombie", 1, &.{}, &.{});
            var entity = Entity.init(allocator, &entity_type, null);
            defer entity.deinit();

            var tag = CompoundTag.init(allocator, null);
            defer tag.deinit(allocator);

            const pos = try allocator.alloc(Tag, 3);
            pos[0] = .{ .Float = FloatTag.init(std.math.inf(f32), null) };
            pos[1] = .{ .Float = FloatTag.init(std.math.nan(f32), null) };
            pos[2] = .{ .Float = FloatTag.init(-1e30, null) };
            try tag.set("Pos", .{ .List = ListTag.init(pos, null) });

            const motion = try allocator.alloc(Tag, 3);
            motion[0] = .{ .Float = FloatTag.init(std.math.nan(f32), null) };
            motion[1] = .{ .Float = FloatTag.init(1e30, null) };
            motion[2] = .{ .Float = FloatTag.init(0.02, null) };
            try tag.set("Motion", .{ .List = ListTag.init(motion, null) });

            deserializeEntity(allocator, &entity, &tag);

            try testing.expectEqual(@as(f32, 0.0), entity.position.x);
            try testing.expectEqual(@as(f32, 0.0), entity.position.y);
            try testing.expectEqual(@as(f32, -world_border), entity.position.z);
            try testing.expectEqual(@as(f32, 0.0), entity.motion.x);
            try testing.expectEqual(@as(f32, max_motion), entity.motion.y);
            try testing.expectEqual(@as(f32, 0.02), entity.motion.z);
        }

        pub fn case_001() !void {
            const allocator = testing.allocator;

            const item_type = try EnchantmentTesting.itemType(allocator, "minecraft:test_serialize_sword", &.{"minecraft:is_sword"}, false);
            defer item_type.deinit();

            var item = ItemStack.init(allocator, item_type, .{});
            defer item.deinit();

            _ = item.enchantments.set(9, 3);
            try testing.expect(item.enchantments.dirty);
            try testing.expect(item.nbt == null);

            var tag = try serializeItemStack(allocator, &item);
            defer tag.deinit(allocator);

            const inner = tag.get("tag").?.Compound;
            try testing.expect(inner.get("ench") != null);
            try testing.expect(inner.get("Name") == null);
            try testing.expect(!item.enchantments.dirty);

            const ench = inner.get("ench").?;
            try testing.expect(ench == .List);
            try testing.expectEqual(@as(usize, 1), ench.List.value.len);
            try testing.expectEqual(@as(i16, 9), ench.List.value[0].Compound.get("id").?.Short.value);
            try testing.expectEqual(@as(i16, 3), ench.List.value[0].Compound.get("lvl").?.Short.value);
        }

        pub fn case_002() !void {
            const allocator = testing.allocator;

            var tag = CompoundTag.init(allocator, null);
            defer tag.deinit(allocator);
            try tag.set("Name", .{ .String = .{ .value = try allocator.dupe(u8, "minecraft:diamond_sword"), .name = null } });
            try tag.set("Count", .{ .Byte = .{ .value = 1, .name = null } });

            const bytes = try encodeNbt(allocator, &tag);
            defer allocator.free(bytes);
            try testing.expect(bytes.len > 0);

            var decoded = try decodeNbt(allocator, bytes);
            defer decoded.deinit(allocator);
            const name = decoded.get("Name").?.String.value;
            try testing.expectEqualStrings("minecraft:diamond_sword", name);
            try testing.expectEqual(@as(i8, 1), decoded.get("Count").?.Byte.value);

            const bytes_again = try encodeNbt(allocator, &decoded);
            defer allocator.free(bytes_again);
            try testing.expectEqualSlices(u8, bytes, bytes_again);
        }
    };
}
