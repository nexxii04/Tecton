const Helpers = @import("services_test_helpers.zig").Fixture;

pub fn Suite(comptime scope: type) type {
    return struct {
        const F = Helpers(scope);
        const std = F.std;
        const testing = F.testing;
        const allocator = F.allocator;

        const Tecton = F.Tecton;
        const host = F.host;
        const hostChecked = F.hostChecked;
        const commandViews = F.commandViews;
        const NetworkHandler = F.NetworkHandler;
        const Dimension = F.Dimension;
        const World = F.World;
        const EcsWorld = F.EcsWorld;

        const PlayerRegistry = F.PlayerRegistry;
        const GameInstanceRegistry = F.GameInstanceRegistry;
        const Events = F.Events;
        const TaskQueue = F.TaskQueue;
        const ThreadedTaskQueue = F.ThreadedTaskQueue;
        const TickProfiler = F.TickProfiler;
        const Interval = F.Interval;

        const stubNetwork = F.stubNetwork;
        const plainNetwork = F.plainNetwork;
        const baseTecton = F.baseTecton;
        const fakePlayer = F.fakePlayer;
        const fakeEntity = F.fakeEntity;

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

        pub fn case_017() !void {
            const TransportFake = @import("../transport/fake_port.zig").TransportFake;
            const ConnectionRegistry = @import("../transport/connection.zig").ConnectionRegistry;
            const events_mod = @import("../transport/events.zig");

            var fake = TransportFake.init(allocator);
            defer fake.deinit();
            fake.payload_limit = 8192;

            var stub = stubNetwork();
            var plain = plainNetwork();
            stub.port = fake.port();
            plain.port = fake.port();

            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.players = PlayerRegistry.init(testing.io, allocator);
            defer tecton.players.deinit();

            var events = events_mod.Queue.init(testing.io, allocator);
            defer events.deinit();
            var registry = ConnectionRegistry.init(allocator, testing.io, &events);
            defer registry.deinit();

            var backend_a: u128 = 0;
            var backend_b: u128 = 0;
            const conn_a = try registry.create(&backend_a);
            const conn_b = try registry.create(&backend_b);

            const h = host(&tecton);
            h.replyTo(7, "player", .{0} ** 16, "req", true, "hello");
            try std.testing.expectEqual(@as(usize, 0), fake.sent.items.len);

            var player_a = fakePlayer(7, conn_a);
            var player_b = fakePlayer(8, conn_b);
            try tecton.players.insert(&player_a);
            try tecton.players.insert(&player_b);

            h.replyTo(7, "player", .{0} ** 16, "req", true, "hello");
            try std.testing.expectEqual(@as(usize, 1), fake.sentTo(conn_a.id));
            try std.testing.expectEqual(@as(usize, 0), fake.sentTo(conn_b.id));

            h.replyTo(8, "player", .{0} ** 16, "req", true, "hello");
            try std.testing.expectEqual(@as(usize, 1), fake.sentTo(conn_b.id));

            var big: [2048]u8 = undefined;
            @memset(&big, 'x');
            const marker = "marker-3210";
            @memcpy(big[0..marker.len], marker);
            tecton.network = &plain;
            h.replyTo(7, "player", .{0} ** 16, "req", true, &big);

            try std.testing.expectEqual(@as(usize, 2), fake.sentTo(conn_a.id));
            const last = fake.sent.items[fake.sent.items.len - 1];
            try std.testing.expectEqual(conn_a.id, last.conn_id);
            try std.testing.expect(std.mem.indexOf(u8, last.bytes, marker) != null);
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

        pub fn case_032() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            const views = commandViews(&tecton);

            tecton.current_tps = 17.5;
            tecton.current_mspt = 2.25;
            tecton.current_raknet_mspt = 0.5;
            tecton.current_game_mspt = 1.75;
            tecton.profiler = .{};
            tecton.profiler.slow_ticks = 3;
            tecton.config.max_tps = 30;
            tecton.config.max_players = 90;

            try testing.expectEqual(@as(f64, 17.5), views.world_info.current_tps.*);
            try testing.expectEqual(@as(f64, 2.25), views.world_info.current_mspt.*);
            try testing.expectEqual(@as(f64, 0.5), views.world_info.current_raknet_mspt.*);
            try testing.expectEqual(@as(f64, 1.75), views.world_info.current_game_mspt.*);
            try testing.expectEqual(@as(u64, 3), views.world_info.profiler.slow_ticks);
            try testing.expectEqual(@as(f64, 30), views.world_info.targetTps());
            try testing.expectEqual(@as(u32, 90), views.about.max_players.*);
            try testing.expect(views.enchantment.events == &tecton.events);
        }
    };
}
