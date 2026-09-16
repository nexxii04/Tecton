const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const ItemStackResponse = Protocol.ItemStackResponse;
const StackResponseContainerInfo = Protocol.StackResponseContainerInfo;
const StackResponseSlotInfo = Protocol.StackResponseSlotInfo;
const FullContainerName = Protocol.FullContainerName;
const StackRequestAction = Protocol.StackRequestAction;
const StackRequestSlotInfo = Protocol.StackRequestSlotInfo;
const Raknet = @import("Raknet");

const Container = @import("../../container/container.zig").Container;
const CreatedOutputTrait = @import("../../entity/traits/created-output.zig").CreatedOutputTrait;
const CursorTrait = @import("../../entity/traits/cursor.zig").CursorTrait;
const InventoryTrait = @import("../../entity/traits/inventory.zig").InventoryTrait;
const TradeWindowTrait = @import("../../entity/traits/trade-window.zig").TradeWindowTrait;
const trade_window = @import("../../entity/traits/trade-window.zig");
const villager_trade = @import("../../entity/traits/villager-trade.zig");
const ItemStack = @import("../../items/item-stack.zig").ItemStack;
const ItemType = @import("../../items/item-type.zig").ItemType;
const Display = @import("../../items/traits/display.zig");
const Player = @import("../../player/player.zig").Player;
const PlayerMath = @import("../../player/player.zig");
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;

const HandlerContext = struct {
    inv: *InventoryTrait.TraitState,
    cursor: *CursorTrait.TraitState,
    output: ?*CreatedOutputTrait.TraitState,
    trade: ?*TradeWindowTrait.TraitState,
    player: *Player,
};

fn resolveContainer(ctx: *const HandlerContext, container_name: Protocol.ContainerName) ?*Container {
    return switch (container_name) {
        .Hotbar, .Inventory, .HotbarAndInventory => &ctx.inv.container.base,
        .Armor => if (ctx.inv.armor) |*armor| armor else null,
        .Cursor => &ctx.cursor.container.base,
        .Container, .Barrel, .Shulker => ctx.player.opened_container,
        .Trade2Ingredient1, .Trade2Ingredient2, .TradeIngredient1, .TradeIngredient2 => blk: {
            const trade = ctx.trade orelse break :blk null;
            if (!trade.active) break :blk null;
            break :blk &trade.container;
        },
        .CreativeOutput => if (ctx.output) |output| &output.container.base else null,
        else => null,
    };
}

fn resolveCoreSlot(container_name: Protocol.ContainerName, ui_slot: u8) u32 {
    return switch (container_name) {
        .Trade2Ingredient1, .TradeIngredient1 => 0,
        .Trade2Ingredient2, .TradeIngredient2 => 1,
        .CreativeOutput => 0,
        else => @as(u32, ui_slot),
    };
}

fn isTradeIngredient(container_name: Protocol.ContainerName) bool {
    return switch (container_name) {
        .Trade2Ingredient1, .Trade2Ingredient2, .TradeIngredient1, .TradeIngredient2 => true,
        else => false,
    };
}

fn isTradeContainer(ctx: *const HandlerContext, container: *Container) bool {
    if (ctx.trade) |trade| {
        if (trade.active and &trade.container == container) return true;
    }
    if (ctx.output) |output| {
        if (&output.container.base == container) return true;
    }
    return false;
}

fn refreshTradePreview(ctx: *const HandlerContext) void {
    const trade = ctx.trade orelse return;
    if (!trade.active) return;
    const output = ctx.output orelse return;

    // A pending created output already occupies the slot.
    if (output.container.base.getItem(0) != null) return;

    const villager = trade.villager orelse return;
    const villager_state = villager.getTraitState(villager_trade.VillagerTradeTrait) orelse return;

    const offer = villager_trade.findSatisfiedOffer(villager_state, &trade.container) orelse {
        trade_window.sendResultSlot(ctx.player, null);
        return;
    };
    const sell_type = ItemType.get(offer.sell.identifier) orelse {
        trade_window.sendResultSlot(ctx.player, null);
        return;
    };
    const item = ItemStack.init(ctx.player.entity.allocator, sell_type, .{
        .stack_size = offer.sell.count,
        .metadata = @intCast(offer.sell.damage),
    });
    trade_window.sendResultSlot(ctx.player, item);
}

fn canMergeStacks(a: *const ItemStack, b: *const ItemStack) bool {
    return a.item_type.stackable and
        a.isStackCompatible(b) and
        b.stack_size < b.item_type.max_stack_size;
}

fn applyTransferAction(src: *Container, source_slot: u32, dst: *Container, destination_slot: u32, count: u16) !void {
    if (source_slot >= src.getSize() or destination_slot >= dst.getSize()) return error.TransferFailed;

    const item = src.takeItem(source_slot, count) orelse return error.TransferFailed;

    if (dst.getItemMut(destination_slot)) |existing| {
        if (canMergeStacks(&item, existing)) {
            const space = existing.item_type.max_stack_size - existing.stack_size;
            const to_add = @min(space, item.stack_size);
            existing.stack_size += to_add;
            dst.updateSlot(destination_slot);

            const remaining = item.stack_size - to_add;
            if (remaining > 0) {
                var remainder = item;
                remainder.stack_size = remaining;
                src.setItem(source_slot, remainder);
            } else {
                var consumed = item;
                consumed.deinit();
            }

            return;
        }

        src.setItem(source_slot, item);
        dst.swapItems(destination_slot, source_slot, src);
        return;
    }

    dst.setItem(destination_slot, item);
}

fn applyDropAction(src: *Container, source_slot: u32, count: u16) !ItemStack {
    const item = src.getItem(source_slot) orelse return error.DropFailed;
    const drop_count = @min(if (count == 0) @as(u16, 1) else count, item.stack_size);
    return src.takeItem(source_slot, drop_count) orelse error.DropFailed;
}

fn spawnDroppedItem(player: *@import("../../player/player.zig").Player, item: ItemStack) void {
    const dimension = player.entity.dimension orelse return;
    const spawn_pos = playerDropSpawnPosition(player.entity.position);
    const throw_vel = PlayerMath.playerDropVelocity(player.entity.rotation);
    _ = dimension.spawnItemStackEntity(item, spawn_pos, 40, throw_vel) catch {};
}

fn playerDropSpawnPosition(pos: Protocol.Vector3f) Protocol.Vector3f {
    return PlayerMath.playerDropSpawnPosition(pos);
}

// TODO: Handle inventory transactions more accordingly to avoid client predicted issues

const ChangedSlot = struct {
    name: FullContainerName,
    backing: *Container,
    slot: u8,
    ui_slot: u8,
};

fn sameContainer(a: FullContainerName, b: FullContainerName) bool {
    return a.identifier == b.identifier;
}

fn recordChangedSlot(
    allocator: std.mem.Allocator,
    changed: *std.ArrayList(ChangedSlot),
    container_name: FullContainerName,
    backing: *Container,
    slot: u8,
    ui_slot: u8,
) !void {
    for (changed.items) |cs| {
        if (cs.slot == slot and cs.ui_slot == ui_slot and sameContainer(cs.name, container_name)) return;
    }
    try changed.append(allocator, .{
        .name = container_name,
        .backing = backing,
        .slot = slot,
        .ui_slot = ui_slot,
    });
}

/// Record every slot the action touches so the response can report its state.
fn recordActionSlots(
    allocator: std.mem.Allocator,
    changed: *std.ArrayList(ChangedSlot),
    ctx: *const HandlerContext,
    action: StackRequestAction,
) !void {
    switch (action) {
        .take, .place => |t| {
            try recordSlotInfo(allocator, changed, ctx, t.source);
            try recordSlotInfo(allocator, changed, ctx, t.destination);
        },
        .swap => |s| {
            try recordSlotInfo(allocator, changed, ctx, s.source);
            try recordSlotInfo(allocator, changed, ctx, s.destination);
        },
        .drop => |d| {
            try recordSlotInfo(allocator, changed, ctx, d.source);
        },
        .destroy, .consume => |d| {
            try recordSlotInfo(allocator, changed, ctx, d.source);
        },
        .mine_block => |m| {
            if (m.hotbar_slot >= 0 and m.hotbar_slot < ctx.inv.container.base.getSize()) {
                const slot: u8 = @intCast(m.hotbar_slot);
                try recordChangedSlot(
                    allocator,
                    changed,
                    FullContainerName.init(.Hotbar, null),
                    &ctx.inv.container.base,
                    slot,
                    slot,
                );
            }
        },
        else => {},
    }
}

fn recordSlotInfo(
    allocator: std.mem.Allocator,
    changed: *std.ArrayList(ChangedSlot),
    ctx: *const HandlerContext,
    info: StackRequestSlotInfo,
) !void {
    const backing = resolveContainer(ctx, info.container.identifier) orelse return;
    const core_slot = resolveCoreSlot(info.container.identifier, info.slot);
    try recordChangedSlot(allocator, changed, info.container, backing, @intCast(core_slot), info.slot);
}

fn buildResponse(
    allocator: std.mem.Allocator,
    request_id: i32,
    status: Protocol.ItemStackResponseStatus,
    changed: *const std.ArrayList(ChangedSlot),
) !ItemStackResponse {
    var infos = std.ArrayList(StackResponseContainerInfo).empty;
    errdefer infos.deinit(allocator);

    for (changed.items, 0..) |cs, i| {
        // The client does not need source info for the created output slot.
        if (cs.name.identifier == .CreativeOutput) continue;

        const already = for (0..i) |j| {
            if (sameContainer(changed.items[j].name, cs.name)) break true;
        } else false;
        if (already) continue;

        var slots = std.ArrayList(StackResponseSlotInfo).empty;
        errdefer slots.deinit(allocator);

        for (changed.items) |c2| {
            if (!sameContainer(c2.name, cs.name)) continue;
            const item = c2.backing.getItem(c2.slot);
            const name = if (item) |it| Display.getDisplayName(it) orelse &[_]u8{} else &[_]u8{};
            try slots.append(allocator, .{
                .slot = c2.ui_slot,
                .hotbar_slot = c2.ui_slot,
                .count = if (item) |it| @intCast(@min(@as(u16, 255), it.stack_size)) else 0,
                .stack_network_id = if (item) |it| it.network_stack_id else 0,
                .custom_name = name,
                .filtered_custom_name = name,
                .durability_correction = if (item) |it| @as(i32, @bitCast(it.metadata)) else 0,
            });
        }

        try infos.append(allocator, .{ .container = cs.name, .slot_info = try slots.toOwnedSlice(allocator) });
    }

    return .{
        .status = status,
        .request_id = request_id,
        .container_info = try infos.toOwnedSlice(allocator),
    };
}

fn sendItemStackResponse(network: *NetworkHandler, connection: *Raknet.Connection, responses: []const ItemStackResponse) void {
    const allocator = network.allocator;
    var out = BinaryStream.init(allocator, null, null);
    defer out.deinit();
    const out_packet = Protocol.ItemStackResponsePacket{ .responses = responses };
    const serialized = out_packet.serialize(&out) catch return;
    network.sendPacket(connection, serialized) catch {};
}

pub fn processItemStackRequest(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    request: Protocol.ItemStackRequest,
) !void {
    const allocator = network.allocator;
    const player = network.conduit.getPlayerByConnection(connection) orelse return;

    const inv_state = player.entity.getTraitState(InventoryTrait) orelse return;
    const cursor_state = player.entity.getTraitState(CursorTrait) orelse return;

    var ctx = HandlerContext{
        .inv = inv_state,
        .cursor = cursor_state,
        .output = player.entity.getTraitState(CreatedOutputTrait),
        .trade = player.entity.getTraitState(TradeWindowTrait),
        .player = player,
    };

    var changed = std.ArrayList(ChangedSlot).empty;
    defer changed.deinit(allocator);

    var ok = true;
    var touched_trade = false;
    for (request.actions) |action| {
        recordActionSlots(allocator, &changed, &ctx, action) catch {
            ok = false;
            break;
        };
        switch (action) {
            .take, .place => |t| {
                const src = resolveContainer(&ctx, t.source.container.identifier) orelse {
                    ok = false;
                    continue;
                };
                const dst = resolveContainer(&ctx, t.destination.container.identifier) orelse {
                    ok = false;
                    continue;
                };

                if (isTradeContainer(&ctx, src) or isTradeContainer(&ctx, dst)) touched_trade = true;

                applyTransferAction(
                    src,
                    resolveCoreSlot(t.source.container.identifier, t.source.slot),
                    dst,
                    resolveCoreSlot(t.destination.container.identifier, t.destination.slot),
                    t.count,
                ) catch {
                    ok = false;
                    continue;
                };
            },
            .swap => |s| {
                const src = resolveContainer(&ctx, s.source.container.identifier) orelse {
                    ok = false;
                    continue;
                };
                const dst = resolveContainer(&ctx, s.destination.container.identifier) orelse {
                    ok = false;
                    continue;
                };
                if (isTradeContainer(&ctx, src) or isTradeContainer(&ctx, dst)) touched_trade = true;
                src.swapItems(
                    resolveCoreSlot(s.source.container.identifier, s.source.slot),
                    resolveCoreSlot(s.destination.container.identifier, s.destination.slot),
                    dst,
                );
            },
            .drop => |d| {
                const src = resolveContainer(&ctx, d.source.container.identifier) orelse {
                    ok = false;
                    continue;
                };
                if (isTradeContainer(&ctx, src)) touched_trade = true;
                const dropped = applyDropAction(
                    src,
                    resolveCoreSlot(d.source.container.identifier, d.source.slot),
                    d.count,
                ) catch {
                    ok = false;
                    continue;
                };
                spawnDroppedItem(player, dropped);
            },
            .destroy => |d| {
                const src = resolveContainer(&ctx, d.source.container.identifier) orelse {
                    ok = false;
                    continue;
                };
                if (isTradeContainer(&ctx, src)) touched_trade = true;
                src.clearSlot(resolveCoreSlot(d.source.container.identifier, d.source.slot));
            },
            .consume => |d| {
                const src = resolveContainer(&ctx, d.source.container.identifier) orelse {
                    ok = false;
                    continue;
                };
                // Trade inputs were already removed by executeTrade; consuming
                // them again would double-remove.
                if (isTradeIngredient(d.source.container.identifier)) continue;
                src.removeItem(
                    resolveCoreSlot(d.source.container.identifier, d.source.slot),
                    if (d.count == 0) 1 else d.count,
                );
            },
            .craft_recipe => |c| {
                if (c.recipe_network_id < villager_trade.TRADE_RECIPE_BASE) {
                    Raknet.Logger.WARN("Unhandeled action {any}", .{action});
                    continue;
                }

                touched_trade = true;
                const trade = ctx.trade orelse {
                    ok = false;
                    continue;
                };
                const output = ctx.output orelse {
                    ok = false;
                    continue;
                };
                if (!trade.active) {
                    ok = false;
                    continue;
                }
                const villager = trade.villager orelse {
                    ok = false;
                    continue;
                };
                const villager_state = villager.getTraitState(villager_trade.VillagerTradeTrait) orelse {
                    ok = false;
                    continue;
                };

                const crafted = villager_trade.executeTrade(
                    allocator,
                    villager_state,
                    &trade.container,
                    &output.container.base,
                    c.recipe_network_id,
                    c.number_of_crafts,
                );
                if (!crafted) ok = false;
            },
            .craft_creative => |c| {
                if (player.gamemode != .Creative) {
                    ok = false;
                    continue;
                }

                const cc = network.conduit.creative_content orelse {
                    ok = false;
                    continue;
                };
                const network_id = cc.getNetworkIdByCreativeIndex(c.creative_item_network_id) orelse {
                    ok = false;
                    continue;
                };
                const item_type = ItemType.getByNetworkId(network_id) orelse {
                    ok = false;
                    continue;
                };
                const output = ctx.output orelse {
                    ok = false;
                    continue;
                };
                const item = ItemStack.init(player.entity.allocator, item_type, .{
                    .stack_size = item_type.max_stack_size,
                });
                output.container.base.setItem(0, item);
            },
            .craft_results_deprecated => {},
            .mine_block => |m| {
                // Survival mining durability prediction, the response
                // must report the hotbar slot, and the predicted damage is
                // applied when it references the item the server knows.
                if (m.hotbar_slot < 0 or m.hotbar_slot >= inv_state.container.base.getSize()) continue;
                const held = inv_state.container.base.getItemMut(@intCast(m.hotbar_slot)) orelse continue;
                if (m.predicted_durability >= 0 and held.network_stack_id == m.stack_network_id) {
                    held.metadata = @intCast(m.predicted_durability);
                }
            },
            else => |a| {
                Raknet.Logger.WARN("Unhandeled action {any}", .{a});
            },
        }
    }

    inv_state.container.sendContentUpdate();
    cursor_state.container.sendContentUpdate();
    if (player.opened_container) |opened| {
        // A plain InventoryContent for the trading window would desync the UI.
        if (opened.container_type != .Trading) opened.update();
    }

    const status = if (ok) Protocol.ItemStackResponseStatus.Success else Protocol.ItemStackResponseStatus.Error;
    const response = buildResponse(allocator, request.request_id, status, &changed) catch return;
    defer {
        for (response.container_info) |*ci| allocator.free(ci.slot_info);
        allocator.free(response.container_info);
    }
    sendItemStackResponse(network, connection, &[_]ItemStackResponse{response});

    if (touched_trade) refreshTradePreview(&ctx);
}

pub fn handleItemStackRequest(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const allocator = network.allocator;
    var packet = try Protocol.ItemStackRequestPacket.deserialize(stream);
    defer packet.deinit(allocator);

    // Each request is answered with its own ItemStackResponse; the client
    // correlates them by request_id, so per-request packets are fine.
    for (packet.requests) |request| {
        try processItemStackRequest(network, connection, request);
    }
}

test "core slot mapping translates trade and creative ui slots" {
    try std.testing.expectEqual(@as(u32, 0), resolveCoreSlot(.CreativeOutput, 50));
    try std.testing.expectEqual(@as(u32, 1), resolveCoreSlot(.Trade2Ingredient2, 5));
    try std.testing.expectEqual(@as(u32, 7), resolveCoreSlot(.Inventory, 7));
}

test "transfer action merges matching stacks into occupied destination" {
    const allocator = std.testing.allocator;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    var src = try Container.init(allocator, .Inventory, 36);
    defer src.deinit();
    var dst = try Container.init(allocator, .Inventory, 1);
    defer dst.deinit();

    const stone = try ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:stone"),
        1,
        64,
        true,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    try stone.register();

    src.setItem(5, ItemStack.init(allocator, stone, .{ .stack_size = 1 }));
    dst.setItem(0, ItemStack.init(allocator, stone, .{ .stack_size = 10 }));

    try applyTransferAction(&src, 5, &dst, 0, 1);

    try std.testing.expect(src.getItem(5) == null);
    const cursor = dst.getItem(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 11), cursor.stack_size);
}

test "drop action removes only requested amount from source stack" {
    const allocator = std.testing.allocator;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    var src = try Container.init(allocator, .Inventory, 36);
    defer src.deinit();

    const stone = try ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:stone"),
        1,
        64,
        true,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    try stone.register();

    src.setItem(9, ItemStack.init(allocator, stone, .{ .stack_size = 32 }));

    var dropped = try applyDropAction(&src, 9, 1);
    defer dropped.deinit();

    try std.testing.expectEqual(stone, dropped.item_type);
    try std.testing.expectEqual(@as(u16, 1), dropped.stack_size);
    const remaining = src.getItem(9) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 31), remaining.stack_size);
}

test "drop spawn position is relative to player feet, not above head" {
    const pos = Protocol.Vector3f.init(4, 65.62, -2);
    const drop_pos = playerDropSpawnPosition(pos);

    try std.testing.expectEqual(@as(f32, 4), drop_pos.x);
    try std.testing.expectEqual(@as(f32, 65.3), drop_pos.y);
    try std.testing.expectEqual(@as(f32, -2), drop_pos.z);
}
