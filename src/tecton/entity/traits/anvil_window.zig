const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

const Container = @import("../../container/container.zig").Container;
const ItemStack = @import("../../items/item_stack.zig").ItemStack;
const Player = @import("../../player/player.zig").Player;
const PlayerMath = @import("../../player/player.zig");
const Entity = @import("../entity.zig").Entity;
const entities = @import("../../world/dimension/entities.zig");
const InventoryTrait = @import("./inventory.zig").InventoryTrait;
const EntityTrait = @import("./trait.zig").EntityTrait;

pub const INPUT_SLOT: u32 = 0;
pub const MATERIAL_SLOT: u32 = 1;
pub const RESULT_SLOT: u32 = 2;

pub const State = struct {
    container: Container,
    active: bool = false,
    committed: bool = false,
    initialized: bool = false,
};

fn getPlayer(entity: *Entity) ?*Player {
    if (!std.mem.eql(u8, entity.entity_type.identifier, "minecraft:player")) return null;
    return @fieldParentPtr("entity", entity);
}

fn onAttach(state: *State, entity: *Entity) void {
    if (getPlayer(entity) == null) return;
    state.container = Container.init(entity.allocator, .Anvil, 3) catch return;
    state.container.muted = true;
    state.initialized = true;
}

fn onDetach(state: *State, _: *Entity) void {
    if (!state.initialized) return;
    state.container.deinit();
}

pub fn activate(state: *State, player: *Player) void {
    if (!state.initialized or state.active) return;
    state.active = true;
    state.committed = false;
    sendResultSlot(player, null);
}

pub fn deactivate(state: *State, player: *Player) void {
    if (!state.initialized or !state.active) return;
    evacuate(state, player);
    state.active = false;
    state.committed = false;
}

pub fn sendResultSlot(player: *Player, item: ?*const ItemStack) void {
    sendSlotPacket(player, RESULT_SLOT, null);
    sendSlotPacket(player, RESULT_SLOT, item);
}

fn containerNameFor(slot: u32) Protocol.ContainerName {
    return switch (slot) {
        INPUT_SLOT => .AnvilInput,
        MATERIAL_SLOT => .AnvilMaterial,
        else => .AnvilResult,
    };
}

fn sendSlotPacket(player: *Player, slot: u32, item: ?*const ItemStack) void {
    var stream = BinaryStream.init(player.entity.allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.InventorySlotPacket{
        .container_id = .Ui,
        .slot = slot,
        .full_container_name = .{ .identifier = containerNameFor(slot), .dynamic_identifier = 0 },
        .storage_item = emptyDescriptor(),
        .item = if (item) |value| value.toNetworkStack() else emptyDescriptor(),
    };
    const serialized = packet.serialize(&stream) catch return;
    player.network.sendPacket(player.connection, serialized) catch {};
}

fn emptyDescriptor() Protocol.NetworkItemStackDescriptor {
    return .{
        .network = 0,
        .stack_size = null,
        .metadata = null,
        .item_stack_id = null,
        .network_block_id = null,
        .extras = null,
    };
}

fn evacuate(state: *State, player: *Player) void {
    const inv_state = player.entity.getTraitState(InventoryTrait) orelse return;

    state.container.clearSlot(RESULT_SLOT);

    for ([_]u32{ INPUT_SLOT, MATERIAL_SLOT }) |slot| {
        const taken = state.container.takeItem(slot, std.math.maxInt(u16)) orelse continue;
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

pub const AnvilWindowTrait = EntityTrait(State, .{
    .identifier = "anvil-window",
    .on_attach = onAttach,
    .on_detach = onDetach,
});
