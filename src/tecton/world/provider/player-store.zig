const std = @import("std");

const LevelDB = @import("leveldb");

const Player = @import("../../player/player.zig").Player;
const persistence = @import("./persistence.zig");
const serialization = @import("./serialization.zig");
const LevelDBProvider = @import("./leveldb-provider.zig").LevelDBProvider;

pub fn writePlayer(provider: *LevelDBProvider, uuid: []const u8, player: *Player) !void {
    var tag = try serialization.serializePlayer(provider.allocator, player);
    defer tag.deinit(provider.allocator);
    const data = try serialization.encodeNbt(provider.allocator, &tag);
    defer provider.allocator.free(data);
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "player_server_{s}", .{uuid}) catch return;
    var record = persistence.Record{};
    errdefer record.deinit(provider.allocator);
    try record.addPut(provider.allocator, key, data);
    provider.dispatchOrdered(record);
}

pub fn readPlayer(provider: *LevelDBProvider, uuid: []const u8, player: *Player) !bool {
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "player_server_{s}", .{uuid}) catch return false;
    const data = provider.db.get(key) orelse return false;
    defer LevelDB.DB.freeValue(data);
    var tag = serialization.decodeNbt(provider.allocator, data) catch return false;
    defer tag.deinit(provider.allocator);
    serialization.deserializePlayer(provider.allocator, player, &tag);
    return true;
}
