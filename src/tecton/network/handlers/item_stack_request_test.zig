pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Protocol = scope.Protocol;
        const Container = scope.Container;
        const ItemStack = scope.ItemStack;
        const ItemType = scope.ItemType;
        const resolveCoreSlot = scope.resolveCoreSlot;
        const applyTransferAction = scope.applyTransferAction;
        const applyDropAction = scope.applyDropAction;
        const playerDropSpawnPosition = scope.playerDropSpawnPosition;

        pub fn case_000() !void {
            try std.testing.expectEqual(@as(u32, 0), resolveCoreSlot(.CreativeOutput, 50));
            try std.testing.expectEqual(@as(u32, 1), resolveCoreSlot(.Trade2Ingredient2, 5));
            try std.testing.expectEqual(@as(u32, 7), resolveCoreSlot(.Inventory, 7));
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            var src = try Container.init(allocator, .Inventory, 36);
            defer src.deinit();
            var dst = try Container.init(allocator, .Inventory, 1);
            defer dst.deinit();

            const stone = try ItemType.init(
                allocator,
                try allocator.dupe(u8, "minecraft:stone"),
                1,
                64,
                true,
                &.{},
                false,
                0,
                .{ .End = .{} },
            );
            try stone.register();

            src.setItem(5, ItemStack.init(allocator, stone, .{ .stack_size = 1 }));
            dst.setItem(0, ItemStack.init(allocator, stone, .{ .stack_size = 10 }));

            try applyTransferAction(&src, 5, &dst, 0, 1);

            try std.testing.expect(src.getItem(5) == null);
            const cursor = dst.getItem(0) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u16, 11), cursor.stack_size);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            var src = try Container.init(allocator, .Inventory, 36);
            defer src.deinit();

            const stone = try ItemType.init(
                allocator,
                try allocator.dupe(u8, "minecraft:stone"),
                1,
                64,
                true,
                &.{},
                false,
                0,
                .{ .End = .{} },
            );
            try stone.register();

            src.setItem(9, ItemStack.init(allocator, stone, .{ .stack_size = 32 }));

            var dropped = try applyDropAction(&src, 9, 1);
            defer dropped.deinit();

            try std.testing.expectEqual(stone, dropped.item_type);
            try std.testing.expectEqual(@as(u16, 1), dropped.stack_size);
            const remaining = src.getItem(9) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u16, 31), remaining.stack_size);
        }

        pub fn case_003() !void {
            const pos = Protocol.Vector3f.init(4, 65.62, -2);
            const drop_pos = playerDropSpawnPosition(pos);

            try std.testing.expectEqual(@as(f32, 4), drop_pos.x);
            try std.testing.expectEqual(@as(f32, 65.3), drop_pos.y);
            try std.testing.expectEqual(@as(f32, -2), drop_pos.z);
        }
    };
}
