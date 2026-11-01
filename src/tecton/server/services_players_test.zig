const Helpers = @import("services_test_helpers.zig").Fixture;

pub fn Suite(comptime scope: type) type {
    return struct {
        const F = Helpers(scope);
        const std = F.std;
        const testing = F.testing;
        const allocator = F.allocator;

        const Tecton = F.Tecton;
        const host = F.host;
        const Player = F.Player;

        const PlayerRegistry = F.PlayerRegistry;
        const PlayerLocations = F.PlayerLocations;

        const stubNetwork = F.stubNetwork;
        const baseTecton = F.baseTecton;
        const fakePlayer = F.fakePlayer;
        const fakeConnection = F.fakeConnection;

        pub fn case_001() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();
            var conn_storage: u128 align(16) = 0;

            const h = host(&tecton);
            try std.testing.expectEqual(@as(?*Player, null), h.players.byRuntimeId(7));
            var player = fakePlayer(7, fakeConnection(&conn_storage, 1));
            try tecton.players.insert(&player);
            try std.testing.expectEqual(@as(?*Player, &player), h.players.byRuntimeId(7));
        }

        pub fn case_002() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();
            var conn_storage: u128 align(16) = 0;

            const h = host(&tecton);
            try std.testing.expectEqual(@as(usize, 0), h.getPlayerCount());
            var player = fakePlayer(7, fakeConnection(&conn_storage, 1));
            try tecton.players.insert(&player);
            try std.testing.expectEqual(@as(usize, 1), h.getPlayerCount());
        }

        pub fn case_003() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();
            var conn_storage: u128 align(16) = 0;

            const h = host(&tecton);
            try std.testing.expectEqual(@as(usize, 0), h.getPlayerSnapshots().len);
            var player = fakePlayer(7, fakeConnection(&conn_storage, 1));
            try tecton.players.insert(&player);
            const snapshots = h.getPlayerSnapshots();
            try std.testing.expectEqual(@as(usize, 1), snapshots.len);
            try std.testing.expectEqual(@as(*Player, &player), snapshots[0]);
        }

        pub fn case_004() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();
            var conn_storage: u128 align(16) = 0;

            const h = host(&tecton);
            try std.testing.expectEqual(@as(?*Player, null), h.findPlayerByRuntimeId(7));
            var player = fakePlayer(7, fakeConnection(&conn_storage, 1));
            try tecton.players.insert(&player);
            try std.testing.expectEqual(@as(?*Player, &player), h.findPlayerByRuntimeId(7));
        }

        pub fn case_007() !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/locations.json", .{&tmp.sub_path});

            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.player_locations = PlayerLocations.init(testing.io, allocator, path);
            defer tecton.player_locations.deinit();

            const h = host(&tecton);
            try std.testing.expect(tecton.player_locations.get("uuid-1") == null);
            h.setPlayerLocation("uuid-1", "arena", "nether");
            const stored = tecton.player_locations.get("uuid-1").?;
            try std.testing.expectEqualStrings("arena", stored.world);
            try std.testing.expectEqualStrings("nether", stored.dimension);
        }

        pub fn case_008() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();
            var conn_storage: u128 align(16) = 0;

            const h = host(&tecton);
            var player = fakePlayer(7, fakeConnection(&conn_storage, 1));
            h.enqueuePlayerRemoval(&player);
            var pending = tecton.players.takePendingRemovals();
            defer pending.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 1), pending.items.len);
            try std.testing.expectEqual(@as(*Player, &player), pending.items[0]);
        }

        pub fn case_009() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();
            var conn_storage: u128 align(16) = 0;

            const h = host(&tecton);
            var player = fakePlayer(7, fakeConnection(&conn_storage, 1));
            try tecton.players.insert(&player);
            h.removePlayer(&player);
            try std.testing.expectEqual(@as(?*Player, null), tecton.players.byRuntimeId(7));
            try std.testing.expectEqual(@as(usize, 0), h.getPlayerCount());
        }

        pub fn case_010() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();
            var conn_storage: u128 align(16) = 0;
            const conn = fakeConnection(&conn_storage, 1);

            const h = host(&tecton);
            var player = fakePlayer(7, conn);
            try tecton.players.insert(&player);
            try std.testing.expect(tecton.players.byConnection(conn) != null);
            h.removeConnectionMapping(conn);
            try std.testing.expectEqual(@as(?*Player, null), tecton.players.byConnection(conn));
        }

        pub fn case_011() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);

            const h = host(&tecton);
            tecton.config.max_tps = 30;
            try std.testing.expectEqual(@as(f64, 30.0), h.targetTps());
        }

        pub fn case_012() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);

            const h = host(&tecton);
            tecton.current_tps = 12.5;
            try std.testing.expectEqual(@as(f64, 12.5), h.currentTps());
        }

        pub fn case_013() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);

            const h = host(&tecton);
            tecton.current_mspt = 4.25;
            try std.testing.expectEqual(@as(f64, 4.25), h.currentMspt());
        }

        pub fn case_014() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);

            const h = host(&tecton);
            tecton.tick_count = 77;
            try std.testing.expectEqual(@as(u64, 77), h.tickCount());
        }
    };
}
