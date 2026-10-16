const std = @import("std");
const ItemType = @import("item_type.zig").ItemType;

pub const Material = enum {
    planks,
    stone,
    golden_ingot,
    iron_ingot,
    diamond,
    netherite_ingot,
    leather,
    phantom_membrane,
    turtle_scute,
    armadillo_scute,
};

pub const Entry = struct {
    identifier: []const u8,
    max: u32,
    material: ?Material = null,
};

fn toolSet(comptime tier: []const u8, comptime max: u32, comptime material: Material) [5]Entry {
    const kinds = [_][]const u8{ "pickaxe", "axe", "shovel", "hoe", "sword" };
    var entries: [5]Entry = undefined;
    for (kinds, 0..) |kind, index| {
        entries[index] = .{
            .identifier = "minecraft:" ++ tier ++ "_" ++ kind,
            .max = max,
            .material = material,
        };
    }
    return entries;
}

fn armorSet(comptime tier: []const u8, comptime maxes: [4]u32, comptime material: Material) [4]Entry {
    const kinds = [_][]const u8{ "helmet", "chestplate", "leggings", "boots" };
    var entries: [4]Entry = undefined;
    for (kinds, 0..) |kind, index| {
        entries[index] = .{
            .identifier = "minecraft:" ++ tier ++ "_" ++ kind,
            .max = maxes[index],
            .material = material,
        };
    }
    return entries;
}

pub const TABLE = toolSet("wooden", 59, .planks) ++
    toolSet("stone", 131, .stone) ++
    toolSet("golden", 32, .golden_ingot) ++
    toolSet("iron", 250, .iron_ingot) ++
    toolSet("diamond", 1561, .diamond) ++
    toolSet("netherite", 2031, .netherite_ingot) ++
    armorSet("leather", .{ 55, 80, 75, 65 }, .leather) ++
    armorSet("chainmail", .{ 165, 240, 225, 195 }, .iron_ingot) ++
    armorSet("golden", .{ 77, 112, 105, 91 }, .golden_ingot) ++
    armorSet("iron", .{ 165, 240, 225, 195 }, .iron_ingot) ++
    armorSet("diamond", .{ 363, 528, 495, 429 }, .diamond) ++
    armorSet("netherite", .{ 407, 592, 555, 481 }, .netherite_ingot) ++
    [_]Entry{
        .{ .identifier = "minecraft:turtle_helmet", .max = 275, .material = .turtle_scute },
        .{ .identifier = "minecraft:elytra", .max = 432, .material = .phantom_membrane },
        .{ .identifier = "minecraft:shield", .max = 336, .material = .planks },
        .{ .identifier = "minecraft:wolf_armor", .max = 64, .material = .armadillo_scute },
        .{ .identifier = "minecraft:bow", .max = 384 },
        .{ .identifier = "minecraft:crossbow", .max = 465 },
        .{ .identifier = "minecraft:trident", .max = 250 },
        .{ .identifier = "minecraft:flint_and_steel", .max = 64 },
        .{ .identifier = "minecraft:shears", .max = 238 },
        .{ .identifier = "minecraft:brush", .max = 64 },
        .{ .identifier = "minecraft:carrot_on_a_stick", .max = 25 },
        .{ .identifier = "minecraft:warped_fungus_on_a_stick", .max = 100 },
    };

pub fn entryOf(identifier: []const u8) ?Entry {
    for (TABLE) |entry| {
        if (std.mem.eql(u8, entry.identifier, identifier)) return entry;
    }
    return null;
}

pub fn maxDurability(identifier: []const u8) ?u32 {
    const entry = entryOf(identifier) orelse return null;
    return entry.max;
}

pub fn materialFor(identifier: []const u8) ?Material {
    const entry = entryOf(identifier) orelse return null;
    return entry.material;
}

pub fn isRepairMaterial(item_type: *const ItemType, material: Material) bool {
    return switch (material) {
        .planks => item_type.hasTag("minecraft:planks"),
        .stone => item_type.hasTag("minecraft:stone_tool_materials"),
        .golden_ingot => std.mem.eql(u8, item_type.identifier, "minecraft:gold_ingot"),
        .iron_ingot => std.mem.eql(u8, item_type.identifier, "minecraft:iron_ingot"),
        .diamond => std.mem.eql(u8, item_type.identifier, "minecraft:diamond"),
        .netherite_ingot => std.mem.eql(u8, item_type.identifier, "minecraft:netherite_ingot"),
        .leather => std.mem.eql(u8, item_type.identifier, "minecraft:leather"),
        .phantom_membrane => std.mem.eql(u8, item_type.identifier, "minecraft:phantom_membrane"),
        .turtle_scute => std.mem.eql(u8, item_type.identifier, "minecraft:turtle_scute"),
        .armadillo_scute => std.mem.eql(u8, item_type.identifier, "minecraft:armadillo_scute"),
    };
}

pub fn remaining(max: u32, damage: u32) u32 {
    return if (damage >= max) 0 else max - damage;
}

pub fn repairPerUnit(max: u32) u32 {
    return max / 4;
}

pub fn damageAfterMaterialRepair(max: u32, damage: u32) u32 {
    const repaired = @min(damage, repairPerUnit(max));
    return damage - repaired;
}

pub fn damageAfterCombineRepair(max: u32, damage_a: u32, damage_b: u32) u32 {
    const pooled = remaining(max, damage_a) + remaining(max, damage_b) + max * 12 / 100;
    if (pooled >= max) return 0;
    return max - pooled;
}

const testing = std.testing;
const test_helpers = @import("enchantments/testing.zig");

test "the curated table answers only for the items it covers" {
    try testing.expectEqual(@as(u32, 1561), maxDurability("minecraft:diamond_pickaxe").?);
    try testing.expectEqual(@as(u32, 59), maxDurability("minecraft:wooden_sword").?);
    try testing.expectEqual(@as(u32, 195), maxDurability("minecraft:chainmail_boots").?);
    try testing.expectEqual(@as(u32, 432), maxDurability("minecraft:elytra").?);
    try testing.expect(maxDurability("minecraft:copper_pickaxe") == null);
    try testing.expect(maxDurability("minecraft:mace") == null);
    try testing.expect(maxDurability("minecraft:fishing_rod") == null);
    try testing.expect(maxDurability("minecraft:stone") == null);
}

test "every table identifier is unique and namespaced" {
    for (TABLE, 0..) |entry, index| {
        try testing.expect(std.mem.startsWith(u8, entry.identifier, "minecraft:"));
        try testing.expect(entry.max > 0);
        for (TABLE[index + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, entry.identifier, other.identifier));
        }
    }
}

test "the repair material follows the tier" {
    try testing.expectEqual(Material.planks, materialFor("minecraft:wooden_axe").?);
    try testing.expectEqual(Material.stone, materialFor("minecraft:stone_shovel").?);
    try testing.expectEqual(Material.golden_ingot, materialFor("minecraft:golden_helmet").?);
    try testing.expectEqual(Material.iron_ingot, materialFor("minecraft:chainmail_leggings").?);
    try testing.expectEqual(Material.diamond, materialFor("minecraft:diamond_chestplate").?);
    try testing.expectEqual(Material.netherite_ingot, materialFor("minecraft:netherite_hoe").?);
    try testing.expectEqual(Material.leather, materialFor("minecraft:leather_boots").?);
    try testing.expectEqual(Material.phantom_membrane, materialFor("minecraft:elytra").?);
    try testing.expectEqual(Material.turtle_scute, materialFor("minecraft:turtle_helmet").?);
    try testing.expectEqual(Material.armadillo_scute, materialFor("minecraft:wolf_armor").?);
    try testing.expect(materialFor("minecraft:bow") == null);
    try testing.expect(materialFor("minecraft:shears") == null);
}

test "planks and stone materials are matched by the vanilla tags" {
    const allocator = testing.allocator;

    const planks = try test_helpers.itemType(allocator, "minecraft:test_planks", &.{"minecraft:planks"}, true);
    defer planks.deinit();
    const cobble = try test_helpers.itemType(allocator, "minecraft:test_cobble", &.{"minecraft:stone_tool_materials"}, true);
    defer cobble.deinit();
    const dirt = try test_helpers.stone(allocator, "minecraft:test_dirt");
    defer dirt.deinit();

    try testing.expect(isRepairMaterial(planks, .planks));
    try testing.expect(!isRepairMaterial(cobble, .planks));
    try testing.expect(isRepairMaterial(cobble, .stone));
    try testing.expect(!isRepairMaterial(dirt, .planks));
    try testing.expect(!isRepairMaterial(dirt, .stone));
}

test "a single material unit restores a quarter of the maximum" {
    const iron = maxDurability("minecraft:iron_pickaxe").?;
    try testing.expectEqual(@as(u32, 62), repairPerUnit(iron));
    try testing.expectEqual(@as(u32, 188), damageAfterMaterialRepair(iron, 250));
    try testing.expectEqual(@as(u32, 0), damageAfterMaterialRepair(iron, 30));
    try testing.expectEqual(@as(u32, 0), damageAfterMaterialRepair(iron, 10));

    const diamond = maxDurability("minecraft:diamond_pickaxe").?;
    try testing.expectEqual(@as(u32, 390), repairPerUnit(diamond));
    try testing.expectEqual(@as(u32, 610), damageAfterMaterialRepair(diamond, 1000));
}

test "an item too small to quarter never repairs with material" {
    try testing.expectEqual(@as(u32, 0), repairPerUnit(3));
    try testing.expectEqual(@as(u32, 2), damageAfterMaterialRepair(3, 2));
}

test "two damaged copies pool their durability plus a twelfth of the maximum" {
    const max = maxDurability("minecraft:diamond_pickaxe").?;
    try testing.expectEqual(@as(u32, 252), damageAfterCombineRepair(max, 1000, 1000));
    try testing.expectEqual(@as(u32, 0), damageAfterCombineRepair(max, 10, 0));
    try testing.expectEqual(@as(u32, 0), damageAfterCombineRepair(max, 0, 0));
    try testing.expectEqual(@as(u32, 1374), damageAfterCombineRepair(max, max, max));
    try testing.expectEqual(@as(u32, 813), damageAfterCombineRepair(max, max, 1000));
    try testing.expectEqual(@as(u32, 0), damageAfterCombineRepair(max, max - 1, 0));
}

test "damage beyond the maximum reads as no durability left" {
    try testing.expectEqual(@as(u32, 0), remaining(100, 100));
    try testing.expectEqual(@as(u32, 0), remaining(100, 4000));
    try testing.expectEqual(@as(u32, 100), remaining(100, 0));
}

test "every ingredient material matches the vanilla identifier it names" {
    const allocator = testing.allocator;
    const cases = [_]struct { identifier: []const u8, material: Material }{
        .{ .identifier = "minecraft:gold_ingot", .material = .golden_ingot },
        .{ .identifier = "minecraft:iron_ingot", .material = .iron_ingot },
        .{ .identifier = "minecraft:diamond", .material = .diamond },
        .{ .identifier = "minecraft:netherite_ingot", .material = .netherite_ingot },
        .{ .identifier = "minecraft:leather", .material = .leather },
        .{ .identifier = "minecraft:phantom_membrane", .material = .phantom_membrane },
        .{ .identifier = "minecraft:turtle_scute", .material = .turtle_scute },
        .{ .identifier = "minecraft:armadillo_scute", .material = .armadillo_scute },
    };

    for (cases) |case| {
        const item_type = try test_helpers.stone(allocator, case.identifier);
        defer item_type.deinit();
        try testing.expect(isRepairMaterial(item_type, case.material));
    }
}
