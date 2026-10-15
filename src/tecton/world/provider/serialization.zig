const std = @import("std");
const testing = std.testing;

const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const ListTag = NBT.ListTag;
const Tag = NBT.Tag;
const FloatTag = NBT.FloatTag;
const ReadWriteOptions = NBT.ReadWriteOptions;
const Protocol = @import("protocol");

const Container = @import("../../container/container.zig").Container;
const EntityType = @import("../../entity/entity_type.zig").EntityType;
const Entity = @import("../../entity/entity.zig").Entity;
const Health = @import("../../entity/traits/health.zig");
const HealthTrait = Health.HealthTrait;
const InventoryTrait = @import("../../entity/traits/inventory.zig").InventoryTrait;
const enchantment_nbt = @import("../../items/enchantments/nbt.zig");
const EnchantmentTesting = @import("../../items/enchantments/testing.zig");
const ItemStack = @import("../../items/item_stack.zig").ItemStack;
const ItemType = @import("../../items/item_type.zig").ItemType;
const Player = @import("../../player/player.zig").Player;
const codec = @import("nbt_codec.zig");
const sanitize_mod = @import("sanitize.zig");
const ItemCodec = @import("serialize_items.zig").ItemCodec;
const EntityCodec = @import("serialize_entities.zig").EntityCodec;
const PlayerCodec = @import("serialize_player.zig").PlayerCodec;

pub const encodeNbt = codec.encodeNbt;
pub const decodeNbt = codec.decodeNbt;

pub const world_border = sanitize_mod.world_border;
pub const max_motion = sanitize_mod.max_motion;

// Hooks bind the entity, item, and trait types so the codec files stay outside the entity/item cycle.
const ItemHooks = struct {
    pub const Item = ItemStack;
    pub const Container = @import("../../container/container.zig").Container;

    pub fn syncEnchantments(item: *ItemStack) !void {
        return enchantment_nbt.sync(item);
    }

    pub fn load(allocator: std.mem.Allocator, name: []const u8, count: u16, metadata: u32, nbt_data: ?CompoundTag) ?ItemStack {
        const item_type = ItemType.get(name) orelse return null;
        var item = ItemStack.init(allocator, item_type, .{
            .stack_size = count,
            .metadata = metadata,
            .nbt = nbt_data,
        });
        enchantment_nbt.hydrate(&item);
        enchantment_nbt.sync(&item) catch {};
        return item;
    }
};

const EntityHooks = struct {
    pub fn reserveUniqueId(uid: i64) void {
        Entity.reserveUniqueId(uid);
    }
};

const PlayerHooks = struct {
    pub const InventoryState = InventoryTrait.TraitState;
    pub const HealthState = HealthTrait.TraitState;

    pub const serializeEntity = entities.serializeEntity;
    pub const deserializeEntity = entities.deserializeEntity;
    pub const serializeContainer = items.serializeContainer;
    pub const deserializeContainer = items.deserializeContainer;

    pub fn inventoryState(entity: *Entity) ?*InventoryState {
        return entity.getTraitState(InventoryTrait);
    }

    pub fn healthState(entity: *Entity) ?*HealthState {
        return entity.getTraitState(HealthTrait);
    }

    pub fn clampLoadedHealth(current: f32, max: f32) f32 {
        return Health.clampLoadedHealth(current, max);
    }

    pub fn syncAttributes(state: *const HealthState, entity: *Entity) void {
        Health.syncAttributes(state, entity);
    }
};

const items = ItemCodec(ItemHooks);
const entities = EntityCodec(EntityHooks);
const players = PlayerCodec(PlayerHooks);

pub const serializeItemStack = items.serializeItemStack;
pub const deserializeItemStack = items.deserializeItemStack;
pub const serializeContainer = items.serializeContainer;
pub const deserializeContainer = items.deserializeContainer;
pub const serializeEntity = entities.serializeEntity;
pub const deserializeEntity = entities.deserializeEntity;
pub const serializePlayer = players.serializePlayer;
pub const deserializePlayer = players.deserializePlayer;

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const testing = test_owner.testing;
    pub const Protocol = test_owner.Protocol;
    pub const CompoundTag = test_owner.CompoundTag;
    pub const encodeNbt = test_owner.encodeNbt;
    pub const decodeNbt = test_owner.decodeNbt;
    pub const ListTag = test_owner.ListTag;
    pub const Tag = test_owner.Tag;
    pub const FloatTag = test_owner.FloatTag;
    pub const EntityType = test_owner.EntityType;
    pub const Entity = test_owner.Entity;
    pub const EnchantmentTesting = test_owner.EnchantmentTesting;
    pub const ItemStack = test_owner.ItemStack;
    pub const ItemType = test_owner.ItemType;
    pub const Container = test_owner.Container;
    pub const serializeItemStack = test_owner.serializeItemStack;
    pub const deserializeItemStack = test_owner.deserializeItemStack;
    pub const serializeContainer = test_owner.serializeContainer;
    pub const deserializeContainer = test_owner.deserializeContainer;
    pub const serializeEntity = test_owner.serializeEntity;
    pub const deserializeEntity = test_owner.deserializeEntity;
    pub const world_border = test_owner.world_border;
    pub const max_motion = test_owner.max_motion;
    pub const Player = test_owner.Player;
    pub const InventoryTrait = test_owner.InventoryTrait;
    pub const serializePlayer = test_owner.serializePlayer;
    pub const deserializePlayer = test_owner.deserializePlayer;
};

test "a corrupt position and motion from disk are clamped on load" {
    try @import("serialization_test.zig").Suite(test_scope).case_000();
}

test "writing a stack syncs the enchantments the ops never wrote" {
    try @import("serialization_test.zig").Suite(test_scope).case_001();
}

test "an NBT round trip preserves bytes exactly" {
    try @import("serialization_test.zig").Suite(test_scope).case_002();
}

test "an enchanted item survives a serialize round trip byte for byte" {
    try @import("serialization_test.zig").Suite(test_scope).case_003();
}

test "an entity survives a serialize round trip byte for byte" {
    try @import("serialization_test.zig").Suite(test_scope).case_004();
}

test "a container survives a serialize round trip byte for byte" {
    try @import("serialization_test.zig").Suite(test_scope).case_005();
}

test "a player with inventory survives a serialize round trip byte for byte" {
    try @import("serialization_test.zig").Suite(test_scope).case_006();
}
