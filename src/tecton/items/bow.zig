const std = @import("std");
const Protocol = @import("protocol");

pub const IDENTIFIER = "minecraft:bow";
pub const ARROW_IDENTIFIER = "minecraft:arrow";
pub const FULL_CHARGE_TICKS: u64 = 20;
pub const MIN_CHARGE_TICKS: u64 = 3;
pub const MAX_LAUNCH_SPEED: f32 = 3.0;
pub const DAMAGE_PER_SPEED: f32 = 2.0;
pub const CRITICAL_CHARGE_TICKS: u64 = FULL_CHARGE_TICKS;
pub const CRITICAL_MULTIPLIER: f32 = 1.5;
pub const MIN_CRITICAL_DAMAGE: f32 = 9.0;
pub const MAX_CRITICAL_DAMAGE: f32 = 10.0;

pub fn isBow(identifier: []const u8) bool {
    return std.mem.eql(u8, identifier, IDENTIFIER);
}

pub fn chargeAfter(ticks: u64) f32 {
    if (ticks >= FULL_CHARGE_TICKS) return 1.0;
    const held: f32 = @as(f32, @floatFromInt(ticks)) / @as(f32, @floatFromInt(FULL_CHARGE_TICKS));
    return (held * held + held * 2.0) / 3.0;
}

pub fn canShoot(ticks: u64) bool {
    return ticks >= MIN_CHARGE_TICKS;
}

pub fn launchSpeed(charge: f32) f32 {
    return charge * MAX_LAUNCH_SPEED;
}

pub fn damageFor(speed: f32) f32 {
    return @ceil(@max(0.0, speed) * DAMAGE_PER_SPEED);
}

pub fn isCritical(drawn_ticks: u64) bool {
    return drawn_ticks >= CRITICAL_CHARGE_TICKS;
}

pub fn criticalDamage(damage: f32) f32 {
    return @min(MAX_CRITICAL_DAMAGE, @max(MIN_CRITICAL_DAMAGE, damage * CRITICAL_MULTIPLIER));
}

pub fn launchVelocity(rotation: Protocol.Vector2f, speed: f32) Protocol.Vector3f {
    const yaw = rotation.y * std.math.pi / 180.0;
    const pitch = rotation.x * std.math.pi / 180.0;
    return Protocol.Vector3f.init(
        -@sin(yaw) * @cos(pitch) * speed,
        -@sin(pitch) * speed,
        @cos(yaw) * @cos(pitch) * speed,
    );
}

pub fn yawOf(motion: Protocol.Vector3f) f32 {
    const horizontal = @sqrt(motion.x * motion.x + motion.z * motion.z);
    if (horizontal < 0.0001) return 0;
    return std.math.atan2(motion.x, motion.z) * 180.0 / std.math.pi;
}

pub fn pitchOf(motion: Protocol.Vector3f) f32 {
    const horizontal = @sqrt(motion.x * motion.x + motion.z * motion.z);
    return std.math.atan2(motion.y, horizontal) * 180.0 / std.math.pi;
}

pub fn rotationOf(motion: Protocol.Vector3f) Protocol.Vector2f {
    return Protocol.Vector2f.init(pitchOf(motion), yawOf(motion));
}

const testing = std.testing;

test "a bow draws from nothing to full in twenty ticks" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), chargeAfter(0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.1075), chargeAfter(3), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.1875), chargeAfter(5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.41666666), chargeAfter(10), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), chargeAfter(20), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), chargeAfter(200), 0.0001);
}

test "only a bow shoots and only after three ticks of draw" {
    try testing.expect(isBow("minecraft:bow"));
    try testing.expect(!isBow("minecraft:crossbow"));
    try testing.expect(!isBow("minecraft:arrow"));
    try testing.expect(!canShoot(0));
    try testing.expect(!canShoot(2));
    try testing.expect(canShoot(3));
    try testing.expect(canShoot(20));
}

test "the launch speed is the vanilla arrow speed scaled by the charge" {
    try testing.expectApproxEqAbs(@as(f32, 3.0), launchSpeed(1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.5), launchSpeed(0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), launchSpeed(0.0), 0.0001);
}

test "a full charge arrow carries the vanilla six damage" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), damageFor(0.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), damageFor(0.45), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 6.0), damageFor(launchSpeed(1.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 3.0), damageFor(launchSpeed(0.5)), 0.0001);
}

test "the aim follows the pitch and yaw the drop velocity uses" {
    const level = launchVelocity(Protocol.Vector2f.init(0, 0), 2.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), level.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), level.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), level.z, 0.0001);

    const down = launchVelocity(Protocol.Vector2f.init(90, 0), 2.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), down.z, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -2.0), down.y, 0.0001);

    const up = launchVelocity(Protocol.Vector2f.init(-90, 0), 2.0);
    try testing.expectApproxEqAbs(@as(f32, 2.0), up.y, 0.0001);

    const west = launchVelocity(Protocol.Vector2f.init(0, 90), 2.0);
    try testing.expectApproxEqAbs(@as(f32, -2.0), west.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), west.z, 0.0001);
}

test "a projectile's wire rotation runs opposite to the aim that launched it" {
    const aims = [_]Protocol.Vector2f{
        Protocol.Vector2f.init(0, 0),
        Protocol.Vector2f.init(-35, 90),
        Protocol.Vector2f.init(12, -140),
        Protocol.Vector2f.init(-72, 179),
        Protocol.Vector2f.init(45, -30),
    };

    for (aims) |aim| {
        const rotation = rotationOf(launchVelocity(aim, 3.0));
        try testing.expectApproxEqAbs(-aim.x, rotation.x, 0.001);
        try testing.expectApproxEqAbs(-aim.y, rotation.y, 0.001);
    }
}

test "the wire rotation of an arrow follows the velocity it is flying with" {
    const cases = [_]struct { motion: Protocol.Vector3f, pitch: f32, yaw: f32 }{
        .{ .motion = Protocol.Vector3f.init(0, 0, 1), .pitch = 0, .yaw = 0 },
        .{ .motion = Protocol.Vector3f.init(0, 0, -1), .pitch = 0, .yaw = 180 },
        .{ .motion = Protocol.Vector3f.init(1, 0, 0), .pitch = 0, .yaw = 90 },
        .{ .motion = Protocol.Vector3f.init(-1, 0, 0), .pitch = 0, .yaw = -90 },
        .{ .motion = Protocol.Vector3f.init(0, 1, 0), .pitch = 90, .yaw = 0 },
        .{ .motion = Protocol.Vector3f.init(0, -1, 0), .pitch = -90, .yaw = 0 },
        .{ .motion = Protocol.Vector3f.init(0, 1, 1), .pitch = 45, .yaw = 0 },
        .{ .motion = Protocol.Vector3f.init(1, -1, 1), .pitch = -35.264389, .yaw = 45 },
    };

    for (cases) |case| {
        const rotation = rotationOf(case.motion);
        try testing.expectApproxEqAbs(case.pitch, rotation.x, 0.001);
        try testing.expectApproxEqAbs(case.yaw, rotation.y, 0.001);
    }
}

test "a straight up and a straight down shot keep a level yaw" {
    const up = rotationOf(launchVelocity(Protocol.Vector2f.init(-90, 0), 2.0));
    try testing.expectApproxEqAbs(@as(f32, 90.0), up.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), up.y, 0.001);

    const down = rotationOf(launchVelocity(Protocol.Vector2f.init(90, 0), 2.0));
    try testing.expectApproxEqAbs(@as(f32, -90.0), down.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), down.y, 0.001);
}

test "a critical arrow is clamped into the vanilla nine to ten band" {
    try testing.expect(!isCritical(CRITICAL_CHARGE_TICKS - 1));
    try testing.expect(isCritical(CRITICAL_CHARGE_TICKS));
    try testing.expect(isCritical(60));

    try testing.expectApproxEqAbs(@as(f32, 9.0), criticalDamage(6.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 9.0), criticalDamage(1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 9.75), criticalDamage(6.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 10.0), criticalDamage(7.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 10.0), criticalDamage(100.0), 0.0001);
}

test "the launch speed never leaves the arrow at rest" {
    try testing.expect(!canShoot(MIN_CHARGE_TICKS - 1));
    try testing.expect(launchSpeed(chargeAfter(MIN_CHARGE_TICKS)) > 0);
    try testing.expect(damageFor(launchSpeed(chargeAfter(MIN_CHARGE_TICKS))) >= 1.0);
    try testing.expect(chargeAfter(MIN_CHARGE_TICKS) >= 0.1);
    try testing.expect(chargeAfter(MIN_CHARGE_TICKS - 1) < 0.1);
}
