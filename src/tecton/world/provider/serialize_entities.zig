const std = @import("std");

const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const ListTag = NBT.ListTag;
const Tag = NBT.Tag;
const FloatTag = NBT.FloatTag;
const LongTag = NBT.LongTag;
const StringTag = NBT.StringTag;
const Protocol = @import("protocol");
const sanitize_mod = @import("sanitize.zig");

const world_border = sanitize_mod.world_border;
const max_motion = sanitize_mod.max_motion;
const sane = sanitize_mod.sane;
const getFloat = sanitize_mod.getFloat;

pub fn serializeEntity(allocator: std.mem.Allocator, entity: anytype) !CompoundTag {
    var tag = CompoundTag.init(allocator, null);
    try tag.set("identifier", .{ .String = StringTag.init(try allocator.dupe(u8, entity.entity_type.identifier), null) });
    try tag.set("UniqueID", .{ .Long = LongTag.init(entity.unique_id, null) });

    var pos_items = try allocator.alloc(Tag, 3);
    pos_items[0] = .{ .Float = FloatTag.init(entity.position.x, null) };
    pos_items[1] = .{ .Float = FloatTag.init(entity.position.y, null) };
    pos_items[2] = .{ .Float = FloatTag.init(entity.position.z, null) };
    try tag.set("Pos", .{ .List = ListTag.init(pos_items, null) });

    var rot_items = try allocator.alloc(Tag, 2);
    rot_items[0] = .{ .Float = FloatTag.init(entity.rotation.x, null) };
    rot_items[1] = .{ .Float = FloatTag.init(entity.rotation.y, null) };
    try tag.set("Rotation", .{ .List = ListTag.init(rot_items, null) });

    var motion_items = try allocator.alloc(Tag, 3);
    motion_items[0] = .{ .Float = FloatTag.init(entity.motion.x, null) };
    motion_items[1] = .{ .Float = FloatTag.init(entity.motion.y, null) };
    motion_items[2] = .{ .Float = FloatTag.init(entity.motion.z, null) };
    try tag.set("Motion", .{ .List = ListTag.init(motion_items, null) });

    entity.fireEvent(.Serialize, .{&tag});

    return tag;
}

pub fn deserializeEntity(_: std.mem.Allocator, entity: anytype, tag: *const CompoundTag) void {
    if (tag.get("UniqueID")) |uid| {
        switch (uid) {
            .Long => |l| {
                entity.unique_id = l.value;
                @TypeOf(entity.*).NbtHooks.reserveUniqueId(l.value);
            },
            else => {},
        }
    }

    if (tag.get("Pos")) |pos| {
        switch (pos) {
            .List => |list| {
                if (list.value.len >= 3) {
                    entity.position = Protocol.Vector3f.init(
                        sane(getFloat(&list.value[0]), world_border),
                        sane(getFloat(&list.value[1]), world_border),
                        sane(getFloat(&list.value[2]), world_border),
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
                    entity.rotation = Protocol.Vector2f.init(
                        getFloat(&list.value[0]),
                        getFloat(&list.value[1]),
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
                    entity.motion = Protocol.Vector3f.init(
                        sane(getFloat(&list.value[0]), max_motion),
                        sane(getFloat(&list.value[1]), max_motion),
                        sane(getFloat(&list.value[2]), max_motion),
                    );
                }
            },
            else => {},
        }
    }

    entity.fireEvent(.Deserialize, .{tag});
}
