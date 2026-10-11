const std = @import("std");

const Command = @import("../command.zig").Command;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;
const types = @import("../types.zig");
const Player = @import("../../player/player.zig").Player;

const ItemStack = @import("../../items/item_stack.zig").ItemStack;
const Enchantment = @import("../../items/enchantments/enchantment.zig").Enchantment;
const EnchantmentRegistry = @import("../../items/enchantments/registry.zig");
const EnchantmentRules = @import("../../items/enchantments/rules.zig");
const Ops = @import("../../items/enchantments/ops.zig");
const Display = @import("../../items/traits/display.zig");
const InventoryTrait = @import("../../entity/traits/inventory.zig");

pub const PERMISSION: []const u8 = "tecton.command.enchant";
pub const DESCRIPTION: []const u8 = "Adds an enchantment to a player's selected item.";
pub const USAGE: []const u8 = "/enchant <player: target> <enchantment: Enchant> [level: int]";

pub const MESSAGE_SUCCESS: []const u8 = "Enchanting succeeded for {s}";
pub const MESSAGE_NO_ITEM: []const u8 = "The target doesn't hold an item: {s}";
pub const MESSAGE_CANT_ENCHANT: []const u8 = "The selected enchantment can't be added to the target item: {s}";
pub const MESSAGE_CANT_COMBINE: []const u8 = "{s} can't be combined with {s}";
pub const MESSAGE_INVALID_LEVEL: []const u8 = "{s} does not support level {d}";
pub const MESSAGE_NOT_FOUND: []const u8 = "There is no such enchantment with ID {d}";
pub const MESSAGE_NO_TARGETS: []const u8 = "No targets matched selector";

fn successMessage(buffer: []u8, username: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_SUCCESS, .{username}) catch USAGE;
}

fn noItemMessage(buffer: []u8, username: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_NO_ITEM, .{username}) catch USAGE;
}

fn cantEnchantMessage(buffer: []u8, item: *const ItemStack) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_CANT_ENCHANT, .{itemLabel(item)}) catch USAGE;
}

fn cantCombineMessage(buffer: []u8, first: *const Enchantment, second: *const Enchantment) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_CANT_COMBINE, .{ first.name, second.name }) catch USAGE;
}

fn invalidLevelMessage(buffer: []u8, definition: *const Enchantment, level: i64) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_INVALID_LEVEL, .{ definition.name, level }) catch USAGE;
}

fn notFoundMessage(buffer: []u8, id: i64) []const u8 {
    return std.fmt.bufPrint(buffer, MESSAGE_NOT_FOUND, .{id}) catch USAGE;
}

pub fn register(registry: *CommandRegistry) !void {
    const enchant_enum = try registerEnchantEnum(registry);

    const cmd = try Command.init(
        registry.allocator,
        "enchant",
        DESCRIPTION,
        PERMISSION,
        &.{},
        @ptrCast(&handle),
    );

    const by_id = try registry.allocator.alloc(types.CommandParameter, 3);
    defer registry.allocator.free(by_id);
    by_id[0] = .{ .name = "player", .param_type = .Target, .optional = false };
    by_id[1] = .{ .name = "enchantmentId", .param_type = .Int, .optional = false };
    by_id[2] = .{ .name = "level", .param_type = .Int, .optional = true };
    try cmd.addOverload(by_id);

    const by_name = try registry.allocator.alloc(types.CommandParameter, 3);
    defer registry.allocator.free(by_name);
    by_name[0] = .{ .name = "player", .param_type = .Target, .optional = false };
    by_name[1] = .{ .name = "enchantmentName", .param_type = .String, .optional = false, .enum_index = enchant_enum };
    by_name[2] = .{ .name = "level", .param_type = .Int, .optional = true };
    try cmd.addOverload(by_name);

    try registry.registerCommand(cmd);
}

fn registerEnchantEnum(registry: *CommandRegistry) !u32 {
    const enchantment_registry = EnchantmentRegistry.ensureGlobal() orelse return error.NoEnchantmentRegistry;

    const values = try registry.allocator.alloc([]const u8, enchantment_registry.count());
    errdefer registry.allocator.free(values);
    for (enchantment_registry.list(), 0..) |definition, index| {
        values[index] = definition.identifier;
    }

    return registry.registerEnum(.{
        .name = "Enchant",
        .values = values,
        .owned = true,
    });
}

fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const trimmed = std.mem.trim(u8, ctx.args, " ");
    if (trimmed.len == 0) {
        ctx.sendOutput(false, USAGE);
        return;
    }

    var arguments = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const target_argument = arguments.next() orelse {
        ctx.sendOutput(false, USAGE);
        return;
    };
    const enchantment_argument = arguments.next() orelse {
        ctx.sendOutput(false, USAGE);
        return;
    };
    const level_argument = arguments.next();

    const registry = EnchantmentRegistry.ensureGlobal() orelse {
        ctx.sendOutput(false, USAGE);
        return;
    };

    var numeric_id: ?i64 = null;
    const definition = resolve(registry, enchantment_argument, &numeric_id) orelse {
        var buffer: [128]u8 = undefined;
        if (numeric_id) |id| {
            ctx.sendOutput(false, notFoundMessage(&buffer, id));
        } else {
            ctx.sendOutput(false, USAGE);
        }
        return;
    };

    const level = parseLevel(level_argument) orelse {
        ctx.sendOutput(false, USAGE);
        return;
    };
    if (!levelInRange(definition, level)) {
        var buffer: [192]u8 = undefined;
        ctx.sendOutput(false, invalidLevelMessage(&buffer, definition, level));
        return;
    }
    const requested: u8 = @intCast(level);

    const targets = ctx.resolvePlayers(target_argument) orelse {
        ctx.sendOutput(false, MESSAGE_NO_TARGETS);
        return;
    };

    for (targets) |target| {
        const inventory_state = target.entity.getTraitState(InventoryTrait.InventoryTrait) orelse continue;
        const slot: u32 = inventory_state.selected_slot;

        const held = inventory_state.container.base.getItemMut(slot) orelse {
            var buffer: [256]u8 = undefined;
            ctx.sendOutput(false, noItemMessage(&buffer, target.username));
            continue;
        };

        const outcome = Ops.enchant(held, definition.id, requested, .{
            .clamp_level = false,
            .allow_conflicts = false,
            .source = .command,
            .actor = ctx.player,
            .events = ctx.views.enchantment.events,
        });

        switch (outcome) {
            .applied => {},
            .unchanged => {
                if (requested != definition.max_level) {
                    inventory_state.container.updateSlot(slot);
                    InventoryTrait.broadcastHeldItem(ctx.network, target, inventory_state, @intCast(slot), inventory_state.selected_slot);
                    sendSuccess(ctx, target);
                    continue;
                }
                sendCantEnchant(ctx, held);
                continue;
            },
            .removed => {
                inventory_state.container.updateSlot(slot);
                InventoryTrait.broadcastHeldItem(ctx.network, target, inventory_state, @intCast(slot), inventory_state.selected_slot);
                sendSuccess(ctx, target);
                continue;
            },
            .rejected => |reject| {
                sendReject(ctx, registry, definition, held, requested, reject);
                continue;
            },
        }

        inventory_state.container.updateSlot(slot);
        InventoryTrait.broadcastHeldItem(ctx.network, target, inventory_state, @intCast(slot), inventory_state.selected_slot);
        sendSuccess(ctx, target);
    }
}

const testing = std.testing;
const enchant_testing = @import("../../items/enchantments/testing.zig");

fn parseLevel(argument: ?[]const u8) ?i64 {
    const text = argument orelse return 1;
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn levelInRange(definition: *const Enchantment, level: i64) bool {
    return level >= 0 and level <= @as(i64, definition.max_level);
}

fn resolve(registry: *const EnchantmentRegistry.Registry, argument: []const u8, numeric_id: *?i64) ?*const Enchantment {
    if (std.fmt.parseInt(i64, argument, 10)) |id| {
        numeric_id.* = id;
        if (id < 0 or id > std.math.maxInt(u16)) return null;
        return registry.get(@intCast(id));
    } else |_| {}
    return registry.resolve(argument);
}

fn sendSuccess(ctx: *CommandContext, target: *Player) void {
    var buffer: [256]u8 = undefined;
    ctx.sendOutput(true, successMessage(&buffer, target.username));
}

fn itemLabel(item: *const ItemStack) []const u8 {
    return Display.getDisplayName(item) orelse Display.getComponentName(item) orelse item.item_type.identifier;
}

fn sendCantEnchant(ctx: *CommandContext, item: *const ItemStack) void {
    var buffer: [320]u8 = undefined;
    ctx.sendOutput(false, cantEnchantMessage(&buffer, item));
}

fn sendReject(
    ctx: *CommandContext,
    registry: *const EnchantmentRegistry.Registry,
    definition: *const Enchantment,
    item: *const ItemStack,
    requested: u8,
    reject: Ops.Reject,
) void {
    switch (reject) {
        error.conflicts => {
            const conflicting = EnchantmentRules.conflictsOf(registry, item.enchantments.items(), definition) orelse {
                sendCantEnchant(ctx, item);
                return;
            };
            const other = registry.get(conflicting.id) orelse {
                sendCantEnchant(ctx, item);
                return;
            };
            var buffer: [320]u8 = undefined;
            ctx.sendOutput(false, cantCombineMessage(&buffer, definition, other));
        },
        error.invalid_level => {
            var buffer: [192]u8 = undefined;
            ctx.sendOutput(false, invalidLevelMessage(&buffer, definition, @as(i64, requested)));
        },
        else => sendCantEnchant(ctx, item),
    }
}

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const ItemStack = test_owner.ItemStack;
    pub const EnchantmentRegistry = test_owner.EnchantmentRegistry;
    pub const DESCRIPTION = test_owner.DESCRIPTION;
    pub const USAGE = test_owner.USAGE;
    pub const MESSAGE_SUCCESS = test_owner.MESSAGE_SUCCESS;
    pub const MESSAGE_NO_ITEM = test_owner.MESSAGE_NO_ITEM;
    pub const MESSAGE_CANT_ENCHANT = test_owner.MESSAGE_CANT_ENCHANT;
    pub const MESSAGE_CANT_COMBINE = test_owner.MESSAGE_CANT_COMBINE;
    pub const MESSAGE_INVALID_LEVEL = test_owner.MESSAGE_INVALID_LEVEL;
    pub const MESSAGE_NOT_FOUND = test_owner.MESSAGE_NOT_FOUND;
    pub const successMessage = test_owner.successMessage;
    pub const noItemMessage = test_owner.noItemMessage;
    pub const cantEnchantMessage = test_owner.cantEnchantMessage;
    pub const cantCombineMessage = test_owner.cantCombineMessage;
    pub const invalidLevelMessage = test_owner.invalidLevelMessage;
    pub const notFoundMessage = test_owner.notFoundMessage;
    pub const testing = test_owner.testing;
    pub const enchant_testing = test_owner.enchant_testing;
    pub const parseLevel = test_owner.parseLevel;
    pub const levelInRange = test_owner.levelInRange;
    pub const resolve = test_owner.resolve;
};

test "the enchantment argument accepts a numeric id or a name" {
    try @import("enchant_test.zig").Suite(test_scope).case_000();
}

test "every message names the argument the design decided" {
    try @import("enchant_test.zig").Suite(test_scope).case_001();
}

test "the level argument defaults to one, accepts the removal level and rejects the rest" {
    try @import("enchant_test.zig").Suite(test_scope).case_002();
}

test "the command exposes the vanilla syntax, description and messages" {
    try @import("enchant_test.zig").Suite(test_scope).case_003();
}
