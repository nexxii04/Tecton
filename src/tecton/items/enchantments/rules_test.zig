pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const ItemStack = scope.ItemStack;
        const registry_mod = scope.registry_mod;
        const Verdict = scope.Verdict;
        const Context = scope.Context;
        const registerRule = scope.registerRule;
        const unregisterOwner = scope.unregisterOwner;
        const registeredRules = scope.registeredRules;
        const slotSetOf = scope.slotSetOf;
        const EnchantmentInstance = scope.EnchantmentInstance;
        const conflictsWith = scope.conflictsWith;
        const exclusivePair = scope.exclusivePair;
        const validate = scope.validate;
        const testing = scope.testing;
        const testType = scope.testType;

        pub fn case_000() !void {
            const allocator = std.testing.allocator;

            const sword = try testType(allocator, "minecraft:diamond_sword", &.{ "minecraft:is_sword", "minecraft:is_tool" }, false);
            defer sword.deinit();
            try std.testing.expect(slotSetOf(sword).contains(.sword));
            try std.testing.expect(!slotSetOf(sword).contains(.tool_any));
            try std.testing.expect(slotSetOf(sword).contains(.durable_any));

            const pickaxe = try testType(allocator, "minecraft:diamond_pickaxe", &.{ "minecraft:is_pickaxe", "minecraft:is_tool" }, false);
            defer pickaxe.deinit();
            try std.testing.expect(slotSetOf(pickaxe).contains(.pickaxe));
            try std.testing.expect(slotSetOf(pickaxe).contains(.tool_any));

            const helmet = try testType(allocator, "minecraft:diamond_helmet", &.{"minecraft:is_armor"}, false);
            defer helmet.deinit();
            try std.testing.expect(slotSetOf(helmet).contains(.helmet));
            try std.testing.expect(!slotSetOf(helmet).contains(.leggings));

            const bow = try testType(allocator, "minecraft:bow", &.{}, false);
            defer bow.deinit();
            try std.testing.expect(slotSetOf(bow).contains(.bow));
            try std.testing.expect(slotSetOf(bow).contains(.durable_any));

            const elytra = try testType(allocator, "minecraft:elytra", &.{"minecraft:is_armor"}, false);
            defer elytra.deinit();
            try std.testing.expect(slotSetOf(elytra).contains(.elytra));
            try std.testing.expect(!slotSetOf(elytra).contains(.chestplate));

            const stone = try testType(allocator, "minecraft:stone", &.{}, true);
            defer stone.deinit();
            try std.testing.expectEqual(@as(usize, 0), slotSetOf(stone).count());

            const shears = try testType(allocator, "minecraft:shears", &.{}, false);
            defer shears.deinit();
            try std.testing.expect(slotSetOf(shears).contains(.durable_any));

            const book = try testType(allocator, "minecraft:enchanted_book", &.{}, true);
            defer book.deinit();
            try std.testing.expect(slotSetOf(book).contains(.book));
            try std.testing.expect(!slotSetOf(book).contains(.durable_any));
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            var registry = registry_mod.Registry.init(allocator);
            defer registry.deinit();
            _ = try registry.loadVanilla();

            const sword = try testType(allocator, "minecraft:diamond_sword", &.{ "minecraft:is_sword", "minecraft:is_tool" }, false);
            defer sword.deinit();
            const pickaxe = try testType(allocator, "minecraft:diamond_pickaxe", &.{ "minecraft:is_pickaxe", "minecraft:is_tool" }, false);
            defer pickaxe.deinit();
            const stone = try testType(allocator, "minecraft:stone", &.{}, true);
            defer stone.deinit();

            var stack = ItemStack.init(allocator, sword, .{});
            defer stack.deinit();

            const sharpness = registry.resolve("sharpness").?;
            const smite = registry.resolve("smite").?;
            const fortune = registry.resolve("fortune").?;
            const silk = registry.resolve("silk_touch").?;
            const efficiency = registry.resolve("efficiency").?;

            try std.testing.expectEqual(@as(u8, 5), try validate(&registry, &stack, sharpness, 5, .{}));
            try std.testing.expect(validate(&registry, &stack, sharpness, 9, .{ .clamp_level = false }) == error.invalid_level);
            try std.testing.expectEqual(@as(u8, 5), try validate(&registry, &stack, sharpness, 9, .{}));
            try std.testing.expect(validate(&registry, &stack, sharpness, 0, .{}) == error.invalid_level);
            try std.testing.expect(validate(&registry, &stack, efficiency, 1, .{}) == error.not_applicable);

            var stone_stack = ItemStack.init(allocator, stone, .{});
            defer stone_stack.deinit();
            try std.testing.expect(validate(&registry, &stone_stack, sharpness, 1, .{}) == error.not_enchantable);

            var tool_stack = ItemStack.init(allocator, pickaxe, .{});
            defer tool_stack.deinit();
            _ = tool_stack.enchantments.set(fortune.id, 3);
            try std.testing.expect(validate(&registry, &tool_stack, silk, 1, .{}) == error.conflicts);
            try std.testing.expectEqual(@as(u8, 1), try validate(&registry, &tool_stack, silk, 1, .{ .allow_conflicts = true }));

            _ = stack.enchantments.set(sharpness.id, 5);
            try std.testing.expect(validate(&registry, &stack, smite, 1, .{}) == error.conflicts);
            try std.testing.expectEqual(@as(usize, 1), stack.enchantments.count());
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            var registry = registry_mod.Registry.init(allocator);
            defer registry.deinit();
            _ = try registry.loadVanilla();

            const sword = try testType(allocator, "minecraft:diamond_sword", &.{ "minecraft:is_sword", "minecraft:is_tool" }, false);
            defer sword.deinit();
            var stack = ItemStack.init(allocator, sword, .{});
            defer stack.deinit();
            const sharpness = registry.resolve("sharpness").?;

            const callbacks = struct {
                fn deny(_: *Context) Verdict {
                    return .deny;
                }
                fn cap(_: *Context) Verdict {
                    return .{ .modify = 1 };
                }
            };

            try registerRule(.{ .id = "test-deny", .priority = 10, .callback = callbacks.deny, .owner_id = 7 });
            try std.testing.expect(validate(&registry, &stack, sharpness, 5, .{}) == error.rule_vetoed);

            unregisterOwner(7);
            try std.testing.expectEqual(@as(u8, 5), try validate(&registry, &stack, sharpness, 5, .{}));

            try registerRule(.{ .id = "test-cap", .priority = 10, .callback = callbacks.cap, .owner_id = 8 });
            try std.testing.expectEqual(@as(u8, 1), try validate(&registry, &stack, sharpness, 5, .{}));
            unregisterOwner(8);
            try std.testing.expectEqual(@as(usize, 0), registeredRules());
        }

        pub fn case_003() !void {
            const allocator = std.testing.allocator;
            var registry = registry_mod.Registry.init(allocator);
            defer registry.deinit();
            _ = try registry.loadVanilla();

            const sword = try testType(allocator, "minecraft:diamond_sword", &.{ "minecraft:is_sword", "minecraft:is_tool" }, false);
            defer sword.deinit();
            var stack = ItemStack.init(allocator, sword, .{});
            defer stack.deinit();

            const callbacks = struct {
                fn zero(_: *Context) Verdict {
                    return .{ .modify = 0 };
                }
            };
            try registerRule(.{ .id = "test-zero", .priority = 10, .callback = callbacks.zero, .owner_id = 9 });
            defer unregisterOwner(9);

            try std.testing.expect(validate(&registry, &stack, registry.resolve("sharpness").?, 5, .{}) == error.invalid_level);
        }

        pub fn case_004() !void {
            const allocator = std.testing.allocator;
            var registry = registry_mod.Registry.init(allocator);
            defer registry.deinit();
            _ = try registry.loadVanilla();

            const pairs = .{
                .{ "silk_touch", "fortune" },
                .{ "depth_strider", "frost_walker" },
                .{ "multishot", "piercing" },
                .{ "riptide", "loyalty" },
                .{ "riptide", "channeling" },
                .{ "infinity", "mending" },
            };
            inline for (pairs) |pair| {
                const first = registry.resolve(pair[0]).?;
                const second = registry.resolve(pair[1]).?;
                try std.testing.expectEqual(@as(u8, 0), first.group);
                try std.testing.expectEqual(@as(u8, 0), second.group);
                try std.testing.expect(exclusivePair(first.id, second.id));
                try std.testing.expect(exclusivePair(second.id, first.id));
                try std.testing.expect(!exclusivePair(first.id, first.id));
                const current = [_]EnchantmentInstance{.{ .id = first.id, .level = 1 }};
                try std.testing.expect(conflictsWith(&registry, &current, second));
            }
        }
    };
}
