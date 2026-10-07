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
const BlockPermutation = @import("../../world/block/block-permutation.zig").BlockPermutation;

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

    var event = Events.DamageEvent{
        .attacker = resolveInstigator(dimension, state),
        .victim = entity,
        .amount = EnchantmentEffects.mitigatedFireDamage(&armor, FIRE_DAMAGE_PER_HIT),
        .cause = damageCauseFor(state.burn_source),
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
const EntityType = @import("../entity-type.zig").EntityType;

test "a shorter ignition never shrinks an active burn" {
    try testing.expectEqual(@as(i32, 80), refreshedFireTicks(0, 80));
    try testing.expectEqual(@as(i32, 80), refreshedFireTicks(80, 40));
    try testing.expectEqual(@as(i32, 80), refreshedFireTicks(80, 80));
    try testing.expectEqual(@as(i32, 160), refreshedFireTicks(80, 160));
    try testing.expectEqual(@as(i32, 0), refreshedFireTicks(0, -5));
}

test "creative and spectator entities are immune to fire" {
    try testing.expect(isImmuneToFire(.Creative));
    try testing.expect(isImmuneToFire(.Spectator));
    try testing.expect(isImmuneToFire(.CreativeSpectator));
    try testing.expect(isImmuneToFire(.SurvivalSpectator));
    try testing.expect(!isImmuneToFire(.Survival));
    try testing.expect(!isImmuneToFire(.Adventure));
    try testing.expect(!isImmuneToFire(null));
}

test "a repeated contact ignition is not a new combustion" {
    var state = State{ .fire_ticks = 200, .burn_source = .lava, .instigator_id = 0 };
    try testing.expect(isRepeatIgnition(&state, .lava, 0));
    try testing.expect(!isRepeatIgnition(&state, .fire_block, 0));
    try testing.expect(!isRepeatIgnition(&state, .lava, 42));

    state.fire_ticks = 0;
    try testing.expect(!isRepeatIgnition(&state, .lava, 0));

    try testing.expectEqual(@as(i32, LAVA_IGNITION_TICKS), refreshedFireTicks(LAVA_IGNITION_TICKS - 1, contactBurnDuration(.lava)));
    try testing.expectEqual(@as(i32, FIRE_BLOCK_IGNITION_TICKS), refreshedFireTicks(FIRE_BLOCK_IGNITION_TICKS - 1, contactBurnDuration(.fire_block)));
}

test "fire resistance keeps the entity burning but cancels the damage" {
    var state = State{};
    try testing.expect(takesFireDamage(&state));

    state.fire_resistant = true;
    try testing.expect(!takesFireDamage(&state));
}

test "the burn damage cause follows the ignition source" {
    try testing.expectEqual(Events.DamageCause.lava, damageCauseFor(.lava));
    try testing.expectEqual(Events.DamageCause.fire, damageCauseFor(.fire_block));
    try testing.expectEqual(Events.DamageCause.fire_tick, damageCauseFor(.fire_aspect));
    try testing.expectEqual(Events.DamageCause.fire_tick, damageCauseFor(.command));
    try testing.expectEqual(Events.DamageCause.fire_tick, damageCauseFor(.projectile));
}

test "the burn state survives an nbt round trip" {
    const allocator = testing.allocator;

    var tag = CompoundTag.init(allocator, null);
    defer tag.deinit(allocator);

    var burning = State{ .fire_ticks = 120, .damage_timer = 7, .burn_source = .lava, .instigator_id = 42 };
    onSerialize(&burning, &tag);

    var restored = State{};
    onDeserialize(&restored, &tag);
    try testing.expectEqual(@as(i32, 120), restored.fire_ticks);
    try testing.expectEqual(@as(i32, 7), restored.damage_timer);
    try testing.expectEqual(Events.CombustSource.lava, restored.burn_source);
    try testing.expectEqual(@as(i64, 0), restored.instigator_id);
}

test "an entity saved without fire loads cold and writes no tags" {
    const allocator = testing.allocator;

    var tag = CompoundTag.init(allocator, null);
    defer tag.deinit(allocator);

    var cold = State{};
    onSerialize(&cold, &tag);
    try testing.expect(tag.get("FireTicks") == null);

    var restored = State{ .fire_ticks = 120, .damage_timer = 7, .burn_source = .lava };
    onDeserialize(&restored, &tag);
    try testing.expectEqual(@as(i32, 120), restored.fire_ticks);
}

test "an unknown burn source falls back to fire_block" {
    const allocator = testing.allocator;

    var tag = CompoundTag.init(allocator, null);
    defer tag.deinit(allocator);

    try tag.set("FireTicks", .{ .Int = IntTag.init(99, null) });
    try tag.set("FireBurnSource", .{ .Int = IntTag.init(99, null) });

    var restored = State{};
    onDeserialize(&restored, &tag);
    try testing.expectEqual(@as(i32, 99), restored.fire_ticks);
    try testing.expectEqual(Events.CombustSource.fire_block, restored.burn_source);
}

test "the on-fire flag re-synchronizes from the restored state" {
    const allocator = testing.allocator;

    const mob_type = EntityType.init("minecraft:zombie", 1, &.{}, &.{});
    var entity = Entity.init(allocator, &mob_type, null);
    defer entity.deinit();

    var state = State{ .fire_ticks = 100 };
    syncOnFireFlag(&state, &entity);
    try testing.expect(entity.flags.getFlag(.OnFire));

    syncOnFireFlag(&state, &entity);
    try testing.expect(entity.flags.getFlag(.OnFire));

    state.fire_ticks = 0;
    syncOnFireFlag(&state, &entity);
    try testing.expect(!entity.flags.getFlag(.OnFire));
}

test "sky access follows the cached column top of the chunk" {
    const allocator = testing.allocator;
    const ChunkImpl = @import("../../world/chunk/chunk.zig").Chunk;
    const chunkHash = @import("../../world/dimension/dimension.zig").chunkHash;
    const BlockState = @import("../../world/block/block-permutation.zig").BlockState;
    const BlockType = @import("../../world/block/block-type.zig").BlockType;

    try BlockPermutation.initRegistry(allocator);
    defer BlockPermutation.deinitRegistry();
    try BlockType.initRegistry(allocator);
    defer BlockType.deinitRegistry();

    const air_type = try BlockType.init(allocator, "minecraft:air");
    try air_type.register();
    const air = try BlockPermutation.init(allocator, 0, "minecraft:air", BlockState.init(allocator));
    try air.register();
    try air_type.addPermutation(air);

    const stone_type = try BlockType.init(allocator, "minecraft:stone");
    try stone_type.register();
    const stone = try BlockPermutation.init(allocator, 1, "minecraft:stone", BlockState.init(allocator));
    try stone.register();
    try stone_type.addPermutation(stone);

    const mob_type = EntityType.init("minecraft:zombie", 1, &.{}, &.{});
    var entity = Entity.init(allocator, &mob_type, null);
    defer entity.deinit();
    entity.position = Protocol.Vector3f.init(4.5, 64.0, 4.5);

    var dimension = Dimension.init(undefined, allocator, "overworld", .Overworld, null);
    const chunk = try allocator.create(ChunkImpl);
    chunk.* = ChunkImpl.init(allocator, 0, 0, .Overworld);
    try dimension.chunks.put(chunkHash(0, 0), chunk);
    defer dimension.deinit();

    // Nothing above the mob: the rain reaches it.
    try testing.expect(hasSkyAccess(&dimension, &entity));

    // Only the mob's own column counts.
    try chunk.setPermutation(0, 200, 0, stone, 0);
    try testing.expect(hasSkyAccess(&dimension, &entity));

    // A roof inside the two-block grace still lets the rain through.
    try chunk.setPermutation(4, 65, 4, stone, 0);
    try testing.expect(hasSkyAccess(&dimension, &entity));

    // From feet + 2 upwards any block shelters the mob.
    try chunk.setPermutation(4, 66, 4, stone, 0);
    try testing.expect(!hasSkyAccess(&dimension, &entity));
}
