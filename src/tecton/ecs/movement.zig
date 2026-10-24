const std = @import("std");
const Protocol = @import("protocol");
const MoveDelta = @import("../player/move_delta.zig");
const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const components = @import("components.zig");
const query = @import("query.zig");

const Transform = components.Transform;
const Physics = components.Physics;
const PhysicsProfile = components.PhysicsProfile;

pub const Profile = struct {
    gravity: f32,
    drag: f32,
    drag_before_gravity: bool,
    ground_friction: f32 = 0.6,
    rest_threshold: f32 = 0.001,
};

pub const profiles = [_]Profile{
    .{ .gravity = -0.04, .drag = 0.02, .drag_before_gravity = true },
    .{ .gravity = -0.08, .drag = 0.0, .drag_before_gravity = false },
    .{ .gravity = -0.03, .drag = 0.01, .drag_before_gravity = false },
};

pub fn profileOf(profile: PhysicsProfile) Profile {
    return profiles[@intFromEnum(profile)];
}

pub fn applyAirPhysics(motion: *Protocol.Vector3f, drag: f32, gravity: f32, apply_drag_before_gravity: bool) void {
    if (apply_drag_before_gravity and drag > 0) {
        motion.x *= 1.0 - drag;
        motion.y *= 1.0 - drag;
        motion.z *= 1.0 - drag;
    }

    motion.y += gravity;

    if (!apply_drag_before_gravity and drag > 0) {
        motion.x *= 1.0 - drag;
        motion.y *= 1.0 - drag;
        motion.z *= 1.0 - drag;
    }
}

pub const Ground = struct {
    solid: bool,
    cell_y: i32,
};

pub fn resolveGround(profile: Profile, physics: *Physics, transform: *Transform, ground: Ground) void {
    if (ground.solid) {
        if (transform.velocity.y > 0) {
            const ceiling_y: f32 = @floatFromInt(ground.cell_y);
            transform.position.y = ceiling_y - 0.01;
            transform.velocity.y = 0;
            physics.on_ground = false;
            return;
        }
        const land_y: f32 = @floatFromInt(ground.cell_y + 1);
        if (transform.position.y < land_y) {
            transform.position.y = land_y;
        }
        if (transform.velocity.y < 0) {
            transform.velocity.y = 0;
        }
        transform.velocity.x *= profile.ground_friction;
        transform.velocity.z *= profile.ground_friction;
        if (@abs(transform.velocity.x) < profile.rest_threshold) transform.velocity.x = 0;
        if (@abs(transform.velocity.z) < profile.rest_threshold) transform.velocity.z = 0;
        physics.falling_distance = 0;
        physics.fall_ticks = 0;
        physics.on_ground = true;
        return;
    }

    physics.on_ground = false;
    if (transform.velocity.y < 0) {
        physics.falling_distance += @abs(transform.velocity.y);
        physics.fall_ticks += 1;
    }
}

pub fn integrateWith(
    profile: Profile,
    physics: *Physics,
    transform: *Transform,
    ctx: anytype,
    comptime probe: fn (@TypeOf(ctx), Protocol.Vector3f) Ground,
) void {
    const previous = transform.position;
    applyAirPhysics(&transform.velocity, profile.drag, profile.gravity, profile.drag_before_gravity);
    transform.position = transform.position.add(transform.velocity);
    resolveGround(profile, physics, transform, probe(ctx, transform.position));

    const moved = MoveDelta.movedEnough(transform.position.x, previous.x) or
        MoveDelta.movedEnough(transform.position.y, previous.y) or
        MoveDelta.movedEnough(transform.position.z, previous.z);
    transform.dirty = transform.dirty or moved;
    transform.moved = moved;
}

pub fn groundAt(dimension: *Dimension, position: Protocol.Vector3f) Ground {
    const bx: i32 = @intFromFloat(@floor(position.x));
    const bz: i32 = @intFromFloat(@floor(position.z));
    if (dimension.getChunk(bx >> 4, bz >> 4) == null) return .{ .solid = false, .cell_y = 0 };

    const by: i32 = @intFromFloat(@floor(position.y - 0.01));
    const below = Protocol.BlockPosition{ .x = bx, .y = by, .z = bz };
    var solid = false;
    if (dimension.getPermutation(below, 0) catch null) |perm| {
        solid = !std.mem.eql(u8, perm.identifier, "minecraft:air");
    }
    return .{ .solid = solid, .cell_y = by };
}

fn probeGroundAt(ctx: *Dimension, position: Protocol.Vector3f) Ground {
    return groundAt(ctx, position);
}

pub fn movementApply(world: *components.GameWorld, dimension: *Dimension) void {
    const Ctx = struct { dimension: *Dimension };
    var ctx = Ctx{ .dimension = dimension };
    query.each(world, .{ Physics, Transform }, &ctx, struct {
        fn call(c: *Ctx, _: @import("entity_id.zig").EntityId, physics: *Physics, transform: *Transform) void {
            integrateWith(profileOf(physics.profile), physics, transform, c.dimension, probeGroundAt);
        }
    }.call);
}

test "item air physics matches pocketmine order" {
    var motion = Protocol.Vector3f.init(0.4, 0.0, 0.4);
    applyAirPhysics(&motion, 0.02, -0.04, true);

    try std.testing.expectApproxEqAbs(@as(f32, 0.392), motion.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.04), motion.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.392), motion.z, 0.0001);
}

test "mob air physics applies gravity without drag" {
    var motion = Protocol.Vector3f.init(0.3, 0.1, 0.0);
    applyAirPhysics(&motion, 0.0, -0.08, false);

    try std.testing.expectApproxEqAbs(@as(f32, 0.3), motion.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), motion.y, 0.0001);
}

const FlatWorld = struct {
    floor_y: i32,
    ceiling_y: ?i32,

    fn probe(self: *const FlatWorld, position: Protocol.Vector3f) Ground {
        const cell: i32 = @intFromFloat(@floor(position.y - 0.01));
        if (self.ceiling_y) |ceiling| {
            if (cell >= ceiling and position.y > @as(f32, @floatFromInt(ceiling)) - 0.01) {
                return .{ .solid = true, .cell_y = cell };
            }
        }
        if (cell <= self.floor_y) {
            return .{ .solid = true, .cell_y = cell };
        }
        return .{ .solid = false, .cell_y = cell };
    }
};

test "landing snaps to the block top and stops negative velocity" {
    const profile = profileOf(.item);
    var physics = Physics{ .profile = .item, .falling_distance = 3.5, .fall_ticks = 20 };
    var transform = Transform{ .position = Protocol.Vector3f.init(0.5, 63.8, 0.5), .velocity = Protocol.Vector3f.init(0.4, -0.08, 0.4) };
    const flat = FlatWorld{ .floor_y = 63, .ceiling_y = null };

    integrateWith(profile, &physics, &transform, &flat, FlatWorld.probe);

    try std.testing.expect(physics.on_ground);
    try std.testing.expectEqual(@as(f32, 64), transform.position.y);
    try std.testing.expectEqual(@as(f32, 0), transform.velocity.y);
    try std.testing.expectEqual(@as(f32, 0), physics.falling_distance);
    try std.testing.expect(transform.velocity.x < 0.4);
    try std.testing.expect(transform.dirty);
    try std.testing.expect(transform.moved);
}

test "rising into a solid cell clamps below instead of teleporting on top" {
    const profile = profileOf(.item);
    var physics = Physics{ .profile = .item, .on_ground = true };
    var transform = Transform{ .position = Protocol.Vector3f.init(0.5, 64.5, 0.5), .velocity = Protocol.Vector3f.init(0, 0.25, 0) };
    const gap = FlatWorld{ .floor_y = 63, .ceiling_y = 65 };

    var iterations: usize = 0;
    while (transform.velocity.y > 0 and iterations < 20) : (iterations += 1) {
        integrateWith(profile, &physics, &transform, &gap, FlatWorld.probe);
    }

    try std.testing.expect(transform.position.y < 65);
    try std.testing.expect(!physics.on_ground);
    try std.testing.expectEqual(@as(f32, 0), transform.velocity.y);
}

test "falling accumulates distance while airborne" {
    const profile = profileOf(.mob);
    var physics = Physics{ .profile = .mob };
    var transform = Transform{ .position = Protocol.Vector3f.init(0, 80, 0) };
    const air = FlatWorld{ .floor_y = 40, .ceiling_y = null };

    integrateWith(profile, &physics, &transform, &air, FlatWorld.probe);
    try std.testing.expect(!physics.on_ground);
    try std.testing.expect(physics.falling_distance > 0);
    try std.testing.expectEqual(@as(u32, 1), physics.fall_ticks);
}

test "resting entities stop marking dirty" {
    const profile = profileOf(.mob);
    var physics = Physics{ .profile = .mob, .on_ground = true };
    var transform = Transform{ .position = Protocol.Vector3f.init(1, 64, 1), .velocity = Protocol.Vector3f.zero(), .dirty = false, .moved = false };
    const flat = FlatWorld{ .floor_y = 63, .ceiling_y = null };

    integrateWith(profile, &physics, &transform, &flat, FlatWorld.probe);
    try std.testing.expectEqual(@as(f32, 64), transform.position.y);
    try std.testing.expect(physics.on_ground);

    transform.dirty = false;
    transform.moved = false;
    integrateWith(profile, &physics, &transform, &flat, FlatWorld.probe);
    try std.testing.expect(!transform.dirty);
    try std.testing.expect(!transform.moved);
}

test "profile table matches vanilla constants per entity family" {
    try std.testing.expectEqual(@as(f32, -0.04), profiles[@intFromEnum(PhysicsProfile.item)].gravity);
    try std.testing.expectEqual(@as(f32, 0.02), profiles[@intFromEnum(PhysicsProfile.item)].drag);
    try std.testing.expect(profiles[@intFromEnum(PhysicsProfile.item)].drag_before_gravity);
    try std.testing.expectEqual(@as(f32, -0.08), profiles[@intFromEnum(PhysicsProfile.mob)].gravity);
    try std.testing.expectEqual(@as(f32, 0.0), profiles[@intFromEnum(PhysicsProfile.mob)].drag);
}
