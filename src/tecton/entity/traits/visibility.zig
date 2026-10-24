const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

const Player = @import("../../player/player.zig").Player;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const entities = @import("../../world/dimension/entities.zig");
const inventory = @import("./inventory.zig");

pub const VISIBILITY_UPDATE_INTERVAL: u8 = 4;

pub fn sendPublisherUpdate(player: *Player) void {
    var stream = BinaryStream.init(player.entity.allocator, null, null);
    defer stream.deinit();

    var update = Protocol.NetworkChunkPublisherUpdatePacket{
        .coordinate = Protocol.BlockPosition{
            .x = @intFromFloat(@floor(player.entity.position.x)),
            .y = @intFromFloat(@floor(player.entity.position.y)),
            .z = @intFromFloat(@floor(player.entity.position.z)),
        },
        .radius = @intCast(player.view_distance * 16),
        .saved_chunks = &[_]Protocol.ChunkCoords{},
    };
    const serialized = update.serialize(&stream) catch return;
    player.network.sendPacket(player.connection, serialized) catch {};
}

pub fn updatePlayerVisibility(player: *Player) void {
    const tecton = player.tecton;
    const allocator = player.entity.allocator;
    const pass_start = std.Io.Timestamp.now(tecton.io, .awake);
    defer {
        const elapsed = pass_start.durationTo(.now(tecton.io, .awake));
        tecton.profiler.record(.visibility_pass, @intCast(@max(0, elapsed.nanoseconds)));
    }
    const snapshots = tecton.getPlayerSnapshots();
    const range = player.view_distance * 16;
    const range_sq: f32 = @floatFromInt(range * range);

    player.visibility_epoch +%= 1;
    const epoch = player.visibility_epoch;

    for (snapshots) |other| {
        if (other.entity.runtime_id == player.entity.runtime_id) continue;

        const entry = player.visible_players.getPtr(other.entity.runtime_id);
        if (entry) |e| e.* = epoch;

        if (!other.spawned) continue;

        const currently_visible = entry != null;

        if (other.entity.dimension != player.entity.dimension) {
            if (currently_visible) {
                despawnPlayerFor(player, other, allocator);
                _ = player.visible_players.remove(other.entity.runtime_id);
            }
            continue;
        }

        const dx = player.entity.position.x - other.entity.position.x;
        const dz = player.entity.position.z - other.entity.position.z;
        const dist_sq = dx * dx + dz * dz;
        const in_range = dist_sq <= range_sq;

        if (in_range and !currently_visible) {
            spawnPlayerFor(player, other, allocator);
            player.visible_players.put(other.entity.runtime_id, epoch) catch {};
        } else if (!in_range and currently_visible) {
            despawnPlayerFor(player, other, allocator);
            _ = player.visible_players.remove(other.entity.runtime_id);
        }
    }

    _ = sweepUnseenPlayers(&player.visible_players, epoch, &player.visible_sweep, allocator) catch 0;

    updateTrackedEntities(player);

    if (player.entity.dimension) |dimension| {
        if (dimension.floating_texts) |manager| manager.updateVisibilityForPlayer(player);
    }
}

fn sweepUnseenPlayers(
    map: *std.AutoHashMap(i64, u32),
    epoch: u32,
    scratch: *std.ArrayList(i64),
    allocator: std.mem.Allocator,
) !usize {
    scratch.clearRetainingCapacity();

    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != epoch) {
            try scratch.append(allocator, entry.key_ptr.*);
        }
    }

    const removed = scratch.items.len;
    for (scratch.items) |runtime_id| {
        _ = map.remove(runtime_id);
    }
    return removed;
}

fn updateTrackedEntities(player: *Player) void {
    const start = std.Io.Timestamp.now(player.tecton.io, .awake);
    defer {
        const elapsed = start.durationTo(.now(player.tecton.io, .awake));
        player.tecton.profiler.record(.visibility_tracked, @intCast(@max(0, elapsed.nanoseconds)));
    }
    const dimension = player.entity.dimension orelse return;
    const allocator = player.entity.allocator;

    const center_x = @as(i32, @intFromFloat(@floor(player.entity.position.x))) >> 4;
    const center_z = @as(i32, @intFromFloat(@floor(player.entity.position.z))) >> 4;
    const view = player.view_distance;

    var chunk_dx: i32 = -view;
    while (chunk_dx <= view) : (chunk_dx += 1) {
        var chunk_dz: i32 = -view;
        while (chunk_dz <= view) : (chunk_dz += 1) {
            if (chunk_dx * chunk_dx + chunk_dz * chunk_dz > view * view) continue;
            for (dimension.entitiesInChunk(center_x + chunk_dx, center_z + chunk_dz)) |entity| {
                if (player.visible_entities.contains(entity.runtime_id)) continue;
                const dx = player.entity.position.x - entity.position.x;
                const dz = player.entity.position.z - entity.position.z;
                if (!Dimension.withinViewDistance(dx, dz, view)) continue;
                if (entities.sendAddEntityToPlayer(dimension, player, entity)) {
                    player.visible_entities.put(entity.runtime_id, entity.unique_id) catch {};
                }
            }
        }
    }

    if (dimension.ecs) |state| {
        trackEcsEntities(player, state, allocator, center_x, center_z, view);
    }

    var stale = std.ArrayList(i64).empty;
    defer stale.deinit(allocator);
    var tracked_it = player.visible_entities.keyIterator();
    while (tracked_it.next()) |runtime_id| {
        const entity = dimension.entities.get(runtime_id.*) orelse {
            stale.append(allocator, runtime_id.*) catch {};
            continue;
        };
        const dx = player.entity.position.x - entity.position.x;
        const dz = player.entity.position.z - entity.position.z;
        if (!Dimension.withinViewDistance(dx, dz, view)) {
            entities.sendRemoveEntityToPlayer(dimension, player, entity);
            stale.append(allocator, runtime_id.*) catch {};
        }
    }
    for (stale.items) |runtime_id| {
        _ = player.visible_entities.remove(runtime_id);
    }
}

fn trackEcsEntities(
    player: *Player,
    state: *@import("../../ecs/resources.zig").DimensionEcs,
    allocator: std.mem.Allocator,
    center_x: i32,
    center_z: i32,
    view: i32,
) void {
    const ecs_components = @import("../../ecs/components.zig");
    const ecs_protocol = @import("../../ecs/protocol.zig");
    const world = &state.world;

    var chunk_dx: i32 = -view;
    while (chunk_dx <= view) : (chunk_dx += 1) {
        var chunk_dz: i32 = -view;
        while (chunk_dz <= view) : (chunk_dz += 1) {
            if (chunk_dx * chunk_dx + chunk_dz * chunk_dz > view * view) continue;
            const hash = @import("../../world/dimension/dimension.zig").chunkHash(center_x + chunk_dx, center_z + chunk_dz);
            for (state.chunk_index.bucket(hash)) |id| {
                const proto = world.get(id, ecs_components.ProtocolId) orelse continue;
                if (player.visible_entities.contains(proto.runtime)) continue;
                const transform = world.get(id, ecs_components.Transform) orelse continue;
                const dx = player.entity.position.x - transform.position.x;
                const dz = player.entity.position.z - transform.position.z;
                if (!Dimension.withinViewDistance(dx, dz, view)) continue;
                var stream = BinaryStream.init(allocator, null, null);
                defer stream.deinit();
                const serialized = ecs_protocol.buildAddPacket(allocator, world, id, &stream) catch continue;
                player.network.sendPacket(player.connection, serialized) catch continue;
                player.visible_entities.put(proto.runtime, proto.unique) catch {};
            }
        }
    }
}

fn spawnPlayerFor(viewer: *Player, target: *Player, allocator: std.mem.Allocator) void {
    {
        var stream = BinaryStream.init(allocator, null, null);
        defer stream.deinit();

        var abilities: [20]Protocol.AbilitySet = undefined;
        for (&abilities, 0..) |*set, i| {
            set.* = .{ .ability = @enumFromInt(i), .value = false };
        }
        const layers = [1]Protocol.AbilityLayer{.{
            .layer_type = @intFromEnum(Protocol.AbilityLayerType.Base),
            .abilities = &abilities,
            .fly_speed = 0.0,
            .vertical_fly_speed = 0.0,
            .walk_speed = 0.0,
        }};

        const size = target.pose.size();
        const metadata = [_]Protocol.DataItem{
            Protocol.DataItem.init(Protocol.ActorDataId.Flags, .Long, .{ .Long = target.entity.flags.flags_one }),
            Protocol.DataItem.init(Protocol.ActorDataId.FlagsTwo, .Long, .{ .Long = target.entity.flags.flags_two }),
            Protocol.DataItem.initFloat(Protocol.ActorDataId.Scale, 1.0),
            Protocol.DataItem.initFloat(Protocol.ActorDataId.Width, size.width),
            Protocol.DataItem.initFloat(Protocol.ActorDataId.Height, size.height),
        };

        const packet = Protocol.AddPlayerPacket{
            .uuid = target.uuid,
            .username = target.username,
            .entity_runtime_id = target.entity.runtime_id,
            .position = target.entity.position,
            .rotation = Protocol.Rotation.init(
                target.entity.rotation.x,
                target.entity.rotation.y,
                target.entity.head_yaw,
            ),
            .entity_metadata = &metadata,
            .entity_properties = Protocol.PropertySyncData.init(allocator),

            .ability_entity_unique_id = target.entity.unique_id,
            .ability_layers = &layers,
            .build_platform = @intCast(target.login_data.client_data.device_os),
        };
        const serialized = packet.serialize(&stream) catch return;
        viewer.network.sendPacket(viewer.connection, serialized) catch {};
    }

    {
        var stream = BinaryStream.init(allocator, null, null);
        defer stream.deinit();
        const skin_packet = Protocol.PlayerSkinPacket{
            .uuid = target.uuid,
            .skin = &target.login_data.client_data,
        };
        const serialized = skin_packet.serialize(&stream, allocator) catch return;
        viewer.network.sendPacket(viewer.connection, serialized) catch {};
    }

    {
        var stream = BinaryStream.init(allocator, null, null);
        defer stream.deinit();
        const flags_data = target.entity.flags.buildDataItems(allocator, target.pose.size()) catch return;
        var packet = Protocol.SetActorDataPacket.init(allocator, target.entity.runtime_id, 0, flags_data);
        defer packet.deinit();
        const serialized = packet.serialize(&stream) catch return;
        viewer.network.sendPacket(viewer.connection, serialized) catch {};
    }

    if (target.entity.getTraitState(inventory.InventoryTrait)) |state| {
        inventory.sendEquipmentTo(viewer, target, state);
    }
}

fn despawnPlayerFor(viewer: *Player, target: *Player, allocator: std.mem.Allocator) void {
    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();
    const packet = Protocol.RemoveEntityPacket{ .unique_entity_id = target.entity.unique_id };
    const serialized = packet.serialize(&stream) catch return;
    viewer.network.sendPacket(viewer.connection, serialized) catch {};
}

pub fn forgetPlayerForViewers(player: *Player) void {
    const tecton = player.tecton;
    const dimension = player.entity.dimension orelse return;

    for (tecton.getPlayerSnapshots()) |viewer| {
        if (viewer.entity.runtime_id == player.entity.runtime_id) continue;
        if (!viewer.spawned) continue;
        if (viewer.entity.dimension != dimension) continue;
        if (viewer.visible_players.remove(player.entity.runtime_id)) {
            despawnPlayerFor(viewer, player, viewer.entity.allocator);
        }
    }
}

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const sweepUnseenPlayers = test_owner.sweepUnseenPlayers;
};

test "the epoch sweep matches the original linear sweep" {
    try @import("visibility_test.zig").Suite(test_scope).case_000();
}

test "a wrapping epoch does not purge live entries" {
    try @import("visibility_test.zig").Suite(test_scope).case_001();
}

test "the sweep reuses its scratch without allocating between passes" {
    try @import("visibility_test.zig").Suite(test_scope).case_002();
}
