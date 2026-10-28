pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Protocol = scope.Protocol;
        const WorkerLayout = scope.WorkerLayout;
        const shouldEmitVerboseStartupLogs = scope.shouldEmitVerboseStartupLogs;
        const shouldEmitStartupLogs = scope.shouldEmitStartupLogs;
        const ServerProperties = scope.ServerProperties;

        pub fn case_000() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();
            try std.testing.expectEqual(Protocol.GameMode.Survival, properties.gameMode());
            try scope.set_field(&properties, "gamemode", "creative");
            try std.testing.expectEqual(Protocol.GameMode.Creative, properties.gameMode());
            try scope.set_field(&properties, "gamemode", "Adventure");
            try std.testing.expectEqual(Protocol.GameMode.Adventure, properties.gameMode());
            try scope.set_field(&properties, "gamemode", "spectator");
            try std.testing.expectEqual(Protocol.GameMode.Spectator, properties.gameMode());
            try scope.set_field(&properties, "gamemode", "survival");
            try std.testing.expectEqual(Protocol.GameMode.Survival, properties.gameMode());
            try std.testing.expectError(error.InvalidValue, scope.set_field(&properties, "gamemode", "invalid"));
            try std.testing.expectEqual(Protocol.GameMode.Survival, properties.gameMode());
        }

        pub fn case_001() !void {
            const path = "test-gamemode.properties";
            defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();
            try scope.set_field(&properties, "gamemode", "adventure");
            try properties.save(std.testing.io, path);
            var loaded = try ServerProperties.load(std.testing.io, std.testing.allocator, path);
            defer loaded.deinit();
            try std.testing.expectEqual(Protocol.GameMode.Adventure, loaded.gameMode());
        }

        pub fn case_002() !void {
            const clamp = ServerProperties.clampTransportTickMs;
            try std.testing.expectEqual(@as(u32, 10), clamp(10));
            try std.testing.expectEqual(ServerProperties.min_transport_tick_ms, clamp(0));
            try std.testing.expectEqual(ServerProperties.min_transport_tick_ms, clamp(1));
            try std.testing.expectEqual(ServerProperties.max_transport_tick_ms, clamp(1000));
            try std.testing.expectEqual(ServerProperties.max_transport_tick_ms, clamp(std.math.maxInt(u32)));

            const message = ServerProperties.clampMaxMessageSize;
            try std.testing.expectEqual(@as(u32, 262144), message(262144));
            try std.testing.expectEqual(ServerProperties.min_max_message_size, message(0));
            try std.testing.expectEqual(ServerProperties.max_max_message_size, message(1 << 20));
        }

        pub fn case_003() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();
            try std.testing.expectEqualStrings("immediate", properties.movement_send_priority);

            try scope.set_field(&properties, "movement-send-priority", "normal");
            try std.testing.expectEqualStrings("normal", properties.movement_send_priority);

            try std.testing.expectError(error.UnknownProperty, scope.set_field(&properties, "movement-send_priority", "normal"));
        }

        pub fn case_004() !void {
            const io = std.testing.io;
            const allocator = std.testing.allocator;
            const path = "test-movement-priority.properties";
            defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

            var properties = ServerProperties{ .allocator = allocator };
            defer properties.deinit();
            properties.movement_send_priority = "immediate";
            try properties.save(io, path);

            var content: [8192]u8 = undefined;
            const file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);
            var read_buf: [512]u8 = undefined;
            var reader = file.reader(io, &read_buf);
            const bytes = try reader.interface.readSliceShort(&content);
            try std.testing.expect(std.mem.indexOf(u8, content[0..bytes], "\nmovement-send-priority=immediate\n") != null);

            var loaded = try ServerProperties.load(io, allocator, path);
            defer loaded.deinit();
            try std.testing.expectEqualStrings("immediate", loaded.movement_send_priority);
        }

        pub fn case_005() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();
            try std.testing.expect(properties.movement_distance_bands);

            try scope.set_field(&properties, "movement-distance-bands", "false");
            try std.testing.expect(!properties.movement_distance_bands);

            try scope.set_field(&properties, "movement-distance-bands", "true");
            try std.testing.expect(properties.movement_distance_bands);

            try std.testing.expectError(error.InvalidValue, scope.set_field(&properties, "movement-distance-bands", "maybe"));
        }

        pub fn case_006() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();
            try std.testing.expectEqual(WorkerLayout.split, properties.worker_layout);

            try scope.set_field(&properties, "worker-layout", "shared");
            try std.testing.expectEqual(WorkerLayout.shared, properties.worker_layout);
            try scope.set_field(&properties, "worker-layout", "split");
            try std.testing.expectEqual(WorkerLayout.split, properties.worker_layout);

            try std.testing.expectError(error.InvalidValue, scope.set_field(&properties, "worker-layout", "chunky"));
            try std.testing.expectError(error.UnknownProperty, scope.set_field(&properties, "worker-layouts", "split"));
        }

        pub fn case_007() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();
            try std.testing.expect(properties.network_inbound_ring);
            try std.testing.expectEqual(@as(u32, 512), properties.inbound_ring_slots);
            try std.testing.expectEqual(@as(u32, 1536), properties.inbound_ring_slot_size);

            try scope.set_field(&properties, "network-inbound-ring", "false");
            try std.testing.expect(!properties.network_inbound_ring);
            try scope.set_field(&properties, "network-inbound-ring", "true");
            try std.testing.expect(properties.network_inbound_ring);
            try std.testing.expectError(error.InvalidValue, scope.set_field(&properties, "network-inbound-ring", "maybe"));

            try scope.set_field(&properties, "inbound-ring-slots", "16384");
            try std.testing.expectEqual(@as(u32, 16384), properties.inbound_ring_slots);
            try scope.set_field(&properties, "inbound-ring-slot-size", "2048");
            try std.testing.expectEqual(@as(u32, 2048), properties.inbound_ring_slot_size);

            try std.testing.expectEqual(ServerProperties.min_inbound_ring_slots, ServerProperties.clampInboundRingSlots(0));
            try std.testing.expectEqual(ServerProperties.max_inbound_ring_slots, ServerProperties.clampInboundRingSlots(std.math.maxInt(u32)));
            try std.testing.expectEqual(ServerProperties.min_inbound_ring_slot_size, ServerProperties.clampInboundRingSlotSize(1));
            try std.testing.expectEqual(ServerProperties.max_inbound_ring_slot_size, ServerProperties.clampInboundRingSlotSize(std.math.maxInt(u32)));
        }

        pub fn case_008() !void {
            const clamp = ServerProperties.clampMobBroadcastInterval;
            try std.testing.expectEqual(@as(u8, 1), clamp(0));
            try std.testing.expectEqual(@as(u8, 1), clamp(1));
            try std.testing.expectEqual(@as(u8, 2), clamp(2));
            try std.testing.expectEqual(@as(u8, 20), clamp(20));
            try std.testing.expectEqual(@as(u8, 20), clamp(std.math.maxInt(u8)));

            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();
            try std.testing.expectEqual(@as(u8, 2), properties.mob_broadcast_interval);
            try scope.set_field(&properties, "mob-broadcast-interval", "4");
            try std.testing.expectEqual(@as(u8, 4), properties.mob_broadcast_interval);
            try std.testing.expectError(error.InvalidValue, scope.set_field(&properties, "mob-broadcast-interval", "fast"));
        }

        pub fn case_009() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();
            try std.testing.expectEqual(@as(u32, 0), properties.max_sessions);
            try std.testing.expectEqual(@as(u32, 152), properties.effectiveMaxSessions());

            properties.max_players = 300;
            try std.testing.expectEqual(@as(u32, 332), properties.effectiveMaxSessions());

            properties.max_players = 4096;
            try std.testing.expectEqual(ServerProperties.max_max_sessions, properties.effectiveMaxSessions());
        }

        pub fn case_010() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();

            try scope.set_field(&properties, "max-sessions", "256");
            try std.testing.expectEqual(@as(u32, 256), properties.max_sessions);

            try scope.set_field(&properties, "max-sessions", "0");
            try std.testing.expectEqual(@as(u32, 0), properties.max_sessions);

            try std.testing.expectError(error.InvalidValue, scope.set_field(&properties, "max-sessions", "many"));
            try std.testing.expectError(error.UnknownProperty, scope.set_field(&properties, "sessions", "256"));
        }

        pub fn case_011() !void {
            const io = std.testing.io;
            const allocator = std.testing.allocator;
            const path = "test-max-sessions.properties";
            defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

            var properties = ServerProperties{ .allocator = allocator };
            defer properties.deinit();
            properties.max_sessions = 512;
            try properties.save(io, path);

            var content: [8192]u8 = undefined;
            const file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);
            var read_buf: [512]u8 = undefined;
            var reader = file.reader(io, &read_buf);
            const bytes = try reader.interface.readSliceShort(&content);
            try std.testing.expect(std.mem.indexOf(u8, content[0..bytes], "\nmax-sessions=512\n") != null);

            var loaded = try ServerProperties.load(io, allocator, path);
            defer loaded.deinit();
            try std.testing.expectEqual(@as(u32, 512), loaded.max_sessions);
            try std.testing.expectEqual(@as(u16, 19132), loaded.port);
        }

        pub fn case_012() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();
            try std.testing.expect(!properties.online_mode);

            try scope.set_field(&properties, "online-mode", "true");
            try std.testing.expect(properties.online_mode);

            try scope.set_field(&properties, "online-mode", "false");
            try std.testing.expect(!properties.online_mode);

            try std.testing.expectError(error.InvalidValue, scope.set_field(&properties, "online-mode", "yes"));
            try std.testing.expect(!properties.online_mode);
        }

        pub fn case_013() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();
            try std.testing.expect(!properties.online_mode_offline_fallback);

            try scope.set_field(&properties, "online-mode-offline-fallback", "true");
            try std.testing.expect(properties.online_mode_offline_fallback);

            try scope.set_field(&properties, "online-mode-offline-fallback", "false");
            try std.testing.expect(!properties.online_mode_offline_fallback);

            try std.testing.expectError(error.InvalidValue, scope.set_field(&properties, "online-mode-offline-fallback", "maybe"));
        }

        pub fn case_014() !void {
            const io = std.testing.io;
            const allocator = std.testing.allocator;
            const path = "test-online-mode.properties";
            defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

            var properties = ServerProperties{ .allocator = allocator };
            defer properties.deinit();
            try properties.save(io, path);

            var content: [8192]u8 = undefined;
            const file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);
            var read_buf: [512]u8 = undefined;
            var reader = file.reader(io, &read_buf);
            const bytes = try reader.interface.readSliceShort(&content);
            try std.testing.expect(std.mem.indexOf(u8, content[0..bytes], "\nonline-mode=false\n") != null);

            var loaded = try ServerProperties.load(io, allocator, path);
            defer loaded.deinit();
            try std.testing.expect(!loaded.online_mode);
        }

        pub fn case_015() !void {
            try std.testing.expect(shouldEmitVerboseStartupLogs(.Debug));
            try std.testing.expect(!shouldEmitVerboseStartupLogs(.ReleaseFast));
            try std.testing.expect(!shouldEmitVerboseStartupLogs(.ReleaseSafe));
            try std.testing.expect(!shouldEmitVerboseStartupLogs(.ReleaseSmall));
        }

        pub fn case_016() !void {
            try std.testing.expect(!shouldEmitStartupLogs());
        }

        pub fn case_018() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();

            try std.testing.expectEqualStrings("", properties.signaling_bind);
            try std.testing.expectEqual(scope.TlsMode.off, properties.tls_mode);
            try std.testing.expectEqualStrings(scope.default_jwks_uri, properties.jwks_uri);
            try std.testing.expect(!properties.require_client_identity);
            try std.testing.expect(!properties.clientIdentityRequired());
            try std.testing.expectEqualStrings("", properties.public_candidate);
            try std.testing.expectEqualStrings("", properties.ice_servers);

            try scope.set_field(&properties, "signaling-bind", "127.0.0.1");
            try std.testing.expectEqualStrings("127.0.0.1", properties.signaling_bind);

            try scope.set_field(&properties, "tls-mode", "proxy");
            try std.testing.expectEqual(scope.TlsMode.proxy, properties.tls_mode);
            try std.testing.expectError(error.InvalidValue, scope.set_field(&properties, "tls-mode", "terminate"));

            try scope.set_field(&properties, "require-client-identity", "true");
            try std.testing.expect(properties.clientIdentityRequired());

            properties.online_mode = true;
            properties.require_client_identity = false;
            try std.testing.expect(properties.clientIdentityRequired());
        }

        pub fn case_019() !void {
            const io = std.testing.io;
            const allocator = std.testing.allocator;
            const path = "test-legacy.properties";
            defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

            const legacy =
                "port=19133\n" ++
                "transport=raknet\n" ++
                "max-mtu=1400\n" ++
                "output-slab-slots=512\n" ++
                "transient-slab-slots=128\n" ++
                "outbox-slots=512\n" ++
                "max-players=42\n";
            const file = try std.Io.Dir.cwd().createFile(io, path, .{});
            file.writeStreamingAll(io, legacy) catch |err| {
                file.close(io);
                return err;
            };
            file.close(io);

            var loaded = try ServerProperties.load(io, allocator, path);
            defer loaded.deinit();
            try std.testing.expectEqual(@as(u16, 19133), loaded.port);
            try std.testing.expectEqual(@as(u32, 42), loaded.max_players);
            try std.testing.expectEqual(@as(u32, 10), loaded.transport_tick_ms);
            try std.testing.expectEqual(@as(u32, 0), loaded.max_sessions);
        }

        pub fn case_020() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();

            try scope.set_field(&properties, "ice-servers", "stun:stun.example.org:3478");
            try std.testing.expectEqualStrings("stun:stun.example.org:3478", properties.ice_servers);

            try scope.set_field(&properties, "public-candidate", "203.0.113.7:19132");
            try std.testing.expectEqualStrings("203.0.113.7:19132", properties.public_candidate);

            try scope.set_field(&properties, "jwks-uri", "https://example.org/keys");
            try std.testing.expectEqualStrings("https://example.org/keys", properties.jwks_uri);
        }

        pub fn case_017() !void {
            const clamp = ServerProperties.clampViewDistance;

            try std.testing.expectEqual(@as(i32, 8), clamp(8, 16));
            try std.testing.expectEqual(@as(i32, 16), clamp(16, 16));

            try std.testing.expectEqual(@as(i32, 32), clamp(128, 128));
            try std.testing.expectEqual(@as(i32, 32), clamp(std.math.maxInt(i32), 4096));

            try std.testing.expectEqual(@as(i32, 4), clamp(10, 4));

            try std.testing.expectEqual(ServerProperties.min_view_distance, clamp(0, 16));
            try std.testing.expectEqual(ServerProperties.min_view_distance, clamp(-1, 16));
            try std.testing.expectEqual(ServerProperties.min_view_distance, clamp(std.math.minInt(i32), 16));

            try std.testing.expectEqual(ServerProperties.min_view_distance, clamp(5, 0));

            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();
            try std.testing.expectEqual(@as(i32, 8), properties.effectiveMaxViewDistance());
            properties.max_view_distance = 128;
            try std.testing.expectEqual(@as(i32, 32), properties.effectiveMaxViewDistance());
            properties.max_view_distance = 0;
            try std.testing.expectEqual(ServerProperties.min_view_distance, properties.effectiveMaxViewDistance());
        }
    };
}
