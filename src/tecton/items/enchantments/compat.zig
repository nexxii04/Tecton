const std = @import("std");
const ItemStack = @import("../item-stack.zig").ItemStack;
const Container = @import("../../container/container.zig").Container;
const set_mod = @import("set.zig");
const EnchantmentSet = set_mod.EnchantmentSet;
const registry_mod = @import("registry.zig");
const ops = @import("ops.zig");

pub const PROTECTION: u16 = 0;
pub const FIRE_PROTECTION: u16 = 1;
pub const FEATHER_FALLING: u16 = 2;
pub const BLAST_PROTECTION: u16 = 3;
pub const PROJECTILE_PROTECTION: u16 = 4;
pub const THORNS: u16 = 5;
pub const RESPIRATION: u16 = 6;
pub const DEPTH_STRIDER: u16 = 7;
pub const AQUA_AFFINITY: u16 = 8;
pub const SHARPNESS: u16 = 9;
pub const SMITE: u16 = 10;
pub const BANE_OF_ARTHROPODS: u16 = 11;
pub const KNOCKBACK: u16 = 12;
pub const FIRE_ASPECT: u16 = 13;
pub const LOOTING: u16 = 14;
pub const EFFICIENCY: u16 = 15;
pub const SILK_TOUCH: u16 = 16;
pub const UNBREAKING: u16 = 17;
pub const FORTUNE: u16 = 18;
pub const POWER: u16 = 19;
pub const PUNCH: u16 = 20;
pub const FLAME: u16 = 21;
pub const INFINITY: u16 = 22;
pub const LUCK_OF_THE_SEA: u16 = 23;
pub const LURE: u16 = 24;
pub const FROST_WALKER: u16 = 25;
pub const MENDING: u16 = 26;
pub const CURSE_OF_BINDING: u16 = 27;
pub const CURSE_OF_VANISHING: u16 = 28;
pub const IMPALING: u16 = 29;
pub const RIPTIDE: u16 = 30;
pub const LOYALTY: u16 = 31;
pub const CHANNELING: u16 = 32;
pub const MULTISHOT: u16 = 33;
pub const PIERCING: u16 = 34;
pub const QUICK_CHARGE: u16 = 35;
pub const SOUL_SPEED: u16 = 36;
pub const SWIFT_SNEAK: u16 = 37;
pub const WIND_BURST: u16 = 38;
pub const DENSITY: u16 = 39;
pub const BREACH: u16 = 40;
pub const LUNGE: u16 = 41;

pub const DAMAGE_GROUP: EnchantmentSet = EnchantmentSet.fromIds(&.{ SHARPNESS, SMITE, BANE_OF_ARTHROPODS });
pub const PROTECTION_GROUP: EnchantmentSet = EnchantmentSet.fromIds(&.{ PROTECTION, FIRE_PROTECTION, BLAST_PROTECTION, PROJECTILE_PROTECTION });
pub const TOOL_GROUP: EnchantmentSet = EnchantmentSet.fromIds(&.{ EFFICIENCY, SILK_TOUCH, FORTUNE });
pub const DURABILITY_GROUP: EnchantmentSet = EnchantmentSet.fromIds(&.{ UNBREAKING, MENDING });
pub const CURSES: EnchantmentSet = EnchantmentSet.fromIds(&.{ CURSE_OF_BINDING, CURSE_OF_VANISHING });

pub const ARMOR_SLOTS: u32 = 4;

pub const ArmorAggregate = struct {
    protection: u8 = 0,
    fire_protection: u8 = 0,
    blast_protection: u8 = 0,
    projectile_protection: u8 = 0,
    respiration: u8 = 0,
    depth_strider: u8 = 0,
    aqua_affinity: u8 = 0,
    soul_speed: u8 = 0,
    swift_sneak: u8 = 0,
    frost_walker: u8 = 0,
    thorns: u8 = 0,
    feather_falling: u8 = 0,
    unbreaking: u8 = 0,
    mending: u8 = 0,
    curse_of_binding: u8 = 0,
    curse_of_vanishing: u8 = 0,

    pub const empty: ArmorAggregate = .{};

    pub fn refresh(self: *ArmorAggregate, armor: *const Container) void {
        self.* = .empty;
        var slot: u32 = 0;
        while (slot < armor.getSize()) : (slot += 1) {
            const stack = armor.getItem(slot) orelse continue;
            if (!ops.isEnchanted(stack)) continue;
            self.absorb(stack);
        }
    }

    fn absorb(self: *ArmorAggregate, stack: *const ItemStack) void {
        self.protection +|= ops.level(stack, PROTECTION) orelse 0;
        self.fire_protection +|= ops.level(stack, FIRE_PROTECTION) orelse 0;
        self.blast_protection +|= ops.level(stack, BLAST_PROTECTION) orelse 0;
        self.projectile_protection +|= ops.level(stack, PROJECTILE_PROTECTION) orelse 0;
        self.respiration +|= ops.level(stack, RESPIRATION) orelse 0;
        self.depth_strider +|= ops.level(stack, DEPTH_STRIDER) orelse 0;
        self.aqua_affinity +|= ops.level(stack, AQUA_AFFINITY) orelse 0;
        self.soul_speed +|= ops.level(stack, SOUL_SPEED) orelse 0;
        self.swift_sneak +|= ops.level(stack, SWIFT_SNEAK) orelse 0;
        self.frost_walker +|= ops.level(stack, FROST_WALKER) orelse 0;
        self.thorns +|= ops.level(stack, THORNS) orelse 0;
        self.feather_falling +|= ops.level(stack, FEATHER_FALLING) orelse 0;
        self.unbreaking +|= ops.level(stack, UNBREAKING) orelse 0;
        self.mending +|= ops.level(stack, MENDING) orelse 0;
        self.curse_of_binding +|= ops.level(stack, CURSE_OF_BINDING) orelse 0;
        self.curse_of_vanishing +|= ops.level(stack, CURSE_OF_VANISHING) orelse 0;
    }

    pub fn invalidate(self: *ArmorAggregate) void {
        self.* = .empty;
    }

    pub fn isEnchanted(self: *const ArmorAggregate) bool {
        inline for (std.meta.fields(ArmorAggregate)) |field| {
            if (@field(self, field.name) != 0) return true;
        }
        return false;
    }

    pub fn protectionPoints(self: *const ArmorAggregate) u16 {
        return @as(u16, self.protection) +
            @as(u16, self.fire_protection) +
            @as(u16, self.blast_protection) +
            @as(u16, self.projectile_protection);
    }

    pub fn hasCurse(self: *const ArmorAggregate) bool {
        return self.curse_of_binding != 0 or self.curse_of_vanishing != 0;
    }
};

const testing = @import("testing.zig");

test "every id constant still matches the vanilla table" {
    _ = try registry_mod.load();
    const registry = registry_mod.global().?;

    const pairs = .{
        .{ PROTECTION, "protection" },
        .{ FIRE_PROTECTION, "fire_protection" },
        .{ FEATHER_FALLING, "feather_falling" },
        .{ BLAST_PROTECTION, "blast_protection" },
        .{ PROJECTILE_PROTECTION, "projectile_protection" },
        .{ THORNS, "thorns" },
        .{ RESPIRATION, "respiration" },
        .{ DEPTH_STRIDER, "depth_strider" },
        .{ AQUA_AFFINITY, "aqua_affinity" },
        .{ SHARPNESS, "sharpness" },
        .{ SMITE, "smite" },
        .{ BANE_OF_ARTHROPODS, "bane_of_arthropods" },
        .{ KNOCKBACK, "knockback" },
        .{ FIRE_ASPECT, "fire_aspect" },
        .{ LOOTING, "looting" },
        .{ EFFICIENCY, "efficiency" },
        .{ SILK_TOUCH, "silk_touch" },
        .{ UNBREAKING, "unbreaking" },
        .{ FORTUNE, "fortune" },
        .{ POWER, "power" },
        .{ PUNCH, "punch" },
        .{ FLAME, "flame" },
        .{ INFINITY, "infinity" },
        .{ LUCK_OF_THE_SEA, "luck_of_the_sea" },
        .{ LURE, "lure" },
        .{ FROST_WALKER, "frost_walker" },
        .{ MENDING, "mending" },
        .{ CURSE_OF_BINDING, "curse_of_binding" },
        .{ CURSE_OF_VANISHING, "curse_of_vanishing" },
        .{ IMPALING, "impaling" },
        .{ RIPTIDE, "riptide" },
        .{ LOYALTY, "loyalty" },
        .{ CHANNELING, "channeling" },
        .{ MULTISHOT, "multishot" },
        .{ PIERCING, "piercing" },
        .{ QUICK_CHARGE, "quick_charge" },
        .{ SOUL_SPEED, "soul_speed" },
        .{ SWIFT_SNEAK, "swift_sneak" },
        .{ WIND_BURST, "wind_burst" },
        .{ DENSITY, "density" },
        .{ BREACH, "breach" },
        .{ LUNGE, "lunge" },
    };

    try std.testing.expectEqual(registry.count(), pairs.len);
    inline for (pairs) |pair| {
        const definition = registry.resolve(pair[1]) orelse return error.MissingVanillaEnchantment;
        try std.testing.expectEqual(pair[0], definition.id);
    }
}

test "group sets cover the vanilla ids" {
    try std.testing.expectEqual(@as(usize, 3), DAMAGE_GROUP.count());
    try std.testing.expectEqual(@as(usize, 4), PROTECTION_GROUP.count());
    try std.testing.expectEqual(@as(usize, 3), TOOL_GROUP.count());
    try std.testing.expectEqual(@as(usize, 2), DURABILITY_GROUP.count());
    try std.testing.expectEqual(@as(usize, 2), CURSES.count());
    try std.testing.expect(DAMAGE_GROUP.contains(SHARPNESS));
    try std.testing.expect(!DAMAGE_GROUP.contains(SILK_TOUCH));
    try std.testing.expect(PROTECTION_GROUP.contains(BLAST_PROTECTION));
}

test "ArmorAggregate refreshes from the four pieces and invalidates" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    const helmet_type = try testing.itemType(allocator, "minecraft:test_compat_helmet", &.{"minecraft:is_armor"}, false);
    defer helmet_type.deinit();
    const chest_type = try testing.itemType(allocator, "minecraft:test_compat_chestplate", &.{"minecraft:is_armor"}, false);
    defer chest_type.deinit();
    const legs_type = try testing.itemType(allocator, "minecraft:test_compat_leggings", &.{"minecraft:is_armor"}, false);
    defer legs_type.deinit();
    const boots_type = try testing.itemType(allocator, "minecraft:test_compat_boots", &.{"minecraft:is_armor"}, false);
    defer boots_type.deinit();

    var armor = try Container.init(allocator, .Inventory, ARMOR_SLOTS);
    defer armor.deinit();

    var helmet = ItemStack.init(allocator, helmet_type, .{});
    try std.testing.expect(ops.enchant(&helmet, PROTECTION, 4, .{}) == .applied);
    try std.testing.expect(ops.enchant(&helmet, RESPIRATION, 3, .{}) == .applied);
    armor.setItem(0, helmet);

    var chestplate = ItemStack.init(allocator, chest_type, .{});
    try std.testing.expect(ops.enchant(&chestplate, PROTECTION, 4, .{}) == .applied);
    try std.testing.expect(ops.enchant(&chestplate, THORNS, 2, .{}) == .applied);
    armor.setItem(1, chestplate);

    var leggings = ItemStack.init(allocator, legs_type, .{});
    try std.testing.expect(ops.enchant(&leggings, SWIFT_SNEAK, 3, .{}) == .applied);
    armor.setItem(2, leggings);

    var boots = ItemStack.init(allocator, boots_type, .{});
    try std.testing.expect(ops.enchant(&boots, FEATHER_FALLING, 4, .{}) == .applied);
    try std.testing.expect(ops.enchant(&boots, SOUL_SPEED, 3, .{}) == .applied);
    try std.testing.expect(ops.enchant(&boots, CURSE_OF_BINDING, 1, .{}) == .applied);
    armor.setItem(3, boots);

    var aggregate: ArmorAggregate = .empty;
    try std.testing.expect(!aggregate.isEnchanted());

    aggregate.refresh(&armor);
    try std.testing.expectEqual(@as(u8, 8), aggregate.protection);
    try std.testing.expectEqual(@as(u8, 3), aggregate.respiration);
    try std.testing.expectEqual(@as(u8, 2), aggregate.thorns);
    try std.testing.expectEqual(@as(u8, 3), aggregate.swift_sneak);
    try std.testing.expectEqual(@as(u8, 4), aggregate.feather_falling);
    try std.testing.expectEqual(@as(u8, 3), aggregate.soul_speed);
    try std.testing.expectEqual(@as(u8, 0), aggregate.depth_strider);
    try std.testing.expectEqual(@as(u8, 0), aggregate.frost_walker);
    try std.testing.expectEqual(@as(u8, 0), aggregate.blast_protection);
    try std.testing.expectEqual(@as(u16, 8), aggregate.protectionPoints());
    try std.testing.expect(aggregate.hasCurse());
    try std.testing.expect(aggregate.isEnchanted());

    armor.clearSlot(2);
    aggregate.refresh(&armor);
    try std.testing.expectEqual(@as(u8, 0), aggregate.swift_sneak);
    try std.testing.expectEqual(@as(u8, 8), aggregate.protection);

    armor.clearSlot(3);
    aggregate.refresh(&armor);
    try std.testing.expectEqual(@as(u8, 0), aggregate.feather_falling);
    try std.testing.expect(!aggregate.hasCurse());

    aggregate.invalidate();
    try std.testing.expect(!aggregate.isEnchanted());
    try std.testing.expectEqual(@as(u8, 0), aggregate.protection);
}

test "ArmorAggregate ignores unenchanted pieces and aggregates the walking pair" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    const boots_type = try testing.itemType(allocator, "minecraft:test_compat_plain_boots", &.{"minecraft:is_armor"}, false);
    defer boots_type.deinit();

    var armor = try Container.init(allocator, .Inventory, ARMOR_SLOTS);
    defer armor.deinit();
    armor.setItem(3, ItemStack.init(allocator, boots_type, .{}));

    var aggregate: ArmorAggregate = .empty;
    aggregate.refresh(&armor);
    try std.testing.expect(!aggregate.isEnchanted());

    var stack = ItemStack.init(allocator, boots_type, .{});
    defer stack.deinit();
    _ = stack.enchantments.set(DEPTH_STRIDER, 3);
    _ = stack.enchantments.set(FROST_WALKER, 2);
    _ = stack.enchantments.set(UNBREAKING, 200);

    aggregate.absorb(&stack);
    try std.testing.expectEqual(@as(u8, 3), aggregate.depth_strider);
    try std.testing.expectEqual(@as(u8, 2), aggregate.frost_walker);
    try std.testing.expectEqual(@as(u8, 200), aggregate.unbreaking);
    try std.testing.expectEqual(@as(u8, 0), aggregate.protection);
}
