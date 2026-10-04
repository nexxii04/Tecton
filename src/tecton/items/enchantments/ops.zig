const std = @import("std");
const enchantment = @import("enchantment.zig");
const Enchantment = enchantment.Enchantment;
const EnchantmentInstance = enchantment.EnchantmentInstance;
const Category = enchantment.Category;
const Source = enchantment.Source;

const ItemStack = @import("../item-stack.zig").ItemStack;
const ItemType = @import("../item-type.zig").ItemType;
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

test "enchant applies, replaces, clamps and reports every rejection" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();
    const registry = registry_mod.global().?;

    var stack = try testStack(allocator, "minecraft:test_api_sword", true);
    defer stack.deinit();
    defer stack.item_type.deinit();

    const sharpness = registry.resolve("sharpness").?;
    const smite = registry.resolve("smite").?;
    const efficiency = registry.resolve("efficiency").?;
    const mending = registry.resolve("mending").?;

    switch (enchant(&stack, sharpness.id, 3, .{})) {
        .applied => |applied| {
            try std.testing.expectEqual(@as(u8, 3), applied.instance.level);
            try std.testing.expect(!applied.clamped);
        },
        else => return error.ExpectedApplied,
    }
    try std.testing.expectEqual(@as(u8, 3), levelOf(&stack, sharpness.id).?);
    try std.testing.expect(enchantedKey(&stack));

    try std.testing.expect(enchant(&stack, sharpness.id, 5, .{}) == .applied);
    try std.testing.expectEqual(@as(u8, 1), count(&stack));
    try std.testing.expect(enchant(&stack, sharpness.id, 5, .{}) == .unchanged);
    try std.testing.expect(enchant(&stack, sharpness.id, 9, .{}) == .unchanged);

    try std.testing.expect(remove(&stack, sharpness.id, .{}) == .removed);
    switch (enchant(&stack, sharpness.id, 9, .{})) {
        .applied => |applied| {
            try std.testing.expectEqual(@as(u8, 5), applied.instance.level);
            try std.testing.expect(applied.clamped);
        },
        else => return error.ExpectedApplied,
    }
    try expectReject(enchant(&stack, sharpness.id, 9, .{ .clamp_level = false }), error.invalid_level);
    try std.testing.expect(enchant(&stack, sharpness.id, 0, .{}) == .removed);
    try std.testing.expectEqual(@as(u8, 0), count(&stack));
    try std.testing.expect(!enchantedKey(&stack));
    try std.testing.expect(enchant(&stack, sharpness.id, 5, .{}) == .applied);
    try expectReject(enchant(&stack, 999, 1, .{}), error.unknown_enchantment);
    try expectReject(enchant(&stack, efficiency.id, 1, .{}), error.not_applicable);
    try expectReject(enchant(&stack, smite.id, 1, .{}), error.conflicts);

    try std.testing.expectEqual(@as(u8, 1), count(&stack));

    switch (enchant(&stack, smite.id, 1, .{ .allow_conflicts = true })) {
        .applied => |applied| try std.testing.expectEqual(@as(u8, 1), applied.instance.level),
        else => return error.ExpectedApplied,
    }
    try std.testing.expectEqual(@as(u8, 2), count(&stack));

    try std.testing.expect(hasName(&stack, "smite"));
    try std.testing.expect(has(&stack, mending.id) == false);
    try std.testing.expectEqual(@as(u32, 6), totalLevels(&stack));
    try std.testing.expectEqual(sharpness.id, highestOfGroup(&stack, 2).?.id);
    try std.testing.expectEqual(@as(?EnchantmentInstance, null), highestOfGroup(&stack, 0));
    try std.testing.expectEqual(sharpness.id, highestOfCategory(&stack, sharpness.category).?.id);
    try std.testing.expect(matches(&stack, &EnchantmentSet.fromIds(&.{smite.id})));
    try std.testing.expect(!matches(&stack, &EnchantmentSet.fromIds(&.{mending.id})));
    try std.testing.expect(isEnchanted(&stack));
    try std.testing.expect(canEnchant(stack.item_type, sharpness.id));
}

test "addLevels tops up an existing enchantment" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();
    const registry = registry_mod.global().?;

    var stack = try testStack(allocator, "minecraft:test_api_add_levels", true);
    defer stack.deinit();
    defer stack.item_type.deinit();

    const sharpness = registry.resolve("sharpness").?;

    try std.testing.expect(enchantName(&stack, "sharpness", 2, .{}) == .applied);
    switch (addLevels(&stack, sharpness.id, 2, .{})) {
        .applied => |applied| try std.testing.expectEqual(@as(u8, 4), applied.instance.level),
        else => return error.ExpectedApplied,
    }
    switch (addLevels(&stack, sharpness.id, 4, .{})) {
        .applied => |applied| try std.testing.expectEqual(sharpness.max_level, applied.instance.level),
        else => return error.ExpectedApplied,
    }
    try expectReject(addLevels(&stack, 999, 1, .{}), error.unknown_enchantment);
}

test "remove and clear keep the nbt block in sync" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_api_remove", true);
    defer stack.deinit();
    defer stack.item_type.deinit();

    try std.testing.expect(remove(&stack, 9, .{}) == .unchanged);
    try std.testing.expect(enchantName(&stack, "sharpness", 3, .{}) == .applied);
    try std.testing.expect(enchantedKey(&stack));

    try std.testing.expect(remove(&stack, 9, .{}) == .removed);
    try std.testing.expect(!enchantedKey(&stack));
    try std.testing.expectEqual(@as(u8, 0), count(&stack));

    try std.testing.expect(enchantName(&stack, "unbreaking", 2, .{}) == .applied);
    try std.testing.expectEqual(@as(u8, 1), try clear(&stack));
    try std.testing.expectEqual(@as(u8, 0), try clear(&stack));
    try std.testing.expect(!enchantedKey(&stack));
}

test "the removal reaches the wire with nothing left to paint" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_api_wire_removal", true);
    defer stack.deinit();
    defer stack.item_type.deinit();

    try std.testing.expect(enchantName(&stack, "sharpness", 5, .{}) == .applied);

    const before = stack.toNetworkStack().extras.?.nbt.?;
    try std.testing.expect(before.get(nbt.KEY) != null);
    try std.testing.expect(before.get("tag") == null);

    try std.testing.expect(remove(&stack, 9, .{}) == .removed);
    try std.testing.expect(!isEnchanted(&stack));

    const after = stack.toNetworkStack();
    if (after.extras) |extras| {
        try std.testing.expect(extras.nbt.?.get(nbt.KEY) == null);
        try std.testing.expect(extras.nbt.?.get("tag") == null);
    }
}

test "setMany validates the whole batch before touching the item" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_api_set_many", true);
    defer stack.deinit();
    defer stack.item_type.deinit();

    _ = stack.enchantments.set(26, 1);

    const conflicting = [_]EnchantmentInstance{
        .{ .id = 9, .level = 5 },
        .{ .id = 10, .level = 1 },
    };
    const report = setMany(&stack, &conflicting, .replace, .{});
    try std.testing.expectEqual(Reject.conflicts, report.rejected.?);
    try std.testing.expectEqual(@as(u16, 10), report.rejected_id.?);
    try std.testing.expectEqual(@as(u8, 1), count(&stack));
    try std.testing.expectEqual(@as(u8, 1), levelOf(&stack, 26).?);

    const valid = [_]EnchantmentInstance{
        .{ .id = 17, .level = 3 },
        .{ .id = 9, .level = 5 },
    };
    const applied = setMany(&stack, &valid, .replace, .{});
    try std.testing.expectEqual(@as(?Reject, null), applied.rejected);
    try std.testing.expectEqual(@as(u8, 2), applied.applied);
    try std.testing.expectEqual(@as(u8, 2), count(&stack));
    try std.testing.expectEqual(@as(?u8, null), levelOf(&stack, 26));
    try std.testing.expectEqual(@as(u8, 5), levelOf(&stack, 9).?);

    const merged = [_]EnchantmentInstance{.{ .id = 9, .level = 2 }};
    const merge_report = setMany(&stack, &merged, .merge, .{});
    try std.testing.expectEqual(@as(u8, 1), merge_report.applied);
    try std.testing.expectEqual(@as(u8, 5), levelOf(&stack, 9).?);
}

test "a batch that would overflow the cap is rejected whole" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    const item_type = try native_testing.itemType(allocator, "minecraft:enchanted_book", &.{}, true);
    defer item_type.deinit();
    var stack = ItemStack.init(allocator, item_type, .{});
    defer stack.deinit();

    var entries: [storage.MAX_ENCHANTMENTS + 1]EnchantmentInstance = undefined;
    for (&entries, 0..) |*entry, index| entry.* = .{ .id = @intCast(index), .level = 1 };

    const opts: Options = .{ .allow_books = true, .allow_conflicts = true };
    const report = setMany(&stack, &entries, .replace, opts);

    try std.testing.expectEqual(Reject.too_many, report.rejected.?);
    try std.testing.expectEqual(@as(?u16, storage.MAX_ENCHANTMENTS), report.rejected_id);
    try std.testing.expectEqual(@as(u8, 0), report.applied);
    try std.testing.expectEqual(@as(u8, 0), count(&stack));
    try std.testing.expect(!enchantedKey(&stack));
}

test "an operation that cannot write its nbt is rolled back" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();
    const registry = registry_mod.global().?;

    var stack = try testStack(allocator, "minecraft:test_ops_rollback", true);
    defer stack.deinit();
    defer stack.item_type.deinit();

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    stack.allocator = failing.allocator();
    defer stack.allocator = allocator;

    const sharpness = registry.resolve("sharpness").?;
    try expectReject(enchant(&stack, sharpness.id, 3, .{}), error.storage_failure);
    try std.testing.expectEqual(@as(u8, 0), count(&stack));
    try std.testing.expect(!isEnchanted(&stack));
    try std.testing.expect(stack.enchantments.dirty);

    if (stack.nbt) |*leftover| leftover.deinit(allocator);
    stack.nbt = null;
    stack.allocator = allocator;

    try std.testing.expect(enchant(&stack, sharpness.id, 3, .{}) == .applied);
    try std.testing.expectEqual(@as(u8, 3), levelOf(&stack, sharpness.id).?);
}

test "a transfer leaves behind what the target refused" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();
    const registry = registry_mod.global().?;

    var source = try testStack(allocator, "minecraft:test_ops_source", true);
    defer source.deinit();
    defer source.item_type.deinit();
    var target = try testStack(allocator, "minecraft:test_ops_target", true);
    defer target.deinit();
    defer target.item_type.deinit();

    const sharpness = registry.resolve("sharpness").?;
    const smite = registry.resolve("smite").?;

    _ = source.enchantments.set(sharpness.id, 3);
    _ = source.enchantments.set(smite.id, 2);
    _ = target.enchantments.set(sharpness.id, 5);

    const report = try transferTo(&source, &target, .{ .overwrite_existing = false, .respect_conflicts = false });
    try std.testing.expectEqual(@as(u8, 1), report.skipped);
    try std.testing.expectEqual(@as(u8, 1), report.moved);
    try std.testing.expectEqual(@as(u8, 3), levelOf(&source, sharpness.id).?);
    try std.testing.expectEqual(@as(u8, 5), levelOf(&target, sharpness.id).?);
    try std.testing.expectEqual(@as(u8, 2), levelOf(&target, smite.id).?);
    try std.testing.expectEqual(@as(u8, 0), levelOf(&source, smite.id) orelse 0);
}

test "a transfer takes off every id that landed, not every other one" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var source = try testStack(allocator, "minecraft:test_ops_drain_source", false);
    defer source.deinit();
    defer source.item_type.deinit();
    var target = try testStack(allocator, "minecraft:test_ops_drain_target", false);
    defer target.deinit();
    defer target.item_type.deinit();

    _ = source.enchantments.set(17, 2);
    _ = source.enchantments.set(18, 3);

    const report = try transferTo(&source, &target, .{});
    try std.testing.expectEqual(@as(u8, 2), report.moved);
    try std.testing.expectEqual(@as(u8, 0), count(&source));
    try std.testing.expect(!isEnchanted(&source));
    try std.testing.expectEqual(@as(u8, 2), levelOf(&target, 17).?);
    try std.testing.expectEqual(@as(u8, 3), levelOf(&target, 18).?);
}

test "a transfer that moves nothing leaves the source untouched" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();
    const registry = registry_mod.global().?;

    var source = try testStack(allocator, "minecraft:test_ops_idle_source", true);
    defer source.deinit();
    defer source.item_type.deinit();
    var target = try testStack(allocator, "minecraft:test_ops_idle_target", true);
    defer target.deinit();
    defer target.item_type.deinit();

    const sharpness = registry.resolve("sharpness").?;
    _ = source.enchantments.set(sharpness.id, 3);
    _ = target.enchantments.set(sharpness.id, 5);
    try syncNbt(&source);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    source.allocator = failing.allocator();
    defer source.allocator = allocator;

    const report = try transferTo(&source, &target, .{ .overwrite_existing = false });
    try std.testing.expectEqual(@as(u8, 0), report.moved);
    try std.testing.expectEqual(@as(u8, 1), report.skipped);
    try std.testing.expectEqual(@as(u8, 3), levelOf(&source, sharpness.id).?);
    try std.testing.expect(!source.enchantments.dirty);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "events can veto an application" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_api_veto", true);
    defer stack.deinit();
    defer stack.item_type.deinit();

    var bus = events.Events.init(allocator);
    defer bus.deinit();

    const listeners = struct {
        fn veto(_: *events.EventContext, event: *events.types.EnchantmentApplyEvent) events.EventResult {
            if (event.stack.enchantments.count() > 0) return .cancel;
            return .continue_;
        }
    };
    _ = try bus.subscribe(.EnchantmentApply, .pre, 10, 1, listeners.veto);

    try std.testing.expect(enchantName(&stack, "sharpness", 3, .{ .events = &bus }) == .applied);
    try expectReject(enchantName(&stack, "unbreaking", 1, .{ .events = &bus }), error.rule_vetoed);
    try std.testing.expectEqual(@as(u8, 1), count(&stack));
    try std.testing.expect(remove(&stack, 9, .{}) == .removed);
}

test "events can rewrite the requested level" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();

    var stack = try testStack(allocator, "minecraft:test_api_rewrite", true);
    defer stack.deinit();
    defer stack.item_type.deinit();

    var bus = events.Events.init(allocator);
    defer bus.deinit();

    const listeners = struct {
        fn downgrade(_: *events.EventContext, event: *events.types.EnchantmentApplyEvent) events.EventResult {
            event.level = 1;
            return .continue_;
        }
    };
    _ = try bus.subscribe(.EnchantmentApply, .pre, 10, 1, listeners.downgrade);

    switch (enchantName(&stack, "sharpness", 5, .{ .events = &bus, .source = .plugin })) {
        .applied => |applied| {
            try std.testing.expectEqual(@as(u8, 1), applied.instance.level);
            try std.testing.expect(applied.clamped);
        },
        else => return error.ExpectedApplied,
    }
}

test "absorb merges, skips conflicts and transferTo drains the source" {
    const allocator = std.testing.allocator;
    _ = try registry_mod.load();
    const registry = registry_mod.global().?;

    var target = try testStack(allocator, "minecraft:test_api_target", false);
    defer target.deinit();
    defer target.item_type.deinit();
    var source = try testStack(allocator, "minecraft:test_api_source", false);
    defer source.deinit();
    defer source.item_type.deinit();

    _ = target.enchantments.set(registry.resolve("silk_touch").?.id, 1);
    _ = target.enchantments.set(17, 1);
    _ = source.enchantments.set(registry.resolve("fortune").?.id, 3);
    _ = source.enchantments.set(17, 2);
    _ = source.enchantments.set(26, 1);

    const report = try transferTo(&source, &target, .{});
    try std.testing.expectEqual(@as(u8, 1), report.moved);
    try std.testing.expectEqual(@as(u8, 1), report.merged);
    try std.testing.expectEqual(@as(u8, 1), report.skipped);
    try std.testing.expectEqual(@as(u8, 3), levelOf(&target, 17).?);
    try std.testing.expectEqual(@as(u8, 1), levelOf(&target, 26).?);
    try std.testing.expectEqual(@as(u8, 1), count(&source));
    try std.testing.expect(levelOf(&source, 18) != null);

    const copy_report = try copyTo(&source, &target, .{ .respect_conflicts = false });
    try std.testing.expectEqual(@as(u8, 1), copy_report.moved);
    try std.testing.expectEqual(@as(u8, 0), copy_report.skipped);
    try std.testing.expectEqual(@as(u8, 3), levelOf(&target, 18).?);
    try std.testing.expectEqual(@as(u8, 1), count(&source));

    var clone = try source.cloneWithCount(allocator, 2);
    defer clone.deinit();
    try std.testing.expect(clone.enchantments.eql(&source.enchantments));
    try std.testing.expectEqual(@as(u16, 2), clone.stack_size);

    var other = try testStack(allocator, "minecraft:test_api_other", false);
    defer other.deinit();
    defer other.item_type.deinit();
    try std.testing.expect(source.isStackCompatible(&clone));
    try std.testing.expect(!source.isStackCompatible(&other));
    _ = other.enchantments.set(9, 1);
    try std.testing.expect(!clone.isStackCompatible(&other));

    try std.testing.expectEqual(@as(u8, 1), try clear(&clone));
    try std.testing.expect(clone.enchantments.isEmpty());
    try std.testing.expect(!source.enchantments.isEmpty());
    syncNbt(&clone) catch return error.UnexpectedSyncFailure;
}
