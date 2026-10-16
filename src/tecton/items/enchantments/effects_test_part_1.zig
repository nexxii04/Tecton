pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Protocol = scope.Protocol;
        const ItemStack = scope.ItemStack;
        const Container = scope.Container;
        const compat = scope.compat;
        const Family = scope.Family;
        const FIST_DAMAGE = scope.FIST_DAMAGE;
        const TRIDENT_DAMAGE = scope.TRIDENT_DAMAGE;
        const BASE_KNOCKBACK = scope.BASE_KNOCKBACK;
        const PROTECTION_MAX_LEVELS = scope.PROTECTION_MAX_LEVELS;
        const FIRE_PROTECTION_MAX_LEVELS = scope.FIRE_PROTECTION_MAX_LEVELS;
        const THORNS_MIN_DAMAGE = scope.THORNS_MIN_DAMAGE;
        const THORNS_MAX_DAMAGE = scope.THORNS_MAX_DAMAGE;
        const FAMILY_MAP = scope.FAMILY_MAP;
        const familyOf = scope.familyOf;
        const baseAttackDamage = scope.baseAttackDamage;
        const attackDamage = scope.attackDamage;
        const knockbackImpulse = scope.knockbackImpulse;
        const meleeImpact = scope.meleeImpact;
        const blocksArmorRemoval = scope.blocksArmorRemoval;
        const mitigatedDamage = scope.mitigatedDamage;
        const mitigatedFireDamage = scope.mitigatedFireDamage;
        const fireBurnDuration = scope.fireBurnDuration;
        const fireAspectDurationTicks = scope.fireAspectDurationTicks;
        const thornsReflection = scope.thornsReflection;
        const testing = scope.testing;
        const test_helpers = scope.test_helpers;
        const FixedEntropy = scope.FixedEntropy;
        const thornsArmor = scope.thornsArmor;

        pub fn case_000() !void {
            const allocator = testing.allocator;

            const swords = [_]struct { tag: []const u8, damage: f32 }{
                .{ .tag = "minecraft:wooden_tier", .damage = 4 },
                .{ .tag = "minecraft:copper_tier", .damage = 4 },
                .{ .tag = "minecraft:golden_tier", .damage = 4 },
                .{ .tag = "minecraft:stone_tier", .damage = 5 },
                .{ .tag = "minecraft:iron_tier", .damage = 6 },
                .{ .tag = "minecraft:diamond_tier", .damage = 7 },
                .{ .tag = "minecraft:netherite_tier", .damage = 8 },
            };

            for (swords) |entry| {
                const kind = try test_helpers.itemType(allocator, "minecraft:test_effects_sword", &.{ "minecraft:is_sword", entry.tag }, false);
                defer kind.deinit();
                try testing.expectEqual(entry.damage, baseAttackDamage(kind));
            }

            const axes = [_]struct { tag: []const u8, damage: f32 }{
                .{ .tag = "minecraft:wooden_tier", .damage = 3 },
                .{ .tag = "minecraft:stone_tier", .damage = 4 },
                .{ .tag = "minecraft:iron_tier", .damage = 5 },
                .{ .tag = "minecraft:diamond_tier", .damage = 6 },
                .{ .tag = "minecraft:netherite_tier", .damage = 7 },
            };

            for (axes) |entry| {
                const kind = try test_helpers.itemType(allocator, "minecraft:test_effects_axe", &.{ "minecraft:is_axe", entry.tag }, false);
                defer kind.deinit();
                try testing.expectEqual(entry.damage, baseAttackDamage(kind));
            }

            const trident = try test_helpers.itemType(allocator, "minecraft:test_effects_trident", &.{"minecraft:is_trident"}, false);
            defer trident.deinit();
            try testing.expectEqual(TRIDENT_DAMAGE, baseAttackDamage(trident));

            const stick = try test_helpers.itemType(allocator, "minecraft:test_effects_stick", &.{}, false);
            defer stick.deinit();
            try testing.expectEqual(FIST_DAMAGE, baseAttackDamage(stick));

            const untiered_sword = try test_helpers.itemType(allocator, "minecraft:test_effects_toy_sword", &.{"minecraft:is_sword"}, false);
            defer untiered_sword.deinit();
            try testing.expectEqual(FIST_DAMAGE, baseAttackDamage(untiered_sword));
        }

        pub fn case_001() !void {
            try testing.expectEqual(Family.undead, familyOf("minecraft:zombie"));
            try testing.expectEqual(Family.undead, familyOf("minecraft:wither_skeleton"));
            try testing.expectEqual(Family.undead, familyOf("minecraft:phantom"));
            try testing.expectEqual(Family.undead, familyOf("minecraft:drowned"));
            try testing.expectEqual(Family.undead, familyOf("minecraft:parched"));
            try testing.expectEqual(Family.undead, familyOf("minecraft:camel_husk"));
            try testing.expectEqual(Family.arthropod, familyOf("minecraft:spider"));
            try testing.expectEqual(Family.arthropod, familyOf("minecraft:cave_spider"));
            try testing.expectEqual(Family.arthropod, familyOf("minecraft:bee"));
            try testing.expectEqual(Family.none, familyOf("minecraft:cow"));
            try testing.expectEqual(Family.none, familyOf("minecraft:guardian"));
            try testing.expectEqual(Family.none, familyOf("minecraft:player"));
            try testing.expectEqual(Family.none, familyOf("minecraft:not_a_real_mob"));
            try testing.expectEqual(Family.none, familyOf("minecraft:Zombie"));
        }

        pub fn case_002() !void {
            const allocator = testing.allocator;

            const bare = try test_helpers.itemType(allocator, "minecraft:test_effects_plain_sword", &.{ "minecraft:is_sword", "minecraft:diamond_tier" }, false);
            defer bare.deinit();

            var weapon = ItemStack.init(allocator, bare, .{});
            defer weapon.deinit();

            try testing.expectEqual(@as(f32, 7), attackDamage(&weapon, "minecraft:zombie"));

            _ = weapon.enchantments.set(compat.SHARPNESS, 5);
            try testing.expectEqual(@as(f32, 13.25), attackDamage(&weapon, "minecraft:zombie"));
            try testing.expectEqual(@as(f32, 13.25), attackDamage(&weapon, "minecraft:cow"));
            try testing.expectEqual(@as(f32, 1), attackDamage(null, "minecraft:cow"));
        }

        pub fn case_003() !void {
            const allocator = testing.allocator;

            const wooden = try test_helpers.itemType(allocator, "minecraft:test_effects_wooden_sword", &.{ "minecraft:is_sword", "minecraft:wooden_tier" }, false);
            defer wooden.deinit();
            const netherite = try test_helpers.itemType(allocator, "minecraft:test_effects_netherite_sword", &.{ "minecraft:is_sword", "minecraft:netherite_tier" }, false);
            defer netherite.deinit();

            var wood_weapon = ItemStack.init(allocator, wooden, .{});
            defer wood_weapon.deinit();
            _ = wood_weapon.enchantments.set(compat.SHARPNESS, 5);
            try testing.expectEqual(@as(f32, 10.25), attackDamage(&wood_weapon, "minecraft:cow"));

            var netherite_weapon = ItemStack.init(allocator, netherite, .{});
            defer netherite_weapon.deinit();
            _ = netherite_weapon.enchantments.set(compat.SHARPNESS, 5);
            try testing.expectEqual(@as(f32, 14.25), attackDamage(&netherite_weapon, "minecraft:cow"));
        }

        pub fn case_004() !void {
            const allocator = testing.allocator;

            const bare = try test_helpers.itemType(allocator, "minecraft:test_effects_enchanted_sword", &.{ "minecraft:is_sword", "minecraft:iron_tier" }, false);
            defer bare.deinit();

            var smite = ItemStack.init(allocator, bare, .{});
            defer smite.deinit();
            _ = smite.enchantments.set(compat.SMITE, 5);
            try testing.expectEqual(@as(f32, 18.5), attackDamage(&smite, "minecraft:zombie"));
            try testing.expectEqual(@as(f32, 6), attackDamage(&smite, "minecraft:spider"));

            var bane = ItemStack.init(allocator, bare, .{});
            defer bane.deinit();
            _ = bane.enchantments.set(compat.BANE_OF_ARTHROPODS, 5);
            try testing.expectEqual(@as(f32, 18.5), attackDamage(&bane, "minecraft:spider"));
            try testing.expectEqual(@as(f32, 6), attackDamage(&bane, "minecraft:zombie"));
        }

        pub fn case_005() !void {
            const allocator = testing.allocator;

            try testing.expectEqual(BASE_KNOCKBACK, knockbackImpulse(null));

            const bare = try test_helpers.itemType(allocator, "minecraft:test_effects_kb_sword", &.{ "minecraft:is_sword", "minecraft:wooden_tier" }, false);
            defer bare.deinit();

            var weapon = ItemStack.init(allocator, bare, .{});
            defer weapon.deinit();
            try testing.expectEqual(BASE_KNOCKBACK, knockbackImpulse(&weapon));

            _ = weapon.enchantments.set(compat.KNOCKBACK, 2);
            try testing.expectApproxEqAbs(@as(f32, 0.6), knockbackImpulse(&weapon), 0.000001);

            const impact = meleeImpact(null, "minecraft:cow");
            try testing.expectEqual(FIST_DAMAGE, impact.damage);
            try testing.expectEqual(BASE_KNOCKBACK, impact.knockback);
        }

        pub fn case_006() !void {
            const allocator = testing.allocator;

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, Protocol.Data.entity_types_json, .{});
            defer parsed.deinit();

            const known = switch (parsed.value) {
                .array => |arr| arr.items,
                else => return error.InvalidJsonFormat,
            };

            for (FAMILY_MAP.keys()) |identifier| {
                var found = false;
                for (known) |entry| {
                    if (entry != .object) continue;
                    const declared = entry.object.get("identifier") orelse continue;
                    if (declared != .string) continue;
                    if (std.mem.eql(u8, declared.string, identifier)) {
                        found = true;
                        break;
                    }
                }
                if (!found) std.debug.print("unknown entity in the family table: {s}\n", .{identifier});
                try testing.expect(found);
            }
        }

        pub fn case_007() !void {
            var armor: compat.ArmorAggregate = .empty;

            try testing.expectEqual(@as(f32, 20.0), mitigatedDamage(&armor, 20.0));

            armor.protection = 4;
            try testing.expectApproxEqAbs(@as(f32, 16.8), mitigatedDamage(&armor, 20.0), 0.0001);

            armor.protection = 16;
            try testing.expectApproxEqAbs(@as(f32, 7.2), mitigatedDamage(&armor, 20.0), 0.0001);

            armor.protection = PROTECTION_MAX_LEVELS;
            try testing.expectApproxEqAbs(@as(f32, 4.0), mitigatedDamage(&armor, 20.0), 0.0001);

            armor.protection = 40;
            try testing.expectApproxEqAbs(@as(f32, 4.0), mitigatedDamage(&armor, 20.0), 0.0001);
        }

        pub fn case_008() !void {
            var armor: compat.ArmorAggregate = .empty;
            armor.fire_protection = 4;
            armor.blast_protection = 4;
            armor.projectile_protection = 4;
            armor.feather_falling = 4;

            try testing.expectEqual(@as(f32, 20.0), mitigatedDamage(&armor, 20.0));

            armor.protection = 2;
            try testing.expectApproxEqAbs(@as(f32, 18.4), mitigatedDamage(&armor, 20.0), 0.0001);
        }

        pub fn case_009() !void {
            const allocator = testing.allocator;

            const kind = try test_helpers.itemType(allocator, "minecraft:test_effects_plain_boots", &.{"minecraft:is_armor"}, false);
            defer kind.deinit();

            var armor = try Container.init(allocator, .Inventory, compat.ARMOR_SLOTS);
            defer armor.deinit();
            armor.setItem(0, ItemStack.init(allocator, kind, .{}));

            var always: FixedEntropy = .{ .byte = 0 };
            try testing.expectEqual(@as(f32, 0.0), thornsReflection(&armor, scope.entropy_interface(&always)));
        }

        pub fn case_010() !void {
            const allocator = testing.allocator;

            const kind = try test_helpers.itemType(allocator, "minecraft:test_effects_thorns_piece", &.{"minecraft:is_armor"}, false);
            defer kind.deinit();

            var entropy: FixedEntropy = .{ .byte = 0xff };

            var four: Container = try thornsArmor(allocator, kind, .{ 3, 3, 3, 3 });
            defer four.deinit();
            try testing.expectEqual(@as(f32, 0.0), thornsReflection(&four, scope.entropy_interface(&entropy)));

            var one: Container = try thornsArmor(allocator, kind, .{ 0, 0, 7, 0 });
            defer one.deinit();
            try testing.expectApproxEqAbs(THORNS_MAX_DAMAGE, thornsReflection(&one, scope.entropy_interface(&entropy)), 0.0001);
        }
    };
}
