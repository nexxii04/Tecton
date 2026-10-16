const std = @import("std");

const Dimension = @import("../dimension/dimension.zig").Dimension;

pub const TAG_SUBCHUNK_PREFIX: u8 = 47;
pub const TAG_VERSION: u8 = 44;
pub const TAG_VERSION_OLD: u8 = 118;
pub const TAG_BLOCK_ENTITY: u8 = 49;

pub fn dimensionIndex(dimension: *Dimension) i32 {
    return switch (dimension.dimension_type) {
        .Overworld => 0,
        .Nether => 1,
        .End => 2,
    };
}

pub fn chunkKeyBase(x: i32, z: i32, dim_index: i32) struct { buf: [12]u8, len: usize } {
    var buf: [12]u8 = undefined;
    @memcpy(buf[0..4], &@as([4]u8, @bitCast(std.mem.nativeToLittle(i32, x))));
    @memcpy(buf[4..8], &@as([4]u8, @bitCast(std.mem.nativeToLittle(i32, z))));
    if (dim_index != 0) {
        @memcpy(buf[8..12], &@as([4]u8, @bitCast(std.mem.nativeToLittle(i32, dim_index))));
        return .{ .buf = buf, .len = 12 };
    }
    return .{ .buf = buf, .len = 8 };
}

pub const KeyBuf = struct {
    buf: [20]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const KeyBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn subchunkKey(x: i32, z: i32, index: i8, dim_index: i32) KeyBuf {
    var key = KeyBuf{};
    const base = chunkKeyBase(x, z, dim_index);
    @memcpy(key.buf[0..base.len], base.buf[0..base.len]);
    key.buf[base.len] = TAG_SUBCHUNK_PREFIX;
    key.buf[base.len + 1] = @bitCast(index);
    key.len = base.len + 2;
    return key;
}

pub fn versionKey(x: i32, z: i32, dim_index: i32) KeyBuf {
    var key = KeyBuf{};
    const base = chunkKeyBase(x, z, dim_index);
    @memcpy(key.buf[0..base.len], base.buf[0..base.len]);
    key.buf[base.len] = TAG_VERSION;
    key.len = base.len + 1;
    return key;
}

pub fn versionKeyOld(x: i32, z: i32, dim_index: i32) KeyBuf {
    var key = KeyBuf{};
    const base = chunkKeyBase(x, z, dim_index);
    @memcpy(key.buf[0..base.len], base.buf[0..base.len]);
    key.buf[base.len] = TAG_VERSION_OLD;
    key.len = base.len + 1;
    return key;
}

pub fn blockEntityKey(x: i32, z: i32, dim_index: i32) KeyBuf {
    var key = KeyBuf{};
    const base = chunkKeyBase(x, z, dim_index);
    @memcpy(key.buf[0..base.len], base.buf[0..base.len]);
    key.buf[base.len] = TAG_BLOCK_ENTITY;
    key.len = base.len + 1;
    return key;
}

pub fn actorKey(unique_id: i64) KeyBuf {
    var key = KeyBuf{};
    @memcpy(key.buf[0..11], "actorprefix");
    @memcpy(key.buf[11..19], &@as([8]u8, @bitCast(std.mem.nativeToLittle(i64, unique_id))));
    key.len = 19;
    return key;
}

pub fn digpKey(x: i32, z: i32, dim_index: i32) KeyBuf {
    var key = KeyBuf{};
    @memcpy(key.buf[0..4], "digp");
    if (dim_index != 0) {
        @memcpy(key.buf[4..8], &@as([4]u8, @bitCast(std.mem.nativeToLittle(i32, dim_index))));
        @memcpy(key.buf[8..12], &@as([4]u8, @bitCast(std.mem.nativeToLittle(i32, x))));
        @memcpy(key.buf[12..16], &@as([4]u8, @bitCast(std.mem.nativeToLittle(i32, z))));
        key.len = 16;
    } else {
        @memcpy(key.buf[4..8], &@as([4]u8, @bitCast(std.mem.nativeToLittle(i32, x))));
        @memcpy(key.buf[8..12], &@as([4]u8, @bitCast(std.mem.nativeToLittle(i32, z))));
        key.len = 12;
    }
    return key;
}
