const std = @import("std");

const Tecton = @import("../tecton.zig").Tecton;
const Player = @import("../player/player.zig").Player;
const PlayerMath = @import("../player/player.zig");
const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const InventoryTrait = @import("../entity/traits/inventory.zig").InventoryTrait;
const inventory = @import("../entity/traits/inventory.zig");
const EnchantmentEffects = @import("../items/enchantments/effects.zig");
const EventsRoot = @import("../events/root.zig");
const entity_id = @import("entity_id.zig");
const components = @import("components.zig");

const EntityId = entity_id.EntityId;
const Transform = components.Transform;
const ProtocolId = components.ProtocolId;
const TypeRef = components.TypeRef;
const Fire = components.Fire;

pub fn attackEcsTarget(
    tecton: *Tecton,
    player: *Player,
    dimension: *Dimension,
    target_runtime: i64,
) bool {
    const state = dimension.ecs orelse return false;
    const id = state.runtime_index.resolve(target_runtime) orelse return false;
    if (!state.world.isAlive(id)) return false;
    if (id.kind == .player) return false;
    const transform = state.world.get(id, Transform) orelse return false;

    if (!PlayerMath.withinAttackReach(player.entity.position, transform.position)) return true;

    const inv_state = player.entity.getTraitState(InventoryTrait);
    const weapon = if (inv_state) |s| inventory.getHeldItem(s) else null;
    const victim_identifier = if (state.world.get(id, TypeRef)) |t| t.identifier else "";
    const impact = EnchantmentEffects.meleeImpact(weapon, victim_identifier);

    var amount = impact.damage;
    if (tecton.events.hasListeners(.EntityDamage)) {
        var event = EventsRoot.types.EntityDamageEvent{
            .target = id,
            .target_runtime = target_runtime,
            .amount = amount,
            .source_runtime = player.entity.runtime_id,
            .cause = .entity_attack,
        };
        if (!tecton.events.emit(.EntityDamage, &event)) return true;
        amount = event.amount;
    }

    const dx = transform.position.x - player.entity.position.x;
    const dz = transform.position.z - player.entity.position.z;
    const dist = @sqrt(dx * dx + dz * dz);
    if (dist > 0.001) {
        transform.velocity.x = (dx / dist) * impact.knockback;
        transform.velocity.y = 0.3;
        transform.velocity.z = (dz / dist) * impact.knockback;
        transform.dirty = true;
    }

    const burn_ticks = EnchantmentEffects.fireAspectDurationTicks(weapon);
    if (burn_ticks > 0) {
        const fire = state.world.get(id, Fire) orelse blk: {
            state.world.add(id, Fire{}) catch break :blk null;
            break :blk state.world.get(id, Fire);
        };
        if (fire) |burning| {
            burning.ticks = @max(burning.ticks, burn_ticks);
        }
    }

    if (inv_state) |s| {
        if (s.container.base.getItemMut(s.selected_slot)) |held| {
            var wear_entropy: std.Random.IoSource = .{ .io = tecton.io };
            if (EnchantmentEffects.wearTool(held, 1, wear_entropy.interface()) > 0) {
                s.container.updateSlot(s.selected_slot);
            }
        }
    }

    state.damage_queue.append(dimension.allocator, .{
        .target = id,
        .amount = amount,
        .cause = .entity_attack,
        .source_runtime = player.entity.runtime_id,
    }) catch {
        state.damage_overflow += 1;
    };
    return true;
}
