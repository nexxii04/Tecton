const std = @import("std");
const Protocol = @import("protocol");

const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const dimension_mod = @import("../world/dimension/dimension.zig");
const Entity = @import("../entity/entity.zig").Entity;
const entity_id = @import("entity_id.zig");
const components = @import("components.zig");
const protocol_bridge = @import("protocol.zig");

const EntityId = entity_id.EntityId;
const Transform = components.Transform;
const ProtocolId = components.ProtocolId;
const TypeRef = components.TypeRef;

pub const player_identifier = "minecraft:player";

pub fn ensurePlayer(dim: *Dimension, runtime: i64, unique: i64, position: Protocol.Vector3f, rotation: Protocol.Vector2f) !EntityId {
    const state = try dim.ensureEcs(512);
    if (state.runtime_index.resolve(runtime)) |existing| {
        if (state.world.isAlive(existing)) return existing;
    }

    const allocator = dim.allocator;
    const id = try state.world.create(.player);
    errdefer _ = state.world.destroy(id);
    try state.world.add(id, ProtocolId{ .runtime = runtime, .unique = unique });
    try state.world.add(id, TypeRef{ .identifier = player_identifier, .network_id = 1 });
    try state.world.add(id, Transform{ .position = position, .rotation = rotation });
    try state.runtime_index.publish(allocator, runtime, id);
    try state.chunk_index.add(id, chunkHashOf(position));
    return id;
}

pub fn writePlayerTransform(
    dim: *Dimension,
    runtime: i64,
    entity: *Entity,
    position: Protocol.Vector3f,
    rotation: Protocol.Vector2f,
    motion: Protocol.Vector3f,
) void {
    const state = dim.ensureEcs(512) catch return;
    const id = ensurePlayer(dim, runtime, entity.unique_id, position, rotation) catch return;

    const transform = state.world.get(id, Transform) orelse return;
    transform.position = position;
    transform.rotation = rotation;
    transform.velocity = motion;
    transform.dirty = true;

    entity.position = position;
    entity.rotation = rotation;
    entity.motion = motion;

    state.chunk_index.update(id, chunkHashOf(position)) catch {};
}

pub fn removePlayer(dim: *Dimension, runtime: i64) void {
    const state = dim.ecs orelse return;
    const id = state.runtime_index.resolve(runtime) orelse return;
    if (state.world.get(id, ProtocolId)) |proto| {
        if (proto.runtime == runtime) {
            _ = state.chunk_index.remove(id);
            state.runtime_index.unpublish(runtime);
            _ = state.world.destroy(id);
        }
    }
}

fn chunkHashOf(position: Protocol.Vector3f) i64 {
    const cx = @as(i32, @intFromFloat(@floor(position.x))) >> 4;
    const cz = @as(i32, @intFromFloat(@floor(position.z))) >> 4;
    return dimension_mod.chunkHash(cx, cz);
}

test "player entity lifecycle keeps transform authority in the ecs" {
    const allocator = std.testing.allocator;
    const EntityType = @import("../entity/entity_type.zig").EntityType;
    const player_type = EntityType{
        .identifier = player_identifier,
        .network_id = 1,
        .components = &.{},
        .tags = &.{},
    };

    var entity = Entity.init(allocator, &player_type, null);
    defer entity.deinit();

    var dim = Dimension.init(undefined, allocator, "test", .Overworld, null);
    defer dim.deinit();

    const runtime = entity.runtime_id;
    writePlayerTransform(&dim, runtime, &entity, Protocol.Vector3f.init(1, 64, 1), Protocol.Vector2f.init(0, 90), Protocol.Vector3f.zero());
    try std.testing.expectEqual(@as(f32, 1), entity.position.x);
    try std.testing.expectEqual(@as(f32, 90), entity.rotation.y);

    const state = dim.ecs.?;
    const id = state.runtime_index.resolve(runtime).?;
    try std.testing.expect(state.world.isAlive(id));
    try std.testing.expectEqual(id.kind, .player);
    const transform = state.world.get(id, Transform).?;
    try std.testing.expectEqual(@as(f32, 1), transform.position.x);
    try std.testing.expectEqual(@as(f32, 90), transform.rotation.y);
    try std.testing.expectEqual(@as(usize, 1), state.chunk_index.count());

    writePlayerTransform(&dim, runtime, &entity, Protocol.Vector3f.init(500, 70, 500), Protocol.Vector2f.init(0, 0), Protocol.Vector3f.zero());
    try std.testing.expectEqual(@as(f32, 500), state.world.get(id, Transform).?.position.x);
    try std.testing.expectEqual(entity.unique_id, state.world.get(id, ProtocolId).?.unique);
    try std.testing.expectEqual(@as(usize, 1), state.chunk_index.count());

    removePlayer(&dim, runtime);
    try std.testing.expect(!state.world.isAlive(id));
    try std.testing.expect(state.runtime_index.resolve(runtime) == null);
    try std.testing.expectEqual(@as(usize, 0), state.chunk_index.count());
}
