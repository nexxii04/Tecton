const std = @import("std");

pub const MAX_ENCHANTMENT_ID: u16 = 255;
pub const MAX_LEVEL: u8 = 255;

comptime {
    std.debug.assert(MAX_ENCHANTMENT_ID <= std.math.maxInt(i16));
    std.debug.assert(MAX_LEVEL <= std.math.maxInt(i16));
}

pub const Slot = enum(u5) {
    sword,
    axe,
    pickaxe,
    shovel,
    hoe,
    spear,
    mace,
    helmet,
    chestplate,
    leggings,
    boots,
    elytra,
    shield,
    bow,
    crossbow,
    trident,
    fishing_rod,
    book,
    tool_any,
    durable_any,
};

pub const SlotSet = std.EnumSet(Slot);

pub const Category = enum(u8) {
    protection,
    damage,
    weapon,
    tool,
    bow,
    crossbow,
    trident,
    fishing,
    armor,
    durability,
    curse,
    other,
};

pub const Source = enum(u8) {
    command,
    anvil,
    enchanting_table,
    loot,
    plugin,
    server,
};

pub const EnchantmentInstance = struct {
    id: u16,
    level: u8,
};

pub const Enchantment = struct {
    id: u16,
    identifier: []const u8,
    name: []const u8,
    max_level: u8,
    category: Category,
    slots: SlotSet,
    group: u8,
    treasure: bool,
    curse: bool,
    anvil_cost: u8,
};
