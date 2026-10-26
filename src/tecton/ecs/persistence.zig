const std = @import("std");

const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const ListTag = NBT.ListTag;
const Tag = NBT.Tag;
const FloatTag = NBT.FloatTag;
const IntTag = NBT.IntTag;
const LongTag = NBT.LongTag;
const StringTag = NBT.StringTag;
const Protocol = @import("protocol");

const entity_id = @import("entity_id.zig");
const components = @import("components.zig");

const EntityId = entity_id.EntityId;
const GameWorld = components.GameWorld;
const Transform = components.Transform;
const Health = components.Health;
const ProtocolId = components.ProtocolId;
const TypeRef = components.TypeRef;

const sanitize = @import("../world/provider/sanitize.zig");

pub fn serializeEcsEntity(allocator: std.mem.Allocator, world: *GameWorld, id: EntityId) !?CompoundTag {
    const proto = world.get(id, ProtocolId) orelse return null;
    const type_ref = world.get(id, TypeRef) orelse return null;
    const transform = world.get(id, Transform) orelse return null;

    var tag = CompoundTag.init(allocator, null);
    errdefer tag.deinit(allocator);
    try tag.set("identifier", .{ .String = StringTag.init(try allocator.dupe(u8, type_ref.identifier), null) });
    try tag.set("UniqueID", .{ .Long = LongTag.init(proto.unique, null) });

    var pos_items = try allocator.alloc(Tag, 3);
    pos_items[0] = .{ .Float = FloatTag.init(transform.position.x, null) };
    pos_items[1] = .{ .Float = FloatTag.init(transform.position.y, null) };
    pos_items[2] = .{ .Float = FloatTag.init(transform.position.z, null) };
    try tag.set("Pos", .{ .List = ListTag.init(pos_items, null) });

    var rot_items = try allocator.alloc(Tag, 2);
    rot_items[0] = .{ .Float = FloatTag.init(transform.rotation.x, null) };
    rot_items[1] = .{ .Float = FloatTag.init(transform.rotation.y, null) };
    try tag.set("Rotation", .{ .List = ListTag.init(rot_items, null) });

    var motion_items = try allocator.alloc(Tag, 3);
    motion_items[0] = .{ .Float = FloatTag.init(transform.velocity.x, null) };
    motion_items[1] = .{ .Float = FloatTag.init(transform.velocity.y, null) };
    motion_items[2] = .{ .Float = FloatTag.init(transform.velocity.z, null) };
    try tag.set("Motion", .{ .List = ListTag.init(motion_items, null) });

    if (world.get(id, Health)) |health| {
        try tag.set("Health", .{ .Float = FloatTag.init(health.current, null) });
        try tag.set("MaxHealth", .{ .Float = FloatTag.init(health.max, null) });
    }

    if (world.get(id, components.Fire)) |fire| {
        if (fire.ticks > 0) {
            try tag.set("FireTicks", .{ .Int = IntTag.init(fire.ticks, null) });
        }
    }

    return tag;
}

pub fn applyStoredTransform(world: *GameWorld, id: EntityId, tag: *const CompoundTag) void {
    const transform = world.get(id, Transform) orelse return;

    if (tag.get("Pos")) |pos| {
        switch (pos) {
            .List => |list| {
                if (list.value.len >= 3) {
                    transform.position = Protocol.Vector3f.init(
                        sanitize.sane(sanitize.getFloat(&list.value[0]), sanitize.world_border),
                        sanitize.sane(sanitize.getFloat(&list.value[1]), sanitize.world_border),
                        sanitize.sane(sanitize.getFloat(&list.value[2]), sanitize.world_border),
                    );
                }
            },
            else => {},
        }
    }

    if (tag.get("Rotation")) |rot| {
        switch (rot) {
            .List => |list| {
                if (list.value.len >= 2) {
                    transform.rotation = Protocol.Vector2f.init(
                        sanitize.getFloat(&list.value[0]),
                        sanitize.getFloat(&list.value[1]),
                    );
                }
            },
            else => {},
        }
    }

    if (tag.get("Motion")) |motion| {
        switch (motion) {
            .List => |list| {
                if (list.value.len >= 3) {
                    transform.velocity = Protocol.Vector3f.init(
                        sanitize.sane(sanitize.getFloat(&list.value[0]), sanitize.max_motion),
                        sanitize.sane(sanitize.getFloat(&list.value[1]), sanitize.max_motion),
                        sanitize.sane(sanitize.getFloat(&list.value[2]), sanitize.max_motion),
                    );
                }
            },
            else => {},
        }
    }
    transform.dirty = true;
}

pub fn applyStoredHealth(world: *GameWorld, id: EntityId, tag: *const CompoundTag) void {
    const health = world.get(id, Health) orelse return;
    if (tag.get("MaxHealth")) |max| {
        switch (max) {
            .Float => |value| {
                if (value.value > 0) health.max = value.value;
            },
            else => {},
        }
    }
    if (tag.get("Health")) |current| {
        switch (current) {
            .Float => |value| {
                health.current = if (value.value < 0) 0 else @min(value.value, health.max);
            },
            else => {},
        }
    }
}

pub fn applyStoredFire(world: *GameWorld, id: EntityId, tag: *const CompoundTag) void {
    const fire_ticks = tag.get("FireTicks") orelse return;
    const ticks = switch (fire_ticks) {
        .Int => |value| value.value,
        else => return,
    };
    if (ticks <= 0) return;
    if (world.get(id, components.Fire)) |fire| {
        fire.ticks = ticks;
    } else {
        world.add(id, components.Fire{ .ticks = ticks }) catch {};
    }
}

pub fn storedUniqueId(tag: *const CompoundTag) ?i64 {
    const uid = tag.get("UniqueID") orelse return null;
    return switch (uid) {
        .Long => |value| value.value,
        else => null,
    };
}

pub fn storedHealth(tag: *const CompoundTag) ?f32 {
    const health = tag.get("Health") orelse return null;
    return switch (health) {
        .Float => |value| value.value,
        else => null,
    };
}

pub fn storedIdentifier(tag: *const CompoundTag) ?[]const u8 {
    const identifier = tag.get("identifier") orelse return null;
    return switch (identifier) {
        .String => |value| value.value,
        else => null,
    };
}

test "ecs entity nbt round trip preserves identity motion and health" {
    const allocator = std.testing.allocator;
    var world = try GameWorld.init(allocator, 4);
    defer world.deinit();

    const id = try world.create(.mob);
    try world.add(id, ProtocolId{ .runtime = 900, .unique = 1234 });
    try world.add(id, TypeRef{ .identifier = "minecraft:zombie", .network_id = 32 });
    try world.add(id, Transform{
        .position = Protocol.Vector3f.init(10.5, 64.0, -20.25),
        .rotation = Protocol.Vector2f.init(1.0, 2.0),
        .velocity = Protocol.Vector3f.init(0.1, 0.0, -0.3),
        .dirty = false,
    });
    try world.add(id, Health{ .current = 13.5, .max = 25.0 });

    var tag = (try serializeEcsEntity(allocator, &world, id)).?;
    defer tag.deinit(allocator);

    try std.testing.expectEqualStrings("minecraft:zombie", storedIdentifier(&tag).?);
    try std.testing.expectEqual(@as(i64, 1234), storedUniqueId(&tag).?);
    try std.testing.expectEqual(@as(f32, 13.5), storedHealth(&tag).?);

    try world.add(id, Transform{ .position = Protocol.Vector3f.init(0, 0, 0) });
    applyStoredTransform(&world, id, &tag);
    applyStoredHealth(&world, id, &tag);

    const restored = world.get(id, Transform).?;
    try std.testing.expectEqual(@as(f32, 10.5), restored.position.x);
    try std.testing.expectEqual(@as(f32, -20.25), restored.position.z);
    try std.testing.expectEqual(@as(f32, -0.3), restored.velocity.z);
    try std.testing.expect(restored.dirty);
    try std.testing.expectEqual(@as(f32, 13.5), world.get(id, Health).?.current);
    try std.testing.expectEqual(@as(f32, 25.0), world.get(id, Health).?.max);
}

test "serialization skips entities without identity components" {
    const allocator = std.testing.allocator;
    var world = try GameWorld.init(allocator, 4);
    defer world.deinit();

    const bare = try world.create(.mob);
    try std.testing.expect((try serializeEcsEntity(allocator, &world, bare)) == null);
}
