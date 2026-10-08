const std = @import("std");
const testing = std.testing;

const Protocol = @import("protocol");

pub fn rotationToByte(degrees: f32) i8 {
    const normalized = @mod(degrees, 360.0);
    if (!std.math.isFinite(normalized)) return 0;

    const steps: u32 = @intFromFloat(normalized / 360.0 * 256.0);
    return @bitCast(@as(u8, @truncate(steps)));
}

pub const POSITION_EPSILON: f32 = 1.0 / 512.0;

pub fn movedEnough(a: f32, b: f32) bool {
    return !(@abs(a - b) <= POSITION_EPSILON);
}

pub const TELEPORT_DISTANCE: f32 = 4.0;
pub const REFRESH_INTERVAL: u64 = 100;

pub const State = struct {
    position: [3]f32,
    rotation: [3]f32,
    on_ground: bool = true,
};
pub const LastBroadcast = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    rotation: [3]i8 = .{ 0, 0, 0 },
    on_ground: bool = true,
    tick: u64 = 0,
    valid: bool = false,

    pub fn reset(self: *LastBroadcast) void {
        self.* = .{};
    }
};

fn setPosition(packet: *Protocol.MoveActorDeltaPacket, state: State) void {
    packet.x = state.position[0];
    packet.y = state.position[1];
    packet.z = state.position[2];
}

fn setFull(packet: *Protocol.MoveActorDeltaPacket, state: State, rotation: [3]i8) void {
    setPosition(packet, state);
    packet.rotation_x = rotation[0];
    packet.rotation_y = rotation[1];
    packet.rotation_y_head = rotation[2];
}

fn commit(last: *LastBroadcast, state: State, rotation: [3]i8, tick: u64) void {
    last.* = .{
        .position = state.position,
        .rotation = rotation,
        .on_ground = state.on_ground,
        .tick = tick,
        .valid = true,
    };
}

pub fn isTeleport(last: *const LastBroadcast, state: State) bool {
    if (!last.valid) return false;
    const dx = state.position[0] - last.position[0];
    const dy = state.position[1] - last.position[1];
    const dz = state.position[2] - last.position[2];
    return dx * dx + dy * dy + dz * dz > TELEPORT_DISTANCE * TELEPORT_DISTANCE;
}

pub fn nextDelta(
    last: *LastBroadcast,
    runtime_id: u64,
    state: State,
    tick: u64,
) ?Protocol.MoveActorDeltaPacket {
    var packet = Protocol.MoveActorDeltaPacket.init(runtime_id);

    packet.on_ground = state.on_ground;

    const rotation = [3]i8{
        rotationToByte(state.rotation[0]),
        rotationToByte(state.rotation[1]),
        rotationToByte(state.rotation[2]),
    };

    const refresh_due = last.valid and tick -% last.tick >= REFRESH_INTERVAL;
    if (!last.valid or refresh_due) {
        setFull(&packet, state, rotation);
        commit(last, state, rotation, tick);
        return packet;
    }

    const delta = [3]f32{
        state.position[0] - last.position[0],
        state.position[1] - last.position[1],
        state.position[2] - last.position[2],
    };

    var changed = false;

    if (movedEnough(state.position[0], last.position[0]) or
        movedEnough(state.position[1], last.position[1]) or
        movedEnough(state.position[2], last.position[2]))
    {
        const distance_sq = delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2];
        if (distance_sq > TELEPORT_DISTANCE * TELEPORT_DISTANCE) {
            setPosition(&packet, state);
            packet.force_move = true;
            packet.force_completion = true;
        } else {
            if (movedEnough(state.position[0], last.position[0])) packet.x = state.position[0];
            if (movedEnough(state.position[1], last.position[1])) packet.y = state.position[1];
            if (movedEnough(state.position[2], last.position[2])) packet.z = state.position[2];
        }
        changed = true;
    }

    if (rotation[0] != last.rotation[0]) {
        packet.rotation_x = rotation[0];
        changed = true;
    }
    if (rotation[1] != last.rotation[1]) {
        packet.rotation_y = rotation[1];
        changed = true;
    }
    if (rotation[2] != last.rotation[2]) {
        packet.rotation_y_head = rotation[2];
        changed = true;
    }

    if (state.on_ground != last.on_ground) changed = true;

    if (!changed) return null;

    commit(last, state, rotation, tick);
    return packet;
}

fn stateAt(position: [3]f32, rotation: [3]f32) State {
    return .{ .position = position, .rotation = rotation };
}

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const testing = test_owner.testing;
    pub const rotationToByte = test_owner.rotationToByte;
    pub const POSITION_EPSILON = test_owner.POSITION_EPSILON;
    pub const REFRESH_INTERVAL = test_owner.REFRESH_INTERVAL;
    pub const LastBroadcast = test_owner.LastBroadcast;
    pub const isTeleport = test_owner.isTeleport;
    pub const nextDelta = test_owner.nextDelta;
    pub const stateAt = test_owner.stateAt;
};

test "a jump past the teleport distance is detected before the delta is built" {
    try @import("move_delta_test.zig").Suite(test_scope).case_000();
}

test "the first delta carries the full state" {
    try @import("move_delta_test.zig").Suite(test_scope).case_001();
}

test "a still player broadcasts nothing" {
    try @import("move_delta_test.zig").Suite(test_scope).case_002();
}

test "only changed components are emitted" {
    try @import("move_delta_test.zig").Suite(test_scope).case_003();
}

test "turning in place emits only the rotation" {
    try @import("move_delta_test.zig").Suite(test_scope).case_004();
}

test "position noise below the threshold does not broadcast" {
    try @import("move_delta_test.zig").Suite(test_scope).case_005();
}

test "a turn below the quantization step does not broadcast" {
    try @import("move_delta_test.zig").Suite(test_scope).case_006();
}

test "the periodic refresh resends the full state" {
    try @import("move_delta_test.zig").Suite(test_scope).case_007();
}

test "a large jump sets force_move and sends the full position" {
    try @import("move_delta_test.zig").Suite(test_scope).case_008();
}

test "the teleport threshold is a distance, not a per-axis check" {
    try @import("move_delta_test.zig").Suite(test_scope).case_009();
}

test "on_ground is always written and its change counts as a change" {
    try @import("move_delta_test.zig").Suite(test_scope).case_010();
}

test "reset invalidates the broadcast state" {
    try @import("move_delta_test.zig").Suite(test_scope).case_011();
}

test "every receiver gets the same delta" {
    try @import("move_delta_test.zig").Suite(test_scope).case_012();
}

test "an out-of-range rotation normalizes to 0 in every build mode" {
    try @import("move_delta_test.zig").Suite(test_scope).case_013();
}

test "rotationToByte quantizes in 1.40625 degree steps" {
    try @import("move_delta_test.zig").Suite(test_scope).case_014();
}
