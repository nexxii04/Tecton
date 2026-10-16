const std = @import("std");

pub const BlockStateValue = union(enum) {
    boolean: bool,
    integer: i32,
    string: []const u8,

    pub fn eql(self: BlockStateValue, other: BlockStateValue) bool {
        return switch (self) {
            .boolean => |b| if (other == .boolean) b == other.boolean else false,
            .integer => |i| if (other == .integer) i == other.integer else false,
            .string => |s| if (other == .string) std.mem.eql(u8, s, other.string) else false,
        };
    }
};

pub const BlockState = std.StringHashMap(BlockStateValue);
