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
    markInvulnerable(state, tecton.tick_count);

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

test "damage clamps at zero and never goes negative" {
    try testing.expectEqual(@as(f32, 15.0), applyDamage(20.0, 5.0));
    try testing.expectEqual(@as(f32, 0.0), applyDamage(3.0, 5.0));
    try testing.expectEqual(@as(f32, 0.0), applyDamage(0.0, 5.0));
    try testing.expectEqual(@as(f32, 20.0), applyDamage(20.0, 0.0));
    try testing.expect(!isDead(applyDamage(20.0, 19.9)));
    try testing.expect(isDead(applyDamage(20.0, 20.0)));
}

test "a health read back from disk below one comes back as full" {
    try testing.expectEqual(@as(f32, 20.0), clampLoadedHealth(20.0, 20.0));
    try testing.expectEqual(@as(f32, 7.5), clampLoadedHealth(7.5, 20.0));
    try testing.expectEqual(@as(f32, 20.0), clampLoadedHealth(0.0, 20.0));
    try testing.expectEqual(@as(f32, 20.0), clampLoadedHealth(-4.0, 20.0));
    try testing.expectEqual(@as(f32, 20.0), clampLoadedHealth(40.0, 20.0));
}

test "health survives an nbt round trip" {
    const allocator = testing.allocator;

    var tag = CompoundTag.init(allocator, null);
    defer tag.deinit(allocator);

    var hurt = State{ .current = 7.5, .max = 20.0 };
    onSerialize(&hurt, &tag);

    var restored = State{ .current = 20.0, .max = 20.0 };
    onDeserialize(&restored, &tag);
    try testing.expectEqual(@as(f32, 7.5), restored.current);
    try testing.expectEqual(@as(f32, 20.0), restored.max);

    var boosted_tag = CompoundTag.init(allocator, null);
    defer boosted_tag.deinit(allocator);

    var boosted = State{ .current = 24.0, .max = 30.0 };
    onSerialize(&boosted, &boosted_tag);

    var boosted_restored = State{ .current = 20.0, .max = 20.0 };
    onDeserialize(&boosted_restored, &boosted_tag);
    try testing.expectEqual(@as(f32, 24.0), boosted_restored.current);
    try testing.expectEqual(@as(f32, 30.0), boosted_restored.max);
}

test "serializing health twice does not leak the compound key" {
    const allocator = testing.allocator;

    var tag = CompoundTag.init(allocator, null);
    defer tag.deinit(allocator);

    var state = State{ .current = 7.5, .max = 20.0 };
    onSerialize(&state, &tag);
    onSerialize(&state, &tag);

    try testing.expectEqual(@as(usize, 2), tag.count());
    try testing.expectEqual(@as(f32, 7.5), tag.get("Health").?.Float.value);
}

test "a record without health comes back at full" {
    const allocator = testing.allocator;

    var tag = CompoundTag.init(allocator, null);
    defer tag.deinit(allocator);

    var restored = State{ .current = 20.0, .max = 20.0 };
    onDeserialize(&restored, &tag);
    try testing.expectEqual(@as(f32, 20.0), restored.current);
    try testing.expectEqual(@as(f32, 20.0), restored.max);
}

test "a stored zero stays zero instead of healing to full" {
    const allocator = testing.allocator;

    var tag = CompoundTag.init(allocator, null);
    defer tag.deinit(allocator);
    try tag.set("Health", .{ .Float = FloatTag.init(0.0, null) });
    try tag.set("MaxHealth", .{ .Float = FloatTag.init(20.0, null) });

    var restored = State{ .current = 20.0, .max = 20.0 };
    onDeserialize(&restored, &tag);
    try testing.expectEqual(@as(f32, 0.0), restored.current);
    try testing.expect(isDead(restored.current));
}

test "only the player leaves a body behind when it dies" {
    const allocator = testing.allocator;

    const mob_type = EntityType.init("minecraft:zombie", 1, &.{}, &.{});
    const player_type = EntityType.init("minecraft:player", 1, &.{}, &.{});

    var mob = Entity.init(allocator, &mob_type, null);
    defer mob.deinit();
    var player = Entity.init(allocator, &player_type, null);
    defer player.deinit();

    try testing.expect(!isPlayer(&mob));
    try testing.expect(isPlayer(&player));
}

test "attaching the trait registers the health attribute and damage reaches the state" {
    const allocator = testing.allocator;

    const entity_type = EntityType.init("minecraft:zombie", 1, &.{}, &.{});
    var entity = Entity.init(allocator, &entity_type, null);
    defer entity.deinit();

    const trait = try HealthTrait.create(allocator, .{ .current = MAX_HEALTH, .max = MAX_HEALTH });
    try entity.addTrait(trait);

    const state = entity.getTraitState(HealthTrait).?;
    try testing.expectEqual(MAX_HEALTH, state.current);
    try testing.expect(!state.dead);
    try testing.expectEqual(MAX_HEALTH, entity.attributes.get(.Health).?.current);

    entity.fireEvent(.Damage, .{ &entity, 6.0 });
    try testing.expectEqual(@as(f32, 14.0), state.current);
    try testing.expectEqual(@as(f32, 14.0), entity.attributes.get(.Health).?.current);

    entity.fireEvent(.Damage, .{ &entity, 20.0 });
    try testing.expectEqual(@as(f32, 0.0), state.current);
    try testing.expect(isDead(state.current));

    entity.fireEvent(.Damage, .{ &entity, 5.0 });
    try testing.expectEqual(@as(f32, 0.0), state.current);

    try testing.expect(!revive(state, &entity));
}

test "the damage window opens on a landed hit and lasts ten ticks" {
    var state = State{ .current = MAX_HEALTH, .max = MAX_HEALTH };
    try testing.expect(!isInvulnerable(&state, 100));

    markInvulnerable(&state, 100);
    try testing.expect(isInvulnerable(&state, 100));
    try testing.expect(isInvulnerable(&state, 109));
    try testing.expect(!isInvulnerable(&state, 110));
    try testing.expectEqual(@as(u64, 110), state.invulnerable_until);

    markInvulnerable(&state, 110);
    try testing.expect(isInvulnerable(&state, 119));
    try testing.expect(!isInvulnerable(&state, 120));
}

test "a dead player ignores damage until it is revived" {
    const allocator = testing.allocator;

    const entity_type = EntityType.init("minecraft:player", 1, &.{}, &.{});
    var entity = Entity.init(allocator, &entity_type, null);
    defer entity.deinit();

    const trait = try HealthTrait.create(allocator, .{ .current = MAX_HEALTH, .max = MAX_HEALTH });
    try entity.addTrait(trait);

    const state = entity.getTraitState(HealthTrait).?;

    entity.fireEvent(.Damage, .{ &entity, 20.0 });
    try testing.expectEqual(@as(f32, 0.0), state.current);

    state.dead = true;
    entity.fireEvent(.Damage, .{ &entity, 4.0 });
    try testing.expectEqual(@as(f32, 0.0), state.current);

    markInvulnerable(state, 500);
    try testing.expect(revive(state, &entity));
    try testing.expectEqual(MAX_HEALTH, state.current);
    try testing.expectEqual(MAX_HEALTH, entity.attributes.get(.Health).?.current);
    try testing.expect(!isInvulnerable(state, 500));
    try testing.expect(!revive(state, &entity));

    entity.fireEvent(.Damage, .{ &entity, 3.0 });
    try testing.expectEqual(@as(f32, 17.0), state.current);
}

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
