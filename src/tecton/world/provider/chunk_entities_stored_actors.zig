const std = @import("std");

const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const LongTag = NBT.LongTag;
const IntTag = NBT.IntTag;
const FloatTag = NBT.FloatTag;
const StringTag = NBT.StringTag;

const key_mod = @import("./leveldb_keys.zig");
const serialization = @import("./serialization.zig");

// The provider is generic so this test-only file stays outside the provider cycle.
pub fn putStoredActor(provider: anytype, uid: i64, identifier: []const u8, fire_ticks: i32, health: ?f32) !void {
    const allocator = provider.allocator;
    var tag = CompoundTag.init(allocator, null);
    defer tag.deinit(allocator);
    try tag.set("identifier", .{ .String = StringTag.init(try allocator.dupe(u8, identifier), null) });
    try tag.set("UniqueID", .{ .Long = LongTag.init(uid, null) });
    if (fire_ticks > 0) try tag.set("FireTicks", .{ .Int = IntTag.init(fire_ticks, null) });
    if (health) |value| {
        try tag.set("Health", .{ .Float = FloatTag.init(value, null) });
        try tag.set("MaxHealth", .{ .Float = FloatTag.init(20.0, null) });
    }
    const data = try serialization.encodeNbt(allocator, &tag);
    defer allocator.free(data);
    const key = key_mod.actorKey(uid);
    try provider.db.put(key.slice(), data);
}

pub fn putStoredActorWithPosition(provider: anytype, uid: i64, identifier: []const u8, x: f32, y: f32, z: f32) !void {
    const allocator = provider.allocator;
    var tag = CompoundTag.init(allocator, null);
    defer tag.deinit(allocator);

    try tag.set("identifier", .{ .String = StringTag.init(try allocator.dupe(u8, identifier), null) });
    try tag.set("UniqueID", .{ .Long = LongTag.init(uid, null) });

    const pos = try allocator.alloc(NBT.Tag, 3);
    pos[0] = .{ .Float = FloatTag.init(x, null) };
    pos[1] = .{ .Float = FloatTag.init(y, null) };
    pos[2] = .{ .Float = FloatTag.init(z, null) };

    try tag.set("Pos", .{ .List = NBT.ListTag.init(pos, null) });
    const data = try serialization.encodeNbt(allocator, &tag);
    defer allocator.free(data);

    const key = key_mod.actorKey(uid);
    try provider.db.put(key.slice(), data);
}

pub fn putStoredDigest(provider: anytype, dim_index: i32, x: i32, z: i32, uids: []const i64) !void {
    const allocator = provider.allocator;
    const digest = try allocator.alloc(u8, uids.len * 8);
    defer allocator.free(digest);
    for (uids, 0..) |uid, i| {
        const bytes: [8]u8 = @bitCast(std.mem.nativeToLittle(i64, uid));
        @memcpy(digest[i * 8 .. (i + 1) * 8], &bytes);
    }
    const key = key_mod.digpKey(x, z, dim_index);
    try provider.db.put(key.slice(), digest);
}
