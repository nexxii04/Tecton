const std = @import("std");
const Protocol = @import("protocol");
const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const FloatTag = NBT.FloatTag;
const Entity = @import("../entity.zig").Entity;
const EntityType = @import("../entity_type.zig").EntityType;
const EntityTrait = @import("./trait.zig").EntityTrait;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const broadcast = @import("../../world/dimension/broadcast.zig");

pub const MAX_HEALTH: f32 = 20.0;

pub const INVULNERABILITY_TICKS: u64 = 10;

pub const State = struct {
    current: f32,
    max: f32,
    dead: bool = false,
    invulnerable_until: u64 = 0,
};

pub fn isInvulnerable(state: *const State, tick: u64) bool {
    return tick < state.invulnerable_until;
}

pub fn markInvulnerable(state: *State, tick: u64) void {
    state.invulnerable_until = tick +% INVULNERABILITY_TICKS;
}

fn onAttach(state: *State, entity: *Entity) void {
    entity.attributes.registerWithCurrent(.Health, 0, state.max, state.current, state.max) catch {};
}

pub fn applyDamage(current: f32, amount: f32) f32 {
    const next = current - amount;
    return if (next < 0) 0 else next;
}

pub fn isDead(current: f32) bool {
    return current <= 0;
}

pub fn clampLoadedHealth(current: f32, max: f32) f32 {
    if (current > 0) return @min(current, max);
    return max;
}

pub fn syncAttributes(state: *const State, entity: *Entity) void {
    entity.attributes.setMax(.Health, state.max);
    entity.attributes.setCurrent(.Health, state.current);
}

fn onSerialize(state: *State, tag: *CompoundTag) void {
    setFloat(tag, "Health", state.current);
    setFloat(tag, "MaxHealth", state.max);
}

fn setFloat(tag: *CompoundTag, key: []const u8, value: f32) void {
    if (tag.get(key) != null) return;
    tag.set(key, .{ .Float = FloatTag.init(value, null) }) catch {};
}

fn onDeserialize(state: *State, tag: *const CompoundTag) void {
    if (readFloat(tag, "MaxHealth")) |max| {
        if (max > 0) state.max = max;
    }
    if (readFloat(tag, "Health")) |current| {
        state.current = if (current < 0) 0 else @min(current, state.max);
    }
}

fn readFloat(tag: *const CompoundTag, key: []const u8) ?f32 {
    return switch (tag.get(key) orelse return null) {
        .Float => |value| value.value,
        else => null,
    };
}

pub fn isPlayer(entity: *const Entity) bool {
    return std.mem.eql(u8, entity.entity_type.identifier, "minecraft:player");
}

pub fn revive(state: *State, entity: *Entity) bool {
    if (!state.dead) return false;
    state.dead = false;
    state.current = state.max;
    state.invulnerable_until = 0;
    entity.attributes.setCurrent(.Health, state.current);
    return true;
}

fn onDamage(state: *State, entity: *Entity, amount: f32) void {
    if (state.dead) return;

    state.current = applyDamage(state.current, amount);
    entity.attributes.setCurrent(.Health, state.current);

    const dimension = entity.dimension orelse return;
    const tecton = dimension.world.tecton;
    markInvulnerable(state, tecton.tickCount());

    broadcastHurtAnimation(tecton.allocator, dimension, entity);
    broadcastDirtyAttributes(tecton.allocator, dimension, entity);

    if (!isDead(state.current)) return;

    state.dead = true;
    entity.fireEvent(.Death, .{entity});

    var stream = BinaryStream.init(tecton.allocator, null, null);
    defer stream.deinit();

    const death_packet = Protocol.ActorEventPacket{
        .runtime_entity_id = @bitCast(entity.runtime_id),
        .event = .DeathAnimation,
        .data = 0,
    };
    const serialized = death_packet.serialize(&stream) catch return;

    broadcast.broadcastToEntityViewers(dimension, entity, serialized);

    if (isPlayer(entity)) return;

    if (entity.ecs_id != 0) {
        _ = tecton.ecs.queueEntityDrop(@bitCast(entity.ecs_id), entity.position);
    }

    dimension.pending_removals.append(dimension.allocator, entity.runtime_id) catch {};
}

fn broadcastHurtAnimation(allocator: std.mem.Allocator, dimension: *Dimension, entity: *Entity) void {
    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.ActorEventPacket{
        .runtime_entity_id = @bitCast(entity.runtime_id),
        .event = .HurtAnimation,
        .data = 0,
    };
    const serialized = packet.serialize(&stream) catch return;

    broadcast.broadcastToEntityViewers(dimension, entity, serialized);
}

fn broadcastDirtyAttributes(allocator: std.mem.Allocator, dimension: *Dimension, entity: *Entity) void {
    var attrs = entity.attributes.collectDirty(allocator) catch return;
    defer attrs.deinit(allocator);
    if (attrs.items.len == 0) return;

    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();

    var attr_packet = Protocol.UpdateAttributesPacket{
        .runtime_actor_id = entity.runtime_id,
        .attributes = attrs,
        .tick = 0,
    };
    const serialized = attr_packet.serialize(&stream) catch return;

    broadcast.broadcastToEntityViewers(dimension, entity, serialized);
}

const testing = std.testing;

pub const DAMAGEABLE_ENTITIES: []const []const u8 = &.{
    "minecraft:zombie",
    "minecraft:skeleton",
    "minecraft:creeper",
    "minecraft:spider",
    "minecraft:cow",
    "minecraft:pig",
    "minecraft:sheep",
    "minecraft:chicken",
    "minecraft:wolf",
    "minecraft:villager",
    "minecraft:enderman",
    "minecraft:slime",
    "minecraft:silverfish",
    "minecraft:blaze",
    "minecraft:witch",
    "minecraft:bat",
    "minecraft:iron_golem",
    "minecraft:snow_golem",
    "minecraft:ocelot",
    "minecraft:horse",
    "minecraft:rabbit",
    "minecraft:polar_bear",
    "minecraft:llama",
    "minecraft:parrot",
    "minecraft:dolphin",
    "minecraft:drowned",
    "minecraft:phantom",
    "minecraft:cat",
    "minecraft:panda",
    "minecraft:fox",
    "minecraft:bee",
    "minecraft:hoglin",
    "minecraft:piglin",
    "minecraft:strider",
    "minecraft:zoglin",
    "minecraft:goat",
    "minecraft:axolotl",
    "minecraft:glow_squid",
    "minecraft:warden",
    "minecraft:allay",
    "minecraft:frog",
    "minecraft:camel",
    "minecraft:sniffer",
    "minecraft:armadillo",
    "minecraft:bogged",
    "minecraft:breeze",
};

pub const HealthTrait = EntityTrait(State, .{
    .identifier = "health",
    .entities = DAMAGEABLE_ENTITIES,
    .default_state = .{
        .current = 20.0,
        .max = 20.0,
    },
    .on_attach = onAttach,
    .on_damage = onDamage,
    .on_serialize = onSerialize,
    .on_deserialize = onDeserialize,
});

const test_owner = @This();
const test_scope = struct {
    pub const CompoundTag = test_owner.CompoundTag;
    pub const FloatTag = test_owner.FloatTag;
    pub const Entity = test_owner.Entity;
    pub const EntityType = test_owner.EntityType;
    pub const MAX_HEALTH = test_owner.MAX_HEALTH;
    pub const State = test_owner.State;
    pub const isInvulnerable = test_owner.isInvulnerable;
    pub const markInvulnerable = test_owner.markInvulnerable;
    pub const applyDamage = test_owner.applyDamage;
    pub const isDead = test_owner.isDead;
    pub const clampLoadedHealth = test_owner.clampLoadedHealth;
    pub const onSerialize = test_owner.onSerialize;
    pub const onDeserialize = test_owner.onDeserialize;
    pub const isPlayer = test_owner.isPlayer;
    pub const revive = test_owner.revive;
    pub const testing = test_owner.testing;
    pub const HealthTrait = test_owner.HealthTrait;
};

test "damage clamps at zero and never goes negative" {
    try @import("health_test.zig").Suite(test_scope).case_000();
}

test "a health read back from disk below one comes back as full" {
    try @import("health_test.zig").Suite(test_scope).case_001();
}

test "health survives an nbt round trip" {
    try @import("health_test.zig").Suite(test_scope).case_002();
}

test "serializing health twice does not leak the compound key" {
    try @import("health_test.zig").Suite(test_scope).case_003();
}

test "a record without health comes back at full" {
    try @import("health_test.zig").Suite(test_scope).case_004();
}

test "a stored zero stays zero instead of healing to full" {
    try @import("health_test.zig").Suite(test_scope).case_005();
}

test "only the player leaves a body behind when it dies" {
    try @import("health_test.zig").Suite(test_scope).case_006();
}

test "attaching the trait registers the health attribute and damage reaches the state" {
    try @import("health_test.zig").Suite(test_scope).case_007();
}

test "the damage window opens on a landed hit and lasts ten ticks" {
    try @import("health_test.zig").Suite(test_scope).case_008();
}

test "a dead player ignores damage until it is revived" {
    try @import("health_test.zig").Suite(test_scope).case_009();
}
