const std = @import("std");
const enchantment = @import("enchantment.zig");
const Enchantment = enchantment.Enchantment;
const EnchantmentInstance = enchantment.EnchantmentInstance;
const Category = enchantment.Category;
const Source = enchantment.Source;

const ItemStack = @import("../item_stack.zig").ItemStack;
const ItemType = @import("../item_type.zig").ItemType;
const storage = @import("storage.zig");
const EnchantmentStorage = storage.EnchantmentStorage;
const MergeMode = storage.MergeMode;
const registry_mod = @import("registry.zig");
const rules = @import("rules.zig");
const nbt = @import("nbt.zig");
const set_mod = @import("set.zig");
const EnchantmentSet = set_mod.EnchantmentSet;
const events = @import("../../events/root.zig");

pub const Options = rules.Options;
pub const Reject = rules.Reject;
pub const Rule = rules.Rule;
pub const Verdict = rules.Verdict;
pub const RuleContext = rules.Context;

pub const Applied = struct {
    instance: EnchantmentInstance,
    clamped: bool,
};

pub const Outcome = union(enum) {
    applied: Applied,
    unchanged,
    removed: u16,
    rejected: Reject,
};

pub const SetManyReport = struct {
    applied: u8 = 0,
    clamped: u8 = 0,
    rejected: ?Reject = null,
    rejected_id: ?u16 = null,
};

pub const TransferPolicy = struct {
    overwrite_existing: bool = true,
    respect_conflicts: bool = true,
    respect_capacity: bool = true,
};

pub const TransferReport = struct {
    moved: u8 = 0,
    merged: u8 = 0,
    skipped: u8 = 0,
};

pub const AnvilMerge = struct {
    added: u8 = 0,
    upgraded: u8 = 0,
    kept: u8 = 0,
    capped: u8 = 0,
    conflicts: u8 = 0,
    skipped: u8 = 0,
    charge: u32 = 0,
};

fn stage(scratch: *EnchantmentStorage, id: u16, new_level: u8) Reject!void {
    switch (scratch.set(id, new_level)) {
        .full => return error.too_many,
        else => {},
    }
}

fn rollback(stack: *ItemStack, previous: EnchantmentStorage) void {
    stack.enchantments = previous;
    stack.enchantments.dirty = true;
}

fn rejected(reject: Reject, id: ?u16) SetManyReport {
    return .{ .rejected = reject, .rejected_id = id };
}

pub fn isEnchanted(stack: *const ItemStack) bool {
    return !stack.enchantments.isEmpty();
}

pub fn count(stack: *const ItemStack) u8 {
    return stack.enchantments.count();
}

pub fn list(stack: *const ItemStack) []const EnchantmentInstance {
    return stack.enchantments.items();
}

pub fn level(stack: *const ItemStack, id: u16) ?u8 {
    return stack.enchantments.level(id);
}

pub fn has(stack: *const ItemStack, id: u16) bool {
    return stack.enchantments.contains(id);
}

pub fn hasName(stack: *const ItemStack, name: []const u8) bool {
    const registry = registry_mod.ensureGlobal() orelse return false;
    const definition = registry.resolve(name) orelse return false;
    return stack.enchantments.contains(definition.id);
}

pub fn totalLevels(stack: *const ItemStack) u32 {
    var total: u32 = 0;
    for (stack.enchantments.items()) |entry| total += entry.level;
    return total;
}

pub fn matches(stack: *const ItemStack, candidates: *const EnchantmentSet) bool {
    return candidates.matches(&stack.enchantments);
}

pub fn highestOfGroup(stack: *const ItemStack, group: u8) ?EnchantmentInstance {
    if (group == 0) return null;
    const registry = registry_mod.ensureGlobal() orelse return null;
    var best: ?EnchantmentInstance = null;
    for (stack.enchantments.items()) |entry| {
        const definition = registry.get(entry.id) orelse continue;
        if (definition.group != group) continue;
        if (best == null or entry.level > best.?.level) best = entry;
    }
    return best;
}

pub fn highestOfCategory(stack: *const ItemStack, category: Category) ?EnchantmentInstance {
    const registry = registry_mod.ensureGlobal() orelse return null;
    var best: ?EnchantmentInstance = null;
    for (stack.enchantments.items()) |entry| {
        const definition = registry.get(entry.id) orelse continue;
        if (definition.category != category) continue;
        if (best == null or entry.level > best.?.level) best = entry;
    }
    return best;
}

pub fn canEnchant(item_type: *const ItemType, id: u16) bool {
    const registry = registry_mod.ensureGlobal() orelse return false;
    return rules.canEnchant(registry, item_type, id);
}

pub fn enchant(stack: *ItemStack, id: u16, requested_level: u8, opts: Options) Outcome {
    const registry = registry_mod.ensureGlobal() orelse return .{ .rejected = error.no_registry };
    const definition = registry.get(id) orelse return .{ .rejected = error.unknown_enchantment };
    return apply(stack, registry, definition, requested_level, opts);
}

pub fn enchantName(stack: *ItemStack, name: []const u8, requested_level: u8, opts: Options) Outcome {
    const registry = registry_mod.ensureGlobal() orelse return .{ .rejected = error.no_registry };
    const definition = registry.resolve(name) orelse return .{ .rejected = error.unknown_enchantment };
    return apply(stack, registry, definition, requested_level, opts);
}

pub fn addLevels(stack: *ItemStack, id: u16, delta: u8, opts: Options) Outcome {
    const registry = registry_mod.ensureGlobal() orelse return .{ .rejected = error.no_registry };
    const definition = registry.get(id) orelse return .{ .rejected = error.unknown_enchantment };
    const current: u32 = stack.enchantments.level(id) orelse 0;
    const target = current + delta;
    if (target == 0) return .{ .rejected = error.invalid_level };
    const target_level: u8 = @intCast(@min(target, definition.max_level));
    return apply(stack, registry, definition, target_level, opts);
}

fn apply(
    stack: *ItemStack,
    registry: *const registry_mod.Registry,
    definition: *const Enchantment,
    requested: u8,
    opts: Options,
) Outcome {
    if (requested == 0) return remove(stack, definition.id, opts);

    var resolved = rules.validate(registry, stack, definition, requested, opts) catch |reject| {
        return .{ .rejected = reject };
    };

    const before = stack.enchantments;
    const previous = before.level(definition.id);

    if (opts.events) |bus| {
        var event = events.types.EnchantmentApplyEvent{
            .stack = stack,
            .definition = definition,
            .previous_level = previous,
            .level = resolved,
            .source = opts.source,
            .actor = opts.actor,
        };
        if (!bus.emit(.EnchantmentApply, &event)) return .{ .rejected = error.rule_vetoed };
        if (event.level != resolved) {
            resolved = rules.validate(registry, stack, definition, event.level, opts) catch |reject| {
                return .{ .rejected = reject };
            };
        }
    }

    switch (stack.enchantments.set(definition.id, resolved)) {
        .full => return .{ .rejected = error.too_many },
        .unchanged => return .unchanged,
        .inserted, .updated => {},
        .removed => return .{ .removed = definition.id },
    }

    nbt.sync(stack) catch {
        rollback(stack, before);
        return .{ .rejected = error.storage_failure };
    };

    return .{ .applied = .{
        .instance = .{ .id = definition.id, .level = resolved },
        .clamped = resolved < requested,
    } };
}

pub fn remove(stack: *ItemStack, id: u16, opts: Options) Outcome {
    const before = stack.enchantments;
    const previous = before.level(id) orelse return .unchanged;

    if (opts.events) |bus| {
        const registry = registry_mod.ensureGlobal();
        var event = events.types.EnchantmentRemoveEvent{
            .stack = stack,
            .definition = if (registry) |owned| owned.get(id) else null,
            .definition_id = id,
            .previous_level = previous,
            .source = opts.source,
            .actor = opts.actor,
        };
        if (!bus.emit(.EnchantmentRemove, &event)) return .{ .rejected = error.rule_vetoed };
    }

    if (!stack.enchantments.remove(id)) return .unchanged;
    nbt.sync(stack) catch {
        rollback(stack, before);
        return .{ .rejected = error.storage_failure };
    };
    return .{ .removed = id };
}

pub fn clear(stack: *ItemStack) Reject!u8 {
    const before = stack.enchantments;
    const removed = before.count();
    if (removed == 0) return 0;
    stack.enchantments.clear();
    nbt.sync(stack) catch {
        rollback(stack, before);
        return error.storage_failure;
    };
    return removed;
}

pub fn setMany(stack: *ItemStack, items: []const EnchantmentInstance, mode: MergeMode, opts: Options) SetManyReport {
    const registry = registry_mod.ensureGlobal() orelse return .{ .rejected = error.no_registry };
    const before = stack.enchantments;

    var scratch: EnchantmentStorage = if (mode == .replace) .{} else stack.enchantments;
    var report = SetManyReport{};

    for (items) |item| {
        if (item.level == 0) continue;
        const definition = registry.get(item.id) orelse return rejected(error.unknown_enchantment, item.id);

        const existing = scratch.level(item.id);
        if (mode == .keep_existing and existing != null) continue;

        var probe = stack.*;
        probe.enchantments = scratch;

        var requested = item.level;
        if (mode == .merge) {
            if (existing) |current| {
                const total = @as(u32, current) + item.level;
                requested = @intCast(@min(total, @as(u32, definition.max_level)));
            }
        }

        const resolved = rules.validate(registry, &probe, definition, requested, opts) catch |reject| {
            return rejected(reject, item.id);
        };

        if (opts.events) |bus| {
            var event = events.types.EnchantmentApplyEvent{
                .stack = stack,
                .definition = definition,
                .previous_level = existing,
                .level = resolved,
                .source = opts.source,
                .actor = opts.actor,
            };
            if (!bus.emit(.EnchantmentApply, &event)) return rejected(error.rule_vetoed, item.id);
            if (event.level != resolved) {
                const revalidated = rules.validate(registry, &probe, definition, event.level, opts) catch |reject| {
                    return rejected(reject, item.id);
                };
                stage(&scratch, item.id, revalidated) catch |reject| return rejected(reject, item.id);
                report.applied += 1;
                if (revalidated < item.level) report.clamped += 1;
                continue;
            }
        }

        stage(&scratch, item.id, resolved) catch |reject| return rejected(reject, item.id);
        report.applied += 1;
        if (resolved < item.level) report.clamped += 1;
    }

    if (!stack.enchantments.eql(&scratch)) {
        stack.enchantments.copyFrom(&scratch);
        stack.enchantments.dirty = true;
        nbt.sync(stack) catch {
            rollback(stack, before);
            return rejected(error.storage_failure, null);
        };
    }

    return report;
}

pub fn absorb(stack: *ItemStack, other: *const ItemStack, policy: TransferPolicy) Reject!TransferReport {
    return absorbInto(stack, other, policy, null);
}

fn absorbInto(
    stack: *ItemStack,
    other: *const ItemStack,
    policy: TransferPolicy,
    landed: ?*EnchantmentSet,
) Reject!TransferReport {
    const registry = registry_mod.ensureGlobal() orelse return error.no_registry;
    const before = stack.enchantments;
    var report = TransferReport{};
    var changed = false;

    for (other.enchantments.items()) |entry| {
        const definition = registry.get(entry.id) orelse {
            report.skipped += 1;
            continue;
        };

        const existing = stack.enchantments.level(entry.id);
        if (existing) |current| {
            if (!policy.overwrite_existing) {
                report.skipped += 1;
                continue;
            }
            const combined: u8 = @intCast(@min(@as(u32, current) + entry.level, @as(u32, definition.max_level)));
            if (combined != current) {
                _ = stack.enchantments.set(entry.id, combined);
                if (landed) |ids| ids.add(entry.id);
                changed = true;
                report.merged += 1;
            } else {
                report.skipped += 1;
            }
            continue;
        }

        if (policy.respect_conflicts and rules.conflictsWith(registry, stack.enchantments.items(), definition)) {
            report.skipped += 1;
            continue;
        }
        if (policy.respect_capacity and stack.enchantments.count() == storage.MAX_ENCHANTMENTS) {
            report.skipped += 1;
            continue;
        }

        if (stack.enchantments.set(entry.id, @min(entry.level, definition.max_level)) == .full) {
            report.skipped += 1;
            continue;
        }
        if (landed) |ids| ids.add(entry.id);
        changed = true;
        report.moved += 1;
    }

    if (changed) {
        stack.enchantments.dirty = true;
        nbt.sync(stack) catch {
            rollback(stack, before);
            return error.storage_failure;
        };
    }
    return report;
}

pub fn transferTo(source: *ItemStack, target: *ItemStack, policy: TransferPolicy) Reject!TransferReport {
    const target_before = target.enchantments;
    const source_before = source.enchantments;

    var landed: EnchantmentSet = .empty;
    const report = try absorbInto(target, source, policy, &landed);

    var removed_any = false;
    var index = source.enchantments.count();
    while (index > 0) {
        index -= 1;
        const id = source.enchantments.items()[index].id;
        if (!landed.contains(id)) continue;
        _ = source.enchantments.remove(id);
        removed_any = true;
    }

    if (!removed_any) return report;

    source.enchantments.dirty = true;
    nbt.sync(source) catch {
        rollback(source, source_before);
        rollback(target, target_before);
        return error.storage_failure;
    };
    return report;
}

pub fn copyTo(source: *const ItemStack, target: *ItemStack, policy: TransferPolicy) Reject!TransferReport {
    return absorbInto(target, source, policy, null);
}

pub fn mergeForAnvil(target: *ItemStack, sacrifice: *const ItemStack) Reject!AnvilMerge {
    const registry = registry_mod.ensureGlobal() orelse return error.no_registry;
    const before = target.enchantments;
    var report = AnvilMerge{};
    var changed = false;

    var incoming: [storage.MAX_ENCHANTMENTS]EnchantmentInstance = undefined;
    const entry_count = sacrifice.enchantments.count();
    @memcpy(incoming[0..entry_count], sacrifice.enchantments.items());

    for (incoming[0..entry_count]) |entry| {
        const definition = registry.get(entry.id) orelse {
            report.skipped += 1;
            continue;
        };

        if (target.enchantments.level(entry.id)) |current| {
            const combined: u8 = if (current == entry.level)
                @intCast(@min(@as(u32, current) + 1, @as(u32, definition.max_level)))
            else
                @max(current, entry.level);

            if (combined == current) {
                if (current == definition.max_level) {
                    report.capped += 1;
                } else {
                    report.kept += 1;
                }
                continue;
            }

            if (target.enchantments.set(entry.id, combined) == .full) return error.too_many;
            report.charge += @as(u32, definition.anvil_cost) * @as(u32, combined - current);
            report.upgraded += 1;
            changed = true;
            continue;
        }

        if (rules.conflictsWith(registry, target.enchantments.items(), definition)) {
            report.conflicts += 1;
            continue;
        }
        if (target.enchantments.count() == storage.MAX_ENCHANTMENTS) {
            report.skipped += 1;
            continue;
        }

        const landing: u8 = @min(entry.level, definition.max_level);
        if (target.enchantments.set(entry.id, landing) == .full) {
            report.skipped += 1;
            continue;
        }
        report.charge += @as(u32, definition.anvil_cost) * @as(u32, landing);
        report.added += 1;
        changed = true;
    }

    if (changed) {
        target.enchantments.dirty = true;
        nbt.sync(target) catch {
            rollback(target, before);
            return error.storage_failure;
        };
    }
    return report;
}

pub fn syncNbt(stack: *ItemStack) Reject!void {
    nbt.sync(stack) catch return error.storage_failure;
}

pub fn hydrate(stack: *ItemStack) void {
    nbt.hydrate(stack);
}

pub fn rejectName(reject: Reject) []const u8 {
    return @errorName(reject);
}

const native_testing = @import("testing.zig");
const display_module = @import("../traits/display.zig");

fn testStack(allocator: std.mem.Allocator, identifier: []const u8, sword: bool) !ItemStack {
    const item_type = if (sword)
        try native_testing.sword(allocator, identifier)
    else
        try native_testing.pickaxe(allocator, identifier);
    return ItemStack.init(allocator, item_type, .{});
}

fn expectReject(outcome: Outcome, expected: Reject) !void {
    switch (outcome) {
        .rejected => |reject| try std.testing.expectEqual(expected, reject),
        else => return error.ExpectedRejection,
    }
}

fn enchantedKey(stack: *const ItemStack) bool {
    const tag_compound = display_module.getTagCompound(stack) orelse return false;
    return tag_compound.get(nbt.KEY) != null;
}

fn levelOf(stack: *const ItemStack, id: u16) ?u8 {
    return stack.enchantments.level(id);
}

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const enchantment = test_owner.enchantment;
    pub const EnchantmentInstance = test_owner.EnchantmentInstance;
    pub const ItemStack = test_owner.ItemStack;
    pub const storage = test_owner.storage;
    pub const registry_mod = test_owner.registry_mod;
    pub const nbt = test_owner.nbt;
    pub const EnchantmentSet = test_owner.EnchantmentSet;
    pub const events = test_owner.events;
    pub const Options = test_owner.Options;
    pub const Reject = test_owner.Reject;
    pub const rejected = test_owner.rejected;
    pub const isEnchanted = test_owner.isEnchanted;
    pub const count = test_owner.count;
    pub const level = test_owner.level;
    pub const has = test_owner.has;
    pub const hasName = test_owner.hasName;
    pub const totalLevels = test_owner.totalLevels;
    pub const matches = test_owner.matches;
    pub const highestOfGroup = test_owner.highestOfGroup;
    pub const highestOfCategory = test_owner.highestOfCategory;
    pub const canEnchant = test_owner.canEnchant;
    pub const enchant = test_owner.enchant;
    pub const enchantName = test_owner.enchantName;
    pub const addLevels = test_owner.addLevels;
    pub const remove = test_owner.remove;
    pub const clear = test_owner.clear;
    pub const setMany = test_owner.setMany;
    pub const absorb = test_owner.absorb;
    pub const transferTo = test_owner.transferTo;
    pub const copyTo = test_owner.copyTo;
    pub const syncNbt = test_owner.syncNbt;
    pub const native_testing = test_owner.native_testing;
    pub const testStack = test_owner.testStack;
    pub const expectReject = test_owner.expectReject;
    pub const enchantedKey = test_owner.enchantedKey;
    pub const levelOf = test_owner.levelOf;
};

test "enchant applies, replaces, clamps and reports every rejection" {
    try @import("ops_test.zig").Suite(test_scope).case_000();
}

test "addLevels tops up an existing enchantment" {
    try @import("ops_test.zig").Suite(test_scope).case_001();
}

test "remove and clear keep the nbt block in sync" {
    try @import("ops_test.zig").Suite(test_scope).case_002();
}

test "the removal reaches the wire with nothing left to paint" {
    try @import("ops_test.zig").Suite(test_scope).case_003();
}

test "setMany validates the whole batch before touching the item" {
    try @import("ops_test.zig").Suite(test_scope).case_004();
}

test "a batch that would overflow the cap is rejected whole" {
    try @import("ops_test.zig").Suite(test_scope).case_005();
}

test "an operation that cannot write its nbt is rolled back" {
    try @import("ops_test.zig").Suite(test_scope).case_006();
}

test "a transfer leaves behind what the target refused" {
    try @import("ops_test.zig").Suite(test_scope).case_007();
}

test "a transfer takes off every id that landed, not every other one" {
    try @import("ops_test.zig").Suite(test_scope).case_008();
}

test "a transfer that moves nothing leaves the source untouched" {
    try @import("ops_test.zig").Suite(test_scope).case_009();
}

test "events can veto an application" {
    try @import("ops_test.zig").Suite(test_scope).case_010();
}

test "events can rewrite the requested level" {
    try @import("ops_test.zig").Suite(test_scope).case_011();
}

test "absorb merges, skips conflicts and transferTo drains the source" {
    try @import("ops_test.zig").Suite(test_scope).case_012();
}
