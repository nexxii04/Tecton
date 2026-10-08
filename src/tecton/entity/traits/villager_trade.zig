const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const Entity = @import("../entity.zig").Entity;
const EntityTrait = @import("./trait.zig").EntityTrait;
const Player = @import("../../player/player.zig").Player;
const Container = @import("../../container/container.zig").Container;
const ItemType = @import("../../items/item_type.zig").ItemType;
const ItemStack = @import("../../items/item_stack.zig").ItemStack;
const TradeWindowTrait = @import("./trade_window.zig").TradeWindowTrait;
const trade_window = @import("./trade_window.zig");

pub const TRADE_RECIPE_BASE: u32 = 50000;

var nextTradeNetId: u32 = TRADE_RECIPE_BASE;

pub const TradeItem = struct {
    identifier: []const u8,
    count: u8,
    damage: i16 = 0,
};

pub const TradeOffer = struct {
    net_id: u32,
    buy_a: TradeItem,
    buy_b: ?TradeItem = null,
    sell: TradeItem,
    uses: i32 = 0,
    max_uses: i32,
    unlimited: bool = false,
    trader_exp: i32 = 1,
    reward_exp: i32 = 1,
    tier: i32 = 0,
};

pub const State = struct {
    offers: std.ArrayListUnmanaged(TradeOffer) = .empty,
    tier: i32 = 0,
    trade_exp: i32 = 0,
    initialized: bool = false,
};

pub const TradeRecipeSpec = struct {
    buy_a: TradeItem,
    buy_b: ?TradeItem = null,
    sell: TradeItem,
    max_uses: i32 = 12,

    unlimited: bool = false,
    trader_exp: i32 = 1,
    reward_exp: i32 = 1,
    tier: i32 = 0,
};

const tier_exp_requirements = [_]i32{ 0, 10, 70, 150, 250 };

const unlimited_nbt_max_uses: i32 = 9999;

fn onAttach(state: *State, _: *Entity) void {
    state.initialized = true;
}

fn onDetach(state: *State, entity: *Entity) void {
    if (!state.initialized) return;
    clearOffers(state, entity.allocator);
    state.offers.deinit(entity.allocator);
    state.initialized = false;
}

fn onInteract(state: *State, entity: *Entity, player: *Player) bool {
    if (!player.spawned) return true;
    if (!state.initialized) return true;
    if (state.offers.items.len == 0) return true;

    const trade_state = player.entity.getTraitState(TradeWindowTrait) orelse return true;
    const allocator = entity.allocator;
    const offers = buildOffersNbt(allocator, state) catch return true;
    const display_name = if (entity.getNameTag().len > 0) entity.getNameTag() else "Villager";
    trade_window.open(trade_state, player, entity, offers, @intCast(state.tier), display_name);
    return false;
}

pub fn setRecipes(entity: *Entity, recipes: []const TradeRecipeSpec) !void {
    const state = entity.getTraitState(VillagerTradeTrait) orelse return error.TradeTraitNotAttached;
    clearOffers(state, entity.allocator);
    try appendRecipes(state, entity.allocator, recipes);
}

pub fn addRecipe(entity: *Entity, recipe: TradeRecipeSpec) !void {
    const state = entity.getTraitState(VillagerTradeTrait) orelse return error.TradeTraitNotAttached;
    try appendRecipes(state, entity.allocator, &.{recipe});
}

pub fn clearRecipes(entity: *Entity) void {
    const state = entity.getTraitState(VillagerTradeTrait) orelse return;
    clearOffers(state, entity.allocator);
}

fn clearOffers(state: *State, allocator: std.mem.Allocator) void {
    for (state.offers.items) |*offer| {
        freeOffer(allocator, offer);
    }
    state.offers.clearRetainingCapacity();
}

fn freeOffer(allocator: std.mem.Allocator, offer: *TradeOffer) void {
    allocator.free(offer.buy_a.identifier);
    allocator.free(offer.sell.identifier);
    if (offer.buy_b) |buy_b| allocator.free(buy_b.identifier);
}

fn appendRecipes(state: *State, allocator: std.mem.Allocator, recipes: []const TradeRecipeSpec) !void {
    try state.offers.ensureUnusedCapacity(allocator, recipes.len);
    const start = state.offers.items.len;
    errdefer {
        for (state.offers.items[start..]) |*offer| freeOffer(allocator, offer);
        state.offers.shrinkRetainingCapacity(start);
    }

    for (recipes) |spec| {
        try appendRecipe(state, allocator, spec);
    }
}

fn appendRecipe(state: *State, allocator: std.mem.Allocator, spec: TradeRecipeSpec) !void {
    if (spec.buy_a.count == 0 or spec.sell.count == 0) return error.InvalidTradeCount;
    if (!spec.unlimited and spec.max_uses < 1) return error.InvalidTradeMaxUses;
    if (ItemType.get(spec.buy_a.identifier) == null) return error.UnknownTradeItem;
    if (ItemType.get(spec.sell.identifier) == null) return error.UnknownTradeItem;
    if (spec.buy_b) |buy_b| {
        if (ItemType.get(buy_b.identifier) == null) return error.UnknownTradeItem;
    }

    const buy_a_id = try allocator.dupe(u8, spec.buy_a.identifier);
    errdefer allocator.free(buy_a_id);
    const sell_id = try allocator.dupe(u8, spec.sell.identifier);
    errdefer allocator.free(sell_id);
    var buy_b_id: ?[]const u8 = null;
    errdefer {
        if (buy_b_id) |id| allocator.free(id);
    }
    if (spec.buy_b) |buy_b| {
        buy_b_id = try allocator.dupe(u8, buy_b.identifier);
    }

    const net_id = @atomicRmw(u32, &nextTradeNetId, .Add, 1, .monotonic);
    try state.offers.append(allocator, .{
        .net_id = net_id,
        .buy_a = .{ .identifier = buy_a_id, .count = spec.buy_a.count, .damage = spec.buy_a.damage },
        .buy_b = if (spec.buy_b) |buy_b| TradeItem{
            .identifier = buy_b_id.?,
            .count = buy_b.count,
            .damage = buy_b.damage,
        } else null,
        .sell = .{ .identifier = sell_id, .count = spec.sell.count, .damage = spec.sell.damage },
        .max_uses = spec.max_uses,
        .unlimited = spec.unlimited,
        .trader_exp = spec.trader_exp,
        .reward_exp = spec.reward_exp,
        .tier = spec.tier,
    });
}

fn setOwnedTag(compound: *NBT.CompoundTag, name: []const u8, tag: NBT.Tag) !void {
    var owned = tag;
    compound.set(name, owned) catch |err| {
        owned.deinit(compound.allocator);
        return err;
    };
}

fn buildTradeItemTag(allocator: std.mem.Allocator, item: TradeItem) !NBT.Tag {
    var compound = NBT.CompoundTag.init(allocator, null);
    errdefer compound.deinit(allocator);

    const name = try allocator.dupe(u8, item.identifier);
    try setOwnedTag(&compound, "Name", .{ .String = NBT.StringTag.init(name, null) });
    try setOwnedTag(&compound, "Count", .{ .Byte = NBT.ByteTag.init(@intCast(item.count), null) });
    try setOwnedTag(&compound, "Damage", .{ .Short = NBT.ShortTag.init(item.damage, null) });

    return .{ .Compound = compound };
}

fn buildOfferTag(allocator: std.mem.Allocator, offer: *const TradeOffer) !NBT.Tag {
    var compound = NBT.CompoundTag.init(allocator, null);
    errdefer compound.deinit(allocator);

    try setOwnedTag(&compound, "buyA", try buildTradeItemTag(allocator, offer.buy_a));
    if (offer.buy_b) |buy_b| {
        try setOwnedTag(&compound, "buyB", try buildTradeItemTag(allocator, buy_b));
    }
    try setOwnedTag(&compound, "sell", try buildTradeItemTag(allocator, offer.sell));

    const buy_count_b: i32 = if (offer.buy_b) |buy_b| buy_b.count else 0;
    try setOwnedTag(&compound, "buyCountA", .{ .Int = NBT.IntTag.init(offer.buy_a.count, null) });
    try setOwnedTag(&compound, "buyCountB", .{ .Int = NBT.IntTag.init(buy_count_b, null) });
    try setOwnedTag(&compound, "demand", .{ .Int = NBT.IntTag.init(0, null) });
    try setOwnedTag(&compound, "netId", .{ .Int = NBT.IntTag.init(@intCast(offer.net_id), null) });
    const nbt_uses: i32 = if (offer.unlimited) 0 else offer.uses;
    const nbt_max_uses: i32 = if (offer.unlimited) unlimited_nbt_max_uses else offer.max_uses;
    try setOwnedTag(&compound, "uses", .{ .Int = NBT.IntTag.init(nbt_uses, null) });
    try setOwnedTag(&compound, "maxUses", .{ .Int = NBT.IntTag.init(nbt_max_uses, null) });
    try setOwnedTag(&compound, "priceMultiplierA", .{ .Float = NBT.FloatTag.init(0.0, null) });
    try setOwnedTag(&compound, "priceMultiplierB", .{ .Float = NBT.FloatTag.init(0.0, null) });
    try setOwnedTag(&compound, "rewardExp", .{ .Byte = NBT.ByteTag.init(@intCast(offer.reward_exp), null) });
    try setOwnedTag(&compound, "traderExp", .{ .Int = NBT.IntTag.init(offer.trader_exp, null) });
    try setOwnedTag(&compound, "tier", .{ .Int = NBT.IntTag.init(offer.tier, null) });

    return .{ .Compound = compound };
}

fn buildRecipesList(allocator: std.mem.Allocator, state: *const State) !NBT.ListTag {
    const items = try allocator.alloc(NBT.Tag, state.offers.items.len);
    var built: usize = 0;
    errdefer {
        for (items[0..built]) |*tag| tag.deinit(allocator);
        allocator.free(items);
    }

    for (state.offers.items) |*offer| {
        items[built] = try buildOfferTag(allocator, offer);
        built += 1;
    }

    return NBT.ListTag.init(items, null);
}

fn buildTierRequirementsList(allocator: std.mem.Allocator) !NBT.ListTag {
    const items = try allocator.alloc(NBT.Tag, tier_exp_requirements.len);
    var built: usize = 0;
    errdefer {
        for (items[0..built]) |*tag| tag.deinit(allocator);
        allocator.free(items);
    }

    for (tier_exp_requirements, 0..) |requirement, i| {
        var compound = NBT.CompoundTag.init(allocator, null);
        errdefer compound.deinit(allocator);

        var key_buffer: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "{d}", .{i});
        try setOwnedTag(&compound, key, .{ .Int = NBT.IntTag.init(requirement, null) });

        items[built] = .{ .Compound = compound };
        built += 1;
    }

    return NBT.ListTag.init(items, null);
}

pub fn buildOffersNbt(allocator: std.mem.Allocator, state: *const State) !NBT.Tag {
    var root = NBT.CompoundTag.init(allocator, null);
    errdefer root.deinit(allocator);

    try setOwnedTag(&root, "Recipes", .{ .List = try buildRecipesList(allocator, state) });
    try setOwnedTag(&root, "TierExpRequirements", .{ .List = try buildTierRequirementsList(allocator) });

    return .{ .Compound = root };
}

pub fn findOffer(state: *State, net_id: u32) ?*TradeOffer {
    for (state.offers.items) |*offer| {
        if (offer.net_id == net_id) return offer;
    }
    return null;
}

pub fn findSatisfiedOffer(state: *const State, input: *const Container) ?*TradeOffer {
    for (state.offers.items) |*offer| {
        if (!offer.unlimited and offer.uses >= offer.max_uses) continue;

        const input_a = input.getItem(0) orelse continue;
        if (!matchesTradeItem(input_a, offer.buy_a, 1)) continue;

        if (offer.buy_b) |buy_b| {
            const input_b = input.getItem(1) orelse continue;
            if (!matchesTradeItem(input_b, buy_b, 1)) continue;
        }

        return offer;
    }
    return null;
}

fn matchesTradeItem(item: *const ItemStack, trade_item: TradeItem, crafts: u8) bool {
    if (!std.mem.eql(u8, item.item_type.identifier, trade_item.identifier)) return false;
    if (@as(i64, item.metadata) != trade_item.damage) return false;
    return item.stack_size >= @as(u16, trade_item.count) * @as(u16, crafts);
}

fn bumpTier(state: *State) void {
    while (state.tier + 1 < tier_exp_requirements.len and
        state.trade_exp >= tier_exp_requirements[@intCast(state.tier + 1)])
    {
        state.tier += 1;
    }
}

pub fn executeTrade(
    allocator: std.mem.Allocator,
    state: *State,
    input: *Container,
    output: *Container,
    net_id: u32,
    crafts: u8,
) bool {
    const offer = findOffer(state, net_id) orelse return false;
    if (crafts < 1) return false;
    if (!offer.unlimited and offer.uses + @as(i32, crafts) > offer.max_uses) return false;

    const input_a = input.getItem(0) orelse return false;
    if (!matchesTradeItem(input_a, offer.buy_a, crafts)) return false;

    if (offer.buy_b) |buy_b| {
        const input_b = input.getItem(1) orelse return false;
        if (!matchesTradeItem(input_b, buy_b, crafts)) return false;
    }

    const sell_type = ItemType.get(offer.sell.identifier) orelse return false;

    input.removeItem(0, @as(u16, offer.buy_a.count) * @as(u16, crafts));
    if (offer.buy_b) |buy_b| {
        input.removeItem(1, @as(u16, buy_b.count) * @as(u16, crafts));
    }

    const output_item = ItemStack.init(allocator, sell_type, .{
        .stack_size = @as(u16, offer.sell.count) * @as(u16, crafts),
        .metadata = @intCast(offer.sell.damage),
    });
    output.setItem(0, output_item);

    offer.uses += @as(i32, crafts);
    state.trade_exp += offer.trader_exp * @as(i32, crafts);
    bumpTier(state);

    return true;
}

pub const VillagerTradeTrait = EntityTrait(State, .{
    .identifier = "villager-trade",
    .entities = &.{"minecraft:villager"},
    .default_state = .{},
    .on_attach = onAttach,
    .on_detach = onDetach,
    .on_interact = onInteract,
});

fn registerTestItem(allocator: std.mem.Allocator, identifier: []const u8, network_id: i32) !void {
    const item_type = try ItemType.init(
        allocator,
        try allocator.dupe(u8, identifier),
        network_id,
        64,
        true,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    try item_type.register();
}

fn initTestState(allocator: std.mem.Allocator, buy_a: []const u8, sell: []const u8) !State {
    var state = State{};
    try state.offers.append(allocator, .{
        .net_id = TRADE_RECIPE_BASE + 7,
        .buy_a = .{ .identifier = try allocator.dupe(u8, buy_a), .count = 20 },
        .sell = .{ .identifier = try allocator.dupe(u8, sell), .count = 1 },
        .max_uses = 16,
        .trader_exp = 2,
        .reward_exp = 2,
    });
    return state;
}

fn deinitTestState(allocator: std.mem.Allocator, state: *State) void {
    for (state.offers.items) |*offer| {
        allocator.free(offer.buy_a.identifier);
        allocator.free(offer.sell.identifier);
    }
    state.offers.deinit(allocator);
}

test "executeTrade consumes inputs and fills the output" {
    const allocator = std.testing.allocator;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    try registerTestItem(allocator, "minecraft:test_trade_wheat", 9001);
    try registerTestItem(allocator, "minecraft:test_trade_emerald", 9002);
    const wheat = ItemType.get("minecraft:test_trade_wheat") orelse return error.TestUnexpectedResult;
    const emerald = ItemType.get("minecraft:test_trade_emerald") orelse return error.TestUnexpectedResult;

    var state = try initTestState(allocator, "minecraft:test_trade_wheat", "minecraft:test_trade_emerald");
    defer deinitTestState(allocator, &state);

    var input = try Container.init(allocator, .Trading, 2);
    defer input.deinit();
    var output = try Container.init(allocator, .Trading, 1);
    defer output.deinit();

    input.setItem(0, ItemStack.init(allocator, wheat, .{ .stack_size = 25 }));

    try std.testing.expect(executeTrade(allocator, &state, &input, &output, TRADE_RECIPE_BASE + 7, 1));

    const remaining = input.getItem(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 5), remaining.stack_size);

    const created = output.getItem(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(emerald, created.item_type);
    try std.testing.expectEqual(@as(u16, 1), created.stack_size);

    try std.testing.expectEqual(@as(i32, 1), state.offers.items[0].uses);
    try std.testing.expectEqual(@as(i32, 2), state.trade_exp);
}

test "executeTrade rejects a mismatched input" {
    const allocator = std.testing.allocator;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    try registerTestItem(allocator, "minecraft:test_trade_wheat", 9003);
    try registerTestItem(allocator, "minecraft:test_trade_emerald", 9004);

    var state = try initTestState(allocator, "minecraft:test_trade_wheat", "minecraft:test_trade_emerald");
    defer deinitTestState(allocator, &state);

    var input = try Container.init(allocator, .Trading, 2);
    defer input.deinit();
    var output = try Container.init(allocator, .Trading, 1);
    defer output.deinit();

    const emerald = ItemType.get("minecraft:test_trade_emerald") orelse return error.TestUnexpectedResult;
    input.setItem(0, ItemStack.init(allocator, emerald, .{ .stack_size = 25 }));

    try std.testing.expect(!executeTrade(allocator, &state, &input, &output, TRADE_RECIPE_BASE + 7, 1));
    try std.testing.expect(output.getItem(0) == null);
    try std.testing.expectEqual(@as(i32, 0), state.offers.items[0].uses);

    const untouched = input.getItem(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 25), untouched.stack_size);
}

test "findSatisfiedOffer matches only covered in-stock offers" {
    const allocator = std.testing.allocator;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    try registerTestItem(allocator, "minecraft:test_trade_wheat", 9007);
    try registerTestItem(allocator, "minecraft:test_trade_emerald", 9008);

    var state = try initTestState(allocator, "minecraft:test_trade_wheat", "minecraft:test_trade_emerald");
    defer deinitTestState(allocator, &state);

    var input = try Container.init(allocator, .Trading, 2);
    defer input.deinit();

    try std.testing.expect(findSatisfiedOffer(&state, &input) == null);

    const wheat = ItemType.get("minecraft:test_trade_wheat") orelse return error.TestUnexpectedResult;
    input.setItem(0, ItemStack.init(allocator, wheat, .{ .stack_size = 10 }));
    try std.testing.expect(findSatisfiedOffer(&state, &input) == null);

    input.setItem(0, ItemStack.init(allocator, wheat, .{ .stack_size = 20 }));
    try std.testing.expect(findSatisfiedOffer(&state, &input) != null);

    state.offers.items[0].uses = 16;
    try std.testing.expect(findSatisfiedOffer(&state, &input) == null);
}

test "recipe assignment validates items and keeps previous offers on failure" {
    const allocator = std.testing.allocator;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    try registerTestItem(allocator, "minecraft:test_set_wheat", 9101);
    try registerTestItem(allocator, "minecraft:test_set_emerald", 9102);

    var state = State{ .initialized = true };
    defer {
        clearOffers(&state, allocator);
        state.offers.deinit(allocator);
    }

    try appendRecipes(&state, allocator, &.{
        .{
            .buy_a = .{ .identifier = "minecraft:test_set_wheat", .count = 20 },
            .sell = .{ .identifier = "minecraft:test_set_emerald", .count = 1 },
        },
        .{
            .buy_a = .{ .identifier = "minecraft:test_set_emerald", .count = 1 },
            .sell = .{ .identifier = "minecraft:test_set_wheat", .count = 2 },
            .max_uses = 4,
        },
    });
    try std.testing.expectEqual(@as(usize, 2), state.offers.items.len);

    try std.testing.expectError(error.UnknownTradeItem, appendRecipes(&state, allocator, &.{
        .{
            .buy_a = .{ .identifier = "minecraft:definitely_missing", .count = 1 },
            .sell = .{ .identifier = "minecraft:test_set_emerald", .count = 1 },
        },
    }));
    try std.testing.expectEqual(@as(usize, 2), state.offers.items.len);

    clearOffers(&state, allocator);
    try std.testing.expectEqual(@as(usize, 0), state.offers.items.len);
}

test "unlimited offers stay available past their max uses" {
    const allocator = std.testing.allocator;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    try registerTestItem(allocator, "minecraft:test_unlim_wheat", 9103);
    try registerTestItem(allocator, "minecraft:test_unlim_emerald", 9104);

    var state = State{ .initialized = true };
    defer {
        clearOffers(&state, allocator);
        state.offers.deinit(allocator);
    }

    try appendRecipes(&state, allocator, &.{
        .{
            .buy_a = .{ .identifier = "minecraft:test_unlim_wheat", .count = 1 },
            .sell = .{ .identifier = "minecraft:test_unlim_emerald", .count = 1 },
            .unlimited = true,
        },
    });

    var input = try Container.init(allocator, .Trading, 2);
    defer input.deinit();
    var output = try Container.init(allocator, .Trading, 1);
    defer output.deinit();

    const wheat = ItemType.get("minecraft:test_unlim_wheat") orelse return error.TestUnexpectedResult;
    const offer = &state.offers.items[0];
    offer.uses = 10000;

    input.setItem(0, ItemStack.init(allocator, wheat, .{ .stack_size = 1 }));
    try std.testing.expect(findSatisfiedOffer(&state, &input) != null);
    try std.testing.expect(executeTrade(allocator, &state, &input, &output, offer.net_id, 1));

    var nbt = try buildOffersNbt(allocator, &state);
    defer nbt.deinit(allocator);
    const root = switch (nbt) {
        .Compound => |*compound| compound,
        else => return error.TestUnexpectedResult,
    };
    const recipes = switch (root.get("Recipes") orelse return error.TestUnexpectedResult) {
        .List => |list| list,
        else => return error.TestUnexpectedResult,
    };
    const recipe = switch (recipes.value[0]) {
        .Compound => |*compound| compound,
        else => return error.TestUnexpectedResult,
    };
    const max_uses = switch (recipe.get("maxUses") orelse return error.TestUnexpectedResult) {
        .Int => |int| int.value,
        else => return error.TestUnexpectedResult,
    };
    const uses = switch (recipe.get("uses") orelse return error.TestUnexpectedResult) {
        .Int => |int| int.value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(unlimited_nbt_max_uses, max_uses);
    try std.testing.expectEqual(@as(i32, 0), uses);
}

test "buildOffersNbt round-trips through the network encoding" {
    const allocator = std.testing.allocator;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    try registerTestItem(allocator, "minecraft:test_trade_wheat", 9005);
    try registerTestItem(allocator, "minecraft:test_trade_emerald", 9006);

    var state = try initTestState(allocator, "minecraft:test_trade_wheat", "minecraft:test_trade_emerald");
    defer deinitTestState(allocator, &state);
    state.tier = 2;
    state.trade_exp = 70;
    state.offers.items[0].tier = 2;

    var offers = try buildOffersNbt(allocator, &state);
    defer offers.deinit(allocator);

    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();
    try offers.write(&stream, .network);

    var read_stream = BinaryStream.init(allocator, stream.getBuffer(), null);
    defer read_stream.deinit();
    var parsed = try NBT.Tag.read(&read_stream, allocator, .network);
    defer parsed.deinit(allocator);

    const root = switch (parsed) {
        .Compound => |*compound| compound,
        else => return error.TestUnexpectedResult,
    };

    const recipes = switch (root.get("Recipes") orelse return error.TestUnexpectedResult) {
        .List => |list| list,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), recipes.value.len);

    const recipe = switch (recipes.value[0]) {
        .Compound => |*compound| compound,
        else => return error.TestUnexpectedResult,
    };
    const buy_a = switch (recipe.get("buyA") orelse return error.TestUnexpectedResult) {
        .Compound => |*compound| compound,
        else => return error.TestUnexpectedResult,
    };
    const buy_a_name = switch (buy_a.get("Name") orelse return error.TestUnexpectedResult) {
        .String => |string| string.value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("minecraft:test_trade_wheat", buy_a_name);

    const sell = switch (recipe.get("sell") orelse return error.TestUnexpectedResult) {
        .Compound => |*compound| compound,
        else => return error.TestUnexpectedResult,
    };
    const sell_name = switch (sell.get("Name") orelse return error.TestUnexpectedResult) {
        .String => |string| string.value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("minecraft:test_trade_emerald", sell_name);
    const sell_count = switch (sell.get("Count") orelse return error.TestUnexpectedResult) {
        .Byte => |byte| byte.value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(i8, 1), sell_count);

    const net_id = switch (recipe.get("netId") orelse return error.TestUnexpectedResult) {
        .Int => |int| int.value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(i32, @intCast(TRADE_RECIPE_BASE + 7)), net_id);
    const tier = switch (recipe.get("tier") orelse return error.TestUnexpectedResult) {
        .Int => |int| int.value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(i32, 2), tier);

    const tier_requirements = switch (root.get("TierExpRequirements") orelse return error.TestUnexpectedResult) {
        .List => |list| list,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 5), tier_requirements.value.len);
}
