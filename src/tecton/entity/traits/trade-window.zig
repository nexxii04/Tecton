const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const Protocol = @import("protocol");

const Container = @import("../../container/container.zig").Container;
const ItemStack = @import("../../items/item-stack.zig").ItemStack;
const Player = @import("../../player/player.zig").Player;
const PlayerMath = @import("../../player/player.zig");
const Entity = @import("../entity.zig").Entity;
const entities = @import("../../world/dimension/entities.zig");
const InventoryTrait = @import("./inventory.zig").InventoryTrait;
const EntityTrait = @import("./trait.zig").EntityTrait;

pub const State = struct {
    container: Container,
    villager: ?*Entity = null,
    window_id: Protocol.ContainerId = .None,
    active: bool = false,
    initialized: bool = false,
};

fn getPlayer(entity: *Entity) ?*Player {
    if (!std.mem.eql(u8, entity.entity_type.identifier, "minecraft:player")) return null;
    return @fieldParentPtr("entity", entity);
}

fn onAttach(state: *State, entity: *Entity) void {
    if (getPlayer(entity) == null) return;
    state.container = Container.init(entity.allocator, .Trading, 2) catch return;
    state.container.muted = true;
    state.initialized = true;
}

fn onDetach(state: *State, _: *Entity) void {
    if (!state.initialized) return;
    state.container.deinit();
}

pub fn open(
    state: *State,
    player: *Player,
    villager: *Entity,
    offers: NBT.Tag,
    tier: u32,
    display_name: []const u8,
) void {
    const allocator = player.entity.allocator;
    var offers_tag = offers;
    if (!state.initialized) {
        offers_tag.deinit(allocator);
        return;
    }

    if (player.opened_container) |opened| {
        opened.close(player, true);
    }

    evacuate(state, player);

    state.villager = villager;
    state.active = true;
    state.window_id = Container.getNextContainerId();
    state.container.occupants.put(player, state.window_id) catch {};
    player.opened_container = &state.container;

    sendContainerOpen(state, player, villager);
    sendUpdateTrade(state, player, villager, offers_tag, tier, display_name);
    offers_tag.deinit(allocator);
}

pub fn onWindowClosed(state: *State, player: *Player) void {
    evacuate(state, player);
    state.villager = null;
    state.window_id = .None;
    state.active = false;
}

pub fn sendResultSlot(player: *Player, item: ?ItemStack) void {
    var owned = item;
    defer {
        if (owned) |*value| value.deinit();
    }

    if (owned != null) {
        sendSlotPacket(player, emptyItemDescriptor());
    }
    sendSlotPacket(player, if (owned) |*value| value.toNetworkStack() else emptyItemDescriptor());
}

fn emptyItemDescriptor() Protocol.NetworkItemStackDescriptor {
    return .{
        .network = 0,
        .stack_size = null,
        .metadata = null,
        .item_stack_id = null,
        .network_block_id = null,
        .extras = null,
    };
}

fn sendSlotPacket(player: *Player, item: Protocol.NetworkItemStackDescriptor) void {
    var stream = BinaryStream.init(player.entity.allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.InventorySlotPacket{
        .container_id = .Ui,
        .slot = 50,
        .storage_item = emptyItemDescriptor(),
        .item = item,
    };
    const serialized = packet.serialize(&stream) catch return;
    player.network.sendPacket(player.connection, serialized) catch {};
}

fn sendContainerOpen(state: *const State, player: *Player, villager: *Entity) void {
    var stream = BinaryStream.init(player.entity.allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.ContainerOpenPacket{
        .identifier = state.window_id,
        .container_type = .Trading,
        .position = Protocol.BlockPosition.init(0, 0, 0),
        .unique_id = villager.unique_id,
    };
    const serialized = packet.serialize(&stream) catch return;
    player.network.sendPacket(player.connection, serialized) catch {};
}

fn sendUpdateTrade(
    state: *const State,
    player: *Player,
    villager: *Entity,
    offers: NBT.Tag,
    tier: u32,
    display_name: []const u8,
) void {
    var stream = BinaryStream.init(player.entity.allocator, null, null);
    defer stream.deinit();

    var packet = Protocol.UpdateTradePacket{
        .identifier = state.window_id,
        .container_type = .Trading,
        .size = 0,
        .trade_tier = tier,
        .villager_unique_id = villager.unique_id,
        .entity_unique_id = player.entity.unique_id,
        .display_name = display_name,
        .new_trade_ui = true,
        .demand_based_price = true,
        .offers = offers,
    };
    const serialized = packet.serialize(&stream) catch return;
    player.network.sendPacket(player.connection, serialized) catch {};
}

fn evacuate(state: *State, player: *Player) void {
    if (!state.initialized) return;

    const inv_state = player.entity.getTraitState(InventoryTrait) orelse return;
    for (state.container.storage, 0..) |_, i| {
        const taken = state.container.takeItem(@intCast(i), std.math.maxInt(u16)) orelse continue;
        var item = taken;
        const leftover = addRemainder(&inv_state.container.base, &item);
        if (leftover == 0) {
            item.deinit();
            continue;
        }
        item.stack_size = leftover;
        dropItem(player, item);
    }
    inv_state.container.sendContentUpdate();
}

fn addRemainder(dst: *Container, item: *ItemStack) u16 {
    var remaining: u16 = item.stack_size;

    if (item.item_type.stackable) {
        for (dst.storage, 0..) |*slot, i| {
            if (remaining == 0) break;
            if (slot.*) |*existing| {
                if (existing.isStackCompatible(item) and
                    existing.stack_size < existing.item_type.max_stack_size)
                {
                    const space = existing.item_type.max_stack_size - existing.stack_size;
                    const to_add = @min(space, remaining);
                    existing.stack_size += to_add;
                    remaining -= to_add;
                    dst.updateSlot(@intCast(i));
                }
            }
        }
    }

    while (remaining > 0) {
        const empty_slot = for (dst.storage, 0..) |slot, i| {
            if (slot == null) break i;
        } else break;

        const to_place = @min(remaining, item.item_type.max_stack_size);
        dst.storage[empty_slot] = item.cloneWithCount(dst.allocator, to_place) catch break;
        remaining -= to_place;
        dst.updateSlot(@intCast(empty_slot));
    }

    return remaining;
}

fn dropItem(player: *Player, item: ItemStack) void {
    const dimension = player.entity.dimension orelse {
        var dropped = item;
        dropped.deinit();
        return;
    };
    const spawn_position = PlayerMath.playerDropSpawnPosition(player.entity.position);
    const velocity = PlayerMath.playerDropVelocity(player.entity.rotation);
    _ = entities.spawnItemStackEntity(dimension, item, spawn_position, 40, velocity) catch {
        var dropped = item;
        dropped.deinit();
    };
}

pub const TradeWindowTrait = EntityTrait(State, .{
    .identifier = "trade-window",
    .on_attach = onAttach,
    .on_detach = onDetach,
});
