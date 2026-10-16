const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const ReadWriteOptions = NBT.ReadWriteOptions;

pub fn encodeNbt(allocator: std.mem.Allocator, tag: *const CompoundTag) ![]const u8 {
    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();
    try CompoundTag.write(&stream, tag, ReadWriteOptions.default);
    return try allocator.dupe(u8, stream.getBuffer());
}

pub fn decodeNbt(allocator: std.mem.Allocator, data: []const u8) !CompoundTag {
    var stream = BinaryStream.init(allocator, data, null);
    defer stream.deinit();
    return try CompoundTag.read(&stream, allocator, ReadWriteOptions.default);
}

pub fn copyCompound(allocator: std.mem.Allocator, src: *const CompoundTag) !CompoundTag {
    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();
    try CompoundTag.write(&stream, src, ReadWriteOptions.default);
    var read_stream = BinaryStream.init(allocator, stream.getBuffer(), null);
    defer read_stream.deinit();
    return try CompoundTag.read(&read_stream, allocator, ReadWriteOptions.default);
}
