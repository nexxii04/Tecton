const Helpers = @import("services_test_helpers.zig").Fixture;

pub fn Suite(comptime scope: type) type {
    return struct {
        const F = Helpers(scope);
        const std = F.std;
        const testing = F.testing;
        const allocator = F.allocator;

        const Tecton = F.Tecton;
        const host = F.host;
        const commandViews = F.commandViews;
        const World = F.World;
        const Dimension = F.Dimension;
        const Protocol = F.Protocol;
        const block_root = F.block_root;

        const PlayerRegistry = F.PlayerRegistry;
        const WorldRegistry = F.WorldRegistry;
        const CommandRegistry = F.CommandRegistry;
        const FloatingTextManager = F.FloatingTextManager;

        const stubNetwork = F.stubNetwork;
        const baseTecton = F.baseTecton;
        const registerAir = F.registerAir;
        const enumValues = F.enumValues;

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

        pub fn case_033() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            const views = commandViews(&tecton);

            tecton.worlds = WorldRegistry.init(allocator);
            defer tecton.worlds.deinit();
            defer tecton.worlds.deinitOps();
            var world = try World.init(host(&tecton), allocator, "later", null);
            defer world.deinit();
            try tecton.worlds.adopt(&world);
            defer tecton.worlds.detach(&world);
            try testing.expect(views.world_info.worlds.get("later").? == &world);
            try testing.expectEqual(@as(usize, 1), views.world_info.worlds.count());
        }

        pub fn case_035() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.worlds = WorldRegistry.init(allocator);
            defer tecton.worlds.deinit();
            defer tecton.worlds.deinitOps();
            const built = commandViews(&tecton).floating_text;

            const Probe = struct {
                calls: usize = 0,

                fn refresh(raw: *anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(raw));
                    self.calls += 1;
                }
            };
            var probe: Probe = .{};
            const View = @TypeOf(built);
            const custom: View = .{
                .worlds = built.worlds,
                .ctx = &probe,
                .refresh_command_enums = Probe.refresh,
            };
            custom.refreshCommandEnums();
            try testing.expectEqual(@as(usize, 1), probe.calls);
            custom.refreshCommandEnums();
            try testing.expectEqual(@as(usize, 2), probe.calls);

            var world = try World.init(host(&tecton), allocator, "later", null);
            defer world.deinit();
            try tecton.worlds.adopt(&world);
            defer tecton.worlds.detach(&world);
            try testing.expect(built.worlds.get("later").? == &world);
            try testing.expect(custom.worlds.get("later").? == &world);
        }

        pub fn case_036() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.paths = .{};
            tecton.worlds = WorldRegistry.init(allocator);
            defer tecton.worlds.deinit();
            defer tecton.worlds.deinitOps();
            const built = commandViews(&tecton).world_admin;

            var world = try World.init(host(&tecton), allocator, "later", null);
            defer world.deinit();
            try tecton.worlds.adopt(&world);
            defer tecton.worlds.detach(&world);
            try testing.expect(built.get("later").? == &world);
            try testing.expect(built.has("later"));
            try testing.expectEqual(@as(usize, 1), built.count());

            var names: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
            defer if (names.capacity > 0) names.deinit(allocator);
            try built.collectWorldNames(allocator, &names);
            try testing.expectEqual(@as(usize, 1), names.items.len);
            try testing.expectEqualStrings("later", names.items[0]);

            const owned = try allocator.dupe(u8, "op-probe");
            try testing.expect(built.beginOp(owned));
            try testing.expect(built.opInFlight("op-probe"));
            built.endOp("op-probe");
            allocator.free(owned);
            try testing.expect(!built.opInFlight("op-probe"));

            built.detach(&world);
            try testing.expect(built.get("later") == null);
            try built.adopt(&world);
            try testing.expect(built.get("later").? == &world);

            try testing.expect(!built.worldDirExists("definitely-missing-world-dir"));
        }
    };
}
