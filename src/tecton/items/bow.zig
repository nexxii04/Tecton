const std = @import("std");
const Protocol = @import("protocol");

pub const IDENTIFIER = "minecraft:bow";
pub const ARROW_IDENTIFIER = "minecraft:arrow";
pub const FULL_CHARGE_TICKS: u64 = 20;
pub const MIN_CHARGE_TICKS: u64 = 3;
pub const MAX_LAUNCH_SPEED: f32 = 5.0;
pub const POWER_MULTIPLIER: f32 = 0.97;
pub const BASE_ARROW_DAMAGE: f32 = 1.0;

pub fn isBow(identifier: []const u8) bool {
    return std.mem.eql(u8, identifier, IDENTIFIER);
}

pub fn chargeAfter(ticks: u64) f32 {
    if (ticks >= FULL_CHARGE_TICKS) return 1.0;
    return @as(f32, @floatFromInt(ticks)) / @as(f32, @floatFromInt(FULL_CHARGE_TICKS));
}

pub fn canShoot(ticks: u64) bool {
    return ticks >= MIN_CHARGE_TICKS;
}

pub fn launchSpeed(charge: f32) f32 {
    return charge * MAX_LAUNCH_SPEED;
}

pub fn damageFor(speed: f32) f32 {
    return BASE_ARROW_DAMAGE + POWER_MULTIPLIER * speed;
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

const testing = std.testing;

test "a bow draws from nothing to full in twenty ticks" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), chargeAfter(0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), chargeAfter(5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), chargeAfter(10), 0.0001);
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

test "the launch speed is the arrow power scaled by the charge" {
    try testing.expectApproxEqAbs(@as(f32, 5.0), launchSpeed(1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2.5), launchSpeed(0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), launchSpeed(0.0), 0.0001);
}

test "a full charge arrow carries the bedrock base damage" {
    try testing.expectApproxEqAbs(@as(f32, 1.0), damageFor(0.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5.85), damageFor(launchSpeed(1.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 3.425), damageFor(launchSpeed(0.5)), 0.0001);
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

test "the launch speed never leaves the arrow at rest" {
    try testing.expect(!canShoot(MIN_CHARGE_TICKS - 1));
    try testing.expect(launchSpeed(chargeAfter(MIN_CHARGE_TICKS)) > 0);
    try testing.expect(damageFor(launchSpeed(chargeAfter(MIN_CHARGE_TICKS))) > 1.0);
}
