pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const testing = scope.testing;
        const Protocol = scope.Protocol;
        const EntityTypeRegistry = scope.EntityTypeRegistry;
        const Entity = scope.Entity;
        const EntityTraits = scope.EntityTraits;
        const Events = scope.Events;
        const entities = scope.entities;
        const writeChunkEntities = scope.writeChunkEntities;
        const loadChunkEntities = scope.loadChunkEntities;
        const LoadHarness = scope.LoadHarness;
        const putStoredActor = scope.putStoredActor;
        const putStoredActorWithPosition = scope.putStoredActorWithPosition;
        const putStoredDigest = scope.putStoredDigest;
        pub fn case_000() !void {
            const allocator = testing.allocator;
            var harness: LoadHarness = undefined;
            try scope.harness_init(&harness, allocator, "test_chunk_entities_db\x00");
            defer {
                scope.harness_deinit(&harness);
                std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_db") catch {};
            }

            const entity_type = EntityTypeRegistry.EntityTypeRegistry.get("minecraft:zombie").?;
            const mob = try allocator.create(Entity);
            mob.* = Entity.init(allocator, entity_type, &harness.dim);
            mob.position = Protocol.Vector3f.init(2.5, 64.0, 2.5);
            try mob.addTrait(try EntityTraits.FireTrait.create(allocator, .{
                .fire_ticks = 120,
                .damage_timer = 7,
                .burn_source = .lava,
            }));
            const stored_uid = mob.unique_id;
            const stored_runtime_id = mob.runtime_id;
            try harness.dim.entities.put(stored_runtime_id, mob);
            harness.dim.entity_index.add(mob);

            try writeChunkEntities(harness.provider, harness.chunk, &harness.dim);

            try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);
            try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());

            const removed = harness.dim.entities.fetchRemove(stored_runtime_id).?.value;
            _ = harness.dim.entity_index.remove(stored_runtime_id);
            removed.deinit();
            allocator.destroy(removed);

            try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);
            try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());

            var it = harness.dim.entities.valueIterator();
            const loaded = it.next().?.*;
            try testing.expectEqual(stored_uid, loaded.unique_id);
            try testing.expectEqual(@as(f32, 2.5), loaded.position.x);
            try testing.expectEqual(@as(f32, 64.0), loaded.position.y);
            try testing.expectEqual(@as(f32, 2.5), loaded.position.z);
            try testing.expect(loaded.ecs_id != 0);
            try testing.expectEqual(@as(usize, 1), harness.dim.entity_index.count());

            const fire_state = loaded.getTraitState(EntityTraits.FireTrait).?;
            try testing.expectEqual(@as(i32, 120), fire_state.fire_ticks);
            try testing.expectEqual(@as(i32, 7), fire_state.damage_timer);
            try testing.expectEqual(Events.CombustSource.lava, fire_state.burn_source);

            loaded.fireEvent(.Tick, .{loaded});
            try testing.expect(loaded.flags.getFlag(.OnFire));
            try testing.expectEqual(@as(i32, 119), fire_state.fire_ticks);
        }

        pub fn case_001() !void {
            const allocator = testing.allocator;
            var harness: LoadHarness = undefined;
            try scope.harness_init(&harness, allocator, "test_chunk_entities_skip_db\x00");
            defer {
                scope.harness_deinit(&harness);
                std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_skip_db") catch {};
            }

            try putStoredActor(harness.provider, 9001, "minecraft:not_a_real_mob", 0, null);
            try putStoredActor(harness.provider, 9002, "minecraft:item", 0, null);
            try putStoredActor(harness.provider, 9003, "minecraft:player", 0, null);
            try putStoredActor(harness.provider, 9004, "minecraft:zombie", 55, null);
            try putStoredDigest(harness.provider, 0, 0, 0, &.{ 9001, 9002, 9003, 9004 });

            try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);

            try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());
            var it = harness.dim.entities.valueIterator();
            const loaded = it.next().?.*;
            try testing.expectEqual(@as(i64, 9004), loaded.unique_id);
            const fire_state = loaded.getTraitState(EntityTraits.FireTrait).?;
            try testing.expectEqual(@as(i32, 55), fire_state.fire_ticks);
        }

        pub fn case_002() !void {
            const allocator = testing.allocator;
            var harness: LoadHarness = undefined;
            try scope.harness_init(&harness, allocator, "test_chunk_entities_health_db\x00");
            defer {
                scope.harness_deinit(&harness);
                std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_health_db") catch {};
            }

            const entity_type = EntityTypeRegistry.EntityTypeRegistry.get("minecraft:zombie").?;
            const mob = try allocator.create(Entity);
            mob.* = Entity.init(allocator, entity_type, &harness.dim);
            mob.position = Protocol.Vector3f.init(2.5, 64.0, 2.5);
            try mob.addTrait(try EntityTraits.HealthTrait.create(allocator, .{ .current = 7.5, .max = 20.0 }));
            const stored_uid = mob.unique_id;
            const stored_runtime_id = mob.runtime_id;
            try harness.dim.entities.put(stored_runtime_id, mob);
            harness.dim.entity_index.add(mob);

            try writeChunkEntities(harness.provider, harness.chunk, &harness.dim);

            const removed = harness.dim.entities.fetchRemove(stored_runtime_id).?.value;
            _ = harness.dim.entity_index.remove(stored_runtime_id);
            removed.deinit();
            allocator.destroy(removed);

            try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);
            try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());

            var it = harness.dim.entities.valueIterator();
            const loaded = it.next().?.*;
            try testing.expectEqual(stored_uid, loaded.unique_id);
            const health_state = loaded.getTraitState(EntityTraits.HealthTrait).?;
            try testing.expectEqual(@as(f32, 7.5), health_state.current);
            try testing.expectEqual(@as(f32, 20.0), health_state.max);
            try testing.expectEqual(@as(f32, 7.5), loaded.attributes.get(.Health).?.current);
            try testing.expectEqual(@as(f32, 20.0), loaded.attributes.get(.Health).?.max);
        }

        pub fn case_003() !void {
            const allocator = testing.allocator;
            var harness: LoadHarness = undefined;
            try scope.harness_init(&harness, allocator, "test_chunk_entities_dead_db\x00");
            defer {
                scope.harness_deinit(&harness);
                std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_dead_db") catch {};
            }

            try putStoredActor(harness.provider, 9101, "minecraft:zombie", 0, 0.0);
            try putStoredActor(harness.provider, 9102, "minecraft:zombie", 0, 7.0);
            try putStoredDigest(harness.provider, 0, 0, 0, &.{ 9101, 9102 });

            try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);

            try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());
            var it = harness.dim.entities.valueIterator();
            const loaded = it.next().?.*;
            try testing.expectEqual(@as(i64, 9102), loaded.unique_id);
            try testing.expectEqual(@as(f32, 7.0), loaded.getTraitState(EntityTraits.HealthTrait).?.current);
        }

        pub fn case_004() !void {
            const allocator = testing.allocator;
            var harness: LoadHarness = undefined;
            try scope.harness_init(&harness, allocator, "test_chunk_entities_corrupt_db\x00");
            defer {
                scope.harness_deinit(&harness);
                std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_corrupt_db") catch {};
            }

            try putStoredActorWithPosition(harness.provider, 9301, "minecraft:zombie", std.math.inf(f32), std.math.nan(f32), std.math.nan(f32));
            try putStoredDigest(harness.provider, 0, 0, 0, &.{9301});

            try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);
            try testing.expectEqual(@as(usize, 1), harness.dim.entities.count());

            var it = harness.dim.entities.valueIterator();
            const loaded = it.next().?.*;
            try testing.expect(std.math.isFinite(loaded.position.x));
            try testing.expect(std.math.isFinite(loaded.position.y));
            try testing.expect(std.math.isFinite(loaded.position.z));
            try testing.expect(@abs(loaded.position.x) < 16 and @abs(loaded.position.z) < 16);

            try writeChunkEntities(harness.provider, harness.chunk, &harness.dim);
        }

        pub fn case_005() !void {
            const allocator = testing.allocator;
            var harness: LoadHarness = undefined;
            try scope.harness_init(&harness, allocator, "test_chunk_entities_legacy_db\x00");
            defer {
                scope.harness_deinit(&harness);
                std.Io.Dir.cwd().deleteTree(testing.io, "test_chunk_entities_legacy_db") catch {};
            }

            try putStoredActor(harness.provider, 9201, "minecraft:zombie", 0, null);
            try putStoredDigest(harness.provider, 0, 0, 0, &.{9201});

            try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);

            var it = harness.dim.entities.valueIterator();
            const loaded = it.next().?.*;
            try testing.expectEqual(@as(f32, 20.0), loaded.getTraitState(EntityTraits.HealthTrait).?.current);
            try testing.expectEqual(@as(f32, 20.0), loaded.getTraitState(EntityTraits.HealthTrait).?.max);
            try testing.expectEqual(@as(f32, 20.0), loaded.attributes.get(.Health).?.current);
        }
    };
}
