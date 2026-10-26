const ecs_query = @import("../../ecs/query.zig");
const ecs_components = @import("../../ecs/components.zig");
const ecs_fire = @import("../../ecs/fire.zig");

pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const testing = scope.testing;
        const Protocol = scope.Protocol;
        const EntityTypeRegistry = scope.EntityTypeRegistry;
        const Entity = scope.Entity;
        const EntityTraits = scope.EntityTraits;
        const entities = scope.entities;
        const writeChunkEntities = scope.writeChunkEntities;
        const loadChunkEntities = scope.loadChunkEntities;
        const LoadHarness = scope.LoadHarness;
        const putStoredActor = scope.putStoredActor;
        const putStoredActorWithPosition = scope.putStoredActorWithPosition;
        const putStoredDigest = scope.putStoredDigest;

        const EntityId = @import("../../ecs/entity_id.zig").EntityId;

        fn ecsState(dim: anytype) *@import("../../ecs/resources.zig").DimensionEcs {
            return dim.ecs.?;
        }

        fn findByUnique(dim: anytype, unique: i64) ?EntityId {
            const state = ecsState(dim);
            var found: ?EntityId = null;
            const Ctx = struct { state: @TypeOf(state), unique: i64, found: *?EntityId };
            var ctx = Ctx{ .state = state, .unique = unique, .found = &found };
            ecs_query.eachKind(&state.world, .mob, .{ecs_components.ProtocolId}, &ctx, struct {
                fn call(c: *Ctx, id: EntityId, proto: *ecs_components.ProtocolId) void {
                    if (proto.unique == c.unique) c.found.* = id;
                }
            }.call);
            return found;
        }

        fn destroyMob(dim: anytype, id: EntityId) void {
            const state = ecsState(dim);
            const proto = state.world.get(id, ecs_components.ProtocolId).?;
            state.runtime_index.unpublish(proto.runtime);
            _ = state.unique_ids.remove(proto.unique);
            _ = state.chunk_index.remove(id);
            _ = state.world.destroy(id);
        }

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

            const removed = harness.dim.entities.fetchRemove(stored_runtime_id).?.value;
            _ = harness.dim.entity_index.remove(stored_runtime_id);
            removed.deinit();
            allocator.destroy(removed);

            try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);
            const state = ecsState(&harness.dim);
            try testing.expectEqual(@as(usize, 1), state.world.count);

            const loaded = findByUnique(&harness.dim, stored_uid) orelse return error.TestUnexpectedResult;
            const transform = state.world.get(loaded, ecs_components.Transform).?;
            try testing.expectEqual(@as(f32, 2.5), transform.position.x);
            try testing.expectEqual(@as(f32, 64.0), transform.position.y);
            try testing.expectEqual(@as(f32, 2.5), transform.position.z);
            try testing.expect(state.world.get(loaded, ecs_components.Persistent) == null);
            const fire = state.world.get(loaded, ecs_components.Fire).?;
            try testing.expectEqual(@as(i32, 120), fire.ticks);

            destroyMob(&harness.dim, loaded);
            try loadChunkEntities(harness.provider, harness.chunk, &harness.dim);
            try testing.expectEqual(@as(usize, 1), state.world.count);
            const reloaded = findByUnique(&harness.dim, stored_uid) orelse return error.TestUnexpectedResult;

            ecs_fire.fireApply(state, &harness.dim);
            try testing.expectEqual(@as(i32, 119), state.world.get(reloaded, ecs_components.Fire).?.ticks);
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

            const state = ecsState(&harness.dim);
            try testing.expectEqual(@as(usize, 1), state.world.count);
            const loaded = findByUnique(&harness.dim, 9004) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(i32, 55), state.world.get(loaded, ecs_components.Fire).?.ticks);
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
            const state = ecsState(&harness.dim);
            const loaded = findByUnique(&harness.dim, stored_uid) orelse return error.TestUnexpectedResult;
            const health = state.world.get(loaded, ecs_components.Health).?;
            try testing.expectEqual(@as(f32, 7.5), health.current);
            try testing.expectEqual(@as(f32, 20.0), health.max);
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

            const state = ecsState(&harness.dim);
            try testing.expectEqual(@as(usize, 1), state.world.count);
            const loaded = findByUnique(&harness.dim, 9102) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(f32, 7.0), state.world.get(loaded, ecs_components.Health).?.current);
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
            const state = ecsState(&harness.dim);
            try testing.expectEqual(@as(usize, 1), state.world.count);

            const loaded = findByUnique(&harness.dim, 9301) orelse return error.TestUnexpectedResult;
            const transform = state.world.get(loaded, ecs_components.Transform).?;
            try testing.expect(std.math.isFinite(transform.position.x));
            try testing.expect(std.math.isFinite(transform.position.y));
            try testing.expect(std.math.isFinite(transform.position.z));
            try testing.expect(@abs(transform.position.x) < 16 and @abs(transform.position.z) < 16);

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

            const state = ecsState(&harness.dim);
            const loaded = findByUnique(&harness.dim, 9201) orelse return error.TestUnexpectedResult;
            const health = state.world.get(loaded, ecs_components.Health).?;
            try testing.expectEqual(@as(f32, 20.0), health.current);
            try testing.expectEqual(@as(f32, 20.0), health.max);
        }
    };
}
