pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Protocol = scope.Protocol;
        const damageable = scope.damageable;
        const MAX_ATTACK_REACH = scope.MAX_ATTACK_REACH;
        const withinAttackReach = scope.withinAttackReach;
        const playerDropVelocity = scope.playerDropVelocity;
        const FALL_DAMAGE_GRACE = scope.FALL_DAMAGE_GRACE;
        const MAX_TICK_DESCENT = scope.MAX_TICK_DESCENT;
        const fallDamage = scope.fallDamage;
        const trackFall = scope.trackFall;

        pub fn case_000() !void {
            try std.testing.expect(damageable(.Survival));
            try std.testing.expect(damageable(.Adventure));
            try std.testing.expect(!damageable(.Creative));
            try std.testing.expect(!damageable(.Spectator));
            try std.testing.expect(!damageable(.CreativeSpectator));
            try std.testing.expect(!damageable(.SurvivalSpectator));
        }

        pub fn case_001() !void {
            const attacker = Protocol.Vector3f.init(0, 0, 0);

            try std.testing.expect(withinAttackReach(attacker, Protocol.Vector3f.init(0, 0, 0)));
            try std.testing.expect(withinAttackReach(attacker, Protocol.Vector3f.init(2.5, 1, -2)));
            try std.testing.expect(withinAttackReach(attacker, Protocol.Vector3f.init(MAX_ATTACK_REACH, 0, 0)));
            try std.testing.expect(!withinAttackReach(attacker, Protocol.Vector3f.init(MAX_ATTACK_REACH + 0.01, 0, 0)));
            try std.testing.expect(!withinAttackReach(attacker, Protocol.Vector3f.init(0, MAX_ATTACK_REACH + 1, 0)));
            try std.testing.expect(!withinAttackReach(attacker, Protocol.Vector3f.init(500, 64, -500)));
        }

        pub fn case_002() !void {
            const vel = playerDropVelocity(Protocol.Vector2f.init(0, 0));

            try std.testing.expectApproxEqAbs(@as(f32, 0), vel.x, 0.0001);
            try std.testing.expectApproxEqAbs(@as(f32, 0), vel.y, 0.0001);
            try std.testing.expectApproxEqAbs(@as(f32, 0.4), vel.z, 0.0001);
        }

        pub fn case_003() !void {
            try std.testing.expectEqual(@as(f32, 0), fallDamage(0));
            try std.testing.expectEqual(@as(f32, 0), fallDamage(1.5));
            try std.testing.expectEqual(@as(f32, 0), fallDamage(FALL_DAMAGE_GRACE));
            try std.testing.expectEqual(@as(f32, 1), fallDamage(4));
            try std.testing.expectEqual(@as(f32, 7), fallDamage(10));
            try std.testing.expectEqual(@as(f32, 17), fallDamage(20));
            try std.testing.expectEqual(@as(f32, 1), fallDamage(3.5));
            try std.testing.expectEqual(@as(f32, 0), fallDamage(-40));
        }

        pub fn case_004() !void {
            try std.testing.expectEqual(@as(f32, 0), trackFall(0, 64, 68, false));
            try std.testing.expectEqual(@as(f32, 4), trackFall(0, 68, 64, false));
            try std.testing.expectEqual(@as(f32, 6.5), trackFall(4, 64, 61.5, false));
            try std.testing.expectEqual(@as(f32, 4), trackFall(4, 61, 64, false));
            try std.testing.expectEqual(@as(f32, 0), trackFall(9, 64, 64, true));
            try std.testing.expectEqual(@as(f32, 0), trackFall(0, 64, 64, true));

            try std.testing.expectEqual(@as(f32, 12.5), trackFall(12, 64, 63.5, false));
            try std.testing.expectEqual(@as(f32, MAX_TICK_DESCENT), trackFall(0, 64, 64 - MAX_TICK_DESCENT, false));
            try std.testing.expectEqual(@as(f32, 0), trackFall(10, 64, 59.9, false));
            try std.testing.expectEqual(@as(f32, 0), trackFall(12, 200, 64, false));
        }
    };
}
