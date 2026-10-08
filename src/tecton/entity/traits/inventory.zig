const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");
const Entity = @import("../entity.zig").Entity;
const EntityTrait = @import("./trait.zig").EntityTrait;
const Player = @import("../../player/player.zig").Player;
const NetworkHandler = @import("../../player/player.zig").NetworkHandler;
const Container = @import("../../container/container.zig").Container;
const EntityContainer = @import("../../container/entity_container.zig").EntityContainer;
const ItemStack = @import("../../items/item_stack.zig").ItemStack;
const ItemType = @import("../../items/item_type.zig").ItemType;
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

pub fn serializeArmor(state: *const State, runtime_id: i64, stream: *BinaryStream) ?[]const u8 {
    const armor = state.armor orelse return null;

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

    const item_type = piece.item_type;
    if (armorSlotFor(item_type) == null) return false;

    const applied = swapIntoArmor(state, slot) != null;
    if (applied) state.container.updateSlot(slot);

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

pub const InventoryTrait = EntityTrait(State, .{
    .identifier = "inventory",
    .on_attach = onAttach,
    .on_detach = onDetach,
    .on_spawn = onSpawn,
    .on_tick = onTick,
    .on_container_update = onContainerUpdate,
});

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const BinaryStream = test_owner.BinaryStream;
    pub const Protocol = test_owner.Protocol;
    pub const Container = test_owner.Container;
    pub const EntityContainer = test_owner.EntityContainer;
    pub const ItemStack = test_owner.ItemStack;
    pub const ItemType = test_owner.ItemType;
    pub const State = test_owner.State;
    pub const selectHeldSlot = test_owner.selectHeldSlot;
    pub const serializeArmor = test_owner.serializeArmor;
    pub const armorSlotFor = test_owner.armorSlotFor;
    pub const swapIntoArmor = test_owner.swapIntoArmor;
    pub const testArmorPiece = test_owner.testArmorPiece;
};

test "selectHeldSlot updates held slot without packet side effects" {
    try @import("inventory_test.zig").Suite(test_scope).case_000();
}

test "the armor packet reports the four worn pieces in slot order" {
    try @import("inventory_test.zig").Suite(test_scope).case_001();
}

test "armor slots are read off the item name" {
    try @import("inventory_test.zig").Suite(test_scope).case_002();
}

test "equipping into an empty armor slot leaves the hotbar slot cleared" {
    try @import("inventory_test.zig").Suite(test_scope).case_003();
}

test "a right-click equip swaps the piece with the armor it lands on" {
    try @import("inventory_test.zig").Suite(test_scope).case_004();
}
