const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");
const Entity = @import("../entity.zig").Entity;
const EntityTrait = @import("./trait.zig").EntityTrait;
const Player = @import("../../player/player.zig").Player;
const NetworkHandler = @import("../../player/player.zig").NetworkHandler;
const Container = @import("../../container/container.zig").Container;
const EntityContainer = @import("../../container/entity-container.zig").EntityContainer;
const ItemStack = @import("../../items/item-stack.zig").ItemStack;
const ItemType = @import("../../items/item-type.zig").ItemType;
const EnchantmentEffects = @import("../../items/enchantments/effects.zig");

pub const State = struct {
    container: EntityContainer,
    armor: ?Container = null,
    selected_slot: u8,
    opened: bool,
};

fn getPlayer(entity: *Entity) ?*Player {
    if (!std.mem.eql(u8, entity.entity_type.identifier, "minecraft:player")) return null;
    return @fieldParentPtr("entity", entity);
}

fn onAttach(state: *State, entity: *Entity) void {
    const player = getPlayer(entity) orelse return;
    state.container = EntityContainer.init(entity.allocator, player, .Inventory, 36) catch return;
    state.container.base.identifier = .Inventory;
    state.armor = Container.init(entity.allocator, .Inventory, 4) catch null;
}

fn onDetach(state: *State, _: *Entity) void {
    state.container.deinit();
    if (state.armor) |*armor| armor.deinit();
}

fn onSpawn(state: *State, entity: *Entity) void {
    const player = getPlayer(entity) orelse return;
    if (player.spawned) state.container.update();
}

fn onTick(state: *State, _: *Entity) void {
    const occupants = state.container.base.getAllOccupants();
    const has_occupants = occupants.count() > 0;

    if (!state.opened and has_occupants) {
        state.opened = true;
    }
    if (state.opened and !has_occupants) {
        state.opened = false;
    }
}

fn onContainerUpdate(state: *State, _: *Entity, container: *Container) void {
    if (container != &state.container.base) return;
}

pub fn getHeldItem(state: *const State) ?*const ItemStack {
    return state.container.base.getItem(state.selected_slot);
}

test "selectHeldSlot updates held slot without packet side effects" {
    const allocator = std.testing.allocator;

    var container = try EntityContainer.init(allocator, undefined, .Inventory, 36);
    defer container.deinit();

    var state = State{
        .container = container,
        .selected_slot = 0,
        .opened = false,
    };

    selectHeldSlot(&state, 5);

    try std.testing.expectEqual(@as(u8, 5), state.selected_slot);
}

pub fn setHeldItem(state: *State, entity: *Entity, slot: u8) void {
    const player = getPlayer(entity) orelse return;
    selectHeldSlot(state, slot);

    var stream = BinaryStream.init(entity.allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.MobEquipmentPacket{
        .runtime_entity_id = @bitCast(entity.runtime_id),
        .item = descriptorFor(getHeldItem(state)),
        .slot = slot,
        .selected_slot = slot,
        .container_id = .Inventory,
    };
    const serialized = packet.serialize(&stream) catch return;
    player.network.sendPacket(player.connection, serialized) catch {};
}

pub fn selectHeldSlot(state: *State, slot: u8) void {
    state.selected_slot = slot;
}

fn emptyDescriptor() Protocol.NetworkItemStackDescriptor {
    return Protocol.NetworkItemStackDescriptor{
        .network = 0,
        .stack_size = null,
        .metadata = null,
        .item_stack_id = null,
        .network_block_id = null,
        .extras = null,
    };
}

fn descriptorFor(item: ?*const ItemStack) Protocol.NetworkItemStackDescriptor {
    return if (item) |stack| stack.toNetworkStack() else emptyDescriptor();
}

/// Worn armor reaches other clients through `MobArmorEquipment` (0x20);
/// `MobEquipment` (0x1f) carries only the held item.
pub fn serializeArmor(state: *const State, runtime_id: i64, stream: *BinaryStream) ?[]const u8 {
    const armor = state.armor orelse return null;

    // Armor container order; the body slot is unused by players.
    const packet = Protocol.MobArmorEquipmentPacket{
        .runtime_entity_id = @intCast(runtime_id),
        .helmet = descriptorFor(armor.getItem(0)),
        .chestplate = descriptorFor(armor.getItem(1)),
        .leggings = descriptorFor(armor.getItem(2)),
        .boots = descriptorFor(armor.getItem(3)),
        .body = emptyDescriptor(),
    };
    return packet.serialize(stream) catch null;
}

pub fn broadcastArmor(network: *NetworkHandler, player: *Player, state: *const State) void {
    var stream = BinaryStream.init(player.entity.allocator, null, null);
    defer stream.deinit();

    const serialized = serializeArmor(state, player.entity.runtime_id, &stream) orelse return;

    const dimension = player.entity.dimension orelse return;
    const snapshots = player.tecton.getPlayerSnapshots();
    for (snapshots) |other| {
        if (other.entity.dimension != dimension) continue;
        if (other.entity.runtime_id == player.entity.runtime_id) continue;
        if (!other.spawned) continue;
        if (!other.visible_players.contains(player.entity.runtime_id)) continue;
        network.sendPacket(other.connection, serialized) catch continue;
    }
}

pub fn sendEquipmentTo(viewer: *Player, target: *Player, state: *const State) void {
    {
        var stream = BinaryStream.init(target.entity.allocator, null, null);
        defer stream.deinit();

        if (serializeArmor(state, target.entity.runtime_id, &stream)) |serialized| {
            viewer.network.sendPacket(viewer.connection, serialized) catch {};
        }
    }

    {
        const held = getHeldItem(state);

        var stream = BinaryStream.init(target.entity.allocator, null, null);
        defer stream.deinit();

        const packet = Protocol.MobEquipmentPacket{
            .runtime_entity_id = @intCast(target.entity.runtime_id),
            .item = descriptorFor(held),
            .slot = state.selected_slot,
            .selected_slot = state.selected_slot,
            .container_id = .Inventory,
        };
        const serialized = packet.serialize(&stream) catch return;
        viewer.network.sendPacket(viewer.connection, serialized) catch {};
    }
}

/// Armor slot an item belongs on, or null when no player wears it; the elytra is a chest piece.
pub fn armorSlotFor(item_type: *const ItemType) ?u8 {
    const identifier = item_type.identifier;
    if (std.mem.endsWith(u8, identifier, "_helmet")) return 0;
    if (std.mem.endsWith(u8, identifier, "_chestplate")) return 1;
    if (std.mem.eql(u8, identifier, "minecraft:elytra")) return 1;
    if (std.mem.endsWith(u8, identifier, "_leggings")) return 2;
    if (std.mem.endsWith(u8, identifier, "_boots")) return 3;
    return null;
}

pub fn swapIntoArmor(state: *State, slot: u8) ?u8 {
    const piece = state.container.base.getItem(slot) orelse return null;
    const armor_slot = armorSlotFor(piece.item_type) orelse return null;

    if (state.armor) |*armor| {
        if (armor.getItem(armor_slot)) |worn| {
            if (EnchantmentEffects.blocksArmorRemoval(worn)) return null;
        }

        const taken = state.container.base.takeItem(slot, 1) orelse return null;
        const replaced = armor.takeItem(armor_slot, 1);
        armor.setItem(armor_slot, taken);
        if (replaced) |worn| state.container.base.setItem(slot, worn);
        return @intCast(armor_slot);
    }
    return null;
}

pub fn equipFromSlot(network: *NetworkHandler, player: *Player, state: *State, slot: u8) bool {
    const piece = state.container.base.getItem(slot) orelse return false;
    // Read the item type before the swap: taking the stack clears the slot's pointer.
    const item_type = piece.item_type;
    if (armorSlotFor(item_type) == null) return false;

    const applied = swapIntoArmor(state, slot) != null;
    if (applied) state.container.updateSlot(slot);

    // The owner gets the real set, undoing the client's predicted swap.
    sendEquipmentTo(player, player, state);
    if (!applied) return false;

    Raknet.Logger.INFO("Player {s} put on {s} from hotbar slot {d}", .{
        player.username,
        item_type.identifier,
        slot,
    });

    broadcastArmor(network, player, state);
    broadcastHeldItem(network, player, state, slot, state.selected_slot);
    return true;
}

pub fn broadcastHeldItem(network: *NetworkHandler, player: *Player, state: *const State, slot: u8, selected_slot: u8) void {
    var stream = BinaryStream.init(player.entity.allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.MobEquipmentPacket{
        .runtime_entity_id = @intCast(player.entity.runtime_id),
        .item = descriptorFor(getHeldItem(state)),
        .slot = slot,
        .selected_slot = selected_slot,
        .container_id = .Inventory,
    };
    const serialized = packet.serialize(&stream) catch return;

    const dimension = player.entity.dimension orelse return;
    const snapshots = player.tecton.getPlayerSnapshots();
    for (snapshots) |other| {
        if (other.entity.dimension != dimension) continue;
        if (other.entity.runtime_id == player.entity.runtime_id) continue;
        if (!other.spawned) continue;
        if (!other.visible_players.contains(player.entity.runtime_id)) continue;
        network.sendPacket(other.connection, serialized) catch continue;
    }
}

fn testArmorPiece(allocator: std.mem.Allocator, identifier: []const u8, network_id: i32) !*ItemType {
    const kind = try ItemType.init(
        allocator,
        try allocator.dupe(u8, identifier),
        network_id,
        1,
        false,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    try kind.register();
    return kind;
}

test "the armor packet reports the four worn pieces in slot order" {
    const allocator = std.testing.allocator;

    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    const kinds = [4]*ItemType{
        try testArmorPiece(allocator, "minecraft:test_inventory_helmet", 11),
        try testArmorPiece(allocator, "minecraft:test_inventory_chestplate", 12),
        try testArmorPiece(allocator, "minecraft:test_inventory_leggings", 13),
        try testArmorPiece(allocator, "minecraft:test_inventory_boots", 14),
    };

    var state = State{
        .container = try EntityContainer.init(allocator, undefined, .Inventory, 36),
        .armor = try Container.init(allocator, .Inventory, 4),
        .selected_slot = 0,
        .opened = false,
    };
    defer state.container.deinit();
    defer if (state.armor) |*armor| armor.deinit();

    for (kinds, 0..) |kind, slot| {
        state.armor.?.setItem(@intCast(slot), ItemStack.init(allocator, kind, .{}));
    }

    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();

    const serialized = serializeArmor(&state, 7, &stream) orelse return error.TestUnexpectedResult;

    var reader = BinaryStream.init(allocator, serialized, null);
    defer reader.deinit();

    _ = try reader.readVarInt();
    _ = try reader.readVarLong();

    var pieces: [5]Protocol.NetworkItemStackDescriptor = undefined;
    for (&pieces) |*piece| piece.* = try Protocol.NetworkItemStackDescriptor.readShort(&reader, allocator);
    defer {
        for (&pieces) |*piece| piece.deinit(allocator);
    }

    for (kinds, 0..) |kind, slot| {
        try std.testing.expectEqual(kind.network_id, pieces[slot].network);
    }
    try std.testing.expectEqual(@as(i32, 0), pieces[4].network);
}

test "armor slots are read off the item name" {
    const allocator = std.testing.allocator;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    const kinds = [6]*ItemType{
        try testArmorPiece(allocator, "minecraft:test_equip_helmet", 21),
        try testArmorPiece(allocator, "minecraft:test_equip_chestplate", 22),
        try testArmorPiece(allocator, "minecraft:test_equip_leggings", 23),
        try testArmorPiece(allocator, "minecraft:test_equip_boots", 24),
        try testArmorPiece(allocator, "minecraft:elytra", 25),
        try testArmorPiece(allocator, "minecraft:test_equip_sword", 26),
    };

    try std.testing.expectEqual(@as(?u8, 0), armorSlotFor(kinds[0]));
    try std.testing.expectEqual(@as(?u8, 1), armorSlotFor(kinds[1]));
    try std.testing.expectEqual(@as(?u8, 2), armorSlotFor(kinds[2]));
    try std.testing.expectEqual(@as(?u8, 3), armorSlotFor(kinds[3]));
    try std.testing.expectEqual(@as(?u8, 1), armorSlotFor(kinds[4]));
    try std.testing.expectEqual(@as(?u8, null), armorSlotFor(kinds[5]));
}

test "equipping into an empty armor slot leaves the hotbar slot cleared" {
    const allocator = std.testing.allocator;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    const chestplate = try testArmorPiece(allocator, "minecraft:test_empty_chestplate", 41);

    var state = State{
        .container = try EntityContainer.init(allocator, undefined, .Inventory, 36),
        .armor = try Container.init(allocator, .Inventory, 4),
        .selected_slot = 2,
        .opened = false,
    };
    defer state.container.deinit();
    defer if (state.armor) |*armor| armor.deinit();

    state.container.base.setItem(2, ItemStack.init(allocator, chestplate, .{}));

    // Read the type while the stack is still in the slot, like equipFromSlot.
    const item_type = state.container.base.getItem(2).?.item_type;

    try std.testing.expectEqual(@as(?u8, 1), swapIntoArmor(&state, 2));
    try std.testing.expect(state.container.base.getItem(2) == null);
    try std.testing.expectEqual(@as(i32, 41), item_type.network_id);
}

test "a right-click equip swaps the piece with the armor it lands on" {
    const allocator = std.testing.allocator;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    const helmet = try testArmorPiece(allocator, "minecraft:test_swap_helmet", 31);
    const boots = try testArmorPiece(allocator, "minecraft:test_swap_boots", 32);
    const sword = try testArmorPiece(allocator, "minecraft:test_swap_sword", 33);

    var state = State{
        .container = try EntityContainer.init(allocator, undefined, .Inventory, 36),
        .armor = try Container.init(allocator, .Inventory, 4),
        .selected_slot = 3,
        .opened = false,
    };
    defer state.container.deinit();
    defer if (state.armor) |*armor| armor.deinit();

    state.armor.?.setItem(0, ItemStack.init(allocator, helmet, .{ .metadata = 7 }));
    state.container.base.setItem(3, ItemStack.init(allocator, boots, .{}));

    try std.testing.expectEqual(@as(?u8, 3), swapIntoArmor(&state, 3));
    try std.testing.expectEqual(@as(i32, 32), state.armor.?.getItem(3).?.item_type.network_id);
    try std.testing.expect(state.container.base.getItem(3) == null);

    state.container.base.setItem(3, ItemStack.init(allocator, helmet, .{ .metadata = 1 }));
    try std.testing.expectEqual(@as(?u8, 0), swapIntoArmor(&state, 3));
    try std.testing.expectEqual(@as(i32, 31), state.armor.?.getItem(0).?.item_type.network_id);
    try std.testing.expectEqual(@as(u32, 1), state.armor.?.getItem(0).?.metadata);
    try std.testing.expectEqual(@as(u32, 7), state.container.base.getItem(3).?.metadata);

    state.container.base.setItem(3, ItemStack.init(allocator, sword, .{}));
    try std.testing.expectEqual(@as(?u8, null), swapIntoArmor(&state, 3));
    try std.testing.expectEqual(@as(i32, 33), state.container.base.getItem(3).?.item_type.network_id);
}

pub const InventoryTrait = EntityTrait(State, .{
    .identifier = "inventory",
    .on_attach = onAttach,
    .on_detach = onDetach,
    .on_spawn = onSpawn,
    .on_tick = onTick,
    .on_container_update = onContainerUpdate,
});
