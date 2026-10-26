const Helpers = @import("services_test_helpers.zig").Fixture;
const worlds_mod = @import("worlds.zig");
const entity_root = @import("../entity/root.zig");
const items_root = @import("../items/root.zig");
const chest_trait = @import("../world/block/traits/chest.zig");

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

        const Entity = F.Entity;
        const Player = F.Player;
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

        pub fn case_037() !void {
            try block_root.initRegistries(allocator);
            defer block_root.deinitRegistries();
            try chest_trait.ChestTrait.register();
            _ = try block_root.loadBlockPermutations(allocator);
            entity_root.traits.initEntityTraitRegistry(allocator);
            defer entity_root.traits.deinitEntityTraitRegistry();
            try entity_root.traits.HealthTrait.register();
            try items_root.initRegistry(allocator);
            defer items_root.deinitRegistry();
            _ = try items_root.loadItemTypes(allocator);
            _ = try entity_root.EntityTypeRegistry.initRegistry(allocator);
            defer entity_root.EntityTypeRegistry.EntityTypeRegistry.deinit();

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var dir_buf: [512]u8 = undefined;
            const worlds_dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}/worlds", .{&tmp.sub_path});

            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.worlds = WorldRegistry.init(allocator);
            defer tecton.worlds.deinit();
            defer tecton.worlds.deinitOps();
            tecton.ecs = try entity_root.ECS.EcsWorld.init(allocator, 16);
            defer tecton.ecs.deinit();
            tecton.paths = .{ .worlds = worlds_dir };

            const uuid = "00000000-0000-0000-0000-0000000000ab";
            const zombie_type = entity_root.EntityTypeRegistry.EntityTypeRegistry.get("minecraft:zombie").?;
            const dirt_type = items_root.ItemType.get("minecraft:dirt").?;
            const player_type = entity_root.EntityType.init("minecraft:player", 20, &.{}, &.{});
            const mob_position = Protocol.Vector3f.init(1.5, 5.0, 2.5);
            const chest_position = Protocol.BlockPosition{ .x = 1, .y = 5, .z = 1 };
            var stored_unique_id: i64 = 0;

            {
                const world = try worlds_mod.build(host(&tecton), worlds_dir, "restart");
                defer tecton.worlds.destroy(world);
                const dim = world.getDimension("overworld").?;

                const chest = try block_root.BlockPermutation.resolve(allocator, "minecraft:chest", null);
                try dim.setPermutation(chest_position, chest, 0);
                try block_root.applyTraitsForBlock(allocator, dim, chest_position);
                const chest_state = dim.getBlockPtr(chest_position).?.getTraitState(chest_trait.ChestTrait).?;
                chest_state.container.?.base.setItem(3, items_root.ItemStack.init(allocator, dirt_type, .{ .stack_size = 9 }));

                const mob = try allocator.create(Entity);
                mob.* = Entity.init(allocator, zombie_type, dim);
                mob.position = mob_position;
                try mob.addTrait(try entity_root.traits.HealthTrait.create(allocator, .{ .current = 7.5, .max = 20.0 }));
                stored_unique_id = mob.unique_id;
                try dim.entities.put(mob.runtime_id, mob);
                dim.entity_index.add(mob);

                var player: Player = undefined;
                player.uuid = uuid;
                player.entity = Entity.init(allocator, &player_type, null);
                defer player.entity.deinit();
                try player.entity.addTrait(try entity_root.traits.InventoryTrait.create(allocator, .{ .container = undefined, .selected_slot = 0, .opened = false }));
                const inventory = player.entity.getTraitState(entity_root.traits.InventoryTrait).?;
                inventory.selected_slot = 5;
                inventory.container.base.setItem(5, items_root.ItemStack.init(allocator, dirt_type, .{ .stack_size = 12 }));
                try world.provider.writePlayer(uuid, &player);

                world.save();
                try testing.expectEqual(@as(usize, 1), dim.entities.count());
            }

            {
                const world = try worlds_mod.build(host(&tecton), worlds_dir, "restart");
                defer tecton.worlds.destroy(world);
                const dim = world.getDimension("overworld").?;

                const ecs_query = @import("../ecs/query.zig");
                const ecs_components = @import("../ecs/components.zig");
                const ecs_entity_id = @import("../ecs/entity_id.zig");
                const ecs_state = dim.ecs.?;
                try testing.expectEqual(@as(usize, 1), ecs_state.world.count);

                var loaded_id: ?ecs_entity_id.EntityId = null;
                const Finder = struct { unique: i64, found: *?ecs_entity_id.EntityId };
                var finder = Finder{ .unique = stored_unique_id, .found = &loaded_id };
                ecs_query.eachKind(&ecs_state.world, .mob, .{ecs_components.ProtocolId}, &finder, struct {
                    fn call(c: *Finder, id: ecs_entity_id.EntityId, proto: *ecs_components.ProtocolId) void {
                        if (proto.unique == c.unique) c.found.* = id;
                    }
                }.call);
                const loaded_mob = loaded_id orelse return error.TestUnexpectedResult;

                const transform = ecs_state.world.get(loaded_mob, ecs_components.Transform).?;
                try testing.expectEqual(mob_position.x, transform.position.x);
                try testing.expectEqual(@as(f32, 7.5), ecs_state.world.get(loaded_mob, ecs_components.Health).?.current);

                try testing.expectEqualStrings("minecraft:chest", (try dim.getPermutation(chest_position, 0)).identifier);
                const chest_state = dim.getBlockPtr(chest_position).?.getTraitState(chest_trait.ChestTrait).?;
                const stored_item = chest_state.container.?.base.getItem(3).?;
                try testing.expectEqualStrings("minecraft:dirt", stored_item.item_type.identifier);
                try testing.expectEqual(@as(u16, 9), stored_item.stack_size);

                var loaded_player: Player = undefined;
                loaded_player.entity = Entity.init(allocator, &player_type, null);
                defer loaded_player.entity.deinit();
                try loaded_player.entity.addTrait(try entity_root.traits.InventoryTrait.create(allocator, .{ .container = undefined, .selected_slot = 0, .opened = false }));
                try testing.expect(try world.provider.readPlayer(uuid, &loaded_player));
                const inventory = loaded_player.entity.getTraitState(entity_root.traits.InventoryTrait).?;
                try testing.expectEqual(@as(u8, 5), inventory.selected_slot);
                const carried = inventory.container.base.getItem(5).?;
                try testing.expectEqualStrings("minecraft:dirt", carried.item_type.identifier);
                try testing.expectEqual(@as(u16, 12), carried.stack_size);
            }
        }
    };
}
