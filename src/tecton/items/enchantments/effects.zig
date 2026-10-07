const std = @import("std");
const Protocol = @import("protocol");

const ItemStack = @import("../item-stack.zig").ItemStack;
const ItemType = @import("../item-type.zig").ItemType;
const Container = @import("../../container/container.zig").Container;
const ops = @import("ops.zig");
const compat = @import("compat.zig");

pub const Family = enum { none, undead, arthropod };

pub const FIST_DAMAGE: f32 = 1.0;
pub const TRIDENT_DAMAGE: f32 = 8.0;
pub const SHARPNESS_PER_LEVEL: f32 = 1.25;
pub const SMITE_PER_LEVEL: f32 = 2.5;
pub const BANE_PER_LEVEL: f32 = 2.5;
pub const BASE_KNOCKBACK: f32 = 0.3;
pub const KNOCKBACK_PER_LEVEL: f32 = 0.15;
pub const PROTECTION_PER_LEVEL: f32 = 0.04;
pub const PROTECTION_MAX_LEVELS: u8 = 20;
pub const FIRE_PROTECTION_DAMAGE_PER_LEVEL: f32 = 0.08;
pub const FIRE_PROTECTION_DURATION_PER_LEVEL: f32 = 0.15;
pub const FIRE_PROTECTION_MAX_LEVELS: u8 = 4;
pub const FIRE_ASPECT_TICKS_PER_LEVEL: i32 = 80;
pub const THORNS_CHANCE_PER_LEVEL: f32 = 0.15;
pub const THORNS_MIN_DAMAGE: f32 = 1.0;
pub const THORNS_MAX_DAMAGE: f32 = 5.0;

const TierDamage = struct {
    tag: []const u8,
    sword: f32,
    axe: f32,
};

const TIERS = [_]TierDamage{
    .{ .tag = "minecraft:wooden_tier", .sword = 4, .axe = 3 },
    .{ .tag = "minecraft:copper_tier", .sword = 4, .axe = 3 },
    .{ .tag = "minecraft:golden_tier", .sword = 4, .axe = 3 },
    .{ .tag = "minecraft:stone_tier", .sword = 5, .axe = 4 },
    .{ .tag = "minecraft:iron_tier", .sword = 6, .axe = 5 },
    .{ .tag = "minecraft:diamond_tier", .sword = 7, .axe = 6 },
    .{ .tag = "minecraft:netherite_tier", .sword = 8, .axe = 7 },
};

const FAMILY_MAP = std.StaticStringMap(Family).initComptime(.{
    .{ "minecraft:zombie", Family.undead },
    .{ "minecraft:husk", Family.undead },
    .{ "minecraft:camel_husk", Family.undead },
    .{ "minecraft:parched", Family.undead },
    .{ "minecraft:drowned", Family.undead },
    .{ "minecraft:zombie_villager", Family.undead },
    .{ "minecraft:zombie_villager_v2", Family.undead },
    .{ "minecraft:skeleton", Family.undead },
    .{ "minecraft:stray", Family.undead },
    .{ "minecraft:bogged", Family.undead },
    .{ "minecraft:wither_skeleton", Family.undead },
    .{ "minecraft:phantom", Family.undead },
    .{ "minecraft:zombie_pigman", Family.undead },
    .{ "minecraft:zoglin", Family.undead },
    .{ "minecraft:wither", Family.undead },
    .{ "minecraft:skeleton_horse", Family.undead },
    .{ "minecraft:zombie_horse", Family.undead },
    .{ "minecraft:zombie_nautilus", Family.undead },
    .{ "minecraft:spider", Family.arthropod },
    .{ "minecraft:cave_spider", Family.arthropod },
    .{ "minecraft:silverfish", Family.arthropod },
    .{ "minecraft:endermite", Family.arthropod },
    .{ "minecraft:bee", Family.arthropod },
});

pub const MeleeImpact = struct {
    damage: f32,
    knockback: f32,
};

pub fn familyOf(identifier: []const u8) Family {
    return FAMILY_MAP.get(identifier) orelse .none;
}

pub fn baseAttackDamage(item_type: *const ItemType) f32 {
    if (item_type.hasTag("minecraft:is_trident")) return TRIDENT_DAMAGE;

    const is_sword = item_type.hasTag("minecraft:is_sword");
    const is_axe = item_type.hasTag("minecraft:is_axe");
    if (!is_sword and !is_axe) return FIST_DAMAGE;

    for (TIERS) |tier| {
        if (!item_type.hasTag(tier.tag)) continue;
        return if (is_sword) tier.sword else tier.axe;
    }
    return FIST_DAMAGE;
}

pub fn attackDamage(weapon: ?*const ItemStack, victim: []const u8) f32 {
    const item_type = if (weapon) |stack| stack.item_type else null;
    var damage = if (item_type) |kind| baseAttackDamage(kind) else FIST_DAMAGE;

    const stack = weapon orelse return damage;
    if (!ops.isEnchanted(stack)) return damage;

    if (ops.level(stack, compat.SHARPNESS)) |level| {
        damage += SHARPNESS_PER_LEVEL * @as(f32, @floatFromInt(level));
    }

    switch (familyOf(victim)) {
        .undead => if (ops.level(stack, compat.SMITE)) |level| {
            damage += SMITE_PER_LEVEL * @as(f32, @floatFromInt(level));
        },
        .arthropod => if (ops.level(stack, compat.BANE_OF_ARTHROPODS)) |level| {
            damage += BANE_PER_LEVEL * @as(f32, @floatFromInt(level));
        },
        else => {},
    }

    return damage;
}

pub fn knockbackImpulse(weapon: ?*const ItemStack) f32 {
    const stack = weapon orelse return BASE_KNOCKBACK;
    const level = ops.level(stack, compat.KNOCKBACK) orelse return BASE_KNOCKBACK;
    return BASE_KNOCKBACK + KNOCKBACK_PER_LEVEL * @as(f32, @floatFromInt(level));
}

pub fn meleeImpact(weapon: ?*const ItemStack, victim: []const u8) MeleeImpact {
    return .{
        .damage = attackDamage(weapon, victim),
        .knockback = knockbackImpulse(weapon),
    };
}

pub fn blocksArmorRemoval(item: *const ItemStack) bool {
    return ops.has(item, compat.CURSE_OF_BINDING);
}

pub fn mitigatedDamage(armor: *const compat.ArmorAggregate, amount: f32) f32 {
    const levels: f32 = @floatFromInt(@min(armor.protection, PROTECTION_MAX_LEVELS));
    return amount * (1.0 - PROTECTION_PER_LEVEL * levels);
}

pub fn mitigatedFireDamage(armor: *const compat.ArmorAggregate, amount: f32) f32 {
    const levels: f32 = @floatFromInt(@min(armor.fire_protection, FIRE_PROTECTION_MAX_LEVELS));
    return amount * (1.0 - FIRE_PROTECTION_DAMAGE_PER_LEVEL * levels);
}

pub fn fireBurnDuration(base_ticks: i32, fire_protection_levels: u8) i32 {
    if (base_ticks <= 0) return 0;
    const levels: f32 = @floatFromInt(@min(fire_protection_levels, FIRE_PROTECTION_MAX_LEVELS));
    const reduced = @as(f32, @floatFromInt(base_ticks)) * (1.0 - FIRE_PROTECTION_DURATION_PER_LEVEL * levels);
    return @intFromFloat(@round(reduced));
}

pub fn fireAspectDurationTicks(weapon: ?*const ItemStack) i32 {
    const stack = weapon orelse return 0;
    const level = ops.level(stack, compat.FIRE_ASPECT) orelse return 0;
    return FIRE_ASPECT_TICKS_PER_LEVEL * @as(i32, level);
}

pub fn thornsReflection(armor: *const Container, random: std.Random) f32 {
    var hardest: f32 = 0;
    var slot: u32 = 0;
    while (slot < armor.getSize()) : (slot += 1) {
        const stack = armor.getItem(slot) orelse continue;
        const level = ops.level(stack, compat.THORNS) orelse continue;
        if (level == 0) continue;

        const chance = @min(@as(f32, 1.0), THORNS_CHANCE_PER_LEVEL * @as(f32, @floatFromInt(level)));
        if (random.float(f32) >= chance) continue;

        const damage = THORNS_MIN_DAMAGE + random.float(f32) * (THORNS_MAX_DAMAGE - THORNS_MIN_DAMAGE);
        if (damage > hardest) hardest = damage;
    }
    return hardest;
}

const testing = std.testing;
const test_helpers = @import("testing.zig");

test "the base attack damage follows the tier and blade tags" {
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

test "the victim family decides which damage bonus applies" {
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

test "sharpness smite and bane add their bedrock bonuses" {
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

test "sharpness five matches the damage the client prints" {
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

test "smite only pays against the undead and bane only against arthropods" {
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

test "knockback scales the impulse the attack path already used" {
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

test "every family row names a real entity type" {
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

const FixedEntropy = struct {
    byte: u8,

    fn fill(self: *FixedEntropy, buffer: []u8) void {
        @memset(buffer, self.byte);
    }

    fn interface(self: *FixedEntropy) std.Random {
        return std.Random.init(self, fill);
    }
};

fn thornsArmor(allocator: std.mem.Allocator, kind: *ItemType, levels: [compat.ARMOR_SLOTS]u8) !Container {
    var armor = try Container.init(allocator, .Inventory, compat.ARMOR_SLOTS);
    for (levels, 0..) |level, slot| {
        if (level == 0) continue;
        var piece = ItemStack.init(allocator, kind, .{});
        _ = piece.enchantments.set(compat.THORNS, level);
        armor.setItem(@intCast(slot), piece);
    }
    return armor;
}

test "protection shaves four percent a level up to twenty levels" {
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

test "the typed protections do not shave a melee hit" {
    var armor: compat.ArmorAggregate = .empty;
    armor.fire_protection = 4;
    armor.blast_protection = 4;
    armor.projectile_protection = 4;
    armor.feather_falling = 4;

    try testing.expectEqual(@as(f32, 20.0), mitigatedDamage(&armor, 20.0));

    armor.protection = 2;
    try testing.expectApproxEqAbs(@as(f32, 18.4), mitigatedDamage(&armor, 20.0), 0.0001);
}

test "thorns never fires without a piece that carries it" {
    const allocator = testing.allocator;

    const kind = try test_helpers.itemType(allocator, "minecraft:test_effects_plain_boots", &.{"minecraft:is_armor"}, false);
    defer kind.deinit();

    var armor = try Container.init(allocator, .Inventory, compat.ARMOR_SLOTS);
    defer armor.deinit();
    armor.setItem(0, ItemStack.init(allocator, kind, .{}));

    var always: FixedEntropy = .{ .byte = 0 };
    try testing.expectEqual(@as(f32, 0.0), thornsReflection(&armor, always.interface()));
}

test "four pieces of thorns roll four separate dice" {
    const allocator = testing.allocator;

    const kind = try test_helpers.itemType(allocator, "minecraft:test_effects_thorns_piece", &.{"minecraft:is_armor"}, false);
    defer kind.deinit();

    var entropy: FixedEntropy = .{ .byte = 0xff };

    var four: Container = try thornsArmor(allocator, kind, .{ 3, 3, 3, 3 });
    defer four.deinit();
    try testing.expectEqual(@as(f32, 0.0), thornsReflection(&four, entropy.interface()));

    var one: Container = try thornsArmor(allocator, kind, .{ 0, 0, 7, 0 });
    defer one.deinit();
    try testing.expectApproxEqAbs(THORNS_MAX_DAMAGE, thornsReflection(&one, entropy.interface()), 0.0001);
}

test "thorns level three fires about forty-five times in a hundred" {
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

test "curse of binding blocks armor removal and nothing else" {
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

test "fire protection shaves the burn duration by fifteen percent a level" {
    try testing.expectEqual(@as(i32, 150), fireBurnDuration(150, 0));
    try testing.expectEqual(@as(i32, 128), fireBurnDuration(150, 1));
    try testing.expectEqual(@as(i32, 105), fireBurnDuration(150, 2));
    try testing.expectEqual(@as(i32, 60), fireBurnDuration(150, FIRE_PROTECTION_MAX_LEVELS));
    try testing.expectEqual(@as(i32, 60), fireBurnDuration(150, 200));
    try testing.expectEqual(@as(i32, 0), fireBurnDuration(0, 2));
    try testing.expectEqual(@as(i32, 0), fireBurnDuration(-40, 2));
}

test "fire protection shaves the fire damage by eight percent a level" {
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

test "fire aspect burns for four seconds per level" {
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
