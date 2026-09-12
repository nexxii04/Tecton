const std = @import("std");
const Raknet = @import("Raknet");
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Container = @import("../../container/container.zig").Container;
const InventoryTrait = @import("../../entity/traits/inventory.zig").InventoryTrait;
const CursorTrait = @import("../../entity/traits/cursor.zig").CursorTrait;
const ItemType = @import("../../items/item-type.zig").ItemType;
const ItemStack = @import("../../items/item-stack.zig").ItemStack;
const Display = @import("../../items/traits/display.zig");
const PlayerMath = @import("../../player/player.zig");
const ItemStackResponse = Protocol.ItemStackResponse;
const StackResponseContainerInfo = Protocol.StackResponseContainerInfo;
const StackResponseSlotInfo = Protocol.StackResponseSlotInfo;
const FullContainerName = Protocol.FullContainerName;
const StackRequestAction = Protocol.StackRequestAction;
const StackRequestSlotInfo = Protocol.StackRequestSlotInfo;

fn resolveContainer(
    inv_state: *InventoryTrait.TraitState,
    cursor_state: *CursorTrait.TraitState,
    container_name: Protocol.ContainerName,
    player: *@import("../../player/player.zig").Player,
) ?*Container {
    return switch (container_name) {
        .Hotbar, .Inventory, .HotbarAndInventory => &inv_state.container.base,
        .Cursor => &cursor_state.container.base,
        .Container, .Barrel, .Shulker => player.opened_container,
        else => null,
    };
}

fn resolveTransferContainer(
    inv_state: *InventoryTrait.TraitState,
    cursor_state: *CursorTrait.TraitState,
    container_name: Protocol.ContainerName,
    player: *@import("../../player/player.zig").Player,
) ?*Container {
    return switch (container_name) {
        .CreativeOutput => &cursor_state.container.base,
        else => resolveContainer(inv_state, cursor_state, container_name, player),
    };
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
) !void {
    for (changed.items) |cs| {
        if (cs.slot == slot and sameContainer(cs.name, container_name)) return;
    }
    try changed.append(allocator, .{ .name = container_name, .backing = backing, .slot = slot });
}

/// Record every slot the action touches so the response can report its state.
fn recordActionSlots(
    allocator: std.mem.Allocator,
    changed: *std.ArrayList(ChangedSlot),
    inv_state: *InventoryTrait.TraitState,
    cursor_state: *CursorTrait.TraitState,
    player: *@import("../../player/player.zig").Player,
    action: StackRequestAction,
) !void {
    switch (action) {
        .take, .place => |t| {
            try recordSlotInfo(allocator, changed, inv_state, cursor_state, player, t.source);
            try recordSlotInfo(allocator, changed, inv_state, cursor_state, player, t.destination);
        },
        .swap => |s| {
            try recordSlotInfo(allocator, changed, inv_state, cursor_state, player, s.source);
            try recordSlotInfo(allocator, changed, inv_state, cursor_state, player, s.destination);
        },
        .drop => |d| {
            try recordSlotInfo(allocator, changed, inv_state, cursor_state, player, d.source);
        },
        .destroy, .consume => |d| {
            try recordSlotInfo(allocator, changed, inv_state, cursor_state, player, d.source);
        },
        .mine_block => |m| {
            if (m.hotbar_slot >= 0 and m.hotbar_slot < inv_state.container.base.getSize()) {
                try recordChangedSlot(allocator, changed, FullContainerName.init(.Hotbar, null), &inv_state.container.base, @intCast(m.hotbar_slot));
            }
        },
        else => {},
    }
}

fn recordSlotInfo(
    allocator: std.mem.Allocator,
    changed: *std.ArrayList(ChangedSlot),
    inv_state: *InventoryTrait.TraitState,
    cursor_state: *CursorTrait.TraitState,
    player: *@import("../../player/player.zig").Player,
    info: StackRequestSlotInfo,
) !void {
    const backing = resolveContainer(inv_state, cursor_state, info.container.identifier, player) orelse return;
    try recordChangedSlot(allocator, changed, info.container, backing, info.slot);
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
                .slot = c2.slot,
                .hotbar_slot = c2.slot,
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

    var changed = std.ArrayList(ChangedSlot).empty;
    defer changed.deinit(allocator);

    var ok = true;
    for (request.actions) |action| {
        recordActionSlots(allocator, &changed, inv_state, cursor_state, player, action) catch {
            ok = false;
            break;
        };
        switch (action) {
            .take, .place => |t| {
                const src = resolveTransferContainer(inv_state, cursor_state, t.source.container.identifier, player) orelse {
                    ok = false;
                    continue;
                };
                const dst = resolveTransferContainer(inv_state, cursor_state, t.destination.container.identifier, player) orelse {
                    ok = false;
                    continue;
                };

                // Clients address the creative output with catalog slot
                // numbers instead of 0; the cursor backing store it
                // resolves to only has one slot.
                const source_slot: u32 = if (t.source.container.identifier == .CreativeOutput) 0 else t.source.slot;
                applyTransferAction(src, source_slot, dst, t.destination.slot, t.count) catch {
                    ok = false;
                    continue;
                };
            },
            .swap => |s| {
                const src = resolveContainer(inv_state, cursor_state, s.source.container.identifier, player) orelse {
                    ok = false;
                    continue;
                };
                const dst = resolveContainer(inv_state, cursor_state, s.destination.container.identifier, player) orelse {
                    ok = false;
                    continue;
                };
                src.swapItems(s.source.slot, s.destination.slot, dst);
            },
            .drop => |d| {
                const src = resolveContainer(inv_state, cursor_state, d.source.container.identifier, player) orelse {
                    ok = false;
                    continue;
                };
                const dropped = applyDropAction(src, d.source.slot, d.count) catch {
                    ok = false;
                    continue;
                };
                spawnDroppedItem(player, dropped);
            },
            .destroy, .consume => |d| {
                const src = resolveContainer(inv_state, cursor_state, d.source.container.identifier, player) orelse {
                    ok = false;
                    continue;
                };
                src.clearSlot(d.source.slot);
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
                const item = ItemStack.init(player.entity.allocator, item_type, .{
                    .stack_size = item_type.max_stack_size,
                });
                cursor_state.container.base.setItem(0, item);
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
    if (player.opened_container) |opened| opened.update();

    const status = if (ok) Protocol.ItemStackResponseStatus.Success else Protocol.ItemStackResponseStatus.Error;
    const response = buildResponse(allocator, request.request_id, status, &changed) catch return;
    defer {
        for (response.container_info) |*ci| allocator.free(ci.slot_info);
        allocator.free(response.container_info);
    }
    sendItemStackResponse(network, connection, &[_]ItemStackResponse{response});
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

test "creative output resolves to cursor for transfer handling" {
    const allocator = std.testing.allocator;

    var inv_base = try Container.init(allocator, .Inventory, 36);
    defer inv_base.deinit();
    var cursor_base = try Container.init(allocator, .Inventory, 1);
    defer cursor_base.deinit();

    var inv_state = InventoryTrait.TraitState{
        .container = .{
            .base = inv_base,
            .owner = undefined,
        },
        .selected_slot = 0,
        .opened = false,
    };
    var cursor_state = CursorTrait.TraitState{
        .container = .{
            .base = cursor_base,
            .owner = undefined,
        },
    };
    var player: @import("../../player/player.zig").Player = undefined;

    const resolved = resolveTransferContainer(&inv_state, &cursor_state, .CreativeOutput, &player) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expect(resolved == &cursor_state.container.base);
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
