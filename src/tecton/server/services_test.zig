pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const testing = std.testing;
        const allocator = testing.allocator;

        const Tecton = scope.Tecton;
        const Host = scope.Host;
        const host = scope.host;
        const hostChecked = scope.hostChecked;
        const Player = scope.Player;
        const Entity = scope.Entity;
        const EcsWorld = scope.EcsWorld;
        const NetworkHandler = scope.NetworkHandler;
        const Dimension = scope.Dimension;
        const World = scope.World;
        const Raknet = scope.Raknet;
        const Protocol = scope.Protocol;
        const block_root = scope.block_root;

        const PlayerRegistry = @TypeOf(@as(Tecton, undefined).players);
        const WorldRegistry = @TypeOf(@as(Tecton, undefined).worlds);
        const CommandRegistry = @TypeOf(@as(Tecton, undefined).command_registry);
        const CommandEnum = std.meta.Child(@TypeOf(@as(CommandRegistry, undefined).enums.items));
        const GameInstanceRegistry = @TypeOf(@as(Tecton, undefined).instances);
        const PermissionManager = @TypeOf(@as(Tecton, undefined).permission_manager);
        const PlayerLocations = @TypeOf(@as(Tecton, undefined).player_locations);
        const FloatingTextManager = std.meta.Child(std.meta.Child(@TypeOf(@as(Dimension, undefined).floating_texts)));
        const Events = @TypeOf(@as(Tecton, undefined).events);
        const TaskQueue = @TypeOf(@as(Tecton, undefined).tasks);
        const ThreadedTaskQueue = @TypeOf(@as(Tecton, undefined).threaded_tasks);
        const TickProfiler = @TypeOf(@as(Tecton, undefined).profiler);
        const Interval = @TypeOf(@as(Host, undefined).mob_broadcast_interval);

        fn stubNetwork() NetworkHandler {
            var stub: NetworkHandler = undefined;
            stub.allocator = allocator;
            stub.options = .{ .compression_method = .Zlib, .compression_threshold = 0 };
            return stub;
        }

        fn plainNetwork() NetworkHandler {
            var stub: NetworkHandler = undefined;
            stub.allocator = allocator;
            stub.options = .{ .compression_method = .NotPresent, .compression_threshold = 255 };
            return stub;
        }

        fn baseTecton(tecton: *Tecton, network: *NetworkHandler) void {
            tecton.* = undefined;
            tecton.io = testing.io;
            tecton.allocator = allocator;
            tecton.config = .{ .allocator = allocator };
            tecton.network = network;
            tecton.network_initialized = true;
            tecton.mob_broadcast_interval = 2;
            tecton.fixAddress();
        }

        fn fakePlayer(runtime_id: i64, connection: *Raknet.Connection) Player {
            var player: Player = undefined;
            player.entity.runtime_id = runtime_id;
            player.connection = connection;
            player.pending_removal = .init(false);
            return player;
        }

        fn fakeEntity() Entity {
            var entity: Entity = undefined;
            entity.ecs_id = 0;
            entity.position = std.mem.zeroes(@TypeOf(entity.position));
            entity.rotation = std.mem.zeroes(@TypeOf(entity.rotation));
            entity.motion = std.mem.zeroes(@TypeOf(entity.motion));
            entity.flags = @TypeOf(entity.flags).init();
            return entity;
        }

        fn fakeConnection(storage: *u128) *Raknet.Connection {
            return @ptrCast(storage);
        }

        fn registerAir() !void {
            const air_type = try block_root.BlockType.init(allocator, "minecraft:air");
            try air_type.register();
            const air_perm = try block_root.BlockPermutation.init(allocator, 0, "minecraft:air", block_root.BlockState.init(allocator));
            try air_perm.register();
            try air_type.addPermutation(air_perm);
        }

        fn enumValues(registry: *CommandRegistry, name: []const u8) ?[]const []const u8 {
            for (registry.enums.items) |cmd_enum| {
                if (std.mem.eql(u8, cmd_enum.name, name)) return cmd_enum.values;
            }
            return null;
        }

        pub fn case_000() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.network_initialized = false;
            try std.testing.expectError(error.NetworkNotInitialized, hostChecked(&tecton));

            var second = stubNetwork();
            tecton.network_initialized = true;
            tecton.network = &second;
            const h = host(&tecton);
            try std.testing.expectEqual(@as(*NetworkHandler, &second), h.network);
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&tecton)), h.ctx);
        }

        pub fn case_001() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();
            var conn_storage: u128 align(16) = 0;

            const h = host(&tecton);
            try std.testing.expectEqual(@as(?*Player, null), h.players.byRuntimeId(7));
            var player = fakePlayer(7, fakeConnection(&conn_storage));
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
            var player = fakePlayer(7, fakeConnection(&conn_storage));
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
            var player = fakePlayer(7, fakeConnection(&conn_storage));
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
            var player = fakePlayer(7, fakeConnection(&conn_storage));
            try tecton.players.insert(&player);
            try std.testing.expectEqual(@as(?*Player, &player), h.findPlayerByRuntimeId(7));
        }

        pub fn case_005() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.ecs = try EcsWorld.init(allocator, 16);
            defer tecton.ecs.deinit();

            const h = host(&tecton);
            var entity = fakeEntity();
            try std.testing.expectEqual(@as(u64, 0), entity.ecs_id);
            h.registerEcsEntity(&entity);
            try std.testing.expect(entity.ecs_id != 0);
        }

        pub fn case_006() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.ecs = try EcsWorld.init(allocator, 16);
            defer tecton.ecs.deinit();

            const h = host(&tecton);
            var entity = fakeEntity();
            h.registerEcsEntity(&entity);
            try std.testing.expect(entity.ecs_id != 0);
            h.unregisterEcsEntity(&entity);
            try std.testing.expectEqual(@as(u64, 0), entity.ecs_id);
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
            var player = fakePlayer(7, fakeConnection(&conn_storage));
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
            var player = fakePlayer(7, fakeConnection(&conn_storage));
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
            const conn = fakeConnection(&conn_storage);

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

        pub fn case_015() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();
            tecton.worlds = WorldRegistry.init(allocator);
            defer tecton.worlds.deinit();
            defer tecton.worlds.deinitOps();
            tecton.command_registry = CommandRegistry.init(allocator);
            defer tecton.command_registry.deinit();
            _ = try tecton.command_registry.registerEnum(.{ .name = "WorldName", .values = &.{} });
            _ = try tecton.command_registry.registerEnum(.{ .name = "TransferWorld", .values = &.{} });

            const h = host(&tecton);
            try std.testing.expectEqual(@as(usize, 0), enumValues(&tecton.command_registry, "WorldName").?.len);
            var world = try World.init(h, allocator, "alpha", null);
            defer world.deinit();
            try tecton.worlds.adopt(&world);
            defer _ = tecton.worlds.detach(&world);

            h.refreshWorldCommandEnums();
            const values = enumValues(&tecton.command_registry, "WorldName").?;
            try std.testing.expectEqual(@as(usize, 1), values.len);
            try std.testing.expectEqualStrings("alpha", values[0]);
        }

        pub fn case_016() !void {
            try block_root.initRegistries(allocator);
            defer block_root.deinitRegistries();
            try registerAir();

            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();
            tecton.worlds = WorldRegistry.init(allocator);
            defer tecton.worlds.deinit();
            defer tecton.worlds.deinitOps();
            tecton.command_registry = CommandRegistry.init(allocator);
            defer tecton.command_registry.deinit();
            _ = try tecton.command_registry.registerEnum(.{ .name = "FloatingTextName", .values = &.{} });

            const h = host(&tecton);
            var world = try World.init(h, allocator, "hub", null);
            defer world.deinit();
            var dim = Dimension.init(&world, allocator, "overworld", .Overworld, null);
            defer dim.deinit();
            dim.floating_texts = try FloatingTextManager.create(allocator, &dim);
            _ = try dim.floating_texts.?.add("sign-1", "hello", Protocol.Vector3f.init(0, 64, 0));
            try world.dimensions.put("overworld", &dim);
            defer _ = world.dimensions.remove("overworld");
            try tecton.worlds.adopt(&world);
            defer _ = tecton.worlds.detach(&world);

            h.refreshFloatingTextCommandEnums();
            const values = enumValues(&tecton.command_registry, "FloatingTextName").?;
            try std.testing.expectEqual(@as(usize, 1), values.len);
            try std.testing.expectEqualStrings("sign-1", values[0]);
        }

        pub fn case_017() !void {
            var server: Raknet.Server = undefined;
            server.io = testing.io;
            server.options = .{ .allocator = allocator };
            const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19132);
            var conn_a = Raknet.Connection.init(&server, addr, 1400, 1);
            defer conn_a.deinit();
            var conn_b = Raknet.Connection.init(&server, addr, 1400, 2);
            defer conn_b.deinit();

            var stub = stubNetwork();
            var plain = plainNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();

            const h = host(&tecton);
            h.replyTo(7, "player", .{0} ** 16, "req", true, "hello");
            try std.testing.expectEqual(@as(usize, 0), conn_a.comm_data.output_frame_queue.items.len);

            var player_a = fakePlayer(7, &conn_a);
            var player_b = fakePlayer(8, &conn_b);
            try tecton.players.insert(&player_a);
            try tecton.players.insert(&player_b);
            h.replyTo(7, "player", .{0} ** 16, "req", true, "hello");
            try std.testing.expectEqual(@as(usize, 1), conn_a.comm_data.output_frame_queue.items.len);
            try std.testing.expectEqual(@as(usize, 0), conn_b.comm_data.output_frame_queue.items.len);
            h.replyTo(8, "player", .{0} ** 16, "req", true, "hello");
            try std.testing.expectEqual(@as(usize, 1), conn_b.comm_data.output_frame_queue.items.len);

            var big: [2048]u8 = undefined;
            @memset(&big, 'x');
            const marker = "marker-3210";
            @memcpy(big[0..marker.len], marker);
            tecton.network = &plain;
            h.replyTo(7, "player", .{0} ** 16, "req", true, &big);
            try std.testing.expectEqual(@as(usize, 3), conn_a.comm_data.output_frame_queue.items.len);
            var marker_found = false;
            for (conn_a.comm_data.output_frame_queue.items[1..]) |frame| {
                if (std.mem.indexOf(u8, frame.payload, marker) != null) marker_found = true;
            }
            try std.testing.expect(marker_found);
        }

        pub fn case_018() !void {
            try block_root.initRegistries(allocator);
            defer block_root.deinitRegistries();
            try registerAir();

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.worlds = WorldRegistry.init(allocator);
            defer tecton.worlds.deinit();
            defer tecton.worlds.deinitOps();
            var path_a_buf: [512]u8 = undefined;
            const dir_a = try std.fmt.bufPrint(&path_a_buf, ".zig-cache/tmp/{s}/a", .{&tmp.sub_path});
            var path_b_buf: [512]u8 = undefined;
            const dir_b = try std.fmt.bufPrint(&path_b_buf, ".zig-cache/tmp/{s}/b", .{&tmp.sub_path});
            tecton.paths = .{ .worlds = dir_a };

            const h = host(&tecton);
            tecton.paths.worlds = dir_b;
            const world = try h.worlds.build("w1");
            defer tecton.worlds.destroy(world);
            try std.testing.expectEqualStrings("w1", world.identifier);

            var db_buf: [512]u8 = undefined;
            const db_path = try std.fmt.bufPrint(&db_buf, "{s}/w1/db", .{dir_b});
            var db_dir = try std.Io.Dir.cwd().openDir(testing.io, db_path, .{});
            db_dir.close(testing.io);
            var old_buf: [512]u8 = undefined;
            const old_path = try std.fmt.bufPrint(&old_buf, "{s}/w1/db", .{dir_a});
            try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(testing.io, old_path, .{}));
        }

        pub fn case_019() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.worlds = WorldRegistry.init(allocator);
            defer tecton.worlds.deinit();
            defer tecton.worlds.deinitOps();

            const h = host(&tecton);
            try std.testing.expect(!tecton.worlds.has("beta"));
            var world = try World.init(h, allocator, "beta", null);
            defer world.deinit();
            try h.worlds.adopt(&world);
            defer _ = tecton.worlds.detach(&world);
            try std.testing.expect(tecton.worlds.has("beta"));
        }

        pub fn case_020() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.worlds = WorldRegistry.init(allocator);
            defer tecton.worlds.deinit();
            defer tecton.worlds.deinitOps();

            const h = host(&tecton);
            const world = try allocator.create(World);
            world.* = try World.init(h, allocator, "gamma", null);
            try tecton.worlds.adopt(world);
            try std.testing.expect(tecton.worlds.has("gamma"));
            h.worlds.destroy(world);
            try std.testing.expect(!tecton.worlds.has("gamma"));
        }

        pub fn case_021() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.worlds = WorldRegistry.init(allocator);
            defer tecton.worlds.deinit();
            defer tecton.worlds.deinitOps();

            const h = host(&tecton);
            var name = [_]u8{ 'w', 'o', 'r', 'l', 'd' };
            try std.testing.expect(tecton.worlds.beginOp(&name));
            try std.testing.expect(tecton.worlds.opInFlight(&name));
            h.worlds.endOp("world");
            try std.testing.expect(!tecton.worlds.opInFlight(&name));
        }

        pub fn case_022() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.instances = GameInstanceRegistry.init(allocator);
            defer tecton.instances.deinit();

            const h = host(&tecton);
            var world = try World.init(h, allocator, "arena", null);
            defer world.deinit();
            var dim = Dimension.init(&world, allocator, "overworld", .Overworld, null);
            defer dim.deinit();
            try std.testing.expectError(error.InstanceNotFound, h.instances.assignDimension(7, &dim));
            _ = try tecton.instances.create("arena", &world, &dim);
            try h.instances.assignDimension(7, &dim);
            try std.testing.expect(tecton.instances.instanceOf(7) != null);
        }

        pub fn case_023() !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{&tmp.sub_path});

            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.permission_manager = PermissionManager.init(testing.io, allocator, path, "member");
            defer tecton.permission_manager.deinit();

            const h = host(&tecton);
            try std.testing.expectEqualStrings("member", h.permission_manager.getPlayerGroup("Alice"));
            try tecton.permission_manager.setPlayerGroup("Alice", "operator");
            try std.testing.expectEqualStrings("operator", h.permission_manager.getPlayerGroup("Alice"));
        }

        pub fn case_024() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            var moved = tecton;
            try std.testing.expectError(error.TectonMoved, hostChecked(&moved));
            const h = host(&tecton);
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&tecton)), h.ctx);
            try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&tecton)), h.players.ctx);
        }

        pub fn case_025() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);

            const h = host(&tecton);
            tecton.events = Events.init(allocator);
            defer tecton.events.deinit();
            try std.testing.expectEqual(@as(*Events, &tecton.events), h.events);
            h.events.next_order = 7;
            try std.testing.expectEqual(@as(u64, 7), tecton.events.next_order);
        }

        pub fn case_026() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);

            const h = host(&tecton);
            tecton.ecs = try EcsWorld.init(allocator, 16);
            defer tecton.ecs.deinit();
            var entity = fakeEntity();
            h.registerEcsEntity(&entity);
            try std.testing.expect(entity.ecs_id != 0);
        }

        pub fn case_027() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);

            const h = host(&tecton);
            tecton.tasks = TaskQueue.init(allocator);
            defer tecton.tasks.deinit();
            try std.testing.expectEqual(@as(*TaskQueue, &tecton.tasks), h.tasks);
            try std.testing.expectEqual(@as(usize, 0), h.tasks.tasks.items.len);
        }

        pub fn case_028() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);

            const h = host(&tecton);
            tecton.threaded_tasks = ThreadedTaskQueue.init(testing.io, allocator, 1);
            try std.testing.expectEqual(@as(*ThreadedTaskQueue, &tecton.threaded_tasks), h.threaded_tasks);
            try std.testing.expectEqual(@as(usize, 0), h.threaded_tasks.shards.len);
        }

        pub fn case_029() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);

            const h = host(&tecton);
            tecton.profiler = .{};
            try std.testing.expectEqual(@as(*TickProfiler, &tecton.profiler), h.profiler);
            h.profiler.total_ticks = 5;
            try std.testing.expectEqual(@as(u64, 5), tecton.profiler.total_ticks);
        }

        pub fn case_030() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.mob_broadcast_interval = 5;

            const h = host(&tecton);
            try std.testing.expectEqual(@as(Interval, 5), h.mob_broadcast_interval);
            tecton.mob_broadcast_interval = 9;
            try std.testing.expectEqual(@as(Interval, 5), h.mob_broadcast_interval);
        }
    };
}
