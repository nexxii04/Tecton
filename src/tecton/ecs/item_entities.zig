const std = @import("std");
const Protocol = @import("protocol");
const BinaryStream = @import("BinaryStream").BinaryStream;

const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const dimension_mod = @import("../world/dimension/dimension.zig");
const Player = @import("../player/player.zig").Player;
const InventoryTrait = @import("../entity/traits/inventory.zig").InventoryTrait;
const Container = @import("../container/container.zig").Container;
const ItemStack = @import("../items/item_stack.zig").ItemStack;
const entity_id = @import("entity_id.zig");
const components = @import("components.zig");
const query = @import("query.zig");
const protocol_bridge = @import("protocol.zig");
const resources_mod = @import("resources.zig");
const EventsRoot = @import("../events/root.zig");

const EntityId = entity_id.EntityId;
const Resources = resources_mod.Resources;
const Transform = components.Transform;
const Physics = components.Physics;
const ProtocolId = components.ProtocolId;
const ItemPickup = components.ItemPickup;
const Lifetime = components.Lifetime;

pub const item_identifier = "minecraft:item";
pub const item_network_id: i32 = 64;

pub const DESPAWN_TICKS: u32 = 6000;
pub const MAGNET_DISTANCE: f32 = 2.5;
pub const COLLECT_DISTANCE: f32 = 0.8;
pub const MERGE_DISTANCE: f32 = 3.0;
pub const PLAYER_EYE_HEIGHT: f32 = 1.62;
const MERGE_SPEED: f32 = 0.4;

pub const ItemSpawnSpec = struct {
    stack: ItemStack,
    position: Protocol.Vector3f,
    pickup_delay: u32 = 40,
    velocity: Protocol.Vector3f = Protocol.Vector3f.init(0, 0, 0),
    despawn_ticks: u32 = DESPAWN_TICKS,
};

pub fn spawnItem(dim: *Dimension, spec: ItemSpawnSpec) !EntityId {
    const state = try dim.ensureEcs(512);
    const allocator = dim.allocator;

    const id = state.world.create(.item) catch |err| {
        var owned = spec.stack;
        owned.deinit();
        return err;
    };
    var stack_owned = false;
    errdefer {
        if (!stack_owned) {
            var owned = spec.stack;
            owned.deinit();
        }
        _ = state.world.destroy(id);
    }

    const runtime = protocol_bridge.nextRuntimeId();
    try state.world.add(id, components.ProtocolId{ .runtime = runtime, .unique = runtime });
    try state.world.add(id, components.TypeRef{ .identifier = item_identifier, .network_id = item_network_id });
    try state.world.add(id, components.Transform{ .position = spec.position, .velocity = spec.velocity });
    try state.world.add(id, components.Physics{ .profile = .item });
    try state.world.add(id, components.Lifetime{ .despawn_at = spec.despawn_ticks });
    try state.world.add(id, components.NetSync{});
    try state.world.add(id, components.ItemPickup{ .stack = spec.stack, .pickup_delay = spec.pickup_delay });
    stack_owned = true;

    try state.runtime_index.publish(allocator, runtime, id);
    try state.chunk_index.add(id, chunkHashOf(spec.position));
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

pub fn canMergeGroundedItems(
    existing: *const ItemStack,
    existing_pending_remove: bool,
    existing_grounded: bool,
    incoming: *const ItemStack,
    incoming_grounded: bool,
    dist: f32,
) bool {
    if (existing_pending_remove) return false;
    if (!existing_grounded or !incoming_grounded) return false;
    if (!existing.isStackCompatible(incoming)) return false;
    if (existing.stack_size + incoming.stack_size > existing.item_type.max_stack_size) return false;
    return dist <= MERGE_DISTANCE;
}

pub fn tryStackIntoInventory(container: *Container, stack: *const ItemStack) bool {
    var remaining: u16 = stack.stack_size;

    if (stack.item_type.stackable) {
        for (container.storage, 0..) |*slot, i| {
            if (remaining == 0) break;
            if (slot.*) |*existing| {
                if (existing.isStackCompatible(stack) and
                    existing.stack_size < existing.item_type.max_stack_size)
                {
                    const space = existing.item_type.max_stack_size - existing.stack_size;
                    const to_add = @min(space, remaining);
                    existing.stack_size += to_add;
                    remaining -= to_add;
                    container.updateSlot(@intCast(i));
                }
            }
        }
    }

    while (remaining > 0) {
        const empty_slot = for (container.storage, 0..) |slot, i| {
            if (slot == null) break i;
        } else break;

        const to_place = @min(remaining, stack.item_type.max_stack_size);
        container.storage[empty_slot] = stack.cloneWithCount(container.allocator, to_place) catch break;
        remaining -= to_place;
        container.updateSlot(@intCast(empty_slot));
    }

    return remaining == 0;
}

fn broadcastPickup(res: *Resources, runtime: i64, collector: *Player) void {
    const PickupCtx = struct { item_runtime: i64, taker_runtime: i64 };
    const ctx = PickupCtx{
        .item_runtime = runtime,
        .taker_runtime = collector.entity.runtime_id,
    };
    res.ecs.sync.queueViewerPacket(res.allocator, runtime, ctx, struct {
        fn build(c: PickupCtx, stream: *BinaryStream) anyerror!void {
            const packet = Protocol.TakeItemActorPacket{
                .item_entity_runtime_id = @bitCast(c.item_runtime),
                .taker_entity_runtime_id = @bitCast(c.taker_runtime),
            };
            _ = try packet.serialize(stream);
        }
    }.build);

    var stream = BinaryStream.init(res.allocator, null, null);
    defer stream.deinit();
    const packet = Protocol.TakeItemActorPacket{
        .item_entity_runtime_id = @bitCast(runtime),
        .taker_entity_runtime_id = @bitCast(collector.entity.runtime_id),
    };
    const serialized = packet.serialize(&stream) catch return;
    res.tecton.network.sendPacket(collector.connection, serialized) catch {};
}

pub fn pickupSystem(res: *Resources) void {
    const Ctx = struct { res: *Resources };
    var ctx = Ctx{ .res = res };
    query.eachKind(&res.ecs.world, .item, .{ ItemPickup, Transform, ProtocolId }, &ctx, struct {
        fn call(c: *Ctx, id: EntityId, pickup: *ItemPickup, transform: *Transform, proto: *ProtocolId) void {
            if (pickup.pending_remove) return;
            if (pickup.pickup_delay > 0) {
                pickup.pickup_delay -= 1;
                return;
            }

            const tecton = c.res.tecton;
            if (tecton.getPlayerCount() == 0) return;
            var collector: ?*Player = null;

            for (tecton.getPlayerSnapshots()) |player| {
                if (!player.spawned) continue;
                if (player.entity.dimension != c.res.dimension) continue;
                if (player.gamemode == .Spectator) continue;
                const feet = Protocol.Vector3f.init(
                    player.entity.position.x,
                    player.entity.position.y - PLAYER_EYE_HEIGHT,
                    player.entity.position.z,
                );
                const dist = feet.distance(transform.position);
                if (dist > MAGNET_DISTANCE) continue;

                if (dist <= COLLECT_DISTANCE) {
                    const inv = player.entity.getTraitState(InventoryTrait) orelse continue;
                    if (!tryStackIntoInventory(&inv.container.base, &pickup.stack)) continue;
                    inv.container.sendOwnerContentUpdate();
                    collector = player;
                    break;
                }

                const dir = feet.subtract(transform.position);
                transform.velocity = Protocol.Vector3f.init(
                    dir.x / dist * MERGE_SPEED,
                    dir.y / dist * MERGE_SPEED + 0.06,
                    dir.z / dist * MERGE_SPEED,
                );
                transform.dirty = true;
                break;
            }

            if (collector) |player| {
                broadcastPickup(c.res, proto.runtime, player);
                pickup.pending_remove = true;
                c.res.ecs.commands.despawn(c.res.allocator, id, .expired) catch {};
            }
        }
    }.call);
}

pub fn mergeSystem(res: *Resources) void {
    const Ctx = struct { res: *Resources };
    var ctx = Ctx{ .res = res };
    query.eachKind(&res.ecs.world, .item, .{ ItemPickup, Transform, Physics, ProtocolId }, &ctx, struct {
        fn call(
            c: *Ctx,
            id: EntityId,
            pickup: *ItemPickup,
            transform: *Transform,
            physics: *Physics,
            proto: *ProtocolId,
        ) void {
            _ = proto;
            if (pickup.pending_remove) return;
            if (!physics.on_ground) return;

            const state = c.res.ecs;
            const cx = @as(i32, @intFromFloat(@floor(transform.position.x))) >> 4;
            const cz = @as(i32, @intFromFloat(@floor(transform.position.z))) >> 4;

            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                var dz: i32 = -1;
                while (dz <= 1) : (dz += 1) {
                    for (state.chunk_index.bucket(dimension_mod.chunkHash(cx + dx, cz + dz))) |other_id| {
                        if (@as(u64, @bitCast(other_id)) == @as(u64, @bitCast(id))) continue;
                        const other_pickup = state.world.get(other_id, ItemPickup) orelse continue;
                        const other_transform = state.world.get(other_id, Transform) orelse continue;
                        const other_physics = state.world.get(other_id, Physics) orelse continue;

                        const dist = other_transform.position.distance(transform.position);
                        if (!canMergeGroundedItems(
                            &other_pickup.stack,
                            other_pickup.pending_remove,
                            other_physics.on_ground,
                            &pickup.stack,
                            true,
                            dist,
                        )) continue;

                        other_pickup.stack.stack_size += pickup.stack.stack_size;
                        other_pickup.pickup_delay = @max(other_pickup.pickup_delay, pickup.pickup_delay);
                        if (state.world.get(other_id, Lifetime)) |other_lifetime| {
                            other_lifetime.ticks = @min(other_lifetime.ticks, state.world.get(id, Lifetime).?.ticks);
                        }
                        refreshMerged(c.res, other_id);
                        pickup.pending_remove = true;
                        c.res.ecs.commands.despawn(c.res.allocator, id, .expired) catch {};
                        return;
                    }
                }
            }
        }
    }.call);
}

fn refreshMerged(res: *Resources, id: EntityId) void {
    const RefreshCtx = struct { res: *Resources, id: EntityId };
    const ctx = RefreshCtx{ .res = res, .id = id };
    const runtime = res.ecs.world.get(id, ProtocolId).?.runtime;
    res.ecs.sync.queueViewerPacket(res.allocator, runtime, ctx, struct {
        fn build(c: RefreshCtx, stream: *BinaryStream) anyerror!void {
            _ = protocol_bridge.buildAddItemActor(c.res.allocator, &c.res.ecs.world, c.id, stream) catch {
                return;
            };
        }
    }.build);
}

test "grounded item merge rejects airborne items" {
    const allocator = std.testing.allocator;
    const ItemType = @import("../items/item_type.zig").ItemType;
    const item_type = try ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:ecs_merge_test_stone"),
        5003,
        64,
        true,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    defer item_type.deinit();

    const stone = ItemStack.init(allocator, item_type, .{ .stack_size = 1 });
    defer {
        var owned = stone;
        owned.deinit();
    }
    const other = ItemStack.init(allocator, item_type, .{ .stack_size = 1 });
    defer {
        var owned = other;
        owned.deinit();
    }

    try std.testing.expect(!canMergeGroundedItems(&stone, false, false, &other, true, 0.5));
    try std.testing.expect(!canMergeGroundedItems(&stone, false, true, &other, false, 0.5));
    try std.testing.expect(!canMergeGroundedItems(&stone, true, true, &other, true, 0.5));
    try std.testing.expect(canMergeGroundedItems(&stone, false, true, &other, true, 0.5));
    try std.testing.expect(!canMergeGroundedItems(&stone, false, true, &other, true, 3.5));
}

test "item component installation registers discovery and sync" {
    const allocator = std.testing.allocator;
    const ItemType = @import("../items/item_type.zig").ItemType;
    const item_type = try ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:ecs_spawn_test"),
        5004,
        64,
        true,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    defer item_type.deinit();

    const state = try resources_mod.DimensionEcs.create(allocator, 8);
    defer state.destroy(allocator);

    const id = try spawnInto(state, .{
        .stack = ItemStack.init(allocator, item_type, .{ .stack_size = 5 }),
        .position = Protocol.Vector3f.init(1.5, 64, 2.5),
    });
    try std.testing.expect(state.world.isAlive(id));
    try std.testing.expect(state.world.get(id, ItemPickup) != null);
    try std.testing.expect(state.world.get(id, Physics).?.profile == .item);
    try std.testing.expectEqual(@as(usize, 1), state.chunk_index.count());
    try std.testing.expectEqual(@as(usize, 1), state.sync.adds.items.len);
    const runtime = state.world.get(id, ProtocolId).?.runtime;
    try std.testing.expect(state.runtime_index.resolve(runtime) != null);
    state.sync.reset();
}

fn spawnInto(state: *resources_mod.DimensionEcs, spec: ItemSpawnSpec) !EntityId {
    const id = try state.world.create(.item);
    errdefer _ = state.world.destroy(id);
    const runtime = protocol_bridge.nextRuntimeId();
    try state.world.add(id, components.ProtocolId{ .runtime = runtime, .unique = runtime });
    try state.world.add(id, components.TypeRef{ .identifier = item_identifier, .network_id = item_network_id });
    try state.world.add(id, components.Transform{ .position = spec.position, .velocity = spec.velocity });
    try state.world.add(id, components.Physics{ .profile = .item });
    try state.world.add(id, components.Lifetime{ .despawn_at = spec.despawn_ticks });
    try state.world.add(id, components.NetSync{});
    try state.world.add(id, components.ItemPickup{ .stack = spec.stack, .pickup_delay = spec.pickup_delay });
    try state.runtime_index.publish(std.testing.allocator, runtime, id);
    try state.chunk_index.add(id, chunkHashOf(spec.position));
    state.sync.queueAdd(std.testing.allocator, &state.world, id);
    return id;
}
