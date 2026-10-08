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
            const clamp = ServerProperties.clampMaxMtu;
            try std.testing.expectEqual(ServerProperties.max_max_mtu, clamp(ServerProperties.max_max_mtu));
            try std.testing.expectEqual(@as(u16, 1400), clamp(1492));
            try std.testing.expectEqual(ServerProperties.max_max_mtu, clamp(std.math.maxInt(u16)));
            try std.testing.expectEqual(@as(u16, 1028), clamp(1028));
            try std.testing.expectEqual(ServerProperties.min_max_mtu, clamp(ServerProperties.min_max_mtu));
            try std.testing.expectEqual(ServerProperties.min_max_mtu, clamp(0));
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
            try std.testing.expectEqual(@as(u32, 8192), properties.inbound_ring_slots);
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
            try std.testing.expectEqual(ServerProperties.max_max_mtu, properties.max_mtu);
        }

        pub fn case_010() !void {
            var properties = ServerProperties{ .allocator = std.testing.allocator };
            defer properties.deinit();

            try scope.set_field(&properties, "max-mtu", "1028");
            try std.testing.expectEqual(@as(u16, 1028), properties.max_mtu);

            try std.testing.expectError(error.InvalidValue, scope.set_field(&properties, "max-mtu", "big"));
            try std.testing.expectError(error.UnknownProperty, scope.set_field(&properties, "mtu", "1028"));
        }

        pub fn case_011() !void {
            const io = std.testing.io;
            const allocator = std.testing.allocator;
            const path = "test-max-mtu.properties";
            defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

            var properties = ServerProperties{ .allocator = allocator };
            defer properties.deinit();
            properties.max_mtu = 1188;
            try properties.save(io, path);

            var content: [4096]u8 = undefined;
            const file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);
            var read_buf: [512]u8 = undefined;
            var reader = file.reader(io, &read_buf);
            const bytes = try reader.interface.readSliceShort(&content);
            try std.testing.expect(std.mem.indexOf(u8, content[0..bytes], "\nmax-mtu=1188\n") != null);

            var loaded = try ServerProperties.load(io, allocator, path);
            defer loaded.deinit();
            try std.testing.expectEqual(@as(u16, 1188), loaded.max_mtu);
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
    };
}
