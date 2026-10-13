pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const testing = scope.testing;
        const CompoundTag = scope.CompoundTag;
        const ListTag = scope.ListTag;
        const Tag = scope.Tag;
        const FloatTag = scope.FloatTag;
        const Protocol = scope.Protocol;
        const EntityType = scope.EntityType;
        const Entity = scope.Entity;
        const EnchantmentTesting = scope.EnchantmentTesting;
        const ItemStack = scope.ItemStack;
        const ItemType = scope.ItemType;
        const Container = scope.Container;
        const serializeItemStack = scope.serializeItemStack;
        const deserializeItemStack = scope.deserializeItemStack;
        const serializeContainer = scope.serializeContainer;
        const deserializeContainer = scope.deserializeContainer;
        const serializeEntity = scope.serializeEntity;
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

        pub fn case_003() !void {
            const allocator = testing.allocator;

            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            const item_type = try EnchantmentTesting.itemType(allocator, "minecraft:test_rt_blade", &.{"minecraft:is_sword"}, false);
            try item_type.register();

            var item = ItemStack.init(allocator, item_type, .{ .stack_size = 1, .metadata = 3 });
            defer item.deinit();
            _ = item.enchantments.set(9, 3);

            var tag = try serializeItemStack(allocator, &item);
            defer tag.deinit(allocator);
            try testing.expectEqualStrings("minecraft:test_rt_blade", tag.get("Name").?.String.value);
            try testing.expectEqual(@as(i8, 1), tag.get("Count").?.Byte.value);
            try testing.expectEqual(@as(i16, 3), tag.get("Damage").?.Short.value);
            const inner = tag.get("tag").?.Compound;
            const ench = inner.get("ench").?;
            try testing.expectEqual(@as(usize, 1), ench.List.value.len);
            try testing.expectEqual(@as(i16, 9), ench.List.value[0].Compound.get("id").?.Short.value);
            try testing.expectEqual(@as(i16, 3), ench.List.value[0].Compound.get("lvl").?.Short.value);

            const bytes = try encodeNbt(allocator, &tag);
            defer allocator.free(bytes);
            var golden_buf: [91]u8 = undefined;
            const golden_hex = "0a00000a0300746167090400656e63680a01000000020200696409000203006c766c03000000010500436f756e740102060044616d61676503000804004e616d6517006d696e6563726166743a746573745f72745f626c61646500";
            try testing.expectEqual(golden_hex.len / 2, bytes.len);
            _ = try std.fmt.hexToBytes(&golden_buf, golden_hex);
            try testing.expectEqualSlices(u8, &golden_buf, bytes);


            var decoded = try decodeNbt(allocator, bytes);
            defer decoded.deinit(allocator);
            var item_again = deserializeItemStack(allocator, &decoded) orelse return error.TestUnexpectedResult;
            defer item_again.deinit();
            try testing.expectEqualStrings("minecraft:test_rt_blade", item_again.item_type.identifier);
            try testing.expectEqual(@as(u16, 1), item_again.stack_size);
            try testing.expectEqual(@as(u32, 3), item_again.metadata);

            var tag_again = try serializeItemStack(allocator, &item_again);
            defer tag_again.deinit(allocator);
            const bytes_again = try encodeNbt(allocator, &tag_again);
            defer allocator.free(bytes_again);
            try testing.expectEqualSlices(u8, bytes, bytes_again);
        }

        pub fn case_004() !void {
            const allocator = testing.allocator;

            const entity_type = EntityType.init("minecraft:zombie", 32, &.{}, &.{});
            var entity = Entity.init(allocator, &entity_type, null);
            defer entity.deinit();
            entity.position = Protocol.Vector3f.init(10.5, 64.0, -3.25);
            entity.rotation = Protocol.Vector2f.init(90.0, 15.0);
            entity.motion = Protocol.Vector3f.init(0.1, -0.2, 0.3);
            entity.unique_id = 424242;
            const stored_uid = entity.unique_id;

            var tag = try serializeEntity(allocator, &entity);
            defer tag.deinit(allocator);
            try testing.expectEqualStrings("minecraft:zombie", tag.get("identifier").?.String.value);
            const bytes = try encodeNbt(allocator, &tag);
            defer allocator.free(bytes);
            var golden_buf: [127]u8 = undefined;
            const golden_hex = "0a0000080a006964656e74696669657210006d696e6563726166743a7a6f6d626965090800526f746174696f6e05020000000000b442000070410906004d6f74696f6e0503000000cdcccc3dcdcc4cbe9a99993e090300506f7305030000000000284100008042000050c0040800556e697175654944327906000000000000";
            try testing.expectEqual(golden_hex.len / 2, bytes.len);
            _ = try std.fmt.hexToBytes(&golden_buf, golden_hex);
            try testing.expectEqualSlices(u8, &golden_buf, bytes);


            var decoded = try decodeNbt(allocator, bytes);
            defer decoded.deinit(allocator);
            var loaded = Entity.init(allocator, &entity_type, null);
            defer loaded.deinit();
            deserializeEntity(allocator, &loaded, &decoded);
            try testing.expectEqual(stored_uid, loaded.unique_id);
            try testing.expectEqual(@as(f32, 10.5), loaded.position.x);
            try testing.expectEqual(@as(f32, 64.0), loaded.position.y);
            try testing.expectEqual(@as(f32, -3.25), loaded.position.z);
            try testing.expectEqual(@as(f32, 90.0), loaded.rotation.x);
            try testing.expectEqual(@as(f32, 15.0), loaded.rotation.y);
            try testing.expectEqual(@as(f32, 0.1), loaded.motion.x);
            try testing.expectEqual(@as(f32, -0.2), loaded.motion.y);
            try testing.expectEqual(@as(f32, 0.3), loaded.motion.z);

            var tag_again = try serializeEntity(allocator, &loaded);
            defer tag_again.deinit(allocator);
            const bytes_again = try encodeNbt(allocator, &tag_again);
            defer allocator.free(bytes_again);
            try testing.expectEqualSlices(u8, bytes, bytes_again);
        }

        pub fn case_005() !void {
            const allocator = testing.allocator;

            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            const blade_type = try EnchantmentTesting.itemType(allocator, "minecraft:test_rt_chest_blade", &.{"minecraft:is_sword"}, false);
            try blade_type.register();
            const stone_type = try EnchantmentTesting.itemType(allocator, "minecraft:test_rt_chest_stone", &.{}, true);
            try stone_type.register();

            var container = try Container.init(allocator, .Inventory, 9);
            defer container.deinit();
            var blade = ItemStack.init(allocator, blade_type, .{ .stack_size = 1, .metadata = 0 });
            _ = blade.enchantments.set(9, 3);
            container.setItem(0, blade);
            container.setItem(3, ItemStack.init(allocator, stone_type, .{ .stack_size = 5, .metadata = 0 }));

            const list = try serializeContainer(allocator, &container);
            var wrap = CompoundTag.init(allocator, null);
            defer wrap.deinit(allocator);
            try wrap.set("Items", .{ .List = list });
            const bytes = try encodeNbt(allocator, &wrap);
            defer allocator.free(bytes);
            var golden_buf: [186]u8 = undefined;
            const golden_hex = "0a00000905004974656d730a020000000a0300746167090400656e63680a01000000020200696409000203006c766c03000000010400536c6f7400010500436f756e740102060044616d61676500000804004e616d651d006d696e6563726166743a746573745f72745f63686573745f626c61646500010400536c6f7403010500436f756e740502060044616d61676500000804004e616d651d006d696e6563726166743a746573745f72745f63686573745f73746f6e650000";
            try testing.expectEqual(golden_hex.len / 2, bytes.len);
            _ = try std.fmt.hexToBytes(&golden_buf, golden_hex);
            try testing.expectEqualSlices(u8, &golden_buf, bytes);


            var decoded = try decodeNbt(allocator, bytes);
            defer decoded.deinit(allocator);
            var container_again = try Container.init(allocator, .Inventory, 9);
            defer container_again.deinit();
            const items_tag = decoded.get("Items") orelse return error.TestUnexpectedResult;
            switch (items_tag) {
                .List => |items_list| deserializeContainer(allocator, &container_again, &items_list),
                else => return error.TestUnexpectedResult,
            }
            const blade_again = container_again.getItem(0) orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("minecraft:test_rt_chest_blade", blade_again.item_type.identifier);
            const stone_again = container_again.getItem(3) orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("minecraft:test_rt_chest_stone", stone_again.item_type.identifier);
            try testing.expectEqual(@as(u16, 5), stone_again.stack_size);
            try testing.expect(container_again.getItem(1) == null);

            const list_again = try serializeContainer(allocator, &container_again);
            var wrap_again = CompoundTag.init(allocator, null);
            defer wrap_again.deinit(allocator);
            try wrap_again.set("Items", .{ .List = list_again });
            const bytes_again = try encodeNbt(allocator, &wrap_again);
            defer allocator.free(bytes_again);
            try testing.expectEqualSlices(u8, bytes, bytes_again);
        }
    };
}
