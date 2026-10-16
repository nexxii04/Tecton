const std_mod = @import("std");
const protocol_mod = @import("protocol");
const nbt_mod = @import("nbt");
const container_mod = @import("../../container/container.zig");
const entity_mod = @import("../../entity/entity.zig");
const entity_type_mod = @import("../../entity/entity_type.zig");
const inventory_mod = @import("../../entity/traits/inventory.zig");
const enchantment_testing_mod = @import("../../items/enchantments/testing.zig");
const item_stack_mod = @import("../../items/item_stack.zig");
const item_type_mod = @import("../../items/item_type.zig");
const player_mod = @import("../../player/player.zig");
const serialization = @import("serialization.zig");

const scope = struct {
    pub const std = std_mod;
    pub const testing = std_mod.testing;
    pub const Protocol = protocol_mod;
    pub const CompoundTag = nbt_mod.CompoundTag;
    pub const ListTag = nbt_mod.ListTag;
    pub const Tag = nbt_mod.Tag;
    pub const FloatTag = nbt_mod.FloatTag;
    pub const EntityType = entity_type_mod.EntityType;
    pub const Entity = entity_mod.Entity;
    pub const EnchantmentTesting = enchantment_testing_mod;
    pub const ItemStack = item_stack_mod.ItemStack;
    pub const ItemType = item_type_mod.ItemType;
    pub const Container = container_mod.Container;
    pub const Player = player_mod.Player;
    pub const InventoryTrait = inventory_mod.InventoryTrait;
    pub const encodeNbt = serialization.encodeNbt;
    pub const decodeNbt = serialization.decodeNbt;
    pub const serializeItemStack = serialization.serializeItemStack;
    pub const deserializeItemStack = serialization.deserializeItemStack;
    pub const serializeContainer = serialization.serializeContainer;
    pub const deserializeContainer = serialization.deserializeContainer;
    pub const serializeEntity = serialization.serializeEntity;
    pub const deserializeEntity = serialization.deserializeEntity;
    pub const serializePlayer = serialization.serializePlayer;
    pub const deserializePlayer = serialization.deserializePlayer;
    pub const world_border = serialization.world_border;
    pub const max_motion = serialization.max_motion;
};

test "a corrupt position and motion from disk are clamped on load" {
    try @import("serialization_test.zig").Suite(scope).case_000();
}

test "writing a stack syncs the enchantments the ops never wrote" {
    try @import("serialization_test.zig").Suite(scope).case_001();
}

test "an NBT round trip preserves bytes exactly" {
    try @import("serialization_test.zig").Suite(scope).case_002();
}

test "an enchanted item survives a serialize round trip byte for byte" {
    try @import("serialization_test.zig").Suite(scope).case_003();
}

test "an entity survives a serialize round trip byte for byte" {
    try @import("serialization_test.zig").Suite(scope).case_004();
}

test "a container survives a serialize round trip byte for byte" {
    try @import("serialization_test.zig").Suite(scope).case_005();
}

test "a player with inventory survives a serialize round trip byte for byte" {
    try @import("serialization_test.zig").Suite(scope).case_006();
}
