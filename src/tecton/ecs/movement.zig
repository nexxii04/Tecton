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

pub fn resolveGround(profile: Profile, physics: *Physics, transform: *Transform, block_below: Protocol.BlockPosition, solid_below: bool) void {
    if (solid_below) {
        const land_y: f32 = @floatFromInt(block_below.y + 1);
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

pub fn integrate(profile: Profile, physics: *Physics, transform: *Transform, solid_below: bool, block_below: Protocol.BlockPosition) void {
    const previous = transform.position;
    applyAirPhysics(&transform.velocity, profile.drag, profile.gravity, profile.drag_before_gravity);
    transform.position = transform.position.add(transform.velocity);
    resolveGround(profile, physics, transform, block_below, solid_below);

    const moved = MoveDelta.movedEnough(transform.position.x, previous.x) or
        MoveDelta.movedEnough(transform.position.y, previous.y) or
        MoveDelta.movedEnough(transform.position.z, previous.z);
    transform.dirty = transform.dirty or moved;
    transform.moved = moved;
}

pub fn movementApply(world: *components.GameWorld, dimension: *Dimension) void {
    const Ctx = struct { dimension: *Dimension };
    var ctx = Ctx{ .dimension = dimension };
    query.each(world, .{ Physics, Transform }, &ctx, struct {
        fn call(c: *Ctx, _: @import("entity_id.zig").EntityId, physics: *Physics, transform: *Transform) void {
            const dim = c.dimension;
            const bx: i32 = @intFromFloat(@floor(transform.position.x));
            const bz: i32 = @intFromFloat(@floor(transform.position.z));
            if (dim.getChunk(bx >> 4, bz >> 4) == null) return;

            const by: i32 = @intFromFloat(@floor(transform.position.y - 0.01));
            const below = Protocol.BlockPosition{ .x = bx, .y = by, .z = bz };
            var solid = false;
            if (dim.getPermutation(below, 0) catch null) |perm| {
                solid = !std.mem.eql(u8, perm.identifier, "minecraft:air");
            }
            integrate(profileOf(physics.profile), physics, transform, solid, below);
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

test "landing snaps to the block top and stops negative velocity" {
    const profile = profileOf(.item);
    var physics = Physics{ .profile = .item, .falling_distance = 3.5, .fall_ticks = 20 };
    var transform = Transform{ .position = Protocol.Vector3f.init(0.5, 63.8, 0.5), .velocity = Protocol.Vector3f.init(0.4, -0.08, 0.4) };
    const below = Protocol.BlockPosition{ .x = 0, .y = 63, .z = 0 };

    integrate(profile, &physics, &transform, true, below);

    try std.testing.expect(physics.on_ground);
    try std.testing.expectEqual(@as(f32, 64), transform.position.y);
    try std.testing.expectEqual(@as(f32, 0), transform.velocity.y);
    try std.testing.expectEqual(@as(f32, 0), physics.falling_distance);
    try std.testing.expect(transform.velocity.x < 0.4);
    try std.testing.expect(transform.dirty);
    try std.testing.expect(transform.moved);
}

test "falling accumulates distance while airborne" {
    const profile = profileOf(.mob);
    var physics = Physics{ .profile = .mob };
    var transform = Transform{ .position = Protocol.Vector3f.init(0, 80, 0) };
    const below = Protocol.BlockPosition{ .x = 0, .y = 79, .z = 0 };

    integrate(profile, &physics, &transform, false, below);
    try std.testing.expect(!physics.on_ground);
    try std.testing.expect(physics.falling_distance > 0);
    try std.testing.expectEqual(@as(u32, 1), physics.fall_ticks);
}

test "resting entities stop marking dirty" {
    const profile = profileOf(.mob);
    var physics = Physics{ .profile = .mob, .on_ground = true };
    var transform = Transform{ .position = Protocol.Vector3f.init(1, 64, 1), .velocity = Protocol.Vector3f.zero(), .dirty = false, .moved = false };
    const below = Protocol.BlockPosition{ .x = 1, .y = 63, .z = 1 };

    integrate(profile, &physics, &transform, true, below);
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
