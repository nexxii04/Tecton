const std = @import("std");
const Protocol = @import("protocol");
const BinaryStream = @import("BinaryStream").BinaryStream;
const entity_id_mod = @import("entity_id.zig");
const components = @import("components.zig");

const EntityId = entity_id_mod.EntityId;
const GameWorld = components.GameWorld;
const Transform = components.Transform;
const ProtocolId = components.ProtocolId;
const TypeRef = components.TypeRef;
const ActorFlags = components.ActorFlags;
const NameTag = components.NameTag;
const ItemPickup = components.ItemPickup;

var next_unique_id: i64 = 1;

pub fn nextRuntimeId() i64 {
    return @atomicRmw(i64, &next_unique_id, .Add, 1, .monotonic);
}

pub fn reserveUniqueId(uid: i64) void {
    if (uid < 0) return;
    const next = std.math.add(i64, uid, 1) catch return;
    _ = @atomicRmw(i64, &next_unique_id, .Max, next, .monotonic);
}

pub const RuntimeIndex = struct {
    map: std.AutoHashMapUnmanaged(i64, EntityId) = .empty,

    pub fn publish(self: *RuntimeIndex, allocator: std.mem.Allocator, runtime: i64, id: EntityId) !void {
        try self.map.put(allocator, runtime, id);
    }

    pub fn unpublish(self: *RuntimeIndex, runtime: i64) void {
        _ = self.map.remove(runtime);
    }

    pub fn resolve(self: *const RuntimeIndex, runtime: i64) ?EntityId {
        return self.map.get(runtime);
    }

    pub fn deinit(self: *RuntimeIndex, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }
};

pub fn buildAddPacket(allocator: std.mem.Allocator, world: *GameWorld, id: EntityId, stream: *BinaryStream) ![]const u8 {
    if (world.get(id, ItemPickup) != null) {
        return buildAddItemActor(allocator, world, id, stream);
    }
    return buildAddEntity(allocator, world, id, stream);
}

pub fn buildAddEntity(allocator: std.mem.Allocator, world: *GameWorld, id: EntityId, stream: *BinaryStream) ![]const u8 {
    const proto = world.get(id, ProtocolId) orelse return error.MissingProtocolId;
    const transform = world.get(id, Transform) orelse return error.MissingTransform;
    const type_ref = world.get(id, TypeRef) orelse return error.MissingTypeRef;

    var metadata = std.ArrayList(Protocol.DataItem){ .items = &.{}, .capacity = 0 };
    defer metadata.deinit(allocator);

    if (world.get(id, ActorFlags)) |flags| {
        const items = try flags.flags.buildDataItems(allocator, null);
        defer allocator.free(items);
        try metadata.appendSlice(allocator, items);
    }

    if (world.get(id, NameTag)) |name| {
        if (name.text.len > 0) {
            try metadata.append(allocator, Protocol.DataItem.init(
                Protocol.ActorDataId.Name,
                .String,
                .{ .String = name.text },
            ));
            try metadata.append(allocator, Protocol.DataItem.initByte(
                Protocol.ActorDataId.AlwaysShowNameTag,
                0,
            ));
        }
    }

    const packet = Protocol.AddEntityPacket{
        .unique_entity_id = proto.unique,
        .runtime_entity_id = @bitCast(proto.runtime),
        .entity_type = type_ref.identifier,
        .position = transform.position,
        .velocity = transform.velocity,
        .pitch = transform.rotation.x,
        .yaw = transform.rotation.y,
        .head_yaw = transform.head_yaw,
        .body_yaw = transform.rotation.y,
        .entity_metadata = metadata.items,
        .entity_properties = Protocol.PropertySyncData.init(allocator),
    };

    return packet.serialize(stream);
}

pub fn buildAddItemActor(allocator: std.mem.Allocator, world: *GameWorld, id: EntityId, stream: *BinaryStream) ![]const u8 {
    const proto = world.get(id, ProtocolId) orelse return error.MissingProtocolId;
    const transform = world.get(id, Transform) orelse return error.MissingTransform;
    const pickup = world.get(id, ItemPickup) orelse return error.MissingItemPickup;

    const packet = Protocol.AddItemActorPacket{
        .unique_entity_id = proto.unique,
        .runtime_entity_id = @bitCast(proto.runtime),
        .item = pickup.stack.toNetworkStack(),
        .position = transform.position,
        .velocity = transform.velocity,
    };
    return packet.serialize(stream, allocator);
}

pub fn buildRemoveEntity(world: *GameWorld, id: EntityId, stream: *BinaryStream) ![]const u8 {
    const proto = world.get(id, ProtocolId) orelse return error.MissingProtocolId;
    const packet = Protocol.RemoveEntityPacket{ .unique_entity_id = proto.unique };
    return packet.serialize(stream);
}

test "runtime ids never repeat and honor reserved ids" {
    const loaded = nextRuntimeId();
    reserveUniqueId(loaded + 5);
    try std.testing.expect(nextRuntimeId() > loaded + 5);
}

test "runtime index resolves publishes and unpublishes" {
    const allocator = std.testing.allocator;
    var index = RuntimeIndex{};
    defer index.deinit(allocator);

    const id = EntityId{ .index = 4, .generation = 2, .kind = .item };
    try index.publish(allocator, 77, id);
    try std.testing.expectEqual(id, index.resolve(77).?);
    try std.testing.expect(index.resolve(78) == null);

    index.unpublish(77);
    try std.testing.expect(index.resolve(77) == null);
    index.unpublish(77);
}

test "add entity and add item actor packets serialize from components" {
    const allocator = std.testing.allocator;
    const ItemType = @import("../items/item_type.zig").ItemType;
    const item_type = try ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:ecs_packet_test"),
        5002,
        64,
        true,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    defer item_type.deinit();
    const ItemStack = @import("../items/item_stack.zig").ItemStack;

    var world = try GameWorld.init(allocator, 8);
    defer world.deinit();

    const mob = try world.create(.mob);
    try world.add(mob, ProtocolId{ .runtime = 901, .unique = 901 });
    try world.add(mob, Transform{ .position = Protocol.Vector3f.init(1, 64, 2) });
    try world.add(mob, TypeRef{ .identifier = "minecraft:zombie", .network_id = 32 });

    var mob_stream = BinaryStream.init(allocator, null, null);
    defer mob_stream.deinit();
    const mob_bytes = try buildAddEntity(allocator, &world, mob, &mob_stream);
    try std.testing.expect(mob_bytes.len > 0);
    try std.testing.expectEqual(mob_bytes.ptr, mob_stream.getBuffer().ptr);

    const item = try world.create(.item);
    try world.add(item, ProtocolId{ .runtime = 902, .unique = 902 });
    try world.add(item, Transform{ .position = Protocol.Vector3f.init(3, 64, 4) });
    try world.add(item, TypeRef{ .identifier = "minecraft:item", .network_id = 64 });
    try world.add(item, ItemPickup{ .stack = ItemStack.init(allocator, item_type, .{ .stack_size = 1 }) });

    var item_stream = BinaryStream.init(allocator, null, null);
    defer item_stream.deinit();
    const item_bytes = try buildAddPacket(allocator, &world, item, &item_stream);
    try std.testing.expect(item_bytes.len > 0);

    var remove_stream = BinaryStream.init(allocator, null, null);
    defer remove_stream.deinit();
    const remove_bytes = try buildRemoveEntity(&world, item, &remove_stream);
    try std.testing.expect(remove_bytes.len > 0);
}

test "add packets fail cleanly when identity components are missing" {
    const allocator = std.testing.allocator;
    var world = try GameWorld.init(allocator, 4);
    defer world.deinit();

    const bare = try world.create(.mob);
    try world.add(bare, Transform{});
    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();
    try std.testing.expectError(error.MissingProtocolId, buildAddEntity(allocator, &world, bare, &stream));
}
