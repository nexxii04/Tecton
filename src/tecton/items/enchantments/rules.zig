const std = @import("std");
const enchantment = @import("enchantment.zig");
const Enchantment = enchantment.Enchantment;
const EnchantmentInstance = enchantment.EnchantmentInstance;
const Slot = enchantment.Slot;
const SlotSet = enchantment.SlotSet;
const Source = enchantment.Source;

const ItemStack = @import("../item-stack.zig").ItemStack;
const ItemType = @import("../item-type.zig").ItemType;
const registry_mod = @import("registry.zig");
const events = @import("../../events/root.zig");
const Player = @import("../../player/player.zig").Player;

pub const Reject = error{
    unknown_enchantment,
    not_applicable,
    not_enchantable,
    conflicts,
    invalid_level,
    too_many,
    rule_vetoed,
    no_registry,
    storage_failure,
};

pub const Options = struct {
    clamp_level: bool = true,
    allow_conflicts: bool = false,
    allow_books: bool = false,
    allow_unsafe: bool = false,
    source: Source = .server,
    actor: ?*Player = null,
    events: ?*events.Events = null,
};

pub const Verdict = union(enum) {
    allow,
    deny,
    modify: u8,
};

pub const Context = struct {
    stack: *const ItemStack,
    definition: *const Enchantment,
    level: u8,
    source: Source,
    actor: ?*Player,
};

pub const Rule = struct {
    /// Diagnostic label; stored as a pointer, so it must outlive the registry.
    id: []const u8,
    priority: i16,
    /// Runs on the tick thread and must only veto or adjust the level it receives.
    callback: *const fn (*Context) Verdict,
    owner_id: u32,
};

const MAX_RULES = 64;

var rule_list: [MAX_RULES]Rule = undefined;
var rule_count: usize = 0;

pub fn registerRule(rule: Rule) !void {
    if (rule_count == MAX_RULES) return error.TooManyEnchantmentRules;
    var index: usize = 0;
    while (index < rule_count and rule_list[index].priority >= rule.priority) : (index += 1) {}
    var cursor: usize = rule_count;
    while (cursor > index) : (cursor -= 1) rule_list[cursor] = rule_list[cursor - 1];
    rule_list[index] = rule;
    rule_count += 1;
}

pub fn unregisterOwner(owner_id: u32) void {
    var index: usize = 0;
    while (index < rule_count) {
        if (rule_list[index].owner_id != owner_id) {
            index += 1;
            continue;
        }
        var cursor = index;
        while (cursor + 1 < rule_count) : (cursor += 1) rule_list[cursor] = rule_list[cursor + 1];
        rule_count -= 1;
    }
}

pub fn registeredRules() usize {
    return rule_count;
}

fn applyRules(context: *Context) Reject!u8 {
    var level = context.level;
    for (rule_list[0..rule_count]) |rule| {
        context.level = level;
        switch (rule.callback(context)) {
            .allow => {},
            .deny => return error.rule_vetoed,
            .modify => |modified| level = modified,
        }
    }
    return level;
}

pub const EXCLUSIVE_PAIRS = [_][2]u16{
    .{ 16, 18 },
    .{ 7, 25 },
    .{ 33, 34 },
    .{ 30, 31 },
    .{ 30, 32 },
    .{ 22, 26 },
};

const DURABLE_ONLY = [_][]const u8{
    "minecraft:flint_and_steel",
    "minecraft:shears",
    "minecraft:brush",
    "minecraft:carrot_on_a_stick",
    "minecraft:warped_fungus_on_a_stick",
};

pub fn slotSetOf(item_type: *const ItemType) SlotSet {
    var slots: SlotSet = .empty;

    if (item_type.hasTag("minecraft:is_sword")) slots.insert(.sword);
    if (item_type.hasTag("minecraft:is_axe")) slots.insert(.axe);
    if (item_type.hasTag("minecraft:is_pickaxe")) slots.insert(.pickaxe);
    if (item_type.hasTag("minecraft:is_shovel")) slots.insert(.shovel);
    if (item_type.hasTag("minecraft:is_hoe")) slots.insert(.hoe);
    if (item_type.hasTag("minecraft:is_spear")) slots.insert(.spear);
    if (item_type.hasTag("minecraft:is_trident")) slots.insert(.trident);

    const identifier = item_type.identifier;
    if (std.mem.endsWith(u8, identifier, "_helmet")) slots.insert(.helmet);
    if (std.mem.endsWith(u8, identifier, "_chestplate")) slots.insert(.chestplate);
    if (std.mem.endsWith(u8, identifier, "_leggings")) slots.insert(.leggings);
    if (std.mem.endsWith(u8, identifier, "_boots")) slots.insert(.boots);
    if (std.mem.eql(u8, identifier, "minecraft:mace")) slots.insert(.mace);
    if (std.mem.eql(u8, identifier, "minecraft:elytra")) slots.insert(.elytra);
    if (std.mem.eql(u8, identifier, "minecraft:shield")) slots.insert(.shield);
    if (std.mem.eql(u8, identifier, "minecraft:bow")) slots.insert(.bow);
    if (std.mem.eql(u8, identifier, "minecraft:crossbow")) slots.insert(.crossbow);
    if (std.mem.eql(u8, identifier, "minecraft:trident")) slots.insert(.trident);
    if (std.mem.eql(u8, identifier, "minecraft:fishing_rod")) slots.insert(.fishing_rod);
    if (std.mem.eql(u8, identifier, "minecraft:book") or std.mem.eql(u8, identifier, "minecraft:enchanted_book")) slots.insert(.book);

    if (slots.contains(.axe) or slots.contains(.pickaxe) or slots.contains(.shovel) or slots.contains(.hoe)) {
        if (!slots.contains(.mace)) slots.insert(.tool_any);
    }

    if (slots.count() > 0 and !slots.contains(.book)) {
        slots.insert(.durable_any);
    } else {
        for (DURABLE_ONLY) |candidate| {
            if (std.mem.eql(u8, identifier, candidate)) {
                slots.insert(.durable_any);
                break;
            }
        }
    }

    return slots;
}

pub fn isBook(item_type: *const ItemType) bool {
    return std.mem.eql(u8, item_type.identifier, "minecraft:book") or
        std.mem.eql(u8, item_type.identifier, "minecraft:enchanted_book");
}

pub fn exclusivePair(first: u16, second: u16) bool {
    for (EXCLUSIVE_PAIRS) |pair| {
        if ((pair[0] == first and pair[1] == second) or (pair[1] == first and pair[0] == second)) return true;
    }
    return false;
}

pub fn conflictsWith(registry: *const registry_mod.Registry, current: []const EnchantmentInstance, definition: *const Enchantment) bool {
    for (current) |entry| {
        if (entry.id == definition.id) continue;
        const other = registry.get(entry.id) orelse continue;
        if (definition.group != 0 and other.group == definition.group) return true;
        if (exclusivePair(other.id, definition.id)) return true;
    }
    return false;
}

pub fn conflictsOf(registry: *const registry_mod.Registry, current: []const EnchantmentInstance, definition: *const Enchantment) ?EnchantmentInstance {
    for (current) |entry| {
        if (entry.id == definition.id) continue;
        const other = registry.get(entry.id) orelse continue;
        if (definition.group != 0 and other.group == definition.group) return entry;
        if (exclusivePair(other.id, definition.id)) return entry;
    }
    return null;
}

pub fn validate(
    registry: *const registry_mod.Registry,
    stack: *const ItemStack,
    definition: *const Enchantment,
    requested: u8,
    opts: Options,
) Reject!u8 {
    if (requested == 0) return error.invalid_level;

    var level = requested;
    if (level > definition.max_level) {
        if (!opts.clamp_level and !opts.allow_unsafe) return error.invalid_level;
        level = definition.max_level;
    }

    if (!opts.allow_unsafe) {
        const item_slots = slotSetOf(stack.item_type);
        if (item_slots.count() == 0) return error.not_enchantable;

        const book_target = opts.allow_books and isBook(stack.item_type);
        if (!book_target and item_slots.intersectWith(definition.slots).count() == 0) return error.not_applicable;

        if (!opts.allow_conflicts and conflictsWith(registry, stack.enchantments.items(), definition)) return error.conflicts;
    }

    var context = Context{
        .stack = stack,
        .definition = definition,
        .level = level,
        .source = opts.source,
        .actor = opts.actor,
    };
    level = try applyRules(&context);

    if (level == 0) return error.invalid_level;

    return @min(level, definition.max_level);
}

pub fn canEnchant(registry: *const registry_mod.Registry, item_type: *const ItemType, id: u16) bool {
    const definition = registry.get(id) orelse return false;
    const item_slots = slotSetOf(item_type);
    if (item_slots.count() == 0) return false;
    return item_slots.intersectWith(definition.slots).count() > 0;
}

const testing = @import("testing.zig");

fn testType(allocator: std.mem.Allocator, identifier: []const u8, tags: []const []const u8, stackable: bool) !*ItemType {
    return testing.itemType(allocator, identifier, tags, stackable);
}

test "slot derivation maps the real tags onto slots" {
    const allocator = std.testing.allocator;

    const sword = try testType(allocator, "minecraft:diamond_sword", &.{ "minecraft:is_sword", "minecraft:is_tool" }, false);
    defer sword.deinit();
    try std.testing.expect(slotSetOf(sword).contains(.sword));
    try std.testing.expect(!slotSetOf(sword).contains(.tool_any));
    try std.testing.expect(slotSetOf(sword).contains(.durable_any));

    const pickaxe = try testType(allocator, "minecraft:diamond_pickaxe", &.{ "minecraft:is_pickaxe", "minecraft:is_tool" }, false);
    defer pickaxe.deinit();
    try std.testing.expect(slotSetOf(pickaxe).contains(.pickaxe));
    try std.testing.expect(slotSetOf(pickaxe).contains(.tool_any));

    const helmet = try testType(allocator, "minecraft:diamond_helmet", &.{"minecraft:is_armor"}, false);
    defer helmet.deinit();
    try std.testing.expect(slotSetOf(helmet).contains(.helmet));
    try std.testing.expect(!slotSetOf(helmet).contains(.leggings));

    const bow = try testType(allocator, "minecraft:bow", &.{}, false);
    defer bow.deinit();
    try std.testing.expect(slotSetOf(bow).contains(.bow));
    try std.testing.expect(slotSetOf(bow).contains(.durable_any));

    const elytra = try testType(allocator, "minecraft:elytra", &.{"minecraft:is_armor"}, false);
    defer elytra.deinit();
    try std.testing.expect(slotSetOf(elytra).contains(.elytra));
    try std.testing.expect(!slotSetOf(elytra).contains(.chestplate));

    const stone = try testType(allocator, "minecraft:stone", &.{}, true);
    defer stone.deinit();
    try std.testing.expectEqual(@as(usize, 0), slotSetOf(stone).count());

    const shears = try testType(allocator, "minecraft:shears", &.{}, false);
    defer shears.deinit();
    try std.testing.expect(slotSetOf(shears).contains(.durable_any));

    const book = try testType(allocator, "minecraft:enchanted_book", &.{}, true);
    defer book.deinit();
    try std.testing.expect(slotSetOf(book).contains(.book));
    try std.testing.expect(!slotSetOf(book).contains(.durable_any));
}

test "validate enforces applicability, conflicts and level" {
    const allocator = std.testing.allocator;
    var registry = registry_mod.Registry.init(allocator);
    defer registry.deinit();
    _ = try registry.loadVanilla();

    const sword = try testType(allocator, "minecraft:diamond_sword", &.{ "minecraft:is_sword", "minecraft:is_tool" }, false);
    defer sword.deinit();
    const pickaxe = try testType(allocator, "minecraft:diamond_pickaxe", &.{ "minecraft:is_pickaxe", "minecraft:is_tool" }, false);
    defer pickaxe.deinit();
    const stone = try testType(allocator, "minecraft:stone", &.{}, true);
    defer stone.deinit();

    var stack = ItemStack.init(allocator, sword, .{});
    defer stack.deinit();

    const sharpness = registry.resolve("sharpness").?;
    const smite = registry.resolve("smite").?;
    const fortune = registry.resolve("fortune").?;
    const silk = registry.resolve("silk_touch").?;
    const efficiency = registry.resolve("efficiency").?;

    try std.testing.expectEqual(@as(u8, 5), try validate(&registry, &stack, sharpness, 5, .{}));
    try std.testing.expect(validate(&registry, &stack, sharpness, 9, .{ .clamp_level = false }) == error.invalid_level);
    try std.testing.expectEqual(@as(u8, 5), try validate(&registry, &stack, sharpness, 9, .{}));
    try std.testing.expect(validate(&registry, &stack, sharpness, 0, .{}) == error.invalid_level);
    try std.testing.expect(validate(&registry, &stack, efficiency, 1, .{}) == error.not_applicable);

    var stone_stack = ItemStack.init(allocator, stone, .{});
    defer stone_stack.deinit();
    try std.testing.expect(validate(&registry, &stone_stack, sharpness, 1, .{}) == error.not_enchantable);

    var tool_stack = ItemStack.init(allocator, pickaxe, .{});
    defer tool_stack.deinit();
    _ = tool_stack.enchantments.set(fortune.id, 3);
    try std.testing.expect(validate(&registry, &tool_stack, silk, 1, .{}) == error.conflicts);
    try std.testing.expectEqual(@as(u8, 1), try validate(&registry, &tool_stack, silk, 1, .{ .allow_conflicts = true }));

    _ = stack.enchantments.set(sharpness.id, 5);
    try std.testing.expect(validate(&registry, &stack, smite, 1, .{}) == error.conflicts);
    try std.testing.expectEqual(@as(usize, 1), stack.enchantments.count());
}

test "rules can deny or modify and can be removed by owner" {
    const allocator = std.testing.allocator;
    var registry = registry_mod.Registry.init(allocator);
    defer registry.deinit();
    _ = try registry.loadVanilla();

    const sword = try testType(allocator, "minecraft:diamond_sword", &.{ "minecraft:is_sword", "minecraft:is_tool" }, false);
    defer sword.deinit();
    var stack = ItemStack.init(allocator, sword, .{});
    defer stack.deinit();
    const sharpness = registry.resolve("sharpness").?;

    const callbacks = struct {
        fn deny(_: *Context) Verdict {
            return .deny;
        }
        fn cap(_: *Context) Verdict {
            return .{ .modify = 1 };
        }
    };

    try registerRule(.{ .id = "test-deny", .priority = 10, .callback = callbacks.deny, .owner_id = 7 });
    try std.testing.expect(validate(&registry, &stack, sharpness, 5, .{}) == error.rule_vetoed);

    unregisterOwner(7);
    try std.testing.expectEqual(@as(u8, 5), try validate(&registry, &stack, sharpness, 5, .{}));

    try registerRule(.{ .id = "test-cap", .priority = 10, .callback = callbacks.cap, .owner_id = 8 });
    try std.testing.expectEqual(@as(u8, 1), try validate(&registry, &stack, sharpness, 5, .{}));
    unregisterOwner(8);
    try std.testing.expectEqual(@as(usize, 0), registeredRules());
}

test "a rule that lowers the level to zero is a rejection, not a hidden removal" {
    const allocator = std.testing.allocator;
    var registry = registry_mod.Registry.init(allocator);
    defer registry.deinit();
    _ = try registry.loadVanilla();

    const sword = try testType(allocator, "minecraft:diamond_sword", &.{ "minecraft:is_sword", "minecraft:is_tool" }, false);
    defer sword.deinit();
    var stack = ItemStack.init(allocator, sword, .{});
    defer stack.deinit();

    const callbacks = struct {
        fn zero(_: *Context) Verdict {
            return .{ .modify = 0 };
        }
    };
    try registerRule(.{ .id = "test-zero", .priority = 10, .callback = callbacks.zero, .owner_id = 9 });
    defer unregisterOwner(9);

    try std.testing.expect(validate(&registry, &stack, registry.resolve("sharpness").?, 5, .{}) == error.invalid_level);
}
