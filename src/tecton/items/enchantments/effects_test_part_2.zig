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
        const vanishesOnDeath = scope.vanishesOnDeath;
        const mitigatedDamage = scope.mitigatedDamage;
        const mitigatedFireDamage = scope.mitigatedFireDamage;
        const Events = scope.Events;
        const mitigate = scope.mitigate;
        const fireBurnDuration = scope.fireBurnDuration;
        const fireAspectDurationTicks = scope.fireAspectDurationTicks;
        const thornsReflection = scope.thornsReflection;
        const consumeDurability = scope.consumeDurability;
        const wearTool = scope.wearTool;
        const testing = scope.testing;
        const test_helpers = scope.test_helpers;
        const FixedEntropy = scope.FixedEntropy;
        const entropy_interface = scope.entropy_interface;
        const thornsArmor = scope.thornsArmor;

        pub fn case_011() !void {
            const allocator = testing.allocator;

            const kind = try test_helpers.itemType(allocator, "minecraft:test_effects_thorns_helm", &.{"minecraft:is_armor"}, false);
            defer kind.deinit();

            var armor: Container = try thornsArmor(allocator, kind, .{ 0, 0, 3, 0 });
            defer armor.deinit();

            var rng = std.Random.DefaultPrng.init(0x5eed7a11);
            const random = rng.random();

            const trials: u32 = 20_000;
            var hits: u32 = 0;
            var total: f64 = 0;
            var index: u32 = 0;
            while (index < trials) : (index += 1) {
                const damage = thornsReflection(&armor, random);
                if (damage > 0) {
                    try testing.expect(damage >= THORNS_MIN_DAMAGE and damage <= THORNS_MAX_DAMAGE);
                    hits += 1;
                    total += damage;
                }
            }

            const rate = @as(f64, @floatFromInt(hits)) / @as(f64, trials);
            try testing.expect(rate > 0.44 and rate < 0.46);

            const average = total / @as(f64, @floatFromInt(hits));
            try testing.expect(average > 2.85 and average < 3.15);
        }

        pub fn case_012() !void {
            const allocator = testing.allocator;

            const boots = try test_helpers.itemType(allocator, "minecraft:test_effects_cursed_boots", &.{"minecraft:is_armor"}, false);
            defer boots.deinit();

            var plain = ItemStack.init(allocator, boots, .{});
            defer plain.deinit();
            try testing.expect(!blocksArmorRemoval(&plain));

            _ = plain.enchantments.set(compat.CURSE_OF_VANISHING, 1);
            try testing.expect(!blocksArmorRemoval(&plain));

            _ = plain.enchantments.set(compat.CURSE_OF_BINDING, 1);
            try testing.expect(blocksArmorRemoval(&plain));
        }

        pub fn case_013() !void {
            try testing.expectEqual(@as(i32, 150), fireBurnDuration(150, 0));
            try testing.expectEqual(@as(i32, 128), fireBurnDuration(150, 1));
            try testing.expectEqual(@as(i32, 105), fireBurnDuration(150, 2));
            try testing.expectEqual(@as(i32, 60), fireBurnDuration(150, FIRE_PROTECTION_MAX_LEVELS));
            try testing.expectEqual(@as(i32, 60), fireBurnDuration(150, 200));
            try testing.expectEqual(@as(i32, 0), fireBurnDuration(0, 2));
            try testing.expectEqual(@as(i32, 0), fireBurnDuration(-40, 2));
        }

        pub fn case_014() !void {
            var armor: compat.ArmorAggregate = .empty;

            try testing.expectEqual(@as(f32, 1.0), mitigatedFireDamage(&armor, 1.0));

            armor.fire_protection = 2;
            try testing.expectApproxEqAbs(@as(f32, 0.84), mitigatedFireDamage(&armor, 1.0), 0.0001);

            armor.fire_protection = FIRE_PROTECTION_MAX_LEVELS;
            try testing.expectApproxEqAbs(@as(f32, 0.68), mitigatedFireDamage(&armor, 1.0), 0.0001);

            armor.fire_protection = 200;
            try testing.expectApproxEqAbs(@as(f32, 0.68), mitigatedFireDamage(&armor, 1.0), 0.0001);

            armor.protection = 4;
            try testing.expectApproxEqAbs(@as(f32, 0.68), mitigatedFireDamage(&armor, 1.0), 0.0001);
        }

        pub fn case_015() !void {
            const allocator = testing.allocator;

            try testing.expectEqual(@as(i32, 0), fireAspectDurationTicks(null));

            const kind = try test_helpers.itemType(allocator, "minecraft:test_effects_fire_sword", &.{ "minecraft:is_sword", "minecraft:wooden_tier" }, false);
            defer kind.deinit();

            var plain = ItemStack.init(allocator, kind, .{});
            defer plain.deinit();
            try testing.expectEqual(@as(i32, 0), fireAspectDurationTicks(&plain));

            var one = ItemStack.init(allocator, kind, .{});
            defer one.deinit();
            _ = one.enchantments.set(compat.FIRE_ASPECT, 1);
            try testing.expectEqual(@as(i32, 80), fireAspectDurationTicks(&one));

            var two = ItemStack.init(allocator, kind, .{});
            defer two.deinit();
            _ = two.enchantments.set(compat.FIRE_ASPECT, 2);
            try testing.expectEqual(@as(i32, 160), fireAspectDurationTicks(&two));
        }

        pub fn case_016() !void {
            var armor: compat.ArmorAggregate = .empty;
            armor.protection = 8;
            armor.fire_protection = 3;
            armor.blast_protection = 4;

            try testing.expectEqual(mitigatedDamage(&armor, 20.0), mitigate(&armor, .entity_attack, 20.0));
            try testing.expectEqual(mitigatedFireDamage(&armor, 20.0), mitigate(&armor, .fire, 20.0));
            try testing.expectEqual(mitigatedFireDamage(&armor, 20.0), mitigate(&armor, .fire_tick, 20.0));
            try testing.expectEqual(mitigatedFireDamage(&armor, 20.0), mitigate(&armor, .lava, 20.0));
        }

        pub fn case_017() !void {
            var armor: compat.ArmorAggregate = .empty;

            armor.blast_protection = 4;
            try testing.expectApproxEqAbs(@as(f32, 0.68), mitigate(&armor, .explosion, 1.0), 0.0001);

            armor.blast_protection = 0;
            armor.projectile_protection = 2;
            try testing.expectApproxEqAbs(@as(f32, 0.84), mitigate(&armor, .projectile, 1.0), 0.0001);

            armor.projectile_protection = 0;
            armor.feather_falling = 1;
            try testing.expectApproxEqAbs(@as(f32, 0.88), mitigate(&armor, .fall, 1.0), 0.0001);

            armor.feather_falling = 2;
            try testing.expectApproxEqAbs(@as(f32, 0.76), mitigate(&armor, .fall, 1.0), 0.0001);

            armor.feather_falling = 3;
            try testing.expectApproxEqAbs(@as(f32, 0.64), mitigate(&armor, .fall, 1.0), 0.0001);

            armor.feather_falling = 4;
            try testing.expectApproxEqAbs(@as(f32, 0.52), mitigate(&armor, .fall, 1.0), 0.0001);

            armor.feather_falling = 200;
            try testing.expectApproxEqAbs(@as(f32, 0.2), mitigate(&armor, .fall, 1.0), 0.0001);

            armor.feather_falling = 0;
            try testing.expectEqual(@as(f32, 1.0), mitigate(&armor, .fall, 1.0));
        }

        pub fn case_018() !void {
            var armor: compat.ArmorAggregate = .empty;
            armor.protection = 20;
            armor.fire_protection = 4;
            armor.blast_protection = 4;
            armor.projectile_protection = 4;
            armor.feather_falling = 4;

            try testing.expectEqual(@as(f32, 7.0), mitigate(&armor, .thorns, 7.0));
            try testing.expectEqual(@as(f32, 7.0), mitigate(&armor, .magic, 7.0));
            try testing.expectEqual(@as(f32, 7.0), mitigate(&armor, .drowning, 7.0));
            try testing.expectEqual(@as(f32, 7.0), mitigate(&armor, .starvation, 7.0));
            try testing.expectEqual(@as(f32, 7.0), mitigate(&armor, .void, 7.0));
        }

        pub fn case_019() !void {
            var zero = FixedEntropy{ .byte = 0 };
            var full = FixedEntropy{ .byte = 0xff };

            try testing.expect(consumeDurability(0, entropy_interface(&zero)));
            try testing.expect(consumeDurability(0, entropy_interface(&full)));
            try testing.expect(consumeDurability(3, entropy_interface(&zero)));
            try testing.expect(!consumeDurability(3, entropy_interface(&full)));

            var rng = std.Random.DefaultPrng.init(0xd04ab1e5);
            const random = rng.random();
            const trials: u32 = 20_000;
            var hits: u32 = 0;
            var index: u32 = 0;
            while (index < trials) : (index += 1) {
                if (consumeDurability(3, random)) hits += 1;
            }
            const rate = @as(f64, @floatFromInt(hits)) / @as(f64, trials);
            try testing.expect(rate > 0.23 and rate < 0.27);
        }

        pub fn case_020() !void {
            const allocator = testing.allocator;

            const sword_kind = try test_helpers.itemType(allocator, "minecraft:test_wear_sword", &.{"minecraft:is_sword"}, false);
            defer sword_kind.deinit();
            const stone_kind = try test_helpers.itemType(allocator, "minecraft:test_wear_stone", &.{}, true);
            defer stone_kind.deinit();

            var zero = FixedEntropy{ .byte = 0 };
            var full = FixedEntropy{ .byte = 0xff };

            var stackable = ItemStack.init(allocator, stone_kind, .{});
            defer stackable.deinit();
            try testing.expectEqual(@as(u8, 0), wearTool(&stackable, 5, entropy_interface(&zero)));
            try testing.expectEqual(@as(u32, 0), stackable.metadata);

            var plain = ItemStack.init(allocator, sword_kind, .{});
            defer plain.deinit();
            try testing.expectEqual(@as(u8, 3), wearTool(&plain, 3, entropy_interface(&zero)));
            try testing.expectEqual(@as(u32, 3), plain.metadata);

            var enchanted = ItemStack.init(allocator, sword_kind, .{});
            defer enchanted.deinit();
            _ = enchanted.enchantments.set(compat.UNBREAKING, 3);
            try testing.expectEqual(@as(u8, 0), wearTool(&enchanted, 4, entropy_interface(&full)));
            try testing.expectEqual(@as(u32, 0), enchanted.metadata);
            try testing.expectEqual(@as(u8, 2), wearTool(&enchanted, 2, entropy_interface(&zero)));
            try testing.expectEqual(@as(u32, 2), enchanted.metadata);
        }

        pub fn case_021() !void {
            const allocator = testing.allocator;

            const kind = try test_helpers.itemType(allocator, "minecraft:test_effects_thorns_wear", &.{"minecraft:is_armor"}, false);
            defer kind.deinit();

            var firing: Container = try thornsArmor(allocator, kind, .{ 3, 0, 0, 0 });
            defer firing.deinit();

            var zero = FixedEntropy{ .byte = 0 };
            const damage = thornsReflection(&firing, entropy_interface(&zero));
            try testing.expect(damage >= THORNS_MIN_DAMAGE and damage <= THORNS_MAX_DAMAGE);
            try testing.expectEqual(@as(u32, 1), firing.getItem(0).?.metadata);
            try testing.expect(firing.getItem(1) == null);

            var calm: Container = try thornsArmor(allocator, kind, .{ 0, 0, 0, 2 });
            defer calm.deinit();

            var full = FixedEntropy{ .byte = 0xff };
            try testing.expectEqual(@as(f32, 0.0), thornsReflection(&calm, entropy_interface(&full)));
            try testing.expectEqual(@as(u32, 0), calm.getItem(3).?.metadata);
        }

        pub fn case_022() !void {
            const allocator = testing.allocator;

            const kind = try test_helpers.itemType(allocator, "minecraft:test_effects_vanishing", &.{"minecraft:is_armor"}, false);
            defer kind.deinit();

            var plain = ItemStack.init(allocator, kind, .{});
            defer plain.deinit();
            try testing.expect(!vanishesOnDeath(&plain));

            _ = plain.enchantments.set(compat.CURSE_OF_BINDING, 1);
            try testing.expect(!vanishesOnDeath(&plain));

            _ = plain.enchantments.set(compat.CURSE_OF_VANISHING, 1);
            try testing.expect(vanishesOnDeath(&plain));
            try testing.expect(blocksArmorRemoval(&plain));

            var doomed = ItemStack.init(allocator, kind, .{});
            defer doomed.deinit();
            _ = doomed.enchantments.set(compat.CURSE_OF_VANISHING, 1);
            try testing.expect(vanishesOnDeath(&doomed));
        }
    };
}
