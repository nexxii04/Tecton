const std = @import("std");
const testing = std.testing;
const BinaryStream = @import("BinaryStream").BinaryStream;

const Protocol = @import("protocol");
const ActorFlags = Protocol.ActorFlags;
const ActorDataId = Protocol.ActorDataId;

pub const EntityActorFlags = struct {
    pub const Size = struct {
        width: f32,
        height: f32,
    };

    flags_one: i64,
    flags_two: i64,

    pub fn init() EntityActorFlags {
        return .{
            .flags_one = 0,
            .flags_two = 0,
        };
    }

    pub fn getFlag(self: *const EntityActorFlags, flag: ActorFlags) bool {
        const index = @intFromEnum(flag);
        if (index < 64) {
            return self.flags_one & (@as(i64, 1) << @intCast(index)) != 0;
        } else {
            return self.flags_two & (@as(i64, 1) << @intCast(index - 64)) != 0;
        }
    }

    pub fn setFlag(self: *EntityActorFlags, flag: ActorFlags, value: ?bool) void {
        const v = value orelse false;
        self.setFlagRaw(flag, v);
    }

    pub fn setFlags(self: *EntityActorFlags, flags: []const struct { flag: ActorFlags, value: bool }) void {
        for (flags) |item| {
            std.log.info("[EntityActorFlags] setFlag {s} = {}", .{ @tagName(item.flag), item.value });
            self.setFlagRaw(item.flag, item.value);
        }
    }

    pub fn clearAll(self: *EntityActorFlags) void {
        self.flags_one = 0;
        self.flags_two = 0;
    }

    pub fn buildDataItems(self: *const EntityActorFlags, allocator: std.mem.Allocator, size: ?Size) ![]Protocol.DataItem {
        const data = try allocator.alloc(Protocol.DataItem, if (size == null) 3 else 5);
        data[0] = Protocol.DataItem.init(ActorDataId.Flags, .Long, .{ .Long = self.flags_one });
        data[1] = Protocol.DataItem.init(ActorDataId.FlagsTwo, .Long, .{ .Long = self.flags_two });
        data[2] = Protocol.DataItem.initFloat(ActorDataId.Scale, 1.0);
        if (size) |value| {
            data[3] = Protocol.DataItem.initFloat(ActorDataId.Width, value.width);
            data[4] = Protocol.DataItem.initFloat(ActorDataId.Height, value.height);
        }
        return data;
    }

    fn setFlagRaw(self: *EntityActorFlags, flag: ActorFlags, value: bool) void {
        const index = @intFromEnum(flag);
        if (index < 64) {
            const mask = @as(i64, 1) << @intCast(index);
            if (value) {
                self.flags_one |= mask;
            } else {
                self.flags_one &= ~mask;
            }
        } else {
            const mask = @as(i64, 1) << @intCast(index - 64);
            if (value) {
                self.flags_two |= mask;
            } else {
                self.flags_two &= ~mask;
            }
        }
    }
};

test "the actor data only carries the collision box when it is given" {
    var flags = EntityActorFlags.init();

    const without = try flags.buildDataItems(testing.allocator, null);
    defer testing.allocator.free(without);
    try testing.expectEqual(@as(usize, 3), without.len);

    const with = try flags.buildDataItems(testing.allocator, .{ .width = 0.6, .height = 0.6 });
    defer testing.allocator.free(with);
    try testing.expectEqual(@as(usize, 5), with.len);
    try testing.expectEqual(ActorDataId.Width, with[3].id);
    try testing.expectEqual(@as(f32, 0.6), with[3].value.Float);
    try testing.expectEqual(ActorDataId.Height, with[4].id);
    try testing.expectEqual(@as(f32, 0.6), with[4].value.Float);
}
