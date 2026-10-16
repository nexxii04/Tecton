pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const ItemStack = scope.ItemStack;
        const EnchantmentRegistry = scope.EnchantmentRegistry;
        const DESCRIPTION = scope.DESCRIPTION;
        const USAGE = scope.USAGE;
        const MESSAGE_SUCCESS = scope.MESSAGE_SUCCESS;
        const MESSAGE_NO_ITEM = scope.MESSAGE_NO_ITEM;
        const MESSAGE_CANT_ENCHANT = scope.MESSAGE_CANT_ENCHANT;
        const MESSAGE_CANT_COMBINE = scope.MESSAGE_CANT_COMBINE;
        const MESSAGE_INVALID_LEVEL = scope.MESSAGE_INVALID_LEVEL;
        const MESSAGE_NOT_FOUND = scope.MESSAGE_NOT_FOUND;
        const successMessage = scope.successMessage;
        const noItemMessage = scope.noItemMessage;
        const cantEnchantMessage = scope.cantEnchantMessage;
        const cantCombineMessage = scope.cantCombineMessage;
        const invalidLevelMessage = scope.invalidLevelMessage;
        const notFoundMessage = scope.notFoundMessage;
        const testing = scope.testing;
        const enchant_testing = scope.enchant_testing;
        const parseLevel = scope.parseLevel;
        const levelInRange = scope.levelInRange;
        const resolve = scope.resolve;

        pub fn case_000() !void {
            const allocator = std.testing.allocator;
            var registry = EnchantmentRegistry.Registry.init(allocator);
            defer registry.deinit();
            _ = try registry.loadVanilla();

            var numeric_id: ?i64 = null;
            try std.testing.expectEqual(@as(u16, 9), resolve(&registry, "9", &numeric_id).?.id);
            try std.testing.expectEqual(@as(?i64, 9), numeric_id);

            numeric_id = null;
            try std.testing.expectEqual(@as(u16, 9), resolve(&registry, "sharpness", &numeric_id).?.id);
            try std.testing.expect(numeric_id == null);
            try std.testing.expectEqual(@as(u16, 9), resolve(&registry, "minecraft:SHARPNESS", &numeric_id).?.id);
            try std.testing.expect(resolve(&registry, "not_an_enchantment", &numeric_id) == null);

            numeric_id = null;
            try std.testing.expect(resolve(&registry, "999", &numeric_id) == null);
            try std.testing.expectEqual(@as(?i64, 999), numeric_id);
            try std.testing.expect(resolve(&registry, "-3", &numeric_id) == null);
            try std.testing.expect(resolve(&registry, "4000000000", &numeric_id) == null);
            try std.testing.expect(resolve(&registry, "0", &numeric_id).?.id == 0);
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            var registry = EnchantmentRegistry.Registry.init(allocator);
            defer registry.deinit();
            _ = try registry.loadVanilla();

            const sharpness = registry.resolve("sharpness").?;
            const smite = registry.resolve("smite").?;

            const item_type = try enchant_testing.itemType(allocator, "minecraft:test_message_sword", &.{"minecraft:is_sword"}, false);
            defer item_type.deinit();
            var item = ItemStack.init(allocator, item_type, .{});
            defer item.deinit();

            var buffer: [320]u8 = undefined;

            try testing.expectEqualStrings("Enchanting succeeded for Steve", successMessage(&buffer, "Steve"));
            try testing.expectEqualStrings("The target doesn't hold an item: Steve", noItemMessage(&buffer, "Steve"));
            try testing.expectEqualStrings("The selected enchantment can't be added to the target item: minecraft:test_message_sword", cantEnchantMessage(&buffer, &item));
            try testing.expectEqualStrings("Smite can't be combined with Sharpness", cantCombineMessage(&buffer, smite, sharpness));
            try testing.expectEqualStrings("Sharpness does not support level 10", invalidLevelMessage(&buffer, sharpness, 10));
            try testing.expectEqualStrings("There is no such enchantment with ID 999", notFoundMessage(&buffer, 999));
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            var registry = EnchantmentRegistry.Registry.init(allocator);
            defer registry.deinit();
            _ = try registry.loadVanilla();

            const sharpness = registry.resolve("sharpness").?;

            try std.testing.expectEqual(@as(?i64, 1), parseLevel(null));
            try std.testing.expectEqual(@as(?i64, 3), parseLevel("3"));
            try std.testing.expect(parseLevel("three") == null);
            try std.testing.expect(parseLevel("") == null);
            try std.testing.expect(parseLevel("1.5") == null);

            try std.testing.expect(levelInRange(sharpness, 1));
            try std.testing.expect(levelInRange(sharpness, 5));
            try std.testing.expect(!levelInRange(sharpness, 6));
            try std.testing.expect(levelInRange(sharpness, 0));
            try std.testing.expect(!levelInRange(sharpness, -1));
            try std.testing.expect(!levelInRange(sharpness, 2147483647));
        }

        pub fn case_003() !void {
            try std.testing.expectEqualStrings("Adds an enchantment to a player's selected item.", DESCRIPTION);
            try std.testing.expectEqualStrings("/enchant <player: target> <enchantment: Enchant> [level: int]", USAGE);
            try std.testing.expectEqualStrings("Enchanting succeeded for {s}", MESSAGE_SUCCESS);
            try std.testing.expectEqualStrings("The target doesn't hold an item: {s}", MESSAGE_NO_ITEM);
            try std.testing.expectEqualStrings("The selected enchantment can't be added to the target item: {s}", MESSAGE_CANT_ENCHANT);
            try std.testing.expectEqualStrings("{s} can't be combined with {s}", MESSAGE_CANT_COMBINE);
            try std.testing.expectEqualStrings("{s} does not support level {d}", MESSAGE_INVALID_LEVEL);
            try std.testing.expectEqualStrings("There is no such enchantment with ID {d}", MESSAGE_NOT_FOUND);
        }
    };
}
