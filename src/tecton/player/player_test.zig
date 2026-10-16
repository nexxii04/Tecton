pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Protocol = scope.Protocol;
        const damageable = scope.damageable;
        const MAX_ATTACK_REACH = scope.MAX_ATTACK_REACH;
        const withinAttackReach = scope.withinAttackReach;
        const playerDropVelocity = scope.playerDropVelocity;

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
    };
}
