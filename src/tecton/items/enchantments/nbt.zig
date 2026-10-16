const std = @import("std");
const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const ListTag = NBT.ListTag;
const ShortTag = NBT.ShortTag;
const Tag = NBT.Tag;

const ItemStack = @import("../item_stack.zig").ItemStack;
const display = @import("../traits/display.zig");
const storage = @import("storage.zig");
const registry_mod = @import("registry.zig");

pub const KEY = "ench";
pub const ID_KEY = "id";
pub const LEVEL_KEY = "lvl";

pub fn sync(stack: *ItemStack) !void {
    if (!stack.enchantments.dirty) return;

    const allocator = stack.allocator;
    const tag_compound = try display.ensureTagCompound(stack);

    if (tag_compound.value.fetchRemove(KEY)) |removed| {
        var previous = removed.value;
        previous.deinit(allocator);
    }

    const entries = stack.enchantments.items();
    if (entries.len == 0) {
        stack.enchantments.dirty = false;
        return;
    }

    const tags = try allocator.alloc(Tag, entries.len);
    errdefer allocator.free(tags);

    var built: usize = 0;
    errdefer for (tags[0..built]) |*tag| tag.deinit(allocator);

    for (entries, 0..) |entry, index| {
        var compound = CompoundTag.init(allocator, null);
        errdefer compound.deinit(allocator);
        try compound.set(ID_KEY, .{ .Short = ShortTag.init(@intCast(entry.id), null) });
        try compound.set(LEVEL_KEY, .{ .Short = ShortTag.init(@intCast(entry.level), null) });
        tags[index] = .{ .Compound = compound };
        built = index + 1;
    }

    try tag_compound.set(KEY, .{ .List = ListTag.init(tags, null) });
    stack.enchantments.dirty = false;
}

pub fn hydrate(stack: *ItemStack) void {
    stack.enchantments.len = 0;
    stack.enchantments.dirty = false;

    const tag_compound = display.getTagCompound(stack) orelse return;
    const ench = tag_compound.get(KEY) orelse return;
    if (ench != .List) {
        stack.enchantments.dirty = true;
        return;
    }

    const entries = ench.List.value;
    if (entries.len > storage.MAX_ENCHANTMENTS) {
        stack.enchantments.dirty = true;
        return;
    }

    const registry = registry_mod.ensureGlobal() orelse return;

    var repaired = false;
    for (entries) |*entry| {
        if (entry.* != .Compound) {
            repaired = true;
            continue;
        }
        const id_value = shortValue(entry.Compound.get(ID_KEY)) orelse {
            repaired = true;
            continue;
        };
        const level_value = shortValue(entry.Compound.get(LEVEL_KEY)) orelse {
            repaired = true;
            continue;
        };
        if (id_value < 0 or level_value <= 0) {
            repaired = true;
            continue;
        }
        const id: u16 = @intCast(id_value);
        const definition = registry.get(id) orelse {
            repaired = true;
            continue;
        };
        const level: u8 = @intCast(@min(level_value, @as(i64, definition.max_level)));
        if (@as(i64, level) != level_value) repaired = true;
        const existing = stack.enchantments.level(id) orelse 0;
        if (level > existing) {
            _ = stack.enchantments.set(id, level);
        } else {
            repaired = true;
        }
    }

    if (entries.len != @as(usize, stack.enchantments.count())) repaired = true;
    stack.enchantments.dirty = repaired;
}

fn shortValue(tag: ?Tag) ?i64 {
    const value = tag orelse return null;
    return switch (value) {
        .Short => |short| short.value,
        else => null,
    };
}

const testing = @import("testing.zig");
const EnchantmentInstance = @import("enchantment.zig").EnchantmentInstance;

fn testStack(allocator: std.mem.Allocator, identifier: []const u8) !ItemStack {
    const item_type = try testing.sword(allocator, identifier);
    return ItemStack.init(allocator, item_type, .{});
}

test "sync writes the ench list and hydrate reads it back" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_nbt_roundtrip");
    defer stack.deinit();
    defer stack.item_type.deinit();

    _ = stack.enchantments.set(9, 5);
    _ = stack.enchantments.set(26, 1);
    try sync(&stack);
    try std.testing.expect(!stack.enchantments.dirty);

    const tag_compound = display.getTagCompound(&stack).?;
    const ench = tag_compound.get(KEY).?;
    try std.testing.expect(ench == .List);
    try std.testing.expectEqual(@as(usize, 2), ench.List.value.len);
    try std.testing.expect(ench.List.value[0] == .Compound);
    try std.testing.expectEqual(@as(i16, 9), ench.List.value[0].Compound.get(ID_KEY).?.Short.value);
    try std.testing.expectEqual(@as(i16, 5), ench.List.value[0].Compound.get(LEVEL_KEY).?.Short.value);

    stack.enchantments.len = 0;
    hydrate(&stack);
    try std.testing.expectEqual(@as(u8, 5), stack.enchantments.level(9).?);
    try std.testing.expectEqual(@as(u8, 1), stack.enchantments.level(26).?);
    try std.testing.expectEqual(@as(u8, 2), stack.enchantments.count());
    try std.testing.expect(!stack.enchantments.dirty);
}

test "sync is a no-op when the storage is clean" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_nbt_clean");
    defer stack.deinit();
    defer stack.item_type.deinit();

    _ = stack.enchantments.set(9, 5);
    try sync(&stack);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var probe = ItemStack{
        .allocator = failing.allocator(),
        .item_type = stack.item_type,
        .stack_size = stack.stack_size,
        .metadata = stack.metadata,
        .nbt = stack.nbt,
        .network_stack_id = stack.network_stack_id,
        .traits = .empty,
        .enchantments = stack.enchantments,
    };
    probe.enchantments.dirty = false;
    try sync(&probe);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "sync removes the ench key once the storage is empty" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_nbt_removal");
    defer stack.deinit();
    defer stack.item_type.deinit();

    _ = stack.enchantments.set(9, 5);
    try sync(&stack);
    try std.testing.expect(display.getTagCompound(&stack).?.get(KEY) != null);

    stack.enchantments.clear();
    try sync(&stack);
    try std.testing.expect(display.getTagCompound(&stack).?.get(KEY) == null);
    try std.testing.expect(!stack.enchantments.dirty);
}

test "hydrate sanitizes unknown ids, duplicate levels and out of range values" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_nbt_sanitize");
    defer stack.deinit();
    defer stack.item_type.deinit();

    stack.nbt = try testing.enchantedNbt(allocator, &.{
        .{ .id = 999, .level = 2 },
        .{ .id = 9, .level = 99 },
        .{ .id = 9, .level = 2 },
        .{ .id = 26, .level = 0 },
        .{ .id = 0, .level = 2 },
    });
    hydrate(&stack);

    try std.testing.expectEqual(@as(u8, 5), stack.enchantments.level(9).?);
    try std.testing.expect(stack.enchantments.level(999) == null);
    try std.testing.expect(stack.enchantments.level(26) == null);
    try std.testing.expectEqual(@as(u8, 2), stack.enchantments.level(0).?);
    try std.testing.expectEqual(@as(u8, 2), stack.enchantments.count());
}

test "a sanitized payload is rewritten instead of kept" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_nbt_repair");
    defer stack.deinit();
    defer stack.item_type.deinit();

    stack.nbt = try testing.enchantedNbt(allocator, &.{
        .{ .id = 9, .level = 99 },
        .{ .id = 9, .level = 2 },
    });
    hydrate(&stack);
    try std.testing.expectEqual(@as(u8, 1), stack.enchantments.count());
    try std.testing.expectEqual(@as(u8, 5), stack.enchantments.level(9).?);
    try std.testing.expect(stack.enchantments.dirty);

    try sync(&stack);
    const ench = display.getTagCompound(&stack).?.get(KEY).?;
    try std.testing.expect(ench == .List);
    try std.testing.expectEqual(@as(usize, 1), ench.List.value.len);
    try std.testing.expectEqual(@as(i16, 5), ench.List.value[0].Compound.get(LEVEL_KEY).?.Short.value);
    try std.testing.expect(!stack.enchantments.dirty);
}

test "hydrate ignores malformed ench payloads" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_nbt_malformed");
    defer stack.deinit();
    defer stack.item_type.deinit();

    var tag_compound = CompoundTag.init(allocator, null);
    try tag_compound.set(KEY, .{ .Int = NBT.IntTag.init(7, null) });
    var root = CompoundTag.init(allocator, null);
    try root.set("tag", .{ .Compound = tag_compound });
    stack.nbt = root;
    hydrate(&stack);
    try std.testing.expectEqual(@as(u8, 0), stack.enchantments.count());

    var overloaded: [storage.MAX_ENCHANTMENTS + 1]EnchantmentInstance = undefined;
    for (&overloaded, 0..) |*entry, index| entry.* = .{ .id = @intCast(index), .level = 1 };
    const excess = try testing.enchantedNbt(allocator, &overloaded);
    stack.nbt.?.deinit(allocator);
    stack.nbt = excess;
    hydrate(&stack);
    try std.testing.expectEqual(@as(u8, 0), stack.enchantments.count());
}

test "sync keeps the ench payload stable across repeated writes" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_nbt_stable");
    defer stack.deinit();
    defer stack.item_type.deinit();

    _ = stack.enchantments.set(9, 5);
    _ = stack.enchantments.set(17, 3);
    try sync(&stack);
    const first = display.getTagCompound(&stack).?.get(KEY).?.List.value.len;

    stack.enchantments.dirty = true;
    try sync(&stack);
    const second = display.getTagCompound(&stack).?.get(KEY).?.List.value.len;

    try std.testing.expectEqual(@as(usize, 2), first);
    try std.testing.expectEqual(first, second);
}
