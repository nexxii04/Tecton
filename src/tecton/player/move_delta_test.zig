pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const testing = scope.testing;
        const rotationToByte = scope.rotationToByte;
        const POSITION_EPSILON = scope.POSITION_EPSILON;
        const REFRESH_INTERVAL = scope.REFRESH_INTERVAL;
        const LastBroadcast = scope.LastBroadcast;
        const isTeleport = scope.isTeleport;
        const nextDelta = scope.nextDelta;
        const stateAt = scope.stateAt;

        pub fn case_000() !void {
            var last: LastBroadcast = .{};
            const origin = stateAt(.{ 0, 64, 0 }, .{ 0, 0, 0 });
            try testing.expect(!isTeleport(&last, origin));

            _ = nextDelta(&last, 7, origin, 0) orelse return error.TestUnexpectedResult;
            try testing.expect(!isTeleport(&last, stateAt(.{ 3, 64, 0 }, .{ 0, 0, 0 })));
            try testing.expect(!isTeleport(&last, stateAt(.{ 4.0, 64, 0 }, .{ 0, 0, 0 })));
            try testing.expect(isTeleport(&last, stateAt(.{ 0, 64, 4.01 }, .{ 0, 0, 0 })));
            try testing.expect(isTeleport(&last, stateAt(.{ 3, 64, 3 }, .{ 0, 0, 0 })));
        }

        pub fn case_001() !void {
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

        pub fn case_002() !void {
            var last: LastBroadcast = .{};
            const state = stateAt(.{ 1, 2, 3 }, .{ 10, 20, 30 });
            _ = nextDelta(&last, 7, state, 0) orelse return error.TestUnexpectedResult;

            var tick: u64 = 1;
            while (tick < 99) : (tick += 1) {
                try testing.expect(nextDelta(&last, 7, state, tick) == null);
            }
        }

        pub fn case_003() !void {
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

        pub fn case_004() !void {
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

        pub fn case_005() !void {
            var last: LastBroadcast = .{};
            _ = nextDelta(&last, 7, stateAt(.{ 0, 64, 0 }, .{ 0, 0, 0 }), 0) orelse
                return error.TestUnexpectedResult;

            const noise = POSITION_EPSILON / 2.0;
            try testing.expect(nextDelta(&last, 7, stateAt(.{ noise, 64 + noise, noise }, .{ 0, 0, 0 }), 1) == null);
        }

        pub fn case_006() !void {
            var last: LastBroadcast = .{};
            _ = nextDelta(&last, 7, stateAt(.{ 0, 64, 0 }, .{ 0, 0, 0 }), 0) orelse
                return error.TestUnexpectedResult;

            try testing.expect(nextDelta(&last, 7, stateAt(.{ 0, 64, 0 }, .{ 0.5, 0, 0 }), 1) == null);
        }

        pub fn case_007() !void {
            var last: LastBroadcast = .{};
            const state = stateAt(.{ 1, 2, 3 }, .{ 0, 90, 45 });
            _ = nextDelta(&last, 7, state, 0) orelse return error.TestUnexpectedResult;

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

        pub fn case_008() !void {
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

        pub fn case_009() !void {
            var last: LastBroadcast = .{};
            _ = nextDelta(&last, 7, stateAt(.{ 0, 0, 0 }, .{ 0, 0, 0 }), 0) orelse
                return error.TestUnexpectedResult;

            const packet = nextDelta(&last, 7, stateAt(.{ 3, 3, 3 }, .{ 0, 0, 0 }), 1) orelse
                return error.TestUnexpectedResult;
            try testing.expect(packet.force_move);
        }

        pub fn case_010() !void {
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

        pub fn case_011() !void {
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

        pub fn case_012() !void {
            var last: LastBroadcast = .{};
            _ = nextDelta(&last, 7, stateAt(.{ 0, 64, 0 }, .{ 0, 0, 0 }), 0) orelse
                return error.TestUnexpectedResult;

            const packet = nextDelta(&last, 7, stateAt(.{ 0.5, 64, 0 }, .{ 0, 0, 0 }), 1) orelse
                return error.TestUnexpectedResult;
            try testing.expectEqual(@as(u64, 7), packet.runtime_id);
        }

        pub fn case_013() !void {
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

        pub fn case_014() !void {
            try testing.expectEqual(@as(i8, 0), rotationToByte(0));
            try testing.expectEqual(@as(i8, 64), rotationToByte(90));
            try testing.expectEqual(@as(i8, -128), rotationToByte(180));
            try testing.expectEqual(@as(i8, -64), rotationToByte(270));
            try testing.expectEqual(@as(i8, 0), rotationToByte(360));
            try testing.expectEqual(@as(i8, -64), rotationToByte(-90));
            try testing.expectEqual(@as(i8, 64), rotationToByte(450));
        }
    };
}
