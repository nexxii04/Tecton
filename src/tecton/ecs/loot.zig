const std = @import("std");
const Protocol = @import("protocol");
const ItemStack = @import("../items/item_stack.zig").ItemStack;
const ItemType = @import("../items/item_type.zig").ItemType;

pub const Drop = struct {
    identifier: []const u8,
    min: u16,
    max: u16,
    weight: u32 = 1,
};

pub const Table = struct {
    identifier: []const u8,
    drops: []const Drop,
};

pub const tables = [_]Table{
    .{ .identifier = "minecraft:zombie", .drops = &.{.{ .identifier = "minecraft:rotten_flesh", .min = 0, .max = 2 }} },
    .{ .identifier = "minecraft:skeleton", .drops = &.{
        .{ .identifier = "minecraft:bone", .min = 0, .max = 2 },
        .{ .identifier = "minecraft:arrow", .min = 0, .max = 2 },
    } },
    .{ .identifier = "minecraft:creeper", .drops = &.{.{ .identifier = "minecraft:gunpowder", .min = 0, .max = 2 }} },
    .{ .identifier = "minecraft:spider", .drops = &.{.{ .identifier = "minecraft:string", .min = 0, .max = 2 }} },
    .{ .identifier = "minecraft:enderman", .drops = &.{.{ .identifier = "minecraft:ender_pearl", .min = 0, .max = 1 }} },
    .{ .identifier = "minecraft:slime", .drops = &.{.{ .identifier = "minecraft:slime_ball", .min = 0, .max = 2 }} },
    .{ .identifier = "minecraft:blaze", .drops = &.{.{ .identifier = "minecraft:blaze_rod", .min = 0, .max = 1 }} },
    .{ .identifier = "minecraft:witch", .drops = &.{.{ .identifier = "minecraft:glass_bottle", .min = 0, .max = 2 }} },
    .{ .identifier = "minecraft:cow", .drops = &.{
        .{ .identifier = "minecraft:leather", .min = 0, .max = 2 },
        .{ .identifier = "minecraft:raw_beef", .min = 1, .max = 3 },
    } },
    .{ .identifier = "minecraft:pig", .drops = &.{.{ .identifier = "minecraft:raw_porkchop", .min = 1, .max = 3 }} },
    .{ .identifier = "minecraft:sheep", .drops = &.{.{ .identifier = "minecraft:wool", .min = 1, .max = 1 }} },
    .{ .identifier = "minecraft:chicken", .drops = &.{
        .{ .identifier = "minecraft:feather", .min = 0, .max = 2 },
        .{ .identifier = "minecraft:raw_chicken", .min = 1, .max = 1 },
    } },
    .{ .identifier = "minecraft:rabbit", .drops = &.{
        .{ .identifier = "minecraft:rabbit_hide", .min = 0, .max = 1 },
        .{ .identifier = "minecraft:raw_rabbit", .min = 0, .max = 1 },
    } },
};

pub fn tableIndexFor(identifier: []const u8) u32 {
    for (tables, 0..) |table, i| {
        if (std.mem.eql(u8, table.identifier, identifier)) return @intCast(i + 1);
    }
    return 0;
}

pub fn tableAt(index: u32) ?*const Table {
    if (index == 0 or index > tables.len) return null;
    return &tables[index - 1];
}

pub const Roll = struct {
    identifier: []const u8,
    count: u16,
};

pub const RollBuffer = struct {
    entries: [8]Roll = undefined,
    len: usize = 0,

    pub fn slice(self: *const RollBuffer) []const Roll {
        return self.entries[0..self.len];
    }
};

pub fn rollTable(table: *const Table, random: std.Random, buffer: *RollBuffer) void {
    buffer.len = 0;
    for (table.drops) |drop| {
        const span = drop.max - drop.min;
        const count = drop.min + (if (span == 0) 0 else random.intRangeAtMost(u16, 0, span));
        if (count == 0 or buffer.len >= buffer.entries.len) continue;
        buffer.entries[buffer.len] = .{ .identifier = drop.identifier, .count = count };
        buffer.len += 1;
    }
}

pub fn stackOf(allocator: std.mem.Allocator, roll: Roll) ?ItemStack {
    const item_type = ItemType.get(roll.identifier) orelse return null;
    return ItemStack.init(allocator, item_type, .{ .stack_size = roll.count });
}

test "loot tables resolve by identifier index" {
    try std.testing.expectEqual(@as(u32, 0), tableIndexFor("minecraft:unknown_mob"));
    const zombie = tableIndexFor("minecraft:zombie");
    try std.testing.expect(zombie > 0);
    try std.testing.expectEqualStrings("minecraft:zombie", tableAt(zombie).?.identifier);
    try std.testing.expect(tableAt(0) == null);
}

test "rolling a table yields bounded stacks" {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    var buffer = RollBuffer{};

    const cow = tableIndexFor("minecraft:cow");
    rollTable(tableAt(cow).?, prng.random(), &buffer);
    try std.testing.expect(buffer.len > 0);
    for (buffer.slice()) |entry| {
        try std.testing.expect(entry.count > 0);
        try std.testing.expect(entry.count <= 3);
    }

    for (0..64) |_| {
        rollTable(tableAt(cow).?, prng.random(), &buffer);
        try std.testing.expect(buffer.len <= 2);
    }
}
