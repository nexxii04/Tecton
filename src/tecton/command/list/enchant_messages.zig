const std = @import("std");

const items_root = @import("../../items/root.zig");
const ItemStack = items_root.ItemStack;
const Enchantment = items_root.enchantments.Enchantment;
const Display = items_root.traits.display;

pub const USAGE: []const u8 = "/enchant <player: target> <enchantment: Enchant> [level: int]";

pub const MESSAGE_SUCCESS: []const u8 = "Enchanting succeeded for {s}";
pub const MESSAGE_NO_ITEM: []const u8 = "The target doesn't hold an item: {s}";
pub const MESSAGE_CANT_ENCHANT: []const u8 = "The selected enchantment can't be added to the target item: {s}";
pub const MESSAGE_CANT_COMBINE: []const u8 = "{s} can't be combined with {s}";
pub const MESSAGE_INVALID_LEVEL: []const u8 = "{s} does not support level {d}";
pub const MESSAGE_NOT_FOUND: []const u8 = "There is no such enchantment with ID {d}";
pub const MESSAGE_NO_TARGETS: []const u8 = "No targets matched selector";

pub fn successMessage(buffer: []u8, username: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_SUCCESS, .{username}) catch USAGE;
}

pub fn noItemMessage(buffer: []u8, username: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_NO_ITEM, .{username}) catch USAGE;
}

pub fn cantEnchantMessage(buffer: []u8, item: *const ItemStack) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_CANT_ENCHANT, .{itemLabel(item)}) catch USAGE;
}

pub fn cantCombineMessage(buffer: []u8, first: *const Enchantment, second: *const Enchantment) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_CANT_COMBINE, .{ first.name, second.name }) catch USAGE;
}

pub fn invalidLevelMessage(buffer: []u8, definition: *const Enchantment, level: i64) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_INVALID_LEVEL, .{ definition.name, level }) catch USAGE;
}

pub fn notFoundMessage(buffer: []u8, id: i64) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_NOT_FOUND, .{id}) catch USAGE;
}

fn itemLabel(item: *const ItemStack) []const u8 {
    return Display.getDisplayName(item) orelse Display.getComponentName(item) orelse item.item_type.identifier;
}
