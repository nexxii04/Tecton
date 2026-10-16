const std = @import("std");
const Protocol = @import("protocol");

const ItemStack = @import("../item_stack.zig").ItemStack;
const ItemType = @import("../item_type.zig").ItemType;
const Container = @import("../../container/container.zig").Container;
const Events = @import("../../events/types.zig");
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
pub const BLAST_PROTECTION_PER_LEVEL: f32 = 0.08;
pub const PROJECTILE_PROTECTION_PER_LEVEL: f32 = 0.08;
pub const FEATHER_FALLING_PER_LEVEL: f32 = 0.12;
pub const TYPED_PROTECTION_FLOOR: f32 = 0.2;
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

fn scaledMitigation(levels: u8, per_level: f32, amount: f32) f32 {
    const counted: f32 = @floatFromInt(levels);
    return amount * @max(TYPED_PROTECTION_FLOOR, 1.0 - per_level * counted);
}

pub fn mitigate(armor: *const compat.ArmorAggregate, cause: Events.DamageCause, amount: f32) f32 {
    return switch (cause) {
        .entity_attack => mitigatedDamage(armor, amount),
        .fire, .fire_tick, .lava => mitigatedFireDamage(armor, amount),
        .explosion => scaledMitigation(armor.blast_protection, BLAST_PROTECTION_PER_LEVEL, amount),
        .projectile => scaledMitigation(armor.projectile_protection, PROJECTILE_PROTECTION_PER_LEVEL, amount),
        .fall => scaledMitigation(armor.feather_falling, FEATHER_FALLING_PER_LEVEL, amount),
        else => amount,
    };
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

pub fn thornsReflection(armor: *Container, random: std.Random) f32 {
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
        const piece = armor.getItemMut(slot) orelse continue;
        _ = wearTool(piece, 1, random);
    }
    return hardest;
}

pub fn consumeDurability(unbreaking_level: u8, random: std.Random) bool {
    if (unbreaking_level == 0) return true;
    const chance: f32 = 1.0 / (@as(f32, @floatFromInt(unbreaking_level)) + 1.0);
    return random.float(f32) < chance;
}

pub fn wearTool(stack: *ItemStack, uses: u8, random: std.Random) u8 {
    if (stack.item_type.stackable) return 0;
    const level = ops.level(stack, compat.UNBREAKING) orelse 0;
    var consumed: u8 = 0;
    var i: u8 = 0;
    while (i < uses) : (i += 1) {
        if (!consumeDurability(level, random)) continue;
        stack.metadata += 1;
        consumed += 1;
    }
    return consumed;
}

const testing = std.testing;
const test_helpers = @import("testing.zig");

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

const test_owner = @This();
const test_scope = struct {
    pub const entropy_interface = test_owner.FixedEntropy.interface;
    pub const std = test_owner.std;
    pub const Protocol = test_owner.Protocol;
    pub const ItemStack = test_owner.ItemStack;
    pub const Container = test_owner.Container;
    pub const compat = test_owner.compat;
    pub const Family = test_owner.Family;
    pub const FIST_DAMAGE = test_owner.FIST_DAMAGE;
    pub const TRIDENT_DAMAGE = test_owner.TRIDENT_DAMAGE;
    pub const BASE_KNOCKBACK = test_owner.BASE_KNOCKBACK;
    pub const PROTECTION_MAX_LEVELS = test_owner.PROTECTION_MAX_LEVELS;
    pub const FIRE_PROTECTION_MAX_LEVELS = test_owner.FIRE_PROTECTION_MAX_LEVELS;
    pub const THORNS_MIN_DAMAGE = test_owner.THORNS_MIN_DAMAGE;
    pub const THORNS_MAX_DAMAGE = test_owner.THORNS_MAX_DAMAGE;
    pub const FAMILY_MAP = test_owner.FAMILY_MAP;
    pub const familyOf = test_owner.familyOf;
    pub const baseAttackDamage = test_owner.baseAttackDamage;
    pub const attackDamage = test_owner.attackDamage;
    pub const knockbackImpulse = test_owner.knockbackImpulse;
    pub const meleeImpact = test_owner.meleeImpact;
    pub const blocksArmorRemoval = test_owner.blocksArmorRemoval;
    pub const mitigatedDamage = test_owner.mitigatedDamage;
    pub const mitigatedFireDamage = test_owner.mitigatedFireDamage;
    pub const Events = test_owner.Events;
    pub const BLAST_PROTECTION_PER_LEVEL = test_owner.BLAST_PROTECTION_PER_LEVEL;
    pub const PROJECTILE_PROTECTION_PER_LEVEL = test_owner.PROJECTILE_PROTECTION_PER_LEVEL;
    pub const FEATHER_FALLING_PER_LEVEL = test_owner.FEATHER_FALLING_PER_LEVEL;
    pub const TYPED_PROTECTION_FLOOR = test_owner.TYPED_PROTECTION_FLOOR;
    pub const mitigate = test_owner.mitigate;
    pub const fireBurnDuration = test_owner.fireBurnDuration;
    pub const fireAspectDurationTicks = test_owner.fireAspectDurationTicks;
    pub const thornsReflection = test_owner.thornsReflection;
    pub const consumeDurability = test_owner.consumeDurability;
    pub const wearTool = test_owner.wearTool;
    pub const testing = test_owner.testing;
    pub const test_helpers = test_owner.test_helpers;
    pub const FixedEntropy = test_owner.FixedEntropy;
    pub const thornsArmor = test_owner.thornsArmor;
};

test "the base attack damage follows the tier and blade tags" {
    try @import("effects_test.zig").Suite(test_scope).case_000();
}

test "the victim family decides which damage bonus applies" {
    try @import("effects_test.zig").Suite(test_scope).case_001();
}

test "sharpness smite and bane add their bedrock bonuses" {
    try @import("effects_test.zig").Suite(test_scope).case_002();
}

test "sharpness five matches the damage the client prints" {
    try @import("effects_test.zig").Suite(test_scope).case_003();
}

test "smite only pays against the undead and bane only against arthropods" {
    try @import("effects_test.zig").Suite(test_scope).case_004();
}

test "knockback scales the impulse the attack path already used" {
    try @import("effects_test.zig").Suite(test_scope).case_005();
}

test "every family row names a real entity type" {
    try @import("effects_test.zig").Suite(test_scope).case_006();
}

test "protection shaves four percent a level up to twenty levels" {
    try @import("effects_test.zig").Suite(test_scope).case_007();
}

test "the typed protections do not shave a melee hit" {
    try @import("effects_test.zig").Suite(test_scope).case_008();
}

test "thorns never fires without a piece that carries it" {
    try @import("effects_test.zig").Suite(test_scope).case_009();
}

test "four pieces of thorns roll four separate dice" {
    try @import("effects_test.zig").Suite(test_scope).case_010();
}

test "thorns level three fires about forty-five times in a hundred" {
    try @import("effects_test.zig").Suite(test_scope).case_011();
}

test "curse of binding blocks armor removal and nothing else" {
    try @import("effects_test.zig").Suite(test_scope).case_012();
}

test "fire protection shaves the burn duration by fifteen percent a level" {
    try @import("effects_test.zig").Suite(test_scope).case_013();
}

test "fire protection shaves the fire damage by eight percent a level" {
    try @import("effects_test.zig").Suite(test_scope).case_014();
}

test "fire aspect burns for four seconds per level" {
    try @import("effects_test.zig").Suite(test_scope).case_015();
}

test "mitigate routes melee and fire to their legacy formulas" {
    try @import("effects_test.zig").Suite(test_scope).case_016();
}

test "mitigate scales the typed protections with an eighty percent floor" {
    try @import("effects_test.zig").Suite(test_scope).case_017();
}

test "mitigate leaves uncovered causes untouched" {
    try @import("effects_test.zig").Suite(test_scope).case_018();
}

test "unbreaking pays one use in level plus one times" {
    try @import("effects_test.zig").Suite(test_scope).case_019();
}

test "wear skips stackables and spends metadata through the dice" {
    try @import("effects_test.zig").Suite(test_scope).case_020();
}

test "a thorns reflection spends one durability on the firing piece" {
    try @import("effects_test.zig").Suite(test_scope).case_021();
}
