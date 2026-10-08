pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Enchantment = scope.Enchantment;
        const SlotSet = scope.SlotSet;
        const MAX_ENCHANTMENT_ID = scope.MAX_ENCHANTMENT_ID;
        const MAX_LEVEL = scope.MAX_LEVEL;
        const set_width = scope.set_width;
        const Registry = scope.Registry;
        const load = scope.load;
        const ensureGlobal = scope.ensureGlobal;
        const global = scope.global;
        const isLoaded = scope.isLoaded;

        pub fn case_000() !void {
            const allocator = std.testing.allocator;
            var registry = Registry.init(allocator);
            defer registry.deinit();
            _ = try registry.loadVanilla();
            const before = registry.count();

            const slots = SlotSet.initOne(.sword);
            var duplicate_id = Enchantment{
                .id = 9,
                .identifier = "test_duplicate_id",
                .name = "Test",
                .max_level = 1,
                .category = .other,
                .slots = slots,
                .group = 0,
                .treasure = false,
                .curse = false,
                .anvil_cost = 1,
            };
            try std.testing.expectError(error.DuplicateEnchantmentId, registry.register(duplicate_id));
            try std.testing.expectEqual(before, registry.count());

            duplicate_id.id = 200;
            duplicate_id.identifier = "sharpness";
            try std.testing.expectError(error.DuplicateEnchantmentIdentifier, registry.register(duplicate_id));
            try std.testing.expectEqual(before, registry.count());
            try std.testing.expect(registry.get(200) == null);

            duplicate_id.identifier = "test_duplicate_id";
            const registered = try registry.register(duplicate_id);
            try std.testing.expectEqual(before + 1, registry.count());
            try std.testing.expectEqual(registered, registry.get(200).?);
        }

        pub fn case_001() !void {
            const first = try load();
            try std.testing.expectEqual(first, try load());
            try std.testing.expectEqual(first, global().?.count());
            try std.testing.expect(isLoaded());

            const registry = ensureGlobal() orelse return error.ExpectedRegistry;
            try std.testing.expectEqual(registry, global().?);
            try std.testing.expect(registry.count() > 40);
            try std.testing.expectEqual(@as(u16, 9), registry.resolve("sharpness").?.id);
        }

        pub fn case_002() !void {
            const Pointer = std.meta.Child(@typeInfo(@TypeOf(global)).@"fn".return_type.?);
            try std.testing.expect(@typeInfo(Pointer).pointer.is_const);

            const loaded = try load();
            const view = global() orelse return error.ExpectedRegistry;
            try std.testing.expectEqual(view, ensureGlobal().?);
            try std.testing.expectEqual(loaded, view.count());
            try std.testing.expectEqual(@as(u16, 9), view.resolve("sharpness").?.id);
        }

        pub fn case_003() !void {
            const allocator = std.testing.allocator;
            var registry = Registry.init(allocator);
            defer registry.deinit();

            const source =
                \\{"enchantments":[
                \\{"identifier":"test_half_a","id":200,"max_level":1,"slots":["sword"]},
                \\{"identifier":"test_half_b","id":201,"max_level":0,"slots":["sword"]}
                \\]}
            ;
            try std.testing.expectError(error.InvalidEnchantmentMaxLevel, registry.loadJson(source));

            for (registry.list()) |definition| {
                try std.testing.expectEqual(definition, registry.get(definition.id).?);
                try std.testing.expectEqual(definition, registry.byName(definition.identifier).?);
            }
        }

        pub fn case_004() !void {
            try std.testing.expectEqual(@as(u16, 256), set_width);
            try std.testing.expect(MAX_ENCHANTMENT_ID + 1 == set_width);
            try std.testing.expect(MAX_ENCHANTMENT_ID <= std.math.maxInt(i16));
            try std.testing.expect(MAX_LEVEL <= std.math.maxInt(i16));
        }

        pub fn case_005() !void {
            const allocator = std.testing.allocator;
            var registry = Registry.init(allocator);
            defer registry.deinit();

            const loaded = try registry.loadVanilla();
            try std.testing.expect(loaded > 40);
            try std.testing.expectEqual(loaded, registry.count());
            for (registry.list()) |definition| {
                try std.testing.expect(definition.max_level > 0);
                try std.testing.expect(definition.slots.count() > 0);
                try std.testing.expectEqual(definition, registry.get(definition.id).?);
            }
        }

        pub fn case_006() !void {
            const allocator = std.testing.allocator;
            var registry = Registry.init(allocator);
            defer registry.deinit();
            _ = try registry.loadVanilla();

            try std.testing.expectEqual(@as(u16, 9), registry.resolve("sharpness").?.id);
            try std.testing.expectEqual(@as(u16, 9), registry.resolve("minecraft:sharpness").?.id);
            try std.testing.expectEqual(@as(u16, 9), registry.resolve("SHARPNESS").?.id);
            try std.testing.expectEqual(@as(u16, 27), registry.resolve("curse_of_binding").?.id);
            try std.testing.expectEqual(@as(u16, 28), registry.resolve("curse_of_vanishing").?.id);
            try std.testing.expect(registry.resolve("nope") == null);
            try std.testing.expect(registry.resolve("") == null);
        }

        pub fn case_007() !void {
            const allocator = std.testing.allocator;
            var registry = Registry.init(allocator);
            defer registry.deinit();
            _ = try registry.loadVanilla();

            try std.testing.expectEqual(@as(u8, 1), registry.resolve("protection").?.group);
            try std.testing.expectEqual(@as(u8, 1), registry.resolve("projectile_protection").?.group);
            try std.testing.expectEqual(@as(u8, 2), registry.resolve("sharpness").?.group);
            try std.testing.expectEqual(@as(u8, 2), registry.resolve("bane_of_arthropods").?.group);
            try std.testing.expectEqual(@as(u8, 0), registry.resolve("unbreaking").?.group);
            try std.testing.expect(registry.resolve("mending").?.treasure);
            try std.testing.expect(registry.resolve("binding").?.curse);
        }

        pub fn case_008() !void {
            const allocator = std.testing.allocator;
            var registry = Registry.init(allocator);
            defer registry.deinit();

            const source =
                \\{"enchantments":[
                \\{"identifier":"test_a","id":200,"max_level":1,"slots":["sword"]},
                \\{"identifier":"test_b","id":200,"max_level":1,"slots":["sword"]}
                \\]}
            ;
            try std.testing.expectError(error.DuplicateEnchantmentId, registry.loadJson(source));

            const duplicate_name =
                \\{"enchantments":[
                \\{"identifier":"test_a","id":201,"max_level":1,"slots":["sword"]},
                \\{"identifier":"test_a","id":202,"max_level":1,"slots":["sword"]}
                \\]}
            ;
            try std.testing.expectError(error.DuplicateEnchantmentIdentifier, registry.loadJson(duplicate_name));
        }

        pub fn case_009() !void {
            const allocator = std.testing.allocator;
            var registry = Registry.init(allocator);
            defer registry.deinit();

            try std.testing.expectError(error.InvalidEnchantmentMaxLevel, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":1,\"max_level\":0,\"slots\":[\"sword\"]}]}"));
            try std.testing.expectError(error.InvalidEnchantmentData, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":1,\"max_level\":1,\"slots\":[]}]}"));
            try std.testing.expectError(error.InvalidEnchantmentData, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":1,\"max_level\":1,\"slots\":[\"nope\"]}]}"));
            try std.testing.expectError(error.InvalidEnchantmentCategory, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":1,\"max_level\":1,\"slots\":[\"sword\"],\"category\":\"nope\"}]}"));
            try std.testing.expectError(error.EnchantmentIdOutOfRange, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":99999,\"max_level\":1,\"slots\":[\"sword\"]}]}"));
            try std.testing.expectError(error.EnchantmentIdOutOfRange, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":256,\"max_level\":1,\"slots\":[\"sword\"]}]}"));
        }
    };
}
