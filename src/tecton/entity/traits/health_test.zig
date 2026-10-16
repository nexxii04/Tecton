pub fn Suite(comptime scope: type) type {
    return struct {
        const CompoundTag = scope.CompoundTag;
        const FloatTag = scope.FloatTag;
        const Entity = scope.Entity;
        const EntityType = scope.EntityType;
        const MAX_HEALTH = scope.MAX_HEALTH;
        const State = scope.State;
        const isInvulnerable = scope.isInvulnerable;
        const markInvulnerable = scope.markInvulnerable;
        const applyDamage = scope.applyDamage;
        const isDead = scope.isDead;
        const clampLoadedHealth = scope.clampLoadedHealth;
        const onSerialize = scope.onSerialize;
        const onDeserialize = scope.onDeserialize;
        const isPlayer = scope.isPlayer;
        const revive = scope.revive;
        const testing = scope.testing;
        const HealthTrait = scope.HealthTrait;

        pub fn case_000() !void {
            try testing.expectEqual(@as(f32, 15.0), applyDamage(20.0, 5.0));
            try testing.expectEqual(@as(f32, 0.0), applyDamage(3.0, 5.0));
            try testing.expectEqual(@as(f32, 0.0), applyDamage(0.0, 5.0));
            try testing.expectEqual(@as(f32, 20.0), applyDamage(20.0, 0.0));
            try testing.expect(!isDead(applyDamage(20.0, 19.9)));
            try testing.expect(isDead(applyDamage(20.0, 20.0)));
        }

        pub fn case_001() !void {
            try testing.expectEqual(@as(f32, 20.0), clampLoadedHealth(20.0, 20.0));
            try testing.expectEqual(@as(f32, 7.5), clampLoadedHealth(7.5, 20.0));
            try testing.expectEqual(@as(f32, 20.0), clampLoadedHealth(0.0, 20.0));
            try testing.expectEqual(@as(f32, 20.0), clampLoadedHealth(-4.0, 20.0));
            try testing.expectEqual(@as(f32, 20.0), clampLoadedHealth(40.0, 20.0));
        }

        pub fn case_002() !void {
            const allocator = testing.allocator;

            var tag = CompoundTag.init(allocator, null);
            defer tag.deinit(allocator);

            var hurt = State{ .current = 7.5, .max = 20.0 };
            onSerialize(&hurt, &tag);

            var restored = State{ .current = 20.0, .max = 20.0 };
            onDeserialize(&restored, &tag);
            try testing.expectEqual(@as(f32, 7.5), restored.current);
            try testing.expectEqual(@as(f32, 20.0), restored.max);

            var boosted_tag = CompoundTag.init(allocator, null);
            defer boosted_tag.deinit(allocator);

            var boosted = State{ .current = 24.0, .max = 30.0 };
            onSerialize(&boosted, &boosted_tag);

            var boosted_restored = State{ .current = 20.0, .max = 20.0 };
            onDeserialize(&boosted_restored, &boosted_tag);
            try testing.expectEqual(@as(f32, 24.0), boosted_restored.current);
            try testing.expectEqual(@as(f32, 30.0), boosted_restored.max);
        }

        pub fn case_003() !void {
            const allocator = testing.allocator;

            var tag = CompoundTag.init(allocator, null);
            defer tag.deinit(allocator);

            var state = State{ .current = 7.5, .max = 20.0 };
            onSerialize(&state, &tag);
            onSerialize(&state, &tag);

            try testing.expectEqual(@as(usize, 2), tag.count());
            try testing.expectEqual(@as(f32, 7.5), tag.get("Health").?.Float.value);
        }

        pub fn case_004() !void {
            const allocator = testing.allocator;

            var tag = CompoundTag.init(allocator, null);
            defer tag.deinit(allocator);

            var restored = State{ .current = 20.0, .max = 20.0 };
            onDeserialize(&restored, &tag);
            try testing.expectEqual(@as(f32, 20.0), restored.current);
            try testing.expectEqual(@as(f32, 20.0), restored.max);
        }

        pub fn case_005() !void {
            const allocator = testing.allocator;

            var tag = CompoundTag.init(allocator, null);
            defer tag.deinit(allocator);
            try tag.set("Health", .{ .Float = FloatTag.init(0.0, null) });
            try tag.set("MaxHealth", .{ .Float = FloatTag.init(20.0, null) });

            var restored = State{ .current = 20.0, .max = 20.0 };
            onDeserialize(&restored, &tag);
            try testing.expectEqual(@as(f32, 0.0), restored.current);
            try testing.expect(isDead(restored.current));
        }

        pub fn case_006() !void {
            const allocator = testing.allocator;

            const mob_type = EntityType.init("minecraft:zombie", 1, &.{}, &.{});
            const player_type = EntityType.init("minecraft:player", 1, &.{}, &.{});

            var mob = Entity.init(allocator, &mob_type, null);
            defer mob.deinit();
            var player = Entity.init(allocator, &player_type, null);
            defer player.deinit();

            try testing.expect(!isPlayer(&mob));
            try testing.expect(isPlayer(&player));
        }

        pub fn case_007() !void {
            const allocator = testing.allocator;

            const entity_type = EntityType.init("minecraft:zombie", 1, &.{}, &.{});
            var entity = Entity.init(allocator, &entity_type, null);
            defer entity.deinit();

            const trait = try HealthTrait.create(allocator, .{ .current = MAX_HEALTH, .max = MAX_HEALTH });
            try entity.addTrait(trait);

            const state = entity.getTraitState(HealthTrait).?;
            try testing.expectEqual(MAX_HEALTH, state.current);
            try testing.expect(!state.dead);
            try testing.expectEqual(MAX_HEALTH, entity.attributes.get(.Health).?.current);

            entity.fireEvent(.Damage, .{ &entity, 6.0 });
            try testing.expectEqual(@as(f32, 14.0), state.current);
            try testing.expectEqual(@as(f32, 14.0), entity.attributes.get(.Health).?.current);

            entity.fireEvent(.Damage, .{ &entity, 20.0 });
            try testing.expectEqual(@as(f32, 0.0), state.current);
            try testing.expect(isDead(state.current));

            entity.fireEvent(.Damage, .{ &entity, 5.0 });
            try testing.expectEqual(@as(f32, 0.0), state.current);

            try testing.expect(!revive(state, &entity));
        }

        pub fn case_008() !void {
            var state = State{ .current = MAX_HEALTH, .max = MAX_HEALTH };
            try testing.expect(!isInvulnerable(&state, 100));

            markInvulnerable(&state, 100);
            try testing.expect(isInvulnerable(&state, 100));
            try testing.expect(isInvulnerable(&state, 109));
            try testing.expect(!isInvulnerable(&state, 110));
            try testing.expectEqual(@as(u64, 110), state.invulnerable_until);

            markInvulnerable(&state, 110);
            try testing.expect(isInvulnerable(&state, 119));
            try testing.expect(!isInvulnerable(&state, 120));
        }

        pub fn case_009() !void {
            const allocator = testing.allocator;

            const entity_type = EntityType.init("minecraft:player", 1, &.{}, &.{});
            var entity = Entity.init(allocator, &entity_type, null);
            defer entity.deinit();

            const trait = try HealthTrait.create(allocator, .{ .current = MAX_HEALTH, .max = MAX_HEALTH });
            try entity.addTrait(trait);

            const state = entity.getTraitState(HealthTrait).?;

            entity.fireEvent(.Damage, .{ &entity, 20.0 });
            try testing.expectEqual(@as(f32, 0.0), state.current);

            state.dead = true;
            entity.fireEvent(.Damage, .{ &entity, 4.0 });
            try testing.expectEqual(@as(f32, 0.0), state.current);

            markInvulnerable(state, 500);
            try testing.expect(revive(state, &entity));
            try testing.expectEqual(MAX_HEALTH, state.current);
            try testing.expectEqual(MAX_HEALTH, entity.attributes.get(.Health).?.current);
            try testing.expect(!isInvulnerable(state, 500));
            try testing.expect(!revive(state, &entity));

            entity.fireEvent(.Damage, .{ &entity, 3.0 });
            try testing.expectEqual(@as(f32, 17.0), state.current);
        }
    };
}
