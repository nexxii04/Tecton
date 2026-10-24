const std = @import("std");
const Protocol = @import("protocol");
const BinaryStream = @import("BinaryStream").BinaryStream;

const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const dimension_mod = @import("../world/dimension/dimension.zig");
const EntityType = @import("../entity/entity_type.zig").EntityType;
const EventsRoot = @import("../events/root.zig");
const entity_id = @import("entity_id.zig");
const components = @import("components.zig");
const query = @import("query.zig");
const protocol_bridge = @import("protocol.zig");
const resources_mod = @import("resources.zig");

const EntityId = entity_id.EntityId;
const Resources = resources_mod.Resources;
const Transform = components.Transform;
const Physics = components.Physics;
const ProtocolId = components.ProtocolId;
const TypeRef = components.TypeRef;
const Health = components.Health;
const ActorFlags = components.ActorFlags;
const NetSync = components.NetSync;
const Lifetime = components.Lifetime;

pub const INVULNERABILITY_TICKS: u64 = 10;

pub const DamageCause = @import("../events/types.zig").DamageCause;

pub const DamageRequest = struct {
    target: EntityId,
    amount: f32,
    cause: DamageCause,
    source_runtime: ?i64,
};

pub const Template = struct {
    health: bool,
    physics: bool,
};

pub fn templateOf(entity_type: *const EntityType) Template {
    return .{
        .health = entity_type.hasComponent("minecraft:health"),
        .physics = entity_type.hasComponent("minecraft:movement") or
            entity_type.hasComponent("minecraft:navigation.walk") or
            entity_type.hasComponent("minecraft:navigation.generic"),
    };
}

pub const SpawnOptions = struct {
    rotation: Protocol.Vector2f = Protocol.Vector2f.init(0, 0),
    unique_id: ?i64 = null,
    name_tag: []const u8 = "",
};

pub fn spawnMob(dim: *Dimension, entity_type: *const EntityType, position: Protocol.Vector3f, opts: SpawnOptions) !EntityId {
    const state = try dim.ensureEcs(512);
    const allocator = dim.allocator;
    const template = templateOf(entity_type);

    const id = try state.world.create(.mob);
    errdefer _ = state.world.destroy(id);

    const runtime = protocol_bridge.nextRuntimeId();
    try state.world.add(id, ProtocolId{ .runtime = runtime, .unique = opts.unique_id orelse runtime });
    try state.world.add(id, TypeRef{ .identifier = entity_type.identifier, .network_id = entity_type.network_id });
    try state.world.add(id, Transform{ .position = position, .rotation = opts.rotation });
    if (template.physics) {
        try state.world.add(id, Physics{ .profile = .mob });
    }
    if (template.health) {
        try state.world.add(id, Health{});
    }
    try state.world.add(id, ActorFlags{});
    try state.world.add(id, NetSync{});
    if (opts.name_tag.len > 0) {
        try state.world.add(id, components.NameTag{ .text = opts.name_tag });
    }

    if (opts.unique_id) |unique| {
        protocol_bridge.reserveUniqueId(unique);
        try state.unique_ids.put(allocator, unique, {});
    }

    try state.runtime_index.publish(allocator, runtime, id);
    try state.chunk_index.add(id, chunkHashOf(position));
    state.sync.queueAdd(allocator, &state.world, id);

    const tecton = dim.world.tecton;
    if (tecton.events.hasListeners(.EntitySpawn)) {
        var event = EventsRoot.types.EntitySpawnEvent{ .id = id, .runtime_id = runtime };
        _ = tecton.events.emit(.EntitySpawn, &event);
    }
    return id;
}

fn chunkHashOf(position: Protocol.Vector3f) i64 {
    const cx = @as(i32, @intFromFloat(@floor(position.x))) >> 4;
    const cz = @as(i32, @intFromFloat(@floor(position.z))) >> 4;
    return dimension_mod.chunkHash(cx, cz);
}

pub fn damage(res: *Resources, target: EntityId, amount: f32, cause: DamageCause, source_runtime: ?i64) void {
    res.ecs.damage_queue.append(res.allocator, .{
        .target = target,
        .amount = amount,
        .cause = cause,
        .source_runtime = source_runtime,
    }) catch {
        res.ecs.damage_overflow += 1;
    };
}

pub fn applyDamage(current: f32, amount: f32) f32 {
    const next = current - amount;
    return if (next < 0) 0 else next;
}

pub fn isDead(current: f32) bool {
    return current <= 0;
}

fn queueHurtAnimation(res: *Resources, runtime: i64) void {
    res.ecs.sync.queueViewerPacket(res.allocator, runtime, runtime, struct {
        fn build(runtime_id: i64, stream: *BinaryStream) anyerror!void {
            const packet = Protocol.ActorEventPacket{
                .runtime_entity_id = @bitCast(runtime_id),
                .event = .HurtAnimation,
                .data = 0,
            };
            _ = try packet.serialize(stream);
        }
    }.build);
}

fn queueDeathAnimation(res: *Resources, runtime: i64) void {
    res.ecs.sync.queueViewerPacket(res.allocator, runtime, runtime, struct {
        fn build(runtime_id: i64, stream: *BinaryStream) anyerror!void {
            const packet = Protocol.ActorEventPacket{
                .runtime_entity_id = @bitCast(runtime_id),
                .event = .DeathAnimation,
                .data = 0,
            };
            _ = try packet.serialize(stream);
        }
    }.build);
}

pub fn damageSystem(res: *Resources) void {
    for (res.ecs.damage_queue.items) |request| {
        const health = res.ecs.world.get(request.target, Health) orelse continue;
        if (health.dead) continue;
        if (res.tick < health.invulnerable_until) continue;

        var amount = request.amount;
        if (res.bus.hasListeners(.EntityDamage)) {
            var event = EventsRoot.types.EntityDamageEvent{
                .target = request.target,
                .target_runtime = runtimeOf(res, request.target),
                .amount = amount,
                .source_runtime = request.source_runtime,
                .cause = request.cause,
            };
            if (!res.bus.emit(.EntityDamage, &event)) continue;
            amount = event.amount;
        }

        health.current = applyDamage(health.current, amount);
        health.invulnerable_until = res.tick + INVULNERABILITY_TICKS;

        if (res.ecs.world.get(request.target, ProtocolId)) |proto| {
            queueHurtAnimation(res, proto.runtime);
        }

        if (isDead(health.current)) {
            health.dead = true;
        }
    }
    res.ecs.damage_queue.clearRetainingCapacity();
}

fn runtimeOf(res: *Resources, id: EntityId) i64 {
    const proto = res.ecs.world.get(id, ProtocolId) orelse return 0;
    return proto.runtime;
}

pub fn deathSystem(res: *Resources) void {
    const Ctx = struct { res: *Resources };
    var ctx = Ctx{ .res = res };
    query.eachKind(&res.ecs.world, .mob, .{ Health, Transform, ProtocolId }, &ctx, struct {
        fn call(c: *Ctx, id: EntityId, health: *Health, transform: *Transform, proto: *ProtocolId) void {
            if (!health.dead) return;

            if (c.res.bus.hasListeners(.EntityDeath)) {
                var event = EventsRoot.types.EntityDeathEvent{
                    .id = id,
                    .runtime_id = proto.runtime,
                    .position = transform.position,
                };
                _ = c.res.bus.emit(.EntityDeath, &event);
            }
            queueDeathAnimation(c.res, proto.runtime);
            c.res.ecs.commands.despawn(c.res.allocator, id, .death) catch {};
        }
    }.call);
}

test "template derivation follows vanilla components" {
    const with_health = EntityType.init("minecraft:zombie", 32, &.{ "minecraft:health", "minecraft:movement" }, &.{});
    try std.testing.expect(templateOf(&with_health).health);
    try std.testing.expect(templateOf(&with_health).physics);

    const passive = EntityType.init("minecraft:armor_stand", 84, &.{"minecraft:health"}, &.{});
    try std.testing.expect(templateOf(&passive).health);
    try std.testing.expect(!templateOf(&passive).physics);

    const inert = EntityType.init("minecraft:xp_orb", 64, &.{}, &.{});
    try std.testing.expect(!templateOf(&inert).health);
    try std.testing.expect(!templateOf(&inert).physics);
}

test "damage applies invulnerability and death runs through the pipeline" {
    const allocator = std.testing.allocator;
    const state = try resources_mod.DimensionEcs.create(allocator, 8);
    defer state.destroy(allocator);

    var bus = EventsRoot.Events.init(allocator);
    defer bus.deinit();

    var res = Resources{
        .allocator = allocator,
        .tecton = undefined,
        .bus = &bus,
        .dimension = undefined,
        .ecs = state,
        .tick = 5,
    };

    const id = try state.world.create(.mob);
    try state.world.add(id, ProtocolId{ .runtime = 700, .unique = 700 });
    try state.world.add(id, TypeRef{ .identifier = "minecraft:zombie", .network_id = 32 });
    try state.world.add(id, Transform{});
    try state.world.add(id, Health{ .current = 10, .max = 10 });

    state.damage_queue.append(allocator, .{ .target = id, .amount = 4, .cause = .entity_attack, .source_runtime = 1 }) catch unreachable;
    damageSystem(&res);
    try std.testing.expectEqual(@as(f32, 6), state.world.get(id, Health).?.current);
    try std.testing.expectEqual(@as(u64, 5 + INVULNERABILITY_TICKS), state.world.get(id, Health).?.invulnerable_until);
    try std.testing.expectEqual(@as(usize, 0), state.damage_queue.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.sync.viewer_packets.items.len);

    state.damage_queue.append(allocator, .{ .target = id, .amount = 4, .cause = .entity_attack, .source_runtime = 1 }) catch unreachable;
    damageSystem(&res);
    try std.testing.expectEqual(@as(f32, 6), state.world.get(id, Health).?.current);

    state.world.get(id, Health).?.invulnerable_until = 0;
    state.damage_queue.append(allocator, .{ .target = id, .amount = 99, .cause = .entity_attack, .source_runtime = 1 }) catch unreachable;
    damageSystem(&res);
    try std.testing.expect(state.world.get(id, Health).?.dead);

    state.sync.reset();
    deathSystem(&res);
    try std.testing.expectEqual(@as(usize, 1), state.commands.despawns.items.len);
    try std.testing.expectEqual(@import("../events/types.zig").DespawnCause.death, state.commands.despawns.items[0].cause);
    state.commands.flush(&state.world);
    try std.testing.expect(!state.world.isAlive(id));
}

test "cancelable entity damage blocks application" {
    const allocator = std.testing.allocator;
    const state = try resources_mod.DimensionEcs.create(allocator, 8);
    defer state.destroy(allocator);

    var bus = EventsRoot.Events.init(allocator);
    defer bus.deinit();
    _ = try bus.subscribe(.EntityDamage, .pre, 0, 1, struct {
        fn call(_: *EventsRoot.EventContext, _: *EventsRoot.types.EntityDamageEvent) EventsRoot.EventResult {
            return .cancel;
        }
    }.call);

    var res = Resources{
        .allocator = allocator,
        .tecton = undefined,
        .bus = &bus,
        .dimension = undefined,
        .ecs = state,
        .tick = 1,
    };

    const id = try state.world.create(.mob);
    try state.world.add(id, Health{ .current = 10, .max = 10 });

    state.damage_queue.append(allocator, .{ .target = id, .amount = 5, .cause = .fire, .source_runtime = null }) catch unreachable;
    damageSystem(&res);
    try std.testing.expectEqual(@as(f32, 10), state.world.get(id, Health).?.current);
}
