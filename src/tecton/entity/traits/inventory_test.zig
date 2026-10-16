pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const BinaryStream = scope.BinaryStream;
        const Protocol = scope.Protocol;
        const Container = scope.Container;
        const EntityContainer = scope.EntityContainer;
        const ItemStack = scope.ItemStack;
        const ItemType = scope.ItemType;
        const State = scope.State;
        const selectHeldSlot = scope.selectHeldSlot;
        const serializeArmor = scope.serializeArmor;
        const armorSlotFor = scope.armorSlotFor;
        const swapIntoArmor = scope.swapIntoArmor;
        const testArmorPiece = scope.testArmorPiece;
        const DeathDrops = scope.DeathDrops;
        const drainForDeath = scope.drainForDeath;
        const dropsOnDeath = scope.dropsOnDeath;
        const Enchantments = @import("../../items/enchantments/compat.zig");

        pub fn case_000() !void {
            const allocator = std.testing.allocator;

            var container = try EntityContainer.init(allocator, undefined, .Inventory, 36);
            defer container.deinit();

            var state = State{
                .container = container,
                .selected_slot = 0,
                .opened = false,
            };

            selectHeldSlot(&state, 5);

            try std.testing.expectEqual(@as(u8, 5), state.selected_slot);
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;

            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            const kinds = [4]*ItemType{
                try testArmorPiece(allocator, "minecraft:test_inventory_helmet", 11),
                try testArmorPiece(allocator, "minecraft:test_inventory_chestplate", 12),
                try testArmorPiece(allocator, "minecraft:test_inventory_leggings", 13),
                try testArmorPiece(allocator, "minecraft:test_inventory_boots", 14),
            };

            var state = State{
                .container = try EntityContainer.init(allocator, undefined, .Inventory, 36),
                .armor = try Container.init(allocator, .Inventory, 4),
                .selected_slot = 0,
                .opened = false,
            };
            defer state.container.deinit();
            defer if (state.armor) |*armor| armor.deinit();

            for (kinds, 0..) |kind, slot| {
                state.armor.?.setItem(@intCast(slot), ItemStack.init(allocator, kind, .{}));
            }

            var stream = BinaryStream.init(allocator, null, null);
            defer stream.deinit();

            const serialized = serializeArmor(&state, 7, &stream) orelse return error.TestUnexpectedResult;

            var reader = BinaryStream.init(allocator, serialized, null);
            defer reader.deinit();

            _ = try reader.readVarInt();
            _ = try reader.readVarLong();

            var pieces: [5]Protocol.NetworkItemStackDescriptor = undefined;
            for (&pieces) |*piece| piece.* = try Protocol.NetworkItemStackDescriptor.readShort(&reader, allocator);
            defer {
                for (&pieces) |*piece| piece.deinit(allocator);
            }

            for (kinds, 0..) |kind, slot| {
                try std.testing.expectEqual(kind.network_id, pieces[slot].network);
            }
            try std.testing.expectEqual(@as(i32, 0), pieces[4].network);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            const kinds = [6]*ItemType{
                try testArmorPiece(allocator, "minecraft:test_equip_helmet", 21),
                try testArmorPiece(allocator, "minecraft:test_equip_chestplate", 22),
                try testArmorPiece(allocator, "minecraft:test_equip_leggings", 23),
                try testArmorPiece(allocator, "minecraft:test_equip_boots", 24),
                try testArmorPiece(allocator, "minecraft:elytra", 25),
                try testArmorPiece(allocator, "minecraft:test_equip_sword", 26),
            };

            try std.testing.expectEqual(@as(?u8, 0), armorSlotFor(kinds[0]));
            try std.testing.expectEqual(@as(?u8, 1), armorSlotFor(kinds[1]));
            try std.testing.expectEqual(@as(?u8, 2), armorSlotFor(kinds[2]));
            try std.testing.expectEqual(@as(?u8, 3), armorSlotFor(kinds[3]));
            try std.testing.expectEqual(@as(?u8, 1), armorSlotFor(kinds[4]));
            try std.testing.expectEqual(@as(?u8, null), armorSlotFor(kinds[5]));
        }

        pub fn case_003() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            const chestplate = try testArmorPiece(allocator, "minecraft:test_empty_chestplate", 41);

            var state = State{
                .container = try EntityContainer.init(allocator, undefined, .Inventory, 36),
                .armor = try Container.init(allocator, .Inventory, 4),
                .selected_slot = 2,
                .opened = false,
            };
            defer state.container.deinit();
            defer if (state.armor) |*armor| armor.deinit();

            state.container.base.setItem(2, ItemStack.init(allocator, chestplate, .{}));

            const item_type = state.container.base.getItem(2).?.item_type;

            try std.testing.expectEqual(@as(?u8, 1), swapIntoArmor(&state, 2));
            try std.testing.expect(state.container.base.getItem(2) == null);
            try std.testing.expectEqual(@as(i32, 41), item_type.network_id);
        }

        pub fn case_004() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            const helmet = try testArmorPiece(allocator, "minecraft:test_swap_helmet", 31);
            const boots = try testArmorPiece(allocator, "minecraft:test_swap_boots", 32);
            const sword = try testArmorPiece(allocator, "minecraft:test_swap_sword", 33);

            var state = State{
                .container = try EntityContainer.init(allocator, undefined, .Inventory, 36),
                .armor = try Container.init(allocator, .Inventory, 4),
                .selected_slot = 3,
                .opened = false,
            };
            defer state.container.deinit();
            defer if (state.armor) |*armor| armor.deinit();

            state.armor.?.setItem(0, ItemStack.init(allocator, helmet, .{ .metadata = 7 }));
            state.container.base.setItem(3, ItemStack.init(allocator, boots, .{}));

            try std.testing.expectEqual(@as(?u8, 3), swapIntoArmor(&state, 3));
            try std.testing.expectEqual(@as(i32, 32), state.armor.?.getItem(3).?.item_type.network_id);
            try std.testing.expect(state.container.base.getItem(3) == null);

            state.container.base.setItem(3, ItemStack.init(allocator, helmet, .{ .metadata = 1 }));
            try std.testing.expectEqual(@as(?u8, 0), swapIntoArmor(&state, 3));
            try std.testing.expectEqual(@as(i32, 31), state.armor.?.getItem(0).?.item_type.network_id);
            try std.testing.expectEqual(@as(u32, 1), state.armor.?.getItem(0).?.metadata);
            try std.testing.expectEqual(@as(u32, 7), state.container.base.getItem(3).?.metadata);

            state.container.base.setItem(3, ItemStack.init(allocator, sword, .{}));
            try std.testing.expectEqual(@as(?u8, null), swapIntoArmor(&state, 3));
            try std.testing.expectEqual(@as(i32, 33), state.container.base.getItem(3).?.item_type.network_id);
        }

        pub fn case_005() !void {
            try std.testing.expect(dropsOnDeath(.Survival));
            try std.testing.expect(dropsOnDeath(.Adventure));
            try std.testing.expect(!dropsOnDeath(.Creative));
            try std.testing.expect(!dropsOnDeath(.Spectator));
            try std.testing.expect(!dropsOnDeath(.CreativeSpectator));
            try std.testing.expect(!dropsOnDeath(.SurvivalSpectator));
        }

        pub fn case_006() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            const sword = try testArmorPiece(allocator, "minecraft:test_death_sword", 51);
            const bound = try testArmorPiece(allocator, "minecraft:test_death_boots", 52);
            const doomed = try testArmorPiece(allocator, "minecraft:test_death_helmet", 53);

            var state = State{
                .container = try EntityContainer.init(allocator, undefined, .Inventory, 36),
                .armor = try Container.init(allocator, .Inventory, 4),
                .selected_slot = 0,
                .opened = false,
            };
            defer state.container.deinit();
            defer if (state.armor) |*armor| armor.deinit();

            state.container.base.setItem(0, ItemStack.init(allocator, sword, .{}));

            var bound_piece = ItemStack.init(allocator, bound, .{});
            _ = bound_piece.enchantments.set(Enchantments.CURSE_OF_BINDING, 1);
            state.container.base.setItem(1, bound_piece);

            var doomed_piece = ItemStack.init(allocator, doomed, .{});
            _ = doomed_piece.enchantments.set(Enchantments.CURSE_OF_VANISHING, 1);
            state.armor.?.setItem(0, doomed_piece);

            var drops = DeathDrops{};
            drainForDeath(&state.container.base, &drops);
            drainForDeath(&state.armor.?, &drops);

            try std.testing.expectEqual(@as(u8, 2), drops.kept_len);
            try std.testing.expectEqual(@as(u8, 1), drops.destroyed);
            try std.testing.expectEqual(@as(i32, 51), drops.kept[0].item_type.network_id);
            try std.testing.expectEqual(@as(i32, 52), drops.kept[1].item_type.network_id);
            try std.testing.expectEqual(@as(?*const ItemStack, null), state.container.base.getItem(0));
            try std.testing.expectEqual(@as(?*const ItemStack, null), state.container.base.getItem(1));
            try std.testing.expectEqual(@as(?*const ItemStack, null), state.armor.?.getItem(0));

            for (drops.kept[0..drops.kept_len]) |*kept| kept.deinit();
        }
    };
}
