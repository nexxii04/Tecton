const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

const Entity = @import("../entity.zig").Entity;
const EntityTrait = @import("./trait.zig").EntityTrait;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const broadcast = @import("../../world/dimension/broadcast.zig");
const Fire = @import("./fire.zig");
const Health = @import("./health.zig");
const InventoryTrait = @import("./inventory.zig").InventoryTrait;
const EnchantmentEffects = @import("../../items/enchantments/effects.zig");
const ArmorAggregate = @import("../../items/enchantments/compat.zig").ArmorAggregate;
const Events = @import("../../events/types.zig");
const PlayerMath = @import("../../player/player.zig");

pub const GRAVITY: f32 = -0.05;
pub const DRAG: f32 = 0.99;
pub const HIT_RADIUS: f32 = 0.6;
pub const MAX_LIFETIME_TICKS: u32 = 1200;
pub const STUCK_TICKS: u32 = 1200;
pub const KNOCKBACK_LIFT: f32 = 0.3;

pub const State = struct {
    owner_runtime_id: i64,
    damage: f32,
    knockback: f32,
    burn_ticks: i32,
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
    packet.on_ground = false;

    const serialized = packet.serialize(&stream) catch return;
    broadcast.broadcastToEntityViewers(dimension, entity, serialized);
}

fn onTick(state: *State, entity: *Entity) void {
    if (state.pending_remove) return;

    const dimension = entity.dimension orelse return;

    state.age +%= 1;
    if (state.stuck) state.stuck_ticks +%= 1;

    if (outlivesFlight(state.age, state.stuck_ticks, state.stuck)) {
        markForRemoval(state, entity);
        return;
    }

    if (state.stuck) return;

    const from_position = entity.position;
    stepMotion(&entity.motion, GRAVITY, DRAG);

    const moved = entity.position.add(entity.motion);
    const to_position = Protocol.Vector3f.init(moved.x, moved.y, moved.z);

    if (resolveHit(dimension, state, entity, from_position, to_position)) {
        markForRemoval(state, entity);
        return;
    }

    entity.position = to_position;

    if (solidAt(dimension, to_position)) {
        entity.motion = emptyMotion();
        state.stuck = true;
        broadcastMove(entity, dimension);
        return;
    }

    broadcastMove(entity, dimension);
}

pub const ProjectileTrait = EntityTrait(State, .{
    .identifier = "projectile",
    .on_tick = onTick,
});

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

test "a full charge arrow loses its climb to gravity" {
    var motion = Protocol.Vector3f.init(0.0, 5.0, 0.0);
    var ticks: u32 = 0;
    while (motion.y > 0) : (ticks += 1) {
        stepMotion(&motion, GRAVITY, DRAG);
        if (ticks > 200) break;
    }

    try std.testing.expect(ticks > 60);
    try std.testing.expect(ticks < 120);
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
