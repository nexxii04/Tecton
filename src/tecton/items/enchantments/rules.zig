const std = @import("std");
const enchantment = @import("enchantment.zig");
const Enchantment = enchantment.Enchantment;
const EnchantmentInstance = enchantment.EnchantmentInstance;
const Slot = enchantment.Slot;
const SlotSet = enchantment.SlotSet;
const Source = enchantment.Source;

const ItemStack = @import("../item_stack.zig").ItemStack;
const ItemType = @import("../item_type.zig").ItemType;
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
    id: []const u8,
    priority: i16,

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

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const ItemStack = test_owner.ItemStack;
    pub const registry_mod = test_owner.registry_mod;
    pub const Verdict = test_owner.Verdict;
    pub const Context = test_owner.Context;
    pub const registerRule = test_owner.registerRule;
    pub const unregisterOwner = test_owner.unregisterOwner;
    pub const registeredRules = test_owner.registeredRules;
    pub const slotSetOf = test_owner.slotSetOf;
    pub const validate = test_owner.validate;
    pub const testing = test_owner.testing;
    pub const testType = test_owner.testType;
};

test "slot derivation maps the real tags onto slots" {
    try @import("rules_test.zig").Suite(test_scope).case_000();
}

test "validate enforces applicability, conflicts and level" {
    try @import("rules_test.zig").Suite(test_scope).case_001();
}

test "rules can deny or modify and can be removed by owner" {
    try @import("rules_test.zig").Suite(test_scope).case_002();
}

test "a rule that lowers the level to zero is a rejection, not a hidden removal" {
    try @import("rules_test.zig").Suite(test_scope).case_003();
}
