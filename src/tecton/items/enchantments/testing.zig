const std = @import("std");
const NBT = @import("nbt");
const ItemType = @import("../item_type.zig").ItemType;
const EnchantmentInstance = @import("enchantment.zig").EnchantmentInstance;
const Tag = NBT.Tag;
const CompoundTag = NBT.CompoundTag;
const ListTag = NBT.ListTag;
const ShortTag = NBT.ShortTag;

pub fn itemType(allocator: std.mem.Allocator, identifier: []const u8, tags: []const []const u8, stackable: bool) !*ItemType {
    const owned_tags = try allocator.alloc([]const u8, tags.len);
    for (tags, 0..) |tag, index| owned_tags[index] = try allocator.dupe(u8, tag);
    return ItemType.init(
        allocator,
        try allocator.dupe(u8, identifier),
        1,
        if (stackable) 64 else 1,
        stackable,
        owned_tags,
        false,
        0,
        .{ .Compound = CompoundTag.init(allocator, null) },
    );
}

pub fn sword(allocator: std.mem.Allocator, identifier: []const u8) !*ItemType {
    return itemType(allocator, identifier, &.{ "minecraft:is_sword", "minecraft:is_tool" }, false);
}

pub fn pickaxe(allocator: std.mem.Allocator, identifier: []const u8) !*ItemType {
    return itemType(allocator, identifier, &.{ "minecraft:is_pickaxe", "minecraft:is_tool" }, false);
}

pub fn stone(allocator: std.mem.Allocator, identifier: []const u8) !*ItemType {
    return itemType(allocator, identifier, &.{}, true);
}

pub fn enchantedNbt(allocator: std.mem.Allocator, entries: []const EnchantmentInstance) !CompoundTag {
    return enchantedNbtKeyed(allocator, "ench", entries);
}

pub fn enchantedNbtKeyed(allocator: std.mem.Allocator, key: []const u8, entries: []const EnchantmentInstance) !CompoundTag {
    var tag_compound = CompoundTag.init(allocator, null);
    const tags = try allocator.alloc(Tag, entries.len);
    for (entries, 0..) |entry, index| {
        var compound = CompoundTag.init(allocator, null);
        try compound.set("id", .{ .Short = ShortTag.init(@intCast(entry.id), null) });
        try compound.set("lvl", .{ .Short = ShortTag.init(@intCast(entry.level), null) });
        tags[index] = .{ .Compound = compound };
    }
    try tag_compound.set(key, .{ .List = ListTag.init(tags, null) });
    var root = CompoundTag.init(allocator, null);
    try root.set("tag", .{ .Compound = tag_compound });
    return root;
}
