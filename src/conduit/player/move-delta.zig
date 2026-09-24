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

fn movedEnough(a: f32, b: f32) bool {
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

test "the first delta carries the full state" {
    var last: LastBroadcast = .{};
    const packet = nextDelta(&last, 7, stateAt(.{ 1, 2, 3 }, .{ 0, 90, 45 }), 0) orelse
        return error.TestUnexpectedResult;

    try testing.expectEqual(@as(?f32, 1), packet.x);
    try testing.expectEqual(@as(?f32, 2), packet.y);
    try testing.expectEqual(@as(?f32, 3), packet.z);
    try testing.expectEqual(@as(?i8, 0), packet.rotation_x);
    try testing.expectEqual(@as(?i8, 64), packet.rotation_y);
    try testing.expectEqual(@as(?i8, 32), packet.rotation_y_head);
    try testing.expect(packet.on_ground);
    try testing.expect(!packet.force_move);
    try testing.expect(last.valid);
}

test "a still player broadcasts nothing" {
    var last: LastBroadcast = .{};
    const state = stateAt(.{ 1, 2, 3 }, .{ 10, 20, 30 });
    _ = nextDelta(&last, 7, state, 0) orelse return error.TestUnexpectedResult;

    var tick: u64 = 1;
    while (tick < 99) : (tick += 1) {
        try testing.expect(nextDelta(&last, 7, state, tick) == null);
    }
}

test "only changed components are emitted" {
    var last: LastBroadcast = .{};
    _ = nextDelta(&last, 7, stateAt(.{ 0, 64, 0 }, .{ 0, 0, 0 }), 0) orelse
        return error.TestUnexpectedResult;

    const packet = nextDelta(&last, 7, stateAt(.{ 1, 64, 0 }, .{ 0, 0, 0 }), 1) orelse
        return error.TestUnexpectedResult;

    try testing.expectEqual(@as(?f32, 1), packet.x);
    try testing.expectEqual(@as(?f32, null), packet.y);
    try testing.expectEqual(@as(?f32, null), packet.z);
    try testing.expectEqual(@as(?i8, null), packet.rotation_x);
    try testing.expectEqual(@as(?i8, null), packet.rotation_y);
    try testing.expectEqual(@as(?i8, null), packet.rotation_y_head);
}

test "turning in place emits only the rotation" {
    var last: LastBroadcast = .{};
    _ = nextDelta(&last, 7, stateAt(.{ 5, 64, 5 }, .{ 0, 0, 0 }), 0) orelse
        return error.TestUnexpectedResult;

    const packet = nextDelta(&last, 7, stateAt(.{ 5, 64, 5 }, .{ 0, 90, 90 }), 1) orelse
        return error.TestUnexpectedResult;

    try testing.expectEqual(@as(?f32, null), packet.x);
    try testing.expectEqual(@as(?f32, null), packet.y);
    try testing.expectEqual(@as(?f32, null), packet.z);
    try testing.expectEqual(@as(?i8, null), packet.rotation_x);
    try testing.expectEqual(@as(?i8, 64), packet.rotation_y);
    try testing.expectEqual(@as(?i8, 64), packet.rotation_y_head);
}

test "position noise below the threshold does not broadcast" {
    var last: LastBroadcast = .{};
    _ = nextDelta(&last, 7, stateAt(.{ 0, 64, 0 }, .{ 0, 0, 0 }), 0) orelse
        return error.TestUnexpectedResult;

    const noise = POSITION_EPSILON / 2.0;
    try testing.expect(nextDelta(&last, 7, stateAt(.{ noise, 64 + noise, noise }, .{ 0, 0, 0 }), 1) == null);
}

test "a turn below the quantization step does not broadcast" {
    var last: LastBroadcast = .{};
    _ = nextDelta(&last, 7, stateAt(.{ 0, 64, 0 }, .{ 0, 0, 0 }), 0) orelse
        return error.TestUnexpectedResult;

    try testing.expect(nextDelta(&last, 7, stateAt(.{ 0, 64, 0 }, .{ 0.5, 0, 0 }), 1) == null);
}

test "the periodic refresh resends the full state" {
    var last: LastBroadcast = .{};
    const state = stateAt(.{ 1, 2, 3 }, .{ 0, 90, 45 });
    _ = nextDelta(&last, 7, state, 0) orelse return error.TestUnexpectedResult;

    // Justo antes del intervalo sigue sin haber nada que contar.
    try testing.expect(nextDelta(&last, 7, state, REFRESH_INTERVAL - 1) == null);

    const refresh = nextDelta(&last, 7, state, REFRESH_INTERVAL) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?f32, 1), refresh.x);
    try testing.expectEqual(@as(?f32, 2), refresh.y);
    try testing.expectEqual(@as(?f32, 3), refresh.z);
    try testing.expectEqual(@as(?i8, 64), refresh.rotation_y);
    try testing.expect(!refresh.force_move);

    try testing.expect(nextDelta(&last, 7, state, 2 * REFRESH_INTERVAL - 1) == null);
    try testing.expect(nextDelta(&last, 7, state, 2 * REFRESH_INTERVAL) != null);
}

test "a large jump sets force_move and sends the full position" {
    var last: LastBroadcast = .{};
    _ = nextDelta(&last, 7, stateAt(.{ 0, 64, 0 }, .{ 0, 0, 0 }), 0) orelse
        return error.TestUnexpectedResult;

    const packet = nextDelta(&last, 7, stateAt(.{ 100, 64, 0 }, .{ 0, 0, 0 }), 1) orelse
        return error.TestUnexpectedResult;

    try testing.expect(packet.force_move);
    try testing.expect(packet.force_completion);
    try testing.expectEqual(@as(?f32, 100), packet.x);
    try testing.expectEqual(@as(?f32, 64), packet.y);
    try testing.expectEqual(@as(?f32, 0), packet.z);

    const normal = nextDelta(&last, 7, stateAt(.{ 101, 64, 0 }, .{ 0, 0, 0 }), 2) orelse
        return error.TestUnexpectedResult;
    try testing.expect(!normal.force_move);
    try testing.expect(!normal.force_completion);
}

test "the teleport threshold is a distance, not a per-axis check" {
    var last: LastBroadcast = .{};
    _ = nextDelta(&last, 7, stateAt(.{ 0, 0, 0 }, .{ 0, 0, 0 }), 0) orelse
        return error.TestUnexpectedResult;

    const packet = nextDelta(&last, 7, stateAt(.{ 3, 3, 3 }, .{ 0, 0, 0 }), 1) orelse
        return error.TestUnexpectedResult;
    try testing.expect(packet.force_move);
}

test "on_ground is always written and its change counts as a change" {
    var last: LastBroadcast = .{};
    var state = stateAt(.{ 1, 2, 3 }, .{ 0, 0, 0 });
    state.on_ground = false;
    const first = nextDelta(&last, 7, state, 0) orelse return error.TestUnexpectedResult;
    try testing.expect(!first.on_ground);

    try testing.expect(nextDelta(&last, 7, state, 1) == null);

    state.on_ground = true;
    const landed = nextDelta(&last, 7, state, 2) orelse return error.TestUnexpectedResult;
    try testing.expect(landed.on_ground);
    try testing.expectEqual(@as(?f32, null), landed.x);
    try testing.expectEqual(@as(?f32, null), landed.y);
    try testing.expectEqual(@as(?f32, null), landed.z);
    try testing.expectEqual(@as(?i8, null), landed.rotation_x);
    try testing.expectEqual(@as(?i8, null), landed.rotation_y);
    try testing.expectEqual(@as(?i8, null), landed.rotation_y_head);

    const moved = nextDelta(&last, 7, stateAt(.{ 2, 2, 3 }, .{ 0, 0, 0 }), 3) orelse
        return error.TestUnexpectedResult;
    try testing.expect(moved.on_ground);
    try testing.expectEqual(@as(?f32, 2), moved.x);
}

test "reset invalidates the broadcast state" {
    var last: LastBroadcast = .{};
    const state = stateAt(.{ 1, 2, 3 }, .{ 0, 0, 0 });
    _ = nextDelta(&last, 7, state, 0) orelse return error.TestUnexpectedResult;
    try testing.expect(nextDelta(&last, 7, state, 1) == null);

    last.reset();

    const packet = nextDelta(&last, 7, state, 2) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?f32, 1), packet.x);
    try testing.expectEqual(@as(?f32, 2), packet.y);
    try testing.expectEqual(@as(?f32, 3), packet.z);
    try testing.expect(!packet.force_move);
}

test "every receiver gets the same delta" {
    var last: LastBroadcast = .{};
    _ = nextDelta(&last, 7, stateAt(.{ 0, 64, 0 }, .{ 0, 0, 0 }), 0) orelse
        return error.TestUnexpectedResult;

    const packet = nextDelta(&last, 7, stateAt(.{ 0.5, 64, 0 }, .{ 0, 0, 0 }), 1) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 7), packet.runtime_id);
}

test "an out-of-range rotation normalizes to 0 in every build mode" {
    try testing.expectEqual(@as(i8, 0), rotationToByte(std.math.nan(f32)));
    try testing.expectEqual(@as(i8, 0), rotationToByte(std.math.inf(f32)));
    try testing.expectEqual(@as(i8, 0), rotationToByte(-std.math.inf(f32)));

    try testing.expectEqual(@as(i8, 0), rotationToByte(1e40));
    try testing.expectEqual(@as(i8, 0), rotationToByte(std.math.floatMax(f32)));

    var last: LastBroadcast = .{};
    _ = nextDelta(&last, 7, stateAt(.{ 1, 2, 3 }, .{ 0, 0, 0 }), 0) orelse
        return error.TestUnexpectedResult;
    const packet = nextDelta(
        &last,
        7,
        stateAt(.{ std.math.nan(f32), 2, 3 }, .{ 0, 0, 0 }),
        1,
    ) orelse return error.TestUnexpectedResult;
    try testing.expect(packet.x != null);
    try testing.expect(std.math.isNan(packet.x.?));
    try testing.expectEqual(@as(?f32, null), packet.y);
    try testing.expectEqual(@as(?f32, null), packet.z);
}

test "rotationToByte quantizes in 1.40625 degree steps" {
    try testing.expectEqual(@as(i8, 0), rotationToByte(0));
    try testing.expectEqual(@as(i8, 64), rotationToByte(90));
    try testing.expectEqual(@as(i8, -128), rotationToByte(180));
    try testing.expectEqual(@as(i8, -64), rotationToByte(270));
    try testing.expectEqual(@as(i8, 0), rotationToByte(360));
    try testing.expectEqual(@as(i8, -64), rotationToByte(-90));
    try testing.expectEqual(@as(i8, 64), rotationToByte(450));
}
