pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const ItemStack = scope.ItemStack;
        const Display = scope.Display;
        const Container = scope.Container;

        pub fn case_000() !void {
            const allocator = std.testing.allocator;
            const ItemType = scope.test_dependency_0.ItemType;
            const NBT = @import("nbt");

            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            var container = try Container.init(allocator, .Inventory, 9);
            defer container.deinit();

            const test_type = try ItemType.init(
                allocator,
                try allocator.dupe(u8, "minecraft:test_oob_stone"),
                1,
                64,
                true,
                &.{},
                false,
                0,
                NBT.Tag{ .Compound = NBT.CompoundTag.init(allocator, null) },
            );
            try test_type.register();

            container.setItem(9, ItemStack.init(allocator, test_type, .{}));
            try std.testing.expect(container.storage[0] == null);

            try std.testing.expect(container.getItem(9) == null);
            try std.testing.expect(container.getItemMut(27) == null);
            try std.testing.expect(container.takeItem(100, 1) == null);

            container.clearSlot(9);
            container.removeItem(9, 1);
            container.swapItems(0, 9, null);

            try std.testing.expect(container.getItem(0) == null);
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            const ItemType = scope.test_dependency_0.ItemType;
            const NBT = @import("nbt");

            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            var container = try Container.init(allocator, .Inventory, 9);
            defer container.deinit();

            const stone = try ItemType.init(
                allocator,
                try allocator.dupe(u8, "minecraft:test_named_stone"),
                1,
                64,
                true,
                &.{},
                false,
                0,
                NBT.Tag{ .Compound = NBT.CompoundTag.init(allocator, null) },
            );
            try stone.register();
            var item = ItemStack.init(allocator, stone, .{ .stack_size = 5 });
            const display = try Display.DisplayTrait.create(allocator, .{});
            try item.addTrait(display);
            try Display.setDisplayName(&item, "Named Stone");
            container.setItem(0, item);

            var split = container.takeItem(0, 2) orelse return error.TestUnexpectedResult;
            defer split.deinit();

            try std.testing.expectEqual(@as(u16, 2), split.stack_size);
            try std.testing.expectEqualStrings("Named Stone", Display.getDisplayName(&split) orelse return error.TestUnexpectedResult);

            const remaining = container.getItem(0) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u16, 3), remaining.stack_size);
            try std.testing.expectEqualStrings("Named Stone", Display.getDisplayName(remaining) orelse return error.TestUnexpectedResult);
        }
    };
}
