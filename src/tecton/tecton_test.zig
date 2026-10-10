pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const ServerProperties = scope.ServerProperties;
        const Tecton = scope.Tecton;

        pub fn case_000() !void {
            const source = @embedFile("tecton.zig");
            const cutoff = std.mem.indexOf(u8, source, "test \"the RakNet MTU cap") orelse return error.TestUnexpectedResult;
            const init_code = source[0..cutoff];
            try std.testing.expect(std.mem.indexOf(u8, init_code, "ServerProperties.clampMaxMtu(owned_config.max_mtu)") != null);

            var found: usize = 0;
            var rest: []const u8 = init_code;
            while (std.mem.indexOf(u8, rest, ".max_mtu = ")) |at| {
                const value_start = at + ".max_mtu = ".len;
                const end = std.mem.indexOfScalarPos(u8, rest, value_start, ',') orelse return error.TestUnexpectedResult;
                if (!std.mem.eql(u8, rest[value_start..end], "max_mtu")) {
                    std.debug.print("tecton.zig: the RakNet MTU cap is not the clamped config value\n", .{});
                    return error.TestUnexpectedResult;
                }
                found += 1;
                rest = rest[end..];
            }
            try std.testing.expectEqual(@as(usize, 1), found);
        }

        pub fn case_001() !void {
            const source = @embedFile("server/movement.zig");
            try std.testing.expect(std.mem.indexOf(u8, source, "sendPacketsUncompressedWith(viewer.connection, batch.items, tecton.movement_priority)") != null);
        }

        pub fn case_002() !void {
            const source = @embedFile("server/tick.zig");
            const flush_call = "tecton.flushMovementBroadcasts()";

            const on_tick_start = std.mem.indexOf(u8, source, "pub fn onTick(context: ?*anyopaque) void {") orelse
                return error.TestUnexpectedResult;
            const body = source[on_tick_start..];

            const allocator = std.testing.allocator;
            var code: std.ArrayList(u8) = .empty;
            defer code.deinit(allocator);
            var lines = std.mem.splitScalar(u8, body, '\n');
            while (lines.next()) |line| {
                const stripped = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
                try code.appendSlice(allocator, stripped);
                try code.append(allocator, '\n');
            }

            const flush_at = std.mem.indexOf(u8, code.items, flush_call) orelse {
                std.debug.print("tecton.zig: onTick no longer calls {s}: movement is not broadcast\n", .{flush_call});
                return error.TestUnexpectedResult;
            };

            if (std.mem.indexOf(u8, code.items[0..flush_at], "return")) |at| {
                const line_no = std.mem.count(u8, code.items[0..at], "\n") + 2;
                std.debug.print(
                    "server/tick.zig:{d}: onTick returns before the movement flush\n",
                    .{on_tick_start_line(source, on_tick_start) + line_no},
                );
                return error.TestUnexpectedResult;
            }
        }

        pub fn case_003() !void {
            const registry_source = @embedFile("server/players.zig");
            if (std.mem.indexOf(u8, registry_source, "if (!self.publishing) return &.{};") == null) {
                std.debug.print("server/players.zig: the published snapshot outlives the players it points at\n", .{});
                return error.TestUnexpectedResult;
            }
            if (std.mem.indexOf(u8, registry_source, "self.publishing = false;") == null) {
                std.debug.print("server/players.zig: nothing silences the snapshot before teardown\n", .{});
                return error.TestUnexpectedResult;
            }

            const source = @embedFile("tecton.zig");
            const deinit_start = std.mem.indexOf(u8, source, "pub fn deinit(self: *Tecton) void {") orelse
                return error.TestUnexpectedResult;
            const guard = std.mem.indexOfPos(u8, source, deinit_start, "self.players.silence();") orelse {
                std.debug.print("tecton.zig: deinit frees the players while block traits can still broadcast\n", .{});
                return error.TestUnexpectedResult;
            };
            const players_freed = std.mem.indexOfPos(u8, source, guard, "self.players.destroyPlayers();") orelse
                return error.TestUnexpectedResult;
            try std.testing.expect(guard < players_freed);
        }

        fn on_tick_start_line(source: []const u8, at: usize) usize {
            return std.mem.count(u8, source[0..at], "\n") + 1;
        }

        pub fn case_004() !void {
            _ = scope.test_dependency_15;
            _ = scope.test_dependency_2;
            _ = scope.test_dependency_9;
            _ = scope.test_dependency_6;
            _ = scope.test_dependency_7;
            _ = scope.test_dependency_8;
            _ = scope.test_dependency_11;
            _ = scope.test_dependency_10;
            _ = scope.test_dependency_13;
            _ = scope.test_dependency_12;
            _ = scope.test_dependency_0;
            _ = scope.test_dependency_3;
            _ = scope.test_dependency_1;
            _ = scope.test_dependency_20;
            _ = scope.test_dependency_19;
            _ = scope.test_dependency_4;
            _ = scope.test_dependency_5;
            _ = scope.test_dependency_18;
            _ = scope.test_dependency_17;
            _ = scope.test_dependency_16;
        }
    };
}
