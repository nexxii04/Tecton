const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const Protocol = @import("protocol");
const CompoundTag = NBT.CompoundTag;

const EntityType = @import("../../entity/entity_type.zig").EntityType;
const EntityTypeRegistry = @import("../../entity/entity_type_registry.zig").EntityTypeRegistry;
const Entity = @import("../../entity/entity.zig").Entity;
const Health = @import("../../entity/traits/health.zig");
const ProjectileTrait = @import("../../entity/traits/projectile.zig").ProjectileTrait;
const criticalTrailActive = @import("../../entity/traits/projectile.zig").criticalTrailActive;
const applyGlobalTraits = @import("../../entity/traits/root.zig").applyGlobalTraits;
const ecs_items = @import("../../ecs/item_entities.zig");
const ecs_entity_id = @import("../../ecs/entity_id.zig");
const Bow = @import("../../items/bow.zig");
const ItemStack = @import("../../items/item_stack.zig").ItemStack;
const ItemType = @import("../../items/item_type.zig").ItemType;
const Player = @import("../../player/player.zig").Player;
const Dimension = @import("./dimension.zig").Dimension;
const broadcast = @import("./broadcast.zig");
const serialization = @import("../provider/serialization.zig");

pub fn spawnEntity(dim: *Dimension, entity_type: *const EntityType, position: Protocol.Vector3f) !*Entity {
    return spawnEntityWithOptions(dim, entity_type, position, "", false);
}

pub fn spawnEntityWithOptions(dim: *Dimension, entity_type: *const EntityType, position: Protocol.Vector3f, name_tag: []const u8, nametag_always_visible: bool) !*Entity {
    return spawnEntityAt(dim, entity_type, position, Protocol.Vector2f.init(0, 0), null, name_tag, nametag_always_visible);
}

fn spawnEntityAt(dim: *Dimension, entity_type: *const EntityType, position: Protocol.Vector3f, rotation: Protocol.Vector2f, motion: ?Protocol.Vector3f, name_tag: []const u8, nametag_always_visible: bool) !*Entity {
    const entity = try dim.allocator.create(Entity);
    entity.* = Entity.init(dim.allocator, entity_type, dim);
    entity.instance_id = dim.instance_id;
    entity.position = position;
    entity.rotation = rotation;
    entity.head_yaw = rotation.y;
    if (motion) |initial| entity.motion = initial;
    entity.name_tag = name_tag;
    entity.nametag_always_visible = nametag_always_visible;
    dim.world.tecton.registerEcsEntity(entity);
    try applyGlobalTraits(dim.allocator, entity);
    try dim.entities.put(entity.runtime_id, entity);
    dim.entity_index.add(entity);
    try broadcastAddEntity(dim, entity);
    return entity;
}

pub fn removeEntity(dim: *Dimension, entity: *Entity) !void {
    try broadcastRemoveEntity(dim, entity);
    dim.entity_index.remove(entity.runtime_id);
    _ = dim.entities.remove(entity.runtime_id);
    dim.world.tecton.unregisterEcsEntity(entity);
    entity.deinit();
    dim.allocator.destroy(entity);
}

pub fn flushPendingRemovals(dim: *Dimension) void {
    for (dim.pending_removals.items) |rid| {
        if (dim.entities.fetchRemove(rid)) |entry| {
            var entity = entry.value;
            dim.entity_index.remove(rid);
            broadcastRemoveEntity(dim, entity) catch {};
            dim.world.tecton.unregisterEcsEntity(entity);
            entity.deinit();
            dim.allocator.destroy(entity);
        }
    }
    dim.pending_removals.clearRetainingCapacity();
}

pub fn spawnItemEntity(dim: *Dimension, item_type: *ItemType, count: u16, position: Protocol.Vector3f, pickup_delay: u32, velocity: Protocol.Vector3f) !ecs_entity_id.EntityId {
    const stack = ItemStack.init(dim.allocator, item_type, .{ .stack_size = count });
    return spawnItemStackEntity(dim, stack, position, pickup_delay, velocity);
}

pub fn spawnItemStackEntity(dim: *Dimension, stack: ItemStack, position: Protocol.Vector3f, pickup_delay: u32, velocity: Protocol.Vector3f) !ecs_entity_id.EntityId {
    return ecs_items.spawnItem(dim, .{
        .stack = stack,
        .position = position,
        .pickup_delay = pickup_delay,
        .velocity = velocity,
    });
}

pub const ArrowSpec = struct {
    owner_runtime_id: i64,
    speed: f32,
    damage: f32,
    knockback: f32,
    burn_ticks: i32,
    pickup_identifier: []const u8,
    pickup_allowed: bool,
    is_critical: bool,
};

pub fn spawnArrow(
    dim: *Dimension,
    position: Protocol.Vector3f,
    rotation: Protocol.Vector2f,
    spec: ArrowSpec,
) !*Entity {
    const entity_type = EntityTypeRegistry.get(Bow.ARROW_IDENTIFIER) orelse return error.UnknownEntityType;
    const motion = Bow.launchVelocity(rotation, spec.speed);
    const entity = try spawnEntityAt(dim, entity_type, position, Bow.rotationOf(motion), motion, "", false);

    const projectile = try ProjectileTrait.create(dim.allocator, .{
        .owner_runtime_id = spec.owner_runtime_id,
        .damage = spec.damage,
        .knockback = spec.knockback,
        .burn_ticks = spec.burn_ticks,
        .pickup_identifier = spec.pickup_identifier,
        .pickup_allowed = spec.pickup_allowed,
        .is_critical = spec.is_critical,
        .age = 0,
        .stuck_ticks = 0,
        .stuck = false,
        .pending_remove = false,
    });
    try entity.addTrait(projectile);

    if (criticalTrailActive(spec.is_critical, false)) {
        entity.flags.setFlag(.Critical, true);
        updateEntityActorFlags(dim, entity);
    }

    return entity;
}

pub fn spawnStoredEntity(dim: *Dimension, tag: *const CompoundTag) !?*Entity {
    const identifier = stringField(tag, "identifier") orelse return null;
    if (std.mem.eql(u8, identifier, "minecraft:item") or
        std.mem.eql(u8, identifier, "minecraft:player")) return null;
    const entity_type = EntityTypeRegistry.get(identifier) orelse return null;

    if (floatField(tag, "Health")) |stored_health| {
        if (stored_health <= 0) return null;
    }

    if (longField(tag, "UniqueID")) |stored_uid| {
        if (findByUniqueId(dim, stored_uid) != null) return null;
    }

    const entity = try dim.allocator.create(Entity);
    errdefer dim.allocator.destroy(entity);
    entity.* = Entity.init(dim.allocator, entity_type, dim);
    errdefer entity.deinit();
    entity.instance_id = dim.instance_id;
    try applyGlobalTraits(dim.allocator, entity);
    serialization.deserializeEntity(dim.allocator, entity, tag);
    if (entity.getTraitState(Health.HealthTrait)) |health_state| Health.syncAttributes(health_state, entity);
    dim.world.tecton.registerEcsEntity(entity);
    try dim.entities.put(entity.runtime_id, entity);
    dim.entity_index.add(entity);
    return entity;
}

fn findByUniqueId(dim: *Dimension, unique_id: i64) ?*Entity {
    var it = dim.entities.valueIterator();
    while (it.next()) |entry| {
        if (entry.*.unique_id == unique_id) return entry.*;
    }
    return null;
}

fn stringField(tag: *const CompoundTag, key: []const u8) ?[]const u8 {
    return switch (tag.get(key) orelse return null) {
        .String => |s| s.value,
        else => null,
    };
}

fn longField(tag: *const CompoundTag, key: []const u8) ?i64 {
    return switch (tag.get(key) orelse return null) {
        .Long => |l| l.value,
        else => null,
    };
}

fn floatField(tag: *const CompoundTag, key: []const u8) ?f32 {
    return switch (tag.get(key) orelse return null) {
        .Float => |f| f.value,
        else => null,
    };
}

fn serializeAddEntity(dim: *Dimension, entity: *Entity, stream: *BinaryStream) ![]const u8 {
    const flags_data = try entity.flags.buildDataItems(dim.allocator, null);
    defer dim.allocator.free(flags_data);

    var metadata = std.ArrayList(Protocol.DataItem){ .items = &.{}, .capacity = 0 };
    defer if (metadata.capacity > 0) metadata.deinit(dim.allocator);

    for (flags_data) |item| {
        try metadata.append(dim.allocator, item);
    }

    if (entity.name_tag.len > 0) {
        try metadata.append(dim.allocator, Protocol.DataItem.init(
            Protocol.ActorDataId.Name,
            .String,
            .{ .String = entity.name_tag },
        ));
        try metadata.append(dim.allocator, Protocol.DataItem.initByte(
            Protocol.ActorDataId.AlwaysShowNameTag,
            if (entity.nametag_always_visible) 1 else 0,
        ));
    }

    const packet = Protocol.AddEntityPacket{
        .unique_entity_id = entity.unique_id,
        .runtime_entity_id = @bitCast(entity.runtime_id),
        .entity_type = entity.entity_type.identifier,
        .position = entity.position,
        .velocity = entity.motion,
        .pitch = entity.rotation.x,
        .yaw = entity.rotation.y,
        .head_yaw = entity.head_yaw,
        .body_yaw = entity.rotation.y,
        .entity_metadata = metadata.items,
        .entity_properties = Protocol.PropertySyncData.init(dim.allocator),
    };

    return try packet.serialize(stream);
}

pub fn sendAddEntityToPlayer(dim: *Dimension, player: *Player, entity: *Entity) bool {
    var stream = BinaryStream.init(dim.allocator, null, null);
    defer stream.deinit();
    const serialized = serializeAddEntity(dim, entity, &stream) catch return false;
    dim.world.tecton.network.sendPacket(player.connection, serialized) catch return false;
    return true;
}

pub fn updateEntityNameTag(dim: *Dimension, entity: *Entity) void {
    var metadata = [_]Protocol.DataItem{
        Protocol.DataItem.init(Protocol.ActorDataId.Name, .String, .{ .String = entity.name_tag }),
        Protocol.DataItem.initByte(Protocol.ActorDataId.AlwaysShowNameTag, if (entity.nametag_always_visible) 1 else 0),
    };
    var stream = BinaryStream.init(dim.allocator, null, null);
    defer stream.deinit();
    var packet = Protocol.SetActorDataPacket.initBorrowed(dim.allocator, entity.runtime_id, 0, &metadata);
    defer packet.deinit();
    const serialized = packet.serialize(&stream) catch return;
    const snapshots = dim.world.tecton.getPlayerSnapshots();
    for (snapshots) |player| {
        if (!player.spawned) continue;
        if (player.entity.dimension != dim) continue;
        if (!player.visible_entities.contains(entity.runtime_id)) continue;
        dim.world.tecton.network.sendPacket(player.connection, serialized) catch {};
    }
}

pub fn updateEntityActorFlags(dim: *Dimension, entity: *Entity) void {
    const data = entity.flags.buildDataItems(dim.allocator, null) catch return;
    defer dim.allocator.free(data);

    var stream = BinaryStream.init(dim.allocator, null, null);
    defer stream.deinit();
    var packet = Protocol.SetActorDataPacket.initBorrowed(dim.allocator, entity.runtime_id, 0, data);
    defer packet.deinit();
    const serialized = packet.serialize(&stream) catch return;
    broadcast.broadcastToEntityViewers(dim, entity, serialized);
}

pub fn sendRemoveEntityToPlayer(dim: *Dimension, player: *Player, entity: *Entity) void {
    var stream = BinaryStream.init(dim.allocator, null, null);
    defer stream.deinit();
    const packet = Protocol.RemoveEntityPacket{ .unique_entity_id = entity.unique_id };
    const serialized = packet.serialize(&stream) catch return;
    dim.world.tecton.network.sendPacket(player.connection, serialized) catch {};
}

fn sendAddToViewers(dim: *Dimension, entity: *Entity, serialized: []const u8) void {
    const tecton = dim.world.tecton;
    const snapshots = tecton.getPlayerSnapshots();
    for (snapshots) |player| {
        if (!player.spawned) continue;
        if (player.entity.dimension != dim or player.entity.instance_id != dim.instance_id) continue;
        const dx = player.entity.position.x - entity.position.x;
        const dz = player.entity.position.z - entity.position.z;
        if (!Dimension.withinViewDistance(dx, dz, player.view_distance)) continue;
        tecton.network.sendPacket(player.connection, serialized) catch continue;
        player.visible_entities.put(entity.runtime_id, entity.unique_id) catch {};
    }
}

fn broadcastAddEntity(dim: *Dimension, entity: *Entity) !void {
    var stream = BinaryStream.init(dim.allocator, null, null);
    defer stream.deinit();
    const serialized = try serializeAddEntity(dim, entity, &stream);
    sendAddToViewers(dim, entity, serialized);
}

fn broadcastRemoveEntity(dim: *Dimension, entity: *Entity) !void {
    var stream = BinaryStream.init(dim.allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.RemoveEntityPacket{
        .unique_entity_id = entity.unique_id,
    };
    const serialized = try packet.serialize(&stream);

    const tecton = dim.world.tecton;
    const snapshots = tecton.getPlayerSnapshots();
    for (snapshots) |player| {
        if (player.visible_entities.fetchRemove(entity.runtime_id) == null) continue;
        tecton.network.sendPacket(player.connection, serialized) catch {};
    }
}
