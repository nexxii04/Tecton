const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

const Entity = @import("../entity.zig").Entity;
const EntityTrait = @import("./trait.zig").EntityTrait;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const entities = @import("../../world/dimension/entities.zig");
const broadcast = @import("../../world/dimension/broadcast.zig");
const Fire = @import("./fire.zig");
const Health = @import("./health.zig");
const InventoryTrait = @import("./inventory.zig").InventoryTrait;
const EnchantmentEffects = @import("../../items/enchantments/effects.zig");
const ArmorAggregate = @import("../../items/enchantments/compat.zig").ArmorAggregate;
const Events = @import("../../events/types.zig");
const ItemStack = @import("../../items/item_stack.zig").ItemStack;
const ItemType = @import("../../items/item_type.zig").ItemType;
const Bow = @import("../../items/bow.zig");
const EntityActorFlags = @import("../metadata/actor_flags.zig").EntityActorFlags;
const Player = @import("../../player/player.zig").Player;
const PlayerMath = @import("../../player/player.zig");

pub const GRAVITY: f32 = -0.05;
pub const DRAG: f32 = 0.99;
pub const HIT_RADIUS: f32 = 0.6;
pub const MAX_LIFETIME_TICKS: u32 = 1200;
pub const STUCK_TICKS: u32 = 1200;
pub const KNOCKBACK_LIFT: f32 = 0.3;
pub const PICKUP_RADIUS: f32 = 1.5;
pub const PICKUP_VERTICAL_REACH: f32 = 1.5;
pub const PLAYER_EYE_OFFSET: f32 = 1.62;
pub const PICKUP_PER_TICK: u8 = 1;
pub const SWEEP_STEP: f32 = 0.25;
pub const SWEEP_REFINE_STEPS: u8 = 4;

pub const State = struct {
    owner_runtime_id: i64,
    damage: f32,
    knockback: f32,
    burn_ticks: i32,
    pickup_identifier: []const u8,
    pickup_allowed: bool,
    is_critical: bool,
    age: u32,
    stuck_ticks: u32,
    stuck: bool,
    pending_remove: bool,
};

fn emptyMotion() Protocol.Vector3f {
    return Protocol.Vector3f.init(0, 0, 0);
}

pub fn stepMotion(motion: *Protocol.Vector3f, gravity: f32, drag: f32) void {
    motion.x *= drag;
    motion.y = motion.y * drag + gravity;
    motion.z *= drag;
}

pub fn isPassable(identifier: []const u8) bool {
    return std.mem.eql(u8, identifier, "minecraft:air") or
        std.mem.eql(u8, identifier, "minecraft:water") or
        std.mem.eql(u8, identifier, "minecraft:flowing_water") or
        std.mem.eql(u8, identifier, "minecraft:lava") or
        std.mem.eql(u8, identifier, "minecraft:flowing_lava");
}

pub fn blockPositionOf(position: Protocol.Vector3f) Protocol.BlockPosition {
    return Protocol.BlockPosition{
        .x = @intFromFloat(@floor(position.x)),
        .y = @intFromFloat(@floor(position.y)),
        .z = @intFromFloat(@floor(position.z)),
    };
}

pub fn squaredDistanceToSegment(point: Protocol.Vector3f, from: Protocol.Vector3f, to: Protocol.Vector3f) f32 {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const dz = to.z - from.z;
    const length_sq = dx * dx + dy * dy + dz * dz;
    if (length_sq <= 0.000001) {
        const px = point.x - from.x;
        const py = point.y - from.y;
        const pz = point.z - from.z;
        return px * px + py * py + pz * pz;
    }

    const raw = ((point.x - from.x) * dx + (point.y - from.y) * dy + (point.z - from.z) * dz) / length_sq;
    const t = @max(0.0, @min(1.0, raw));
    const cx = from.x + dx * t - point.x;
    const cy = from.y + dy * t - point.y;
    const cz = from.z + dz * t - point.z;
    return cx * cx + cy * cy + cz * cz;
}

pub fn segmentHitsPoint(from: Protocol.Vector3f, to: Protocol.Vector3f, point: Protocol.Vector3f, radius: f32) bool {
    return squaredDistanceToSegment(point, from, to) <= radius * radius;
}

pub fn outlivesFlight(age: u32, stuck_ticks: u32, stuck: bool) bool {
    if (stuck) return stuck_ticks >= STUCK_TICKS;
    return age >= MAX_LIFETIME_TICKS;
}

pub fn isPickable(stuck: bool, allowed: bool) bool {
    return stuck and allowed;
}

pub fn criticalTrailActive(is_critical: bool, stuck: bool) bool {
    return is_critical and !stuck;
}

fn syncCriticalFlag(dimension: *Dimension, state: *const State, entity: *Entity) void {
    const active = criticalTrailActive(state.is_critical, state.stuck);
    if (entity.flags.getFlag(.Critical) == active) return;
    entity.flags.setFlag(.Critical, active);
    entities.updateEntityActorFlags(dimension, entity);
}

pub fn withinPickupReach(player_eye: Protocol.Vector3f, arrow: Protocol.Vector3f) bool {
    const dx = arrow.x - player_eye.x;
    const dz = arrow.z - player_eye.z;
    if (dx * dx + dz * dz > PICKUP_RADIUS * PICKUP_RADIUS) return false;
    const center_y = player_eye.y - PLAYER_EYE_OFFSET * 0.5;
    return @abs(arrow.y - center_y) <= PICKUP_VERTICAL_REACH;
}

pub fn encodeAngle(degrees: f32) i8 {
    const turns = @mod(degrees, 360.0) / 360.0;
    const unit: u8 = @intCast(@as(u32, @intFromFloat(@round(turns * 256.0))) & 255);
    return @bitCast(unit);
}

pub fn decodeAngle(encoded: i8) f32 {
    return @as(f32, @floatFromInt(@as(u8, @bitCast(encoded)))) * 360.0 / 256.0;
}

pub const Sweep = struct {
    position: Protocol.Vector3f,
    hit: bool,
};

pub fn sweepBlocks(ctx: anytype, from: Protocol.Vector3f, to: Protocol.Vector3f, comptime solid: fn (@TypeOf(ctx), Protocol.Vector3f) bool) Sweep {
    if (solid(ctx, from)) return .{ .position = from, .hit = true };

    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const dz = to.z - from.z;
    const length = @sqrt(dx * dx + dy * dy + dz * dz);
    if (length <= 0.0) return .{ .position = from, .hit = false };

    const steps: u32 = @max(1, @as(u32, @intFromFloat(@ceil(length / SWEEP_STEP))));
    var free = from;
    var index: u32 = 1;
    while (index <= steps) : (index += 1) {
        const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(steps));
        const sample = Protocol.Vector3f.init(from.x + dx * t, from.y + dy * t, from.z + dz * t);
        if (!solid(ctx, sample)) {
            free = sample;
            continue;
        }

        var inside = sample;
        var refine: u8 = 0;
        while (refine < SWEEP_REFINE_STEPS) : (refine += 1) {
            const middle = Protocol.Vector3f.init(
                (free.x + inside.x) * 0.5,
                (free.y + inside.y) * 0.5,
                (free.z + inside.z) * 0.5,
            );
            if (solid(ctx, middle)) {
                inside = middle;
            } else {
                free = middle;
            }
        }
        return .{ .position = free, .hit = true };
    }

    return .{ .position = to, .hit = false };
}

pub fn canPickupThisTick(last_pickup_tick: u64, tick: u64) bool {
    return last_pickup_tick != tick;
}

pub fn knockbackImpulse(direction: Protocol.Vector3f, strength: f32) ?Protocol.Vector3f {
    if (strength <= 0) return null;

    const flat = @sqrt(direction.x * direction.x + direction.z * direction.z);
    if (flat <= 0.001) return null;

    return Protocol.Vector3f.init(
        direction.x / flat * strength,
        KNOCKBACK_LIFT,
        direction.z / flat * strength,
    );
}

fn markForRemoval(state: *State, entity: *Entity) void {
    state.pending_remove = true;
    const dimension = entity.dimension orelse return;
    dimension.pending_removals.append(dimension.allocator, entity.runtime_id) catch {};
}

fn solidAt(dimension: *Dimension, position: Protocol.Vector3f) bool {
    const permutation = dimension.getPermutation(blockPositionOf(position), 0) catch return false;
    return !isPassable(permutation.identifier);
}

fn broadcastMotion(dimension: *Dimension, entity: *Entity) void {
    const allocator = dimension.world.tecton.allocator;

    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.SetActorMotionPacket{
        .runtime_entity_id = @bitCast(entity.runtime_id),
        .motion = entity.motion,
    };
    const serialized = packet.serialize(&stream) catch return;

    broadcast.broadcastToEntityViewers(dimension, entity, serialized);
}

fn applyKnockback(dimension: *Dimension, state: *State, arrow: *Entity, target: *Entity) void {
    const impulse = knockbackImpulse(arrow.motion, state.knockback) orelse return;
    target.motion = impulse;
    broadcastMotion(dimension, target);
}

fn igniteTarget(dimension: *Dimension, state: *State, target: *Entity) void {
    if (state.burn_ticks <= 0) return;
    _ = Fire.ignite(target, .projectile, dimension.getEntity(state.owner_runtime_id), state.burn_ticks);
}

fn applyHit(dimension: *Dimension, state: *State, arrow: *Entity, target: *Entity) bool {
    const health_state = target.getTraitState(Health.HealthTrait) orelse return false;

    const tecton = dimension.world.tecton;
    if (Health.isInvulnerable(health_state, tecton.tickCount())) return false;

    if (tecton.findPlayerByRuntimeId(target.runtime_id)) |other| {
        if (!PlayerMath.damageable(other.gamemode)) return false;
    }

    var armor: ArmorAggregate = .empty;
    if (target.getTraitState(InventoryTrait)) |victim_inventory| {
        if (victim_inventory.armor) |*pieces| armor.refresh(pieces);
    }

    var damage_event = Events.DamageEvent{
        .attacker = dimension.getEntity(state.owner_runtime_id),
        .victim = target,
        .amount = EnchantmentEffects.mitigate(&armor, .projectile, state.damage),
        .cause = .projectile,
    };
    if (!tecton.events.emit(.Damage, &damage_event)) return false;

    target.fireEvent(.Damage, .{ target, damage_event.amount });

    applyKnockback(dimension, state, arrow, target);
    igniteTarget(dimension, state, target);
    return true;
}

fn resolveHit(dimension: *Dimension, state: *State, arrow: *Entity, from: Protocol.Vector3f, to: Protocol.Vector3f) bool {
    var it = dimension.entities.valueIterator();
    while (it.next()) |entry| {
        const target = entry.*;
        if (target == arrow) continue;
        if (target.runtime_id == state.owner_runtime_id) continue;
        if (!segmentHitsPoint(from, to, target.position, HIT_RADIUS)) continue;
        if (!applyHit(dimension, state, arrow, target)) continue;
        return true;
    }
    return false;
}

fn broadcastMove(entity: *Entity, dimension: *Dimension) void {
    const allocator = dimension.world.tecton.allocator;

    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();

    var packet = Protocol.MoveActorDeltaPacket.init(@bitCast(entity.runtime_id));
    packet.x = entity.position.x;
    packet.y = entity.position.y;
    packet.z = entity.position.z;
    packet.rotation_x = encodeAngle(entity.rotation.x);
    packet.rotation_y = encodeAngle(entity.rotation.y);
    packet.rotation_y_head = encodeAngle(entity.rotation.y);
    packet.on_ground = false;

    const serialized = packet.serialize(&stream) catch return;
    broadcast.broadcastToEntityViewers(dimension, entity, serialized);
}

fn broadcastPickup(dimension: *Dimension, arrow: *Entity, player: *Player) void {
    const allocator = dimension.world.tecton.allocator;

    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.TakeItemActorPacket{
        .item_entity_runtime_id = @bitCast(arrow.runtime_id),
        .taker_entity_runtime_id = @bitCast(player.entity.runtime_id),
    };
    const serialized = packet.serialize(&stream) catch return;

    player.network.sendPacket(player.connection, serialized) catch {};
    broadcast.broadcastToEntityViewers(dimension, arrow, serialized);
}

fn playPickup(dimension: *Dimension, position: Protocol.Vector3f) void {
    const allocator = dimension.world.tecton.allocator;

    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.LevelSoundEventPacket{
        .event = .pop,
        .position = position,
        .data = 0,
        .actor_identifier = "",
        .is_baby_mob = false,
        .is_global = false,
    };
    const serialized = packet.serialize(&stream) catch return;

    broadcast.broadcastToNearby(dimension, position, broadcast.SOUND_BROADCAST_RADIUS, serialized);
}

fn tryPickup(dimension: *Dimension, state: *State, arrow: *Entity) void {
    if (!isPickable(state.stuck, state.pickup_allowed)) return;
    if (state.pickup_identifier.len == 0) return;

    const tecton = dimension.world.tecton;
    const tick = tecton.tickCount();

    for (tecton.getPlayerSnapshots()) |player| {
        if (!player.spawned) continue;
        if (player.entity.dimension != dimension) continue;
        if (!PlayerMath.damageable(player.gamemode)) continue;
        if (!withinPickupReach(player.entity.position, arrow.position)) continue;
        if (!canPickupThisTick(player.last_arrow_pickup_tick, tick)) continue;

        const inv_state = player.entity.getTraitState(InventoryTrait) orelse continue;

        const item_type = ItemType.get(state.pickup_identifier) orelse return;
        var granted = ItemStack.init(dimension.allocator, item_type, .{ .stack_size = 1 });
        defer granted.deinit();
        if (!inv_state.container.addItem(granted)) continue;

        player.last_arrow_pickup_tick = tick;
        broadcastPickup(dimension, arrow, player);
        playPickup(dimension, arrow.position);
        markForRemoval(state, arrow);
        return;
    }
}

fn onTick(state: *State, entity: *Entity) void {
    if (state.pending_remove) return;

    const dimension = entity.dimension orelse return;

    state.age +%= 1;
    if (state.stuck) state.stuck_ticks +%= 1;
    syncCriticalFlag(dimension, state, entity);

    if (outlivesFlight(state.age, state.stuck_ticks, state.stuck)) {
        markForRemoval(state, entity);
        return;
    }

    if (state.stuck) {
        tryPickup(dimension, state, entity);
        return;
    }

    const from_position = entity.position;
    stepMotion(&entity.motion, GRAVITY, DRAG);
    entity.rotation = Bow.rotationOf(entity.motion);
    entity.head_yaw = entity.rotation.y;

    const to_position = from_position.add(entity.motion);
    const sweep = sweepBlocks(dimension, from_position, to_position, solidAt);

    if (resolveHit(dimension, state, entity, from_position, sweep.position)) {
        markForRemoval(state, entity);
        return;
    }

    entity.position = sweep.position;

    if (sweep.hit) {
        entity.motion = emptyMotion();
        state.stuck = true;
        syncCriticalFlag(dimension, state, entity);
        broadcastMove(entity, dimension);
        return;
    }

    broadcastMove(entity, dimension);
}

pub const ProjectileTrait = EntityTrait(State, .{
    .identifier = "projectile",
    .on_tick = onTick,
});

const SweepProbe = struct {
    solid_below: f32,

    fn solid(ctx: SweepProbe, position: Protocol.Vector3f) bool {
        return position.y <= ctx.solid_below;
    }
};

test "an arrow keeps its air inertia and then takes gravity" {
    var motion = Protocol.Vector3f.init(1.0, 0.0, 0.0);
    stepMotion(&motion, GRAVITY, DRAG);

    try std.testing.expectApproxEqAbs(@as(f32, 0.99), motion.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.05), motion.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), motion.z, 0.0001);

    stepMotion(&motion, GRAVITY, DRAG);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9801), motion.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.0995), motion.y, 0.0001);
}

test "an arrow flies with the vanilla gravity and air drag" {
    try std.testing.expectApproxEqAbs(@as(f32, -0.05), GRAVITY, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.99), DRAG, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), Bow.launchSpeed(1.0), 0.0001);
}

test "a full charge arrow loses its climb to gravity" {
    var motion = Protocol.Vector3f.init(0.0, Bow.launchSpeed(1.0), 0.0);
    var ticks: u32 = 0;
    while (motion.y > 0) : (ticks += 1) {
        stepMotion(&motion, GRAVITY, DRAG);
        if (ticks > 200) break;
    }

    try std.testing.expect(ticks >= 45);
    try std.testing.expect(ticks <= 49);
}

test "only air and fluids let an arrow through" {
    try std.testing.expect(isPassable("minecraft:air"));
    try std.testing.expect(isPassable("minecraft:water"));
    try std.testing.expect(isPassable("minecraft:flowing_water"));
    try std.testing.expect(isPassable("minecraft:lava"));
    try std.testing.expect(!isPassable("minecraft:stone"));
    try std.testing.expect(!isPassable("minecraft:oak_planks"));
    try std.testing.expect(!isPassable("minecraft:short_grass"));
}

test "a block position floors negative coordinates down" {
    const block = blockPositionOf(Protocol.Vector3f.init(1.9, 70.0, -0.2));
    try std.testing.expectEqual(@as(i32, 1), block.x);
    try std.testing.expectEqual(@as(i32, 70), block.y);
    try std.testing.expectEqual(@as(i32, -1), block.z);
}

test "a fast arrow cannot fly through the body it passes" {
    const from = Protocol.Vector3f.init(0.0, 0.0, 0.0);
    const to = Protocol.Vector3f.init(0.0, 0.0, 10.0);
    const body = Protocol.Vector3f.init(0.0, 0.0, 6.0);

    try std.testing.expect(segmentHitsPoint(from, to, body, HIT_RADIUS));
    try std.testing.expect(segmentHitsPoint(from, to, Protocol.Vector3f.init(0.5, 0.0, 6.0), HIT_RADIUS));
    try std.testing.expect(!segmentHitsPoint(from, to, Protocol.Vector3f.init(2.0, 0.0, 6.0), HIT_RADIUS));
    try std.testing.expect(!segmentHitsPoint(from, to, Protocol.Vector3f.init(0.0, 0.0, 14.0), HIT_RADIUS));
}

test "the segment reaches no further than the tick of flight" {
    const from = Protocol.Vector3f.init(0.0, 0.0, 0.0);
    const to = Protocol.Vector3f.init(0.0, 0.0, 1.0);

    try std.testing.expect(!segmentHitsPoint(from, to, Protocol.Vector3f.init(0.0, 0.0, 3.0), HIT_RADIUS));
    try std.testing.expect(!segmentHitsPoint(from, to, Protocol.Vector3f.init(3.0, 0.0, 0.5), HIT_RADIUS));
    try std.testing.expect(segmentHitsPoint(from, to, Protocol.Vector3f.init(0.0, 0.0, 1.4), HIT_RADIUS));
    try std.testing.expect(segmentHitsPoint(from, to, Protocol.Vector3f.init(0.0, 0.0, 0.1), HIT_RADIUS));
}

test "a motionless arrow still measures the distance to the point" {
    const at = Protocol.Vector3f.init(1.0, 2.0, 3.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), squaredDistanceToSegment(at, at, at), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), squaredDistanceToSegment(Protocol.Vector3f.init(1.0, 3.0, 3.0), at, at), 0.0001);
}

test "only a stuck arrow that was paid for can be picked up" {
    try std.testing.expect(!isPickable(false, true));
    try std.testing.expect(!isPickable(true, false));
    try std.testing.expect(!isPickable(false, false));
    try std.testing.expect(isPickable(true, true));
}

test "a player collects at most one arrow per tick" {
    try std.testing.expect(canPickupThisTick(0, 1));
    try std.testing.expect(canPickupThisTick(0, 4000));
    try std.testing.expect(canPickupThisTick(3999, 4000));
    try std.testing.expect(!canPickupThisTick(4000, 4000));
    try std.testing.expect(canPickupThisTick(4001, 4000));
    try std.testing.expectEqual(@as(u8, 1), PICKUP_PER_TICK);
}

test "the pickup reach is measured from the body, not from the eyes" {
    const eye = Protocol.Vector3f.init(0.0, 65.62, 0.0);

    try std.testing.expect(withinPickupReach(eye, Protocol.Vector3f.init(0.0, 64.0, 0.8)));
    try std.testing.expect(withinPickupReach(eye, Protocol.Vector3f.init(1.2, 65.3, 0.0)));
    try std.testing.expect(withinPickupReach(eye, Protocol.Vector3f.init(0.0, 65.62, 0.0)));
    try std.testing.expect(!withinPickupReach(eye, Protocol.Vector3f.init(1.6, 64.0, 0.0)));
    try std.testing.expect(!withinPickupReach(eye, Protocol.Vector3f.init(0.0, 67.2, 0.0)));
}

test "a rotation byte covers the whole turn without wrapping early" {
    try std.testing.expectEqual(@as(i8, 0), encodeAngle(0));
    try std.testing.expectEqual(@as(i8, 0), encodeAngle(360));
    try std.testing.expectEqual(@as(i8, 64), encodeAngle(90));
    try std.testing.expectEqual(@as(i8, -64), encodeAngle(-90));
    try std.testing.expectEqual(@as(i8, -128), encodeAngle(180));

    const angles = [_]f32{ -170, -45, -1, 12, 90, 179, 270, 359 };
    for (angles) |angle| {
        const expected = if (angle < 0) angle + 360 else angle;
        try std.testing.expectApproxEqAbs(expected, decodeAngle(encodeAngle(angle)), 1.5);
    }
}

test "the critical trail only runs while the arrow is flying" {
    try std.testing.expect(criticalTrailActive(true, false));
    try std.testing.expect(!criticalTrailActive(true, true));
    try std.testing.expect(!criticalTrailActive(false, false));
    try std.testing.expect(!criticalTrailActive(false, true));
}

test "the projectile state keeps the critical flag it was spawned with" {
    const critical = try ProjectileTrait.create(std.testing.allocator, .{
        .owner_runtime_id = 7,
        .damage = 9.0,
        .knockback = 0,
        .burn_ticks = 0,
        .pickup_identifier = "minecraft:arrow",
        .pickup_allowed = true,
        .is_critical = true,
        .age = 0,
        .stuck_ticks = 0,
        .stuck = false,
        .pending_remove = false,
    });
    defer ProjectileTrait.destroy(critical, std.testing.allocator);

    const critical_state: *State = @ptrCast(@alignCast(critical.ctx));
    try std.testing.expect(critical_state.is_critical);
    try std.testing.expect(!critical_state.stuck);

    const plain = try ProjectileTrait.create(std.testing.allocator, .{
        .owner_runtime_id = 8,
        .damage = 1.0,
        .knockback = 0,
        .burn_ticks = 0,
        .pickup_identifier = "minecraft:arrow",
        .pickup_allowed = true,
        .is_critical = false,
        .age = 0,
        .stuck_ticks = 0,
        .stuck = false,
        .pending_remove = false,
    });
    defer ProjectileTrait.destroy(plain, std.testing.allocator);

    const plain_state: *State = @ptrCast(@alignCast(plain.ctx));
    try std.testing.expect(!plain_state.is_critical);
}

test "the critical flag lands on the actor bit the client reads" {
    var flags = EntityActorFlags.init();
    flags.setFlag(.Critical, true);

    try std.testing.expect(flags.getFlag(.Critical));
    try std.testing.expectEqual(@as(i64, 1 << 13), flags.flags_one);

    flags.setFlag(.Critical, false);
    try std.testing.expect(!flags.getFlag(.Critical));
    try std.testing.expectEqual(@as(i64, 0), flags.flags_one);
}

test "the arrow's wire angles survive the byte encoding" {
    const east = Bow.rotationOf(Protocol.Vector3f.init(1, 0, 0));
    try std.testing.expectEqual(@as(i8, 0), encodeAngle(east.x));
    try std.testing.expectEqual(@as(i8, 64), encodeAngle(east.y));

    const up = Bow.rotationOf(Protocol.Vector3f.init(0, 1, 0));
    try std.testing.expectEqual(@as(i8, 64), encodeAngle(up.x));
    try std.testing.expectEqual(@as(i8, 0), encodeAngle(up.y));
}

test "the arrow points along its arc as gravity pulls it" {
    var motion = Bow.launchVelocity(Protocol.Vector2f.init(-60, 0), Bow.launchSpeed(1.0));
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), Bow.rotationOf(motion).x, 0.01);

    var ticks: u32 = 0;
    while (ticks < 120) : (ticks += 1) stepMotion(&motion, GRAVITY, DRAG);

    try std.testing.expect(Bow.rotationOf(motion).x < -30.0);
}

test "an arrow that starts inside a block sticks where it is" {
    const probe = SweepProbe{ .solid_below = 0.0 };
    const from = Protocol.Vector3f.init(1.0, -0.5, 2.0);
    const sweep = sweepBlocks(probe, from, Protocol.Vector3f.init(1.0, 2.0, 2.0), SweepProbe.solid);

    try std.testing.expect(sweep.hit);
    try std.testing.expectEqual(from.x, sweep.position.x);
    try std.testing.expectEqual(from.y, sweep.position.y);
    try std.testing.expectEqual(from.z, sweep.position.z);
}

test "a sweep with nothing in the way reaches the tick end" {
    const probe = SweepProbe{ .solid_below = 0.0 };
    const to = Protocol.Vector3f.init(3.0, 10.0, 4.0);
    const sweep = sweepBlocks(probe, Protocol.Vector3f.init(0.0, 10.0, 0.0), to, SweepProbe.solid);

    try std.testing.expect(!sweep.hit);
    try std.testing.expectEqual(to.x, sweep.position.x);
    try std.testing.expectEqual(to.y, sweep.position.y);
    try std.testing.expectEqual(to.z, sweep.position.z);
}

test "a fast arrow stops at the face instead of crossing it" {
    const probe = SweepProbe{ .solid_below = 0.0 };
    const sweep = sweepBlocks(probe, Protocol.Vector3f.init(0.0, 3.0, 0.0), Protocol.Vector3f.init(0.0, -3.0, 0.0), SweepProbe.solid);

    try std.testing.expect(sweep.hit);
    try std.testing.expect(sweep.position.y > 0.0);
    try std.testing.expect(sweep.position.y < 0.02);
}

test "a slow tick stops at the same face as a fast one" {
    const probe = SweepProbe{ .solid_below = 2.6 };
    const fast = sweepBlocks(probe, Protocol.Vector3f.init(0.0, 5.0, 0.0), Protocol.Vector3f.init(0.0, 2.5, 0.0), SweepProbe.solid);
    const slow = sweepBlocks(probe, Protocol.Vector3f.init(0.0, 2.7, 0.0), Protocol.Vector3f.init(0.0, 2.5, 0.0), SweepProbe.solid);

    try std.testing.expect(fast.hit);
    try std.testing.expect(slow.hit);
    try std.testing.expect(fast.position.y > 2.6);
    try std.testing.expect(fast.position.y < 2.62);
    try std.testing.expect(slow.position.y > 2.6);
    try std.testing.expect(slow.position.y < 2.62);
}

test "the arrow pushes along the line it was flying" {
    const forward = Protocol.Vector3f.init(0.0, -0.2, 4.0);
    const impulse = knockbackImpulse(forward, 0.45).?;

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), impulse.x, 0.0001);
    try std.testing.expectApproxEqAbs(KNOCKBACK_LIFT, impulse.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), impulse.z, 0.0001);

    const diagonal = knockbackImpulse(Protocol.Vector3f.init(3.0, 0.0, 4.0), 0.3).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.18), diagonal.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.24), diagonal.z, 0.0001);
}

test "an arrow that carries no push pushes nothing" {
    const forward = Protocol.Vector3f.init(0.0, 0.0, 4.0);

    try std.testing.expect(knockbackImpulse(forward, 0.0) == null);
    try std.testing.expect(knockbackImpulse(forward, -0.5) == null);
    try std.testing.expect(knockbackImpulse(Protocol.Vector3f.init(0.0, 4.0, 0.0), 0.3) == null);
    try std.testing.expect(knockbackImpulse(Protocol.Vector3f.init(0.001, 0.0, 0.0), 0.3) == null);
}

test "a flying arrow dies on its lifetime and a stuck one on its own clock" {
    try std.testing.expect(!outlivesFlight(MAX_LIFETIME_TICKS - 1, 0, false));
    try std.testing.expect(outlivesFlight(MAX_LIFETIME_TICKS, 0, false));
    try std.testing.expect(!outlivesFlight(0, STUCK_TICKS - 1, true));
    try std.testing.expect(outlivesFlight(0, STUCK_TICKS, true));
    try std.testing.expect(!outlivesFlight(MAX_LIFETIME_TICKS, 0, true));
}
