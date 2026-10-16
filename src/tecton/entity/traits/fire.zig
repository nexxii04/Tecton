const std = @import("std");
const Protocol = @import("protocol");
const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const IntTag = NBT.IntTag;

const Entity = @import("../entity.zig").Entity;
const EntityTrait = @import("./trait.zig").EntityTrait;
const Health = @import("./health.zig");
const InventoryTrait = @import("./inventory.zig").InventoryTrait;
const Events = @import("../../events/types.zig");
const EnchantmentEffects = @import("../../items/enchantments/effects.zig");
const ArmorAggregate = @import("../../items/enchantments/compat.zig").ArmorAggregate;
const PlayerMath = @import("../../player/player.zig");
const broadcast = @import("../../world/dimension/broadcast.zig");
const entities = @import("../../world/dimension/entities.zig");
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const BlockPermutation = @import("../../world/block/block_permutation.zig").BlockPermutation;

pub const TICKS_PER_SECOND: i32 = 20;
pub const FIRE_DAMAGE_INTERVAL_TICKS: i32 = TICKS_PER_SECOND;
pub const FIRE_DAMAGE_PER_HIT: f32 = 1.0;
pub const FIRE_BLOCK_IGNITION_TICKS: i32 = 150;
pub const LAVA_IGNITION_TICKS: i32 = 300;
pub const FLAME_IGNITION_TICKS: i32 = 100;

pub const State = struct {
    fire_ticks: i32 = 0,
    damage_timer: i32 = 0,
    burn_source: Events.CombustSource = .fire_block,
    instigator_id: i64 = 0,
    fire_resistant: bool = false,
};

pub fn refreshedFireTicks(current: i32, incoming: i32) i32 {
    return @max(current, incoming);
}

pub fn isImmuneToFire(gamemode: ?Protocol.GameMode) bool {
    const mode = gamemode orelse return false;
    return !PlayerMath.damageable(mode);
}

pub fn takesFireDamage(state: *const State) bool {
    return !state.fire_resistant;
}

pub fn damageCauseFor(source: Events.CombustSource) Events.DamageCause {
    return switch (source) {
        .lava => .lava,
        .fire_block => .fire,
        else => .fire_tick,
    };
}

pub fn ignite(entity: *Entity, source: Events.CombustSource, instigator: ?*Entity, duration_ticks: i32) bool {
    const state = entity.getTraitState(FireTrait) orelse return false;
    const dimension = entity.dimension orelse return false;

    const instigator_id: i64 = if (instigator) |cause| cause.runtime_id else 0;
    const was_burning = state.fire_ticks > 0;
    var incoming = EnchantmentEffects.fireBurnDuration(duration_ticks, fireProtectionLevels(entity));

    if (!isRepeatIgnition(state, source, instigator_id)) {
        var event = Events.EntityCombustEvent{
            .entity = entity,
            .duration = incoming,
            .instigator = instigator,
            .source = source,
        };
        if (!dimension.world.tecton.events.emit(.EntityCombust, &event)) return false;
        incoming = event.duration;
    }

    if (isImmuneToFire(gamemodeOf(dimension, entity))) return false;

    const duration = refreshedFireTicks(state.fire_ticks, incoming);
    if (duration <= 0) return false;

    const extended = duration > state.fire_ticks;
    state.fire_ticks = duration;
    if (extended) {
        state.burn_source = source;
        state.instigator_id = instigator_id;
    }
    if (!was_burning) state.damage_timer = 0;
    syncOnFireFlag(state, entity);
    return true;
}

fn isRepeatIgnition(state: *const State, source: Events.CombustSource, instigator_id: i64) bool {
    return state.fire_ticks > 0 and source == state.burn_source and instigator_id == state.instigator_id;
}

pub fn extinguish(entity: *Entity) void {
    const state = entity.getTraitState(FireTrait) orelse return;
    if (state.fire_ticks <= 0) return;
    stopBurning(state, entity);
    broadcastExtinguishSound(entity);
    broadcastExtinguishParticles(entity);
}

fn onTick(state: *State, entity: *Entity) void {
    const dimension = entity.dimension orelse return;
    syncOnFireFlag(state, entity);
    const contact = scanContact(dimension, entity);

    if (contact.doused) {
        if (state.fire_ticks > 0) extinguishBurning(state, entity);
        return;
    }

    if (state.fire_ticks > 0 and isRainingOn(dimension, entity)) {
        extinguishBurning(state, entity);
        return;
    }

    if (isImmuneToFire(gamemodeOf(dimension, entity))) {
        if (state.fire_ticks > 0) stopBurning(state, entity);
        return;
    }

    if (contact.ignition) |source| {
        _ = ignite(entity, source, null, contactBurnDuration(source));
    }

    if (state.fire_ticks <= 0) return;

    state.fire_ticks -= 1;
    if (state.fire_ticks <= 0) {
        stopBurning(state, entity);
        return;
    }

    state.damage_timer += 1;
    if (state.damage_timer >= FIRE_DAMAGE_INTERVAL_TICKS) {
        state.damage_timer = 0;
        if (takesFireDamage(state)) applyFireDamage(state, entity, dimension);
    }
}

fn onDeath(state: *State, entity: *Entity) void {
    if (state.fire_ticks <= 0) return;
    stopBurning(state, entity);
}

fn onSerialize(state: *State, tag: *CompoundTag) void {
    if (state.fire_ticks <= 0) return;
    tag.set("FireTicks", .{ .Int = IntTag.init(state.fire_ticks, null) }) catch return;
    tag.set("FireDamageTimer", .{ .Int = IntTag.init(state.damage_timer, null) }) catch return;
    tag.set("FireBurnSource", .{ .Int = IntTag.init(@intFromEnum(state.burn_source), null) }) catch {};
}

fn onDeserialize(state: *State, tag: *const CompoundTag) void {
    const fire_ticks = readInt(tag, "FireTicks") orelse return;
    if (fire_ticks <= 0) return;
    state.fire_ticks = fire_ticks;
    state.damage_timer = readInt(tag, "FireDamageTimer") orelse 0;
    if (readInt(tag, "FireBurnSource")) |source| {
        state.burn_source = std.enums.fromInt(Events.CombustSource, source) orelse .fire_block;
    }
}

fn readInt(tag: *const CompoundTag, key: []const u8) ?i32 {
    const entry = tag.get(key) orelse return null;
    return switch (entry) {
        .Int => |value| value.value,
        else => null,
    };
}

fn extinguishBurning(state: *State, entity: *Entity) void {
    stopBurning(state, entity);
    broadcastExtinguishSound(entity);
    broadcastExtinguishParticles(entity);
}

fn stopBurning(state: *State, entity: *Entity) void {
    state.fire_ticks = 0;
    state.damage_timer = 0;
    state.instigator_id = 0;
    syncOnFireFlag(state, entity);
}

fn syncOnFireFlag(state: *const State, entity: *Entity) void {
    const burning = state.fire_ticks > 0;
    if (entity.flags.getFlag(.OnFire) == burning) return;
    setOnFireFlag(entity, burning);
}

fn setOnFireFlag(entity: *Entity, value: bool) void {
    entity.flags.setFlag(.OnFire, value);
    const dimension = entity.dimension orelse return;
    entities.updateEntityActorFlags(dimension, entity);
}

fn applyFireDamage(state: *State, entity: *Entity, dimension: *Dimension) void {
    var armor: ArmorAggregate = .empty;
    refreshArmor(entity, &armor);

    const cause = damageCauseFor(state.burn_source);
    var event = Events.DamageEvent{
        .attacker = resolveInstigator(dimension, state),
        .victim = entity,
        .amount = EnchantmentEffects.mitigate(&armor, cause, FIRE_DAMAGE_PER_HIT),
        .cause = cause,
    };
    if (!dimension.world.tecton.events.emit(.Damage, &event)) return;
    entity.fireEvent(.Damage, .{ entity, event.amount });
}

fn refreshArmor(entity: *Entity, armor: *ArmorAggregate) void {
    const inventory_state = entity.getTraitState(InventoryTrait) orelse return;
    if (inventory_state.armor) |*pieces| armor.refresh(pieces);
}

fn fireProtectionLevels(entity: *Entity) u8 {
    var armor: ArmorAggregate = .empty;
    refreshArmor(entity, &armor);
    return armor.fire_protection;
}

fn resolveInstigator(dimension: *Dimension, state: *const State) ?*Entity {
    if (state.instigator_id == 0) return null;
    const tecton = dimension.world.tecton;
    if (tecton.findPlayerByRuntimeId(state.instigator_id)) |player| return &player.entity;
    return dimension.getEntity(state.instigator_id);
}

fn gamemodeOf(dimension: *Dimension, entity: *Entity) ?Protocol.GameMode {
    if (!Health.isPlayer(entity)) return null;
    const player = dimension.world.tecton.findPlayerByRuntimeId(entity.runtime_id) orelse return null;
    return player.gamemode;
}

fn contactBurnDuration(source: Events.CombustSource) i32 {
    return if (source == .lava) LAVA_IGNITION_TICKS else FIRE_BLOCK_IGNITION_TICKS;
}

const Contact = struct {
    doused: bool = false,
    ignition: ?Events.CombustSource = null,
};

fn scanContact(dimension: *Dimension, entity: *Entity) Contact {
    var contact = Contact{};
    const feet = blockPositionAt(feetPosition(entity));
    const heights = [_]i32{ feet.y, feet.y + 1 };
    for (heights) |y| {
        const permutation = blockPermutationAt(dimension, feet.x, y, feet.z) orelse continue;
        recordContact(permutation, &contact);
    }
    return contact;
}

fn recordContact(permutation: *const BlockPermutation, contact: *Contact) void {
    const identifier = permutation.identifier;
    if (std.mem.eql(u8, identifier, "minecraft:water") or
        std.mem.eql(u8, identifier, "minecraft:flowing_water") or
        isFilledCauldron(permutation, "water"))
    {
        contact.doused = true;
        return;
    }
    if (std.mem.eql(u8, identifier, "minecraft:lava") or
        std.mem.eql(u8, identifier, "minecraft:flowing_lava") or
        isFilledCauldron(permutation, "lava"))
    {
        contact.ignition = .lava;
        return;
    }
    if (std.mem.eql(u8, identifier, "minecraft:fire") or
        std.mem.eql(u8, identifier, "minecraft:soul_fire") or
        isLitCampfire(permutation))
    {
        if (contact.ignition == null) contact.ignition = .fire_block;
    }
}

fn isFilledCauldron(permutation: *const BlockPermutation, liquid: []const u8) bool {
    if (!std.mem.eql(u8, permutation.identifier, "minecraft:cauldron")) return false;
    const contents = permutation.state.get("cauldron_liquid") orelse return false;
    if (contents != .string or !std.mem.eql(u8, contents.string, liquid)) return false;
    const fill_level = permutation.state.get("fill_level") orelse return false;
    return fill_level == .integer and fill_level.integer > 0;
}

fn isLitCampfire(permutation: *const BlockPermutation) bool {
    if (!std.mem.eql(u8, permutation.identifier, "minecraft:campfire") and
        !std.mem.eql(u8, permutation.identifier, "minecraft:soul_campfire")) return false;
    const extinguished = permutation.state.get("extinguished") orelse return true;
    return switch (extinguished) {
        .boolean => |value| !value,
        else => true,
    };
}

fn isRainingOn(dimension: *Dimension, entity: *Entity) bool {
    if (dimension.world.weather == .clear) return false;
    return hasSkyAccess(dimension, entity);
}

fn hasSkyAccess(dimension: *Dimension, entity: *Entity) bool {
    const feet = blockPositionAt(feetPosition(entity));
    const chunk = dimension.getChunk(feet.x >> 4, feet.z >> 4) orelse return false;
    return chunk.isSkyExposed(feet.x, feet.y, feet.z);
}

fn feetPosition(entity: *Entity) Protocol.Vector3f {
    if (Health.isPlayer(entity)) return PlayerMath.internalToWorldFeetPosition(entity.position);
    return entity.position;
}

fn blockPositionAt(position: Protocol.Vector3f) Protocol.BlockPosition {
    return .{
        .x = @intFromFloat(@floor(position.x)),
        .y = @intFromFloat(@floor(position.y)),
        .z = @intFromFloat(@floor(position.z)),
    };
}

fn blockPermutationAt(dimension: *Dimension, x: i32, y: i32, z: i32) ?*BlockPermutation {
    const chunk = dimension.getChunk(x >> 4, z >> 4) orelse return null;
    return chunk.getPermutationReadOnly(x, y, z, 0) catch null;
}

fn broadcastExtinguishSound(entity: *Entity) void {
    const dimension = entity.dimension orelse return;
    var stream = BinaryStream.init(dimension.allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.LevelSoundEventPacket{
        .event = .extinguish_fire,
        .position = feetPosition(entity),
        .data = 0,
        .actor_identifier = "",
        .is_baby_mob = false,
        .is_global = false,
    };
    const serialized = packet.serialize(&stream) catch return;
    broadcast.broadcastToEntityViewers(dimension, entity, serialized);
}

fn broadcastExtinguishParticles(entity: *Entity) void {
    const dimension = entity.dimension orelse return;
    var stream = BinaryStream.init(dimension.allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.LevelEventPacket{
        .event = .ParticlesEvaporate,
        .position = feetPosition(entity),
        .data = 0,
    };
    const serialized = packet.serialize(&stream) catch return;
    broadcast.broadcastToEntityViewers(dimension, entity, serialized);
}

pub const FireTrait = EntityTrait(State, .{
    .identifier = "fire",
    .entities = Health.DAMAGEABLE_ENTITIES,
    .default_state = .{},
    .on_tick = onTick,
    .on_death = onDeath,
    .on_serialize = onSerialize,
    .on_deserialize = onDeserialize,
});

const testing = std.testing;
const EntityType = @import("../entity_type.zig").EntityType;

const test_owner = @This();
const test_scope = struct {
    pub const test_dependency_0 = @import("../../world/chunk/chunk.zig");
    pub const test_dependency_1 = @import("../../world/dimension/dimension.zig");
    pub const test_dependency_2 = @import("../../world/block/block_permutation.zig");
    pub const test_dependency_3 = @import("../../world/block/block_type.zig");
    pub const Protocol = test_owner.Protocol;
    pub const CompoundTag = test_owner.CompoundTag;
    pub const IntTag = test_owner.IntTag;
    pub const Entity = test_owner.Entity;
    pub const Events = test_owner.Events;
    pub const entities = test_owner.entities;
    pub const Dimension = test_owner.Dimension;
    pub const BlockPermutation = test_owner.BlockPermutation;
    pub const FIRE_BLOCK_IGNITION_TICKS = test_owner.FIRE_BLOCK_IGNITION_TICKS;
    pub const LAVA_IGNITION_TICKS = test_owner.LAVA_IGNITION_TICKS;
    pub const State = test_owner.State;
    pub const refreshedFireTicks = test_owner.refreshedFireTicks;
    pub const isImmuneToFire = test_owner.isImmuneToFire;
    pub const takesFireDamage = test_owner.takesFireDamage;
    pub const damageCauseFor = test_owner.damageCauseFor;
    pub const isRepeatIgnition = test_owner.isRepeatIgnition;
    pub const onSerialize = test_owner.onSerialize;
    pub const onDeserialize = test_owner.onDeserialize;
    pub const syncOnFireFlag = test_owner.syncOnFireFlag;
    pub const contactBurnDuration = test_owner.contactBurnDuration;
    pub const hasSkyAccess = test_owner.hasSkyAccess;
    pub const testing = test_owner.testing;
    pub const EntityType = test_owner.EntityType;
};

test "a shorter ignition never shrinks an active burn" {
    try @import("fire_test.zig").Suite(test_scope).case_000();
}

test "creative and spectator entities are immune to fire" {
    try @import("fire_test.zig").Suite(test_scope).case_001();
}

test "a repeated contact ignition is not a new combustion" {
    try @import("fire_test.zig").Suite(test_scope).case_002();
}

test "fire resistance keeps the entity burning but cancels the damage" {
    try @import("fire_test.zig").Suite(test_scope).case_003();
}

test "the burn damage cause follows the ignition source" {
    try @import("fire_test.zig").Suite(test_scope).case_004();
}

test "the burn state survives an nbt round trip" {
    try @import("fire_test.zig").Suite(test_scope).case_005();
}

test "an entity saved without fire loads cold and writes no tags" {
    try @import("fire_test.zig").Suite(test_scope).case_006();
}

test "an unknown burn source falls back to fire_block" {
    try @import("fire_test.zig").Suite(test_scope).case_007();
}

test "the on-fire flag re-synchronizes from the restored state" {
    try @import("fire_test.zig").Suite(test_scope).case_008();
}

test "sky access follows the cached column top of the chunk" {
    try @import("fire_test.zig").Suite(test_scope).case_009();
}
