const std = @import("std");

const entity_id = @import("entity_id.zig");
const components = @import("components.zig");
const query = @import("query.zig");
const resources_mod = @import("resources.zig");

const EntityId = entity_id.EntityId;
const Resources = resources_mod.Resources;
const Transform = components.Transform;
const ProtocolId = components.ProtocolId;
const Lifetime = components.Lifetime;
const Persistent = components.Persistent;

pub const DESPAWN_DISTANCE_SQ: f32 = 128.0 * 128.0;
pub const RANDOM_DESPAWN_DISTANCE_SQ: f32 = 32.0 * 32.0;
pub const RANDOM_DESPAWN_MIN_AGE_TICKS: u32 = 600;
pub const RANDOM_DESPAWN_CHANCE: usize = 600;

pub fn despawnSystem(res: *Resources) void {
    const Ctx = struct { res: *Resources };
    var ctx = Ctx{ .res = res };
    query.eachKind(&res.ecs.world, .mob, .{ Transform, ProtocolId, Lifetime }, &ctx, struct {
        fn call(c: *Ctx, id: EntityId, transform: *Transform, _: *ProtocolId, lifetime: *Lifetime) void {
            if (c.res.ecs.world.get(id, Persistent) != null) return;

            var nearest_sq: f32 = std.math.floatMax(f32);
            for (c.res.tecton.getPlayerSnapshots()) |player| {
                if (!player.spawned) continue;
                if (player.entity.dimension != c.res.dimension) continue;
                const dx = player.entity.position.x - transform.position.x;
                const dz = player.entity.position.z - transform.position.z;
                const dist_sq = dx * dx + dz * dz;
                if (dist_sq < nearest_sq) nearest_sq = dist_sq;
            }

            if (nearest_sq > DESPAWN_DISTANCE_SQ) {
                c.res.ecs.commands.despawn(c.res.allocator, id, .expired) catch {};
                return;
            }
            if (nearest_sq > RANDOM_DESPAWN_DISTANCE_SQ and lifetime.ticks > RANDOM_DESPAWN_MIN_AGE_TICKS) {
                if (c.res.ecs.rng.random().uintLessThan(usize, RANDOM_DESPAWN_CHANCE) == 0) {
                    c.res.ecs.commands.despawn(c.res.allocator, id, .expired) catch {};
                }
            }
        }
    }.call);
}
