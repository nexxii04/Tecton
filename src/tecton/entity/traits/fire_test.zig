pub fn Suite(comptime scope: type) type {
    return struct {
        const Protocol = scope.Protocol;
        const CompoundTag = scope.CompoundTag;
        const IntTag = scope.IntTag;
        const Entity = scope.Entity;
        const Events = scope.Events;
        const entities = scope.entities;
        const Dimension = scope.Dimension;
        const BlockPermutation = scope.BlockPermutation;
        const FIRE_BLOCK_IGNITION_TICKS = scope.FIRE_BLOCK_IGNITION_TICKS;
        const LAVA_IGNITION_TICKS = scope.LAVA_IGNITION_TICKS;
        const State = scope.State;
        const refreshedFireTicks = scope.refreshedFireTicks;
        const isImmuneToFire = scope.isImmuneToFire;
        const takesFireDamage = scope.takesFireDamage;
        const damageCauseFor = scope.damageCauseFor;
        const isRepeatIgnition = scope.isRepeatIgnition;
        const onSerialize = scope.onSerialize;
        const onDeserialize = scope.onDeserialize;
        const syncOnFireFlag = scope.syncOnFireFlag;
        const contactBurnDuration = scope.contactBurnDuration;
        const hasSkyAccess = scope.hasSkyAccess;
        const testing = scope.testing;
        const EntityType = scope.EntityType;

        pub fn case_000() !void {
            try testing.expectEqual(@as(i32, 80), refreshedFireTicks(0, 80));
            try testing.expectEqual(@as(i32, 80), refreshedFireTicks(80, 40));
            try testing.expectEqual(@as(i32, 80), refreshedFireTicks(80, 80));
            try testing.expectEqual(@as(i32, 160), refreshedFireTicks(80, 160));
            try testing.expectEqual(@as(i32, 0), refreshedFireTicks(0, -5));
        }

        pub fn case_001() !void {
            try testing.expect(isImmuneToFire(.Creative));
            try testing.expect(isImmuneToFire(.Spectator));
            try testing.expect(isImmuneToFire(.CreativeSpectator));
            try testing.expect(isImmuneToFire(.SurvivalSpectator));
            try testing.expect(!isImmuneToFire(.Survival));
            try testing.expect(!isImmuneToFire(.Adventure));
            try testing.expect(!isImmuneToFire(null));
        }

        pub fn case_002() !void {
            var state = State{ .fire_ticks = 200, .burn_source = .lava, .instigator_id = 0 };
            try testing.expect(isRepeatIgnition(&state, .lava, 0));
            try testing.expect(!isRepeatIgnition(&state, .fire_block, 0));
            try testing.expect(!isRepeatIgnition(&state, .lava, 42));

            state.fire_ticks = 0;
            try testing.expect(!isRepeatIgnition(&state, .lava, 0));

            try testing.expectEqual(@as(i32, LAVA_IGNITION_TICKS), refreshedFireTicks(LAVA_IGNITION_TICKS - 1, contactBurnDuration(.lava)));
            try testing.expectEqual(@as(i32, FIRE_BLOCK_IGNITION_TICKS), refreshedFireTicks(FIRE_BLOCK_IGNITION_TICKS - 1, contactBurnDuration(.fire_block)));
        }

        pub fn case_003() !void {
            var state = State{};
            try testing.expect(takesFireDamage(&state));

            state.fire_resistant = true;
            try testing.expect(!takesFireDamage(&state));
        }

        pub fn case_004() !void {
            try testing.expectEqual(Events.DamageCause.lava, damageCauseFor(.lava));
            try testing.expectEqual(Events.DamageCause.fire, damageCauseFor(.fire_block));
            try testing.expectEqual(Events.DamageCause.fire_tick, damageCauseFor(.fire_aspect));
            try testing.expectEqual(Events.DamageCause.fire_tick, damageCauseFor(.command));
            try testing.expectEqual(Events.DamageCause.fire_tick, damageCauseFor(.projectile));
        }

        pub fn case_005() !void {
            const allocator = testing.allocator;

            var tag = CompoundTag.init(allocator, null);
            defer tag.deinit(allocator);

            var burning = State{ .fire_ticks = 120, .damage_timer = 7, .burn_source = .lava, .instigator_id = 42 };
            onSerialize(&burning, &tag);

            var restored = State{};
            onDeserialize(&restored, &tag);
            try testing.expectEqual(@as(i32, 120), restored.fire_ticks);
            try testing.expectEqual(@as(i32, 7), restored.damage_timer);
            try testing.expectEqual(Events.CombustSource.lava, restored.burn_source);
            try testing.expectEqual(@as(i64, 0), restored.instigator_id);
        }

        pub fn case_006() !void {
            const allocator = testing.allocator;

            var tag = CompoundTag.init(allocator, null);
            defer tag.deinit(allocator);

            var cold = State{};
            onSerialize(&cold, &tag);
            try testing.expect(tag.get("FireTicks") == null);

            var restored = State{ .fire_ticks = 120, .damage_timer = 7, .burn_source = .lava };
            onDeserialize(&restored, &tag);
            try testing.expectEqual(@as(i32, 120), restored.fire_ticks);
        }

        pub fn case_007() !void {
            const allocator = testing.allocator;

            var tag = CompoundTag.init(allocator, null);
            defer tag.deinit(allocator);

            try tag.set("FireTicks", .{ .Int = IntTag.init(99, null) });
            try tag.set("FireBurnSource", .{ .Int = IntTag.init(99, null) });

            var restored = State{};
            onDeserialize(&restored, &tag);
            try testing.expectEqual(@as(i32, 99), restored.fire_ticks);
            try testing.expectEqual(Events.CombustSource.fire_block, restored.burn_source);
        }

        pub fn case_008() !void {
            const allocator = testing.allocator;

            const mob_type = EntityType.init("minecraft:zombie", 1, &.{}, &.{});
            var entity = Entity.init(allocator, &mob_type, null);
            defer entity.deinit();

            var state = State{ .fire_ticks = 100 };
            syncOnFireFlag(&state, &entity);
            try testing.expect(entity.flags.getFlag(.OnFire));

            syncOnFireFlag(&state, &entity);
            try testing.expect(entity.flags.getFlag(.OnFire));

            state.fire_ticks = 0;
            syncOnFireFlag(&state, &entity);
            try testing.expect(!entity.flags.getFlag(.OnFire));
        }

        pub fn case_009() !void {
            const allocator = testing.allocator;
            const ChunkImpl = scope.test_dependency_0.Chunk;
            const chunkHash = scope.test_dependency_1.chunkHash;
            const BlockState = scope.test_dependency_2.BlockState;
            const BlockType = scope.test_dependency_3.BlockType;

            try BlockPermutation.initRegistry(allocator);
            defer BlockPermutation.deinitRegistry();
            try BlockType.initRegistry(allocator);
            defer BlockType.deinitRegistry();

            const air_type = try BlockType.init(allocator, "minecraft:air");
            try air_type.register();
            const air = try BlockPermutation.init(allocator, 0, "minecraft:air", BlockState.init(allocator));
            try air.register();
            try air_type.addPermutation(air);

            const stone_type = try BlockType.init(allocator, "minecraft:stone");
            try stone_type.register();
            const stone = try BlockPermutation.init(allocator, 1, "minecraft:stone", BlockState.init(allocator));
            try stone.register();
            try stone_type.addPermutation(stone);

            const mob_type = EntityType.init("minecraft:zombie", 1, &.{}, &.{});
            var entity = Entity.init(allocator, &mob_type, null);
            defer entity.deinit();
            entity.position = Protocol.Vector3f.init(4.5, 64.0, 4.5);

            var dimension = Dimension.init(undefined, allocator, "overworld", .Overworld, null);
            const chunk = try allocator.create(ChunkImpl);
            chunk.* = ChunkImpl.init(allocator, 0, 0, .Overworld);
            try dimension.chunks.put(chunkHash(0, 0), chunk);
            defer dimension.deinit();

            try testing.expect(hasSkyAccess(&dimension, &entity));

            try chunk.setPermutation(0, 200, 0, stone, 0);
            try testing.expect(hasSkyAccess(&dimension, &entity));

            try chunk.setPermutation(4, 65, 4, stone, 0);
            try testing.expect(hasSkyAccess(&dimension, &entity));

            try chunk.setPermutation(4, 66, 4, stone, 0);
            try testing.expect(!hasSkyAccess(&dimension, &entity));
        }
    };
}
