const std = @import("std");
const NBT = @import("nbt");
const ItemStack = @import("../item_stack.zig").ItemStack;
const display = @import("../traits/display.zig");
const durability = @import("../durability.zig");
const enchantment = @import("enchantment.zig");
const ops = @import("ops.zig");
const registry_mod = @import("registry.zig");

pub const COMBINE_COST: u32 = 2;
pub const RENAME_COST: u32 = 1;
pub const MATERIAL_REPAIR_COST: u32 = 1;
pub const WORK_PENALTY_KEY = "RepairCost";

pub const Charges = struct {
    combine: bool = false,
    rename: bool = false,
    material: bool = false,
    enchantment: u32 = 0,
    prior: u32 = 0,
};

pub fn totalCost(charges: Charges) u32 {
    var total = charges.prior + charges.enchantment;
    if (charges.combine) total += COMBINE_COST;
    if (charges.rename) total += RENAME_COST;
    if (charges.material) total += MATERIAL_REPAIR_COST;
    return total;
}

pub fn priorWork(stack: *const ItemStack) u32 {
    const tag_compound = display.getTagCompound(stack) orelse return 0;
    const tag = tag_compound.get(WORK_PENALTY_KEY) orelse return 0;
    return switch (tag) {
        .Int => |value| if (value.value > 0) @intCast(value.value) else 0,
        else => 0,
    };
}

pub fn setPriorWork(stack: *ItemStack, value: u32) !void {
    const tag_compound = try display.ensureTagCompound(stack);

    if (tag_compound.value.fetchRemove(WORK_PENALTY_KEY)) |removed| {
        var previous = removed.value;
        previous.deinit(stack.allocator);
    }
    if (value == 0) return;

    try tag_compound.set(WORK_PENALTY_KEY, .{ .Int = NBT.IntTag.init(@intCast(value), null) });
}

pub fn nextPriorWork(first: *const ItemStack, second: ?*const ItemStack) u32 {
    var total = priorWork(first) + 1;
    if (second) |other| total += priorWork(other);
    return total;
}

pub fn isBook(stack: *const ItemStack) bool {
    return enchantment.isBookIdentifier(stack.item_type.identifier);
}

pub const Operation = enum { rename, combine, repair_tools, repair_material };

pub const Preview = struct {
    stack: ItemStack,
    cost: u32,
    merge: ops.AnvilMerge,
    operation: Operation,
};

pub fn evaluate(
    allocator: std.mem.Allocator,
    first: *const ItemStack,
    second: ?*const ItemStack,
    rename: ?[]const u8,
) !?Preview {
    const requested_name = rename orelse "";
    const current_name = display.getDisplayName(first) orelse "";
    const renaming = rename != null and !std.mem.eql(u8, requested_name, current_name);
    if (second == null and !renaming) return null;

    var operation: Operation = .rename;
    var material_repair = false;
    var new_damage = first.metadata;

    if (second) |other| {
        if (isBook(other)) {
            operation = .combine;
        } else if (first.item_type == other.item_type) {
            const max = durability.maxDurability(first.item_type.identifier) orelse return null;
            new_damage = durability.damageAfterCombineRepair(max, first.metadata, other.metadata);
            operation = .repair_tools;
        } else if (durability.materialFor(first.item_type.identifier)) |material| {
            if (!durability.isRepairMaterial(other.item_type, material)) return null;
            const max = durability.maxDurability(first.item_type.identifier) orelse return null;
            new_damage = durability.damageAfterMaterialRepair(max, first.metadata);
            if (new_damage == first.metadata) return null;
            material_repair = true;
            operation = .repair_material;
        } else return null;
    }

    var result = try first.cloneWithCount(allocator, first.stack_size);
    errdefer result.deinit();

    var merge = ops.AnvilMerge{};
    if (second) |other| merge = try ops.mergeForAnvil(&result, other);

    if (renaming) try display.setDisplayName(&result, if (requested_name.len == 0) null else requested_name);

    const repaired = new_damage != first.metadata;
    if (second != null and !renaming and !repaired and merge.added == 0 and merge.upgraded == 0) {
        result.deinit();
        return null;
    }
    if (repaired) result.metadata = new_damage;

    const prior = nextPriorWork(first, second);
    try setPriorWork(&result, prior);

    return .{
        .stack = result,
        .cost = totalCost(.{
            .combine = second != null and !material_repair,
            .rename = renaming,
            .material = material_repair,
            .enchantment = merge.charge,
            .prior = prior,
        }),
        .merge = merge,
        .operation = operation,
    };
}

const testing = std.testing;
const test_helpers = @import("testing.zig");
const EnchantmentInstance = enchantment.EnchantmentInstance;
const ItemType = @import("../item_type.zig").ItemType;

const SHARPNESS: u16 = 9;
const SMITE: u16 = 10;
const UNBREAKING: u16 = 17;

fn stackOn(item_type: *ItemType, entries: []const EnchantmentInstance) ItemStack {
    var stack = ItemStack.init(item_type.allocator, item_type, .{});
    for (entries) |entry| _ = stack.enchantments.set(entry.id, entry.level);
    return stack;
}

test "an equal level gains one and the cost follows the anvil cost" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const item_type = try test_helpers.itemType(allocator, "minecraft:enchanted_book", &.{}, true);
    defer item_type.deinit();
    var first = stackOn(item_type, &.{.{ .id = SHARPNESS, .level = 1 }});
    defer first.deinit();
    var second = stackOn(item_type, &.{.{ .id = SHARPNESS, .level = 1 }});
    defer second.deinit();

    var preview = (try evaluate(allocator, &first, &second, null)).?;
    defer preview.stack.deinit();

    try testing.expectEqual(@as(u8, 2), preview.stack.enchantments.level(SHARPNESS).?);
    try testing.expectEqual(@as(u8, 1), preview.merge.upgraded);
    try testing.expectEqual(@as(u32, 1), preview.merge.charge);
    try testing.expectEqual(COMBINE_COST + 1 + 1, preview.cost);
    try testing.expectEqual(@as(u32, 1), priorWork(&preview.stack));
    try testing.expect(priorWork(&first) == 0);
}

test "a higher sacrifice level wins and only the gain is charged" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const item_type = try test_helpers.itemType(allocator, "minecraft:enchanted_book", &.{}, true);
    defer item_type.deinit();
    var first = stackOn(item_type, &.{.{ .id = SHARPNESS, .level = 1 }});
    defer first.deinit();
    var second = stackOn(item_type, &.{.{ .id = SHARPNESS, .level = 3 }});
    defer second.deinit();

    var preview = (try evaluate(allocator, &first, &second, null)).?;
    defer preview.stack.deinit();

    try testing.expectEqual(@as(u8, 3), preview.stack.enchantments.level(SHARPNESS).?);
    try testing.expectEqual(@as(u32, 2), preview.merge.charge);
    try testing.expectEqual(@as(u8, 1), preview.merge.upgraded);
}

test "a lower sacrifice level is no gain, so nothing is consumed" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const item_type = try test_helpers.itemType(allocator, "minecraft:enchanted_book", &.{}, true);
    defer item_type.deinit();
    var first = stackOn(item_type, &.{.{ .id = SHARPNESS, .level = 3 }});
    defer first.deinit();
    var second = stackOn(item_type, &.{.{ .id = SHARPNESS, .level = 1 }});
    defer second.deinit();

    try testing.expect((try evaluate(allocator, &first, &second, null)) == null);

    const merge = try ops.mergeForAnvil(&first, &second);
    try testing.expectEqual(@as(u8, 1), merge.kept);
    try testing.expectEqual(@as(u32, 0), merge.charge);
    try testing.expectEqual(@as(u8, 3), first.enchantments.level(SHARPNESS).?);
}

test "a conflicting sacrifice enchantment is dropped, not the operation" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const sword_type = try test_helpers.sword(allocator, "minecraft:test_anvil_conflict");
    defer sword_type.deinit();
    const book_type = try test_helpers.itemType(allocator, "minecraft:enchanted_book", &.{}, true);
    defer book_type.deinit();

    var sword = stackOn(sword_type, &.{.{ .id = SHARPNESS, .level = 3 }});
    defer sword.deinit();
    var book = stackOn(book_type, &.{
        .{ .id = SMITE, .level = 2 },
        .{ .id = UNBREAKING, .level = 1 },
    });
    defer book.deinit();

    var preview = (try evaluate(allocator, &sword, &book, null)).?;
    defer preview.stack.deinit();

    try testing.expectEqual(@as(u8, 1), preview.merge.conflicts);
    try testing.expectEqual(@as(u8, 1), preview.merge.added);
    try testing.expect(preview.stack.enchantments.level(SMITE) == null);
    try testing.expectEqual(@as(u8, 1), preview.stack.enchantments.level(UNBREAKING).?);
    try testing.expectEqual(@as(u8, 3), preview.stack.enchantments.level(SHARPNESS).?);
    try testing.expectEqual(@as(u32, 2), preview.merge.charge);
}

test "a book whose only enchantment conflicts leaves no result" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const sword_type = try test_helpers.sword(allocator, "minecraft:test_anvil_dead_book");
    defer sword_type.deinit();
    const book_type = try test_helpers.itemType(allocator, "minecraft:enchanted_book", &.{}, true);
    defer book_type.deinit();

    var sword = stackOn(sword_type, &.{.{ .id = SHARPNESS, .level = 1 }});
    defer sword.deinit();
    var book = stackOn(book_type, &.{.{ .id = SMITE, .level = 2 }});
    defer book.deinit();

    try testing.expect((try evaluate(allocator, &sword, &book, null)) == null);
}

test "renaming charges the rename and clearing the name removes it" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const item_type = try test_helpers.sword(allocator, "minecraft:test_anvil_rename");
    defer item_type.deinit();
    var sword = stackOn(item_type, &.{});
    defer sword.deinit();

    var renamed = (try evaluate(allocator, &sword, null, "Excalibur")).?;
    defer renamed.stack.deinit();
    try testing.expectEqualStrings("Excalibur", display.getDisplayName(&renamed.stack).?);
    try testing.expectEqual(RENAME_COST + 1, renamed.cost);

    var cleared = (try evaluate(allocator, &renamed.stack, null, "")).?;
    defer cleared.stack.deinit();
    try testing.expect(display.getDisplayName(&cleared.stack) == null);
    try testing.expectEqual(@as(u32, 2), priorWork(&cleared.stack));
}

test "an unchanged name is not a rename and an idle pair has no result" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const item_type = try test_helpers.pickaxe(allocator, "minecraft:iron_pickaxe");
    defer item_type.deinit();
    var pickaxe = stackOn(item_type, &.{});
    defer pickaxe.deinit();

    try testing.expect((try evaluate(allocator, &pickaxe, null, null)) == null);
    try testing.expect((try evaluate(allocator, &pickaxe, null, "")) == null);

    var twin = stackOn(item_type, &.{});
    defer twin.deinit();
    try testing.expect((try evaluate(allocator, &pickaxe, &twin, null)) == null);
}

test "two damaged copies of one item pool their durability" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const item_type = try test_helpers.pickaxe(allocator, "minecraft:diamond_pickaxe");
    defer item_type.deinit();
    var first = stackOn(item_type, &.{.{ .id = SHARPNESS, .level = 1 }});
    defer first.deinit();
    var second = stackOn(item_type, &.{.{ .id = SHARPNESS, .level = 1 }});
    defer second.deinit();
    first.metadata = 1000;
    second.metadata = 1000;

    var preview = (try evaluate(allocator, &first, &second, null)).?;
    defer preview.stack.deinit();

    try testing.expectEqual(Operation.repair_tools, preview.operation);
    try testing.expectEqual(@as(u32, 252), preview.stack.metadata);
    try testing.expectEqual(@as(u8, 2), preview.stack.enchantments.level(SHARPNESS).?);
    try testing.expectEqual(COMBINE_COST + 1 + 1, preview.cost);
}

test "one material unit repairs a quarter of the maximum" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const item_type = try test_helpers.pickaxe(allocator, "minecraft:diamond_pickaxe");
    defer item_type.deinit();
    const material_type = try test_helpers.stone(allocator, "minecraft:diamond");
    defer material_type.deinit();

    var pickaxe = stackOn(item_type, &.{.{ .id = UNBREAKING, .level = 2 }});
    defer pickaxe.deinit();
    var material = stackOn(material_type, &.{});
    defer material.deinit();
    pickaxe.metadata = 1000;

    var preview = (try evaluate(allocator, &pickaxe, &material, null)).?;
    defer preview.stack.deinit();

    try testing.expectEqual(Operation.repair_material, preview.operation);
    try testing.expectEqual(@as(u32, 610), preview.stack.metadata);
    try testing.expectEqual(@as(u8, 2), preview.stack.enchantments.level(UNBREAKING).?);
    try testing.expectEqual(MATERIAL_REPAIR_COST + 1, preview.cost);
}

test "planks and stone repair through their vanilla tags" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const axe_type = try test_helpers.itemType(allocator, "minecraft:wooden_axe", &.{}, false);
    defer axe_type.deinit();
    const planks_type = try test_helpers.itemType(allocator, "minecraft:oak_planks", &.{"minecraft:planks"}, true);
    defer planks_type.deinit();

    var axe = stackOn(axe_type, &.{});
    defer axe.deinit();
    var planks = stackOn(planks_type, &.{});
    defer planks.deinit();
    axe.metadata = 40;

    var preview = (try evaluate(allocator, &axe, &planks, null)).?;
    defer preview.stack.deinit();
    try testing.expectEqual(@as(u32, 26), preview.stack.metadata);
}

test "a wrong ingredient, a pristine item and an uncovered item leave no result" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const pickaxe_type = try test_helpers.pickaxe(allocator, "minecraft:diamond_pickaxe");
    defer pickaxe_type.deinit();
    const gold_type = try test_helpers.stone(allocator, "minecraft:gold_ingot");
    defer gold_type.deinit();
    const diamond_type = try test_helpers.stone(allocator, "minecraft:diamond");
    defer diamond_type.deinit();
    const copper_type = try test_helpers.pickaxe(allocator, "minecraft:copper_pickaxe");
    defer copper_type.deinit();

    var pickaxe = stackOn(pickaxe_type, &.{});
    defer pickaxe.deinit();
    var gold = stackOn(gold_type, &.{});
    defer gold.deinit();
    var diamond = stackOn(diamond_type, &.{});
    defer diamond.deinit();
    var copper = stackOn(copper_type, &.{});
    defer copper.deinit();

    pickaxe.metadata = 500;
    try testing.expect((try evaluate(allocator, &pickaxe, &gold, null)) == null);

    var pristine = stackOn(pickaxe_type, &.{});
    defer pristine.deinit();
    try testing.expect((try evaluate(allocator, &pristine, &diamond, null)) == null);

    copper.metadata = 50;
    try testing.expect((try evaluate(allocator, &copper, &copper, null)) == null);
}

test "unrelated item kinds and unknown ids are left alone" {
    const allocator = testing.allocator;
    _ = try registry_mod.load();

    const sword_type = try test_helpers.sword(allocator, "minecraft:test_anvil_kinds");
    defer sword_type.deinit();
    const pickaxe_type = try test_helpers.pickaxe(allocator, "minecraft:test_anvil_kinds_other");
    defer pickaxe_type.deinit();

    var sword = stackOn(sword_type, &.{.{ .id = SHARPNESS, .level = 1 }});
    defer sword.deinit();
    var pickaxe = stackOn(pickaxe_type, &.{.{ .id = SHARPNESS, .level = 1 }});
    defer pickaxe.deinit();

    try testing.expect((try evaluate(allocator, &sword, &pickaxe, null)) == null);
}
